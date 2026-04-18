const std = @import("std");
const i18n = @import("i18n.zig");
const output = @import("output.zig");
const terminal = @import("terminal.zig");
const sites = @import("sites.zig");
const main_mod = @import("main.zig");

pub const SiteType = sites.SiteType;

pub const AddArgs = struct {
    alias: []const u8,
    site_type: ?SiteType = null,
    base_url: ?[]const u8 = null,
    api_key: ?[]const u8 = null,
    model: ?[]const u8 = null,
};

pub const EditArgs = struct {
    alias: []const u8,
};

pub const DelArgs = struct {
    alias: []const u8,
};

pub const ListArgs = struct {
    show_all: bool = false,
    global_check: bool = false, // -g flag for global check including archived
    sort_mode: ?sites.SortMode = null, // CLI override for sort mode
};

pub const UseArgs = struct {
    site_type: ?SiteType, // null means auto-detect from stored site
    alias: []const u8,
    model: ?[]const u8 = null,
};

pub const SetArgs = struct {
    key: []const u8,
    value: []const u8,
};

pub const ModelsArgs = struct {
    alias: []const u8,
};

pub const TestArgs = struct {
    alias: ?[]const u8 = null,
    perf: bool = false,
};

pub const Command = union(enum) {
    add: AddArgs,
    edit: EditArgs,
    del: DelArgs,
    list: ListArgs,
    use: UseArgs,
    set: SetArgs,
    models: ModelsArgs,
    model_test: TestArgs,
    install,
    uninstall,
    update_check, // --update: check and apply update
    help,
    version,
};

pub const Config = struct {
    language: i18n.Language = .en,
    command: Command,
};

pub const ParseError = error{
    HelpRequested,
    VersionRequested,
    InvalidArgument,
    OutOfMemory,
};

pub fn parseArgs(_: std.mem.Allocator) ParseError!Config {
    // Use page_allocator for args to avoid debug leak reports.
    // These tiny allocations live for the entire program lifetime anyway.
    const alloc = std.heap.page_allocator;
    var raw_args = std.process.argsWithAllocator(alloc) catch return error.OutOfMemory;
    // Do not deinit: returned Config holds slices into the args buffer.
    // page_allocator is not tracked by DebugAllocator so no leak reports.

    _ = raw_args.skip(); // skip program name

    // Collect all args into a buffer. Since we use page_allocator for the
    // args iterator, the slices remain valid without explicit duping.
    var args_buf: [32][]const u8 = undefined;
    var arg_count: usize = 0;
    while (raw_args.next()) |arg| {
        if (arg_count >= 32) break;
        args_buf[arg_count] = arg;
        arg_count += 1;
    }
    const args = args_buf[0..arg_count];

    // First pass: extract -l/--lang
    var lang_override: ?i18n.Language = null;
    for (0..args.len) |i| {
        if ((eql(args[i], "-l") or eql(args[i], "--lang")) and i + 1 < args.len) {
            lang_override = parseLang(args[i + 1]);
        }
    }

    const lang = lang_override orelse i18n.detect();

    // No args -> show help
    if (arg_count == 0) {
        printHelp(lang);
        return error.HelpRequested;
    }

    // Second pass: parse subcommand (skip -l/--lang and its value)
    var cmd_args: [32][]const u8 = undefined;
    var cmd_count: usize = 0;
    {
        var i: usize = 0;
        while (i < args.len) : (i += 1) {
            if (eql(args[i], "-l") or eql(args[i], "--lang")) {
                i += 1; // skip value
                continue;
            }
            if (cmd_count < 32) {
                cmd_args[cmd_count] = args[i];
                cmd_count += 1;
            }
        }
    }

    if (cmd_count == 0) {
        printHelp(lang);
        return error.HelpRequested;
    }

    const sub = cmd_args[0];
    const rest = cmd_args[1..cmd_count];

    var config: Config = .{ .language = lang, .command = .help };

    if (eql(sub, "-h") or eql(sub, "--help") or eql(sub, "help")) {
        // `velora help examples` / `velora --help examples` → only the examples section
        if (rest.len > 0 and (eql(rest[0], "examples") or eql(rest[0], "example") or eql(rest[0], "ex"))) {
            printExamples(lang);
            return error.HelpRequested;
        }
        printHelp(lang);
        return error.HelpRequested;
    } else if (eql(sub, "--examples") or eql(sub, "examples")) {
        printExamples(lang);
        return error.HelpRequested;
    } else if (eql(sub, "-v") or eql(sub, "--version") or eql(sub, "version")) {
        config.command = .version;
    } else if (eql(sub, "add")) {
        if (rest.len > 0 and isHelpArg(rest[0])) {
            printHelp(lang);
            return error.HelpRequested;
        }
        config.command = try parseAdd(rest);
    } else if (eql(sub, "edit")) {
        if (rest.len > 0 and isHelpArg(rest[0])) {
            printHelp(lang);
            return error.HelpRequested;
        }
        if (rest.len < 1) return error.InvalidArgument;
        config.command = .{ .edit = .{ .alias = rest[0] } };
    } else if (eql(sub, "del") or eql(sub, "rm") or eql(sub, "remove") or eql(sub, "delete")) {
        if (rest.len > 0 and isHelpArg(rest[0])) {
            printHelp(lang);
            return error.HelpRequested;
        }
        if (rest.len < 1) return error.InvalidArgument;
        config.command = .{ .del = .{ .alias = rest[0] } };
    } else if (eql(sub, "list") or eql(sub, "ls") or eql(sub, "ll")) {
        if (rest.len > 0 and isHelpArg(rest[0])) {
            printHelp(lang);
            return error.HelpRequested;
        }
        var show_all = false;
        var global_check = false;
        var sort_mode: ?sites.SortMode = null;
        var i_rest: usize = 0;
        while (i_rest < rest.len) : (i_rest += 1) {
            const arg = rest[i_rest];
            if (eql(arg, "all")) {
                show_all = true;
            } else if (eql(arg, "-g") or eql(arg, "--global")) {
                global_check = true;
            } else if (eql(arg, "-s") or eql(arg, "--sort")) {
                // -s <mode> or --sort <mode>
                if (i_rest + 1 < rest.len) {
                    sort_mode = sites.SortMode.fromString(rest[i_rest + 1]);
                    i_rest += 1;
                }
            } else if (std.mem.startsWith(u8, arg, "--sort=")) {
                // --sort=<mode>
                sort_mode = sites.SortMode.fromString(arg[7..]);
            }
        }
        config.command = .{ .list = .{ .show_all = show_all, .global_check = global_check, .sort_mode = sort_mode } };
    } else if (eql(sub, "cx") or eql(sub, "codex")) {
        if (rest.len > 0 and isHelpArg(rest[0])) {
            printHelp(lang);
            return error.HelpRequested;
        }
        config.command = try parseUse(.cx, rest);
    } else if (eql(sub, "cc") or eql(sub, "claude")) {
        if (rest.len > 0 and isHelpArg(rest[0])) {
            printHelp(lang);
            return error.HelpRequested;
        }
        config.command = try parseUse(.cc, rest);
    } else if (eql(sub, "oc") or eql(sub, "opencode")) {
        if (rest.len > 0 and isHelpArg(rest[0])) {
            printHelp(lang);
            return error.HelpRequested;
        }
        config.command = try parseUse(.oc, rest);
    } else if (eql(sub, "nb") or eql(sub, "nanobot")) {
        if (rest.len > 0 and isHelpArg(rest[0])) {
            printHelp(lang);
            return error.HelpRequested;
        }
        config.command = try parseUse(.nb, rest);
    } else if (eql(sub, "ow") or eql(sub, "openclaw")) {
        if (rest.len > 0 and isHelpArg(rest[0])) {
            printHelp(lang);
            return error.HelpRequested;
        }
        config.command = try parseUse(.ow, rest);
    } else if (eql(sub, "use")) {
        if (rest.len > 0 and isHelpArg(rest[0])) {
            printHelp(lang);
            return error.HelpRequested;
        }
        // velora use <alias> [model]  or  velora use <type> <alias> [model]
        if (rest.len < 1) return error.InvalidArgument;
        if (SiteType.fromString(rest[0])) |st| {
            if (rest.len < 2) return error.InvalidArgument;
            config.command = .{ .use = .{ .site_type = st, .alias = rest[1], .model = if (rest.len >= 3) rest[2] else null } };
        } else {
            // velora use <alias> [model] - auto-detect type from stored site
            config.command = .{ .use = .{ .site_type = null, .alias = rest[0], .model = if (rest.len >= 2) rest[1] else null } };
        }
    } else if (eql(sub, "set") or eql(sub, "s")) {
        if (rest.len > 0 and isHelpArg(rest[0])) {
            printHelp(lang);
            return error.HelpRequested;
        }
        // velora set <key> <value>  /  velora s mc off
        if (rest.len < 2) return error.InvalidArgument;
        config.command = .{ .set = .{ .key = expandSettingKey(rest[0]), .value = rest[1] } };
    } else if (eql(sub, "models") or eql(sub, "m")) {
        if (rest.len > 0 and isHelpArg(rest[0])) {
            printHelp(lang);
            return error.HelpRequested;
        }
        // velora models <alias>  /  velora m <alias>
        if (rest.len < 1) return error.InvalidArgument;
        config.command = .{ .models = .{ .alias = rest[0] } };
    } else if (eql(sub, "test") or eql(sub, "t")) {
        if (rest.len > 0 and isHelpArg(rest[0])) {
            printHelp(lang);
            return error.HelpRequested;
        }
        // velora test [alias] [-p|--perf]
        var args_out: TestArgs = .{};
        for (rest) |arg| {
            if (eql(arg, "-p") or eql(arg, "--perf") or eql(arg, "--bench")) {
                args_out.perf = true;
            } else if (args_out.alias == null) {
                args_out.alias = arg;
            }
        }
        config.command = .{ .model_test = args_out };
    } else if (eql(sub, "install") or eql(sub, "--install")) {
        config.command = .install;
    } else if (eql(sub, "uninstall") or eql(sub, "--uninstall") or eql(sub, "--del")) {
        config.command = .uninstall;
    } else if (eql(sub, "--update") or eql(sub, "update")) {
        config.command = .update_check;
    } else {
        return error.InvalidArgument;
    }

    return config;
}

fn parseAdd(rest: []const []const u8) ParseError!Command {
    if (rest.len == 0) return error.InvalidArgument;

    // Check if first arg is a type (cx/cc) -> direct mode: velora add<type> <alias> <url> <key> [model]
    if (SiteType.fromString(rest[0])) |st| {
        if (rest.len >= 4) {
            return .{ .add = .{
                .alias = rest[1],
                .site_type = st,
                .base_url = rest[2],
                .api_key = rest[3],
                .model = if (rest.len >= 5) rest[4] else null,
            } };
        }
        // velora add<type> <alias> -> interactive with type pre-set
        if (rest.len >= 2) {
            return .{ .add = .{
                .alias = rest[1],
                .site_type = st,
            } };
        }
        return error.InvalidArgument;
    }

    // velora add<alias> -> fully interactive
    return .{ .add = .{
        .alias = rest[0],
    } };
}

fn parseUse(st: SiteType, rest: []const []const u8) ParseError!Command {
    // veloracx use <alias> [model] or veloracx <alias> [model]
    if (rest.len >= 2 and eql(rest[0], "use")) {
        return .{ .use = .{ .site_type = st, .alias = rest[1], .model = if (rest.len >= 3) rest[2] else null } };
    }
    if (rest.len >= 1 and !eql(rest[0], "use")) {
        // veloracx <alias> [model] (shorthand)
        return .{ .use = .{ .site_type = st, .alias = rest[0], .model = if (rest.len >= 2) rest[1] else null } };
    }
    return error.InvalidArgument;
}

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

fn isHelpArg(s: []const u8) bool {
    return eql(s, "-h") or eql(s, "--help") or eql(s, "help");
}

fn parseLang(s: []const u8) ?i18n.Language {
    if (eql(s, "en")) return .en;
    if (eql(s, "zh")) return .zh;
    if (eql(s, "ja")) return .ja;
    return null;
}

fn expandSettingKey(s: []const u8) []const u8 {
    if (eql(s, "mc")) return "model_check";
    if (eql(s, "ll")) return "list_latency";
    if (eql(s, "aa")) return "auto_archive";
    if (eql(s, "ap")) return "auto_pick_compatible_model";
    if (eql(s, "ls") or eql(s, "sort")) return "list_sort";
    return s;
}

fn printHelp(lang: i18n.Language) void {
    var stdout_buffer: [8192]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
    const w = &stdout_writer.interface;
    const caps = terminal.TermCaps.detect();

    const cyan = if (caps.color) output.Color.miku_cyan else "";
    const accent = if (caps.color) output.Color.miku_accent else "";
    const gray = if (caps.color) output.Color.miku_gray else "";
    const reset = if (caps.color) output.Color.reset else "";

    const title = switch (lang) {
        .zh => "velora - 多站点 API Key 管理器",
        .ja => "velora - マルチサイト APIキー マネージャー",
        .en => "velora - Multi-Site API Key Manager",
    };

    const body = switch (lang) {
        .zh =>
        \\用法: velora <命令> [参数]
        \\
        \\命令:
        \\  add <别名>                         交互式添加站点
        \\  add <类型> <别名> <URL> <Key> [模型] 一次性添加站点 (类型: cx, cc, oc, nb, ow)
        \\  edit <别名>                        编辑站点配置
        \\  del <别名>                         删除站点
        \\  list                               显示站点列表（含连通性检测，并行）
        \\  list -g                            全局检测（含已归档站点）
        \\  list all                           显示详细站点信息
        \\  list --sort=<模式>                 排序: time, alpha, tool, model
        \\  use <别名> [模型]                  自动应用站点（根据类型）
        \\  use <类型> <别名> [模型]           应用站点到指定工具，可覆盖模型
        \\  cx use <别名> [模型]               应用站点到 Codex
        \\  cc use <别名> [模型]               应用站点到 Claude Code
        \\  oc use <别名> [模型]               应用站点到 OpenCode
        \\  nb use <别名> [模型]               应用站点到 Nanobot
        \\  ow use <别名> [模型]               应用站点到 OpenClaw
        \\  models|m <别名>                    浏览站点支持的全部模型
        \\  test|t [别名] [-p|--perf]          全自动检测模型调用 (--perf 进入性能基准测试,交互选择站点)
        \\  set|s <选项> <on/off|值>           设置选项开关
        \\  help examples                      显示完整用法示例
        \\
        \\设置选项 (缩写):
        \\  model_check (mc)                   模型检测 (默认: on)
        \\  list_latency (ll)                  列表延迟检测 (默认: on)
        \\  auto_archive (aa)                  自动归档不可用站点 (默认: off)
        \\  auto_pick_compatible_model (ap)    类型不匹配时自动选择兼容模型 (默认: on)
        \\  list_sort (ls)                     列表排序: time, alpha, tool, model (默认: time)
        \\
        \\类型:
        \\  cx    Codex (OPENAI_API_KEY)
        \\  cc    Claude Code (ANTHROPIC_AUTH_TOKEN)
        \\  oc    OpenCode (~/.config/opencode/opencode.json)
        \\  nb    Nanobot (~/.nanobot/config.json)
        \\  ow    OpenClaw (~/.openclaw/openclaw.json)
        \\
        \\选项:
        \\  -h, --help             显示帮助
        \\  --examples             显示完整用法示例
        \\  -v, --version          显示版本（检查更新）
        \\  --update               检查并自动更新
        \\  -l, --lang <LANG>      语言: en, zh, ja
        \\
        ,
        .ja =>
        \\使い方: velora <コマンド> [引数]
        \\
        \\コマンド:
        \\  add <エイリアス>                       サイトを対話式で追加
        \\  add <タイプ> <エイリアス> <URL> <Key> [モデル] サイトを一括で追加 (タイプ: cx, cc, oc, nb, ow)
        \\  edit <エイリアス>                      サイトの設定を編集
        \\  del <エイリアス>                       サイトを削除
        \\  list                                  サイト一覧表示（接続確認、並列）
        \\  list -g                               グローバル検出（アーカイブ含む）
        \\  list all                              サイト詳細表示
        \\  list --sort=<モード>                  ソート: time, alpha, tool, model
        \\  use <エイリアス> [モデル]              サイトを自動適用（タイプに基づく）
        \\  use <タイプ> <エイリアス> [モデル]     指定ツールに適用し、モデルを上書き可能
        \\  cx use <エイリアス> [モデル]           サイトをCodexに適用
        \\  cc use <エイリアス> [モデル]           サイトをClaude Codeに適用
        \\  oc use <エイリアス> [モデル]           サイトをOpenCodeに適用
        \\  nb use <エイリアス> [モデル]           サイトをNanobotに適用
        \\  ow use <エイリアス> [モデル]           サイトをOpenClawに適用
        \\  models|m <エイリアス>                  サイトの全モデルを表示
        \\  test|t [エイリアス] [-p|--perf]        モデル呼び出し自動検出 (--perf でベンチマーク・対話選択)
        \\  set|s <項目> <on/off|値>              設定の切り替え
        \\  help examples                         使用例の一覧を表示
        \\
        \\設定項目 (略称):
        \\  model_check (mc)                      モデル検出 (デフォルト: on)
        \\  list_latency (ll)                     リスト遅延チェック (デフォルト: on)
        \\  auto_archive (aa)                     不可用サイト自動アーカイブ (デフォルト: off)
        \\  auto_pick_compatible_model (ap)       タイプ不一致時に互換モデルを自動選択 (デフォルト: on)
        \\  list_sort (ls)                        リストソート: time, alpha, tool, model (デフォルト: time)
        \\
        \\タイプ:
        \\  cx    Codex (OPENAI_API_KEY)
        \\  cc    Claude Code (ANTHROPIC_AUTH_TOKEN)
        \\  oc    OpenCode (~/.config/opencode/opencode.json)
        \\  nb    Nanobot (~/.nanobot/config.json)
        \\  ow    OpenClaw (~/.openclaw/openclaw.json)
        \\
        \\オプション:
        \\  -h, --help             ヘルプを表示
        \\  --examples             使用例の一覧を表示
        \\  -v, --version          バージョンを表示（更新確認）
        \\  --update               更新を確認して適用
        \\  -l, --lang <LANG>      言語: en, zh, ja
        \\
        ,
        .en =>
        \\Usage: velora <command> [args]
        \\
        \\Commands:
        \\  add <alias>                        Add a site interactively
        \\  add <type> <alias> <url> <key> [model] Add a site directly (type: cx, cc, oc, nb, ow)
        \\  edit <alias>                       Edit site configuration
        \\  del <alias>                        Delete a site
        \\  list                               List sites with connectivity check (parallel)
        \\  list -g                            Global check (including archived)
        \\  list all                           List sites with full details
        \\  list --sort=<mode>                 Sort: time, alpha, tool, model
        \\  use <alias> [model]                Apply site config (auto-detect type)
        \\  use <type> <alias> [model]         Apply to a target tool and optionally override model
        \\  cx use <alias> [model]             Apply site config to Codex
        \\  cc use <alias> [model]             Apply site config to Claude Code
        \\  oc use <alias> [model]             Apply site config to OpenCode
        \\  nb use <alias> [model]             Apply site config to Nanobot
        \\  ow use <alias> [model]             Apply site config to OpenClaw
        \\  models|m <alias>                   Browse all models for a site
        \\  test|t [alias] [-p|--perf]         Auto-test model calls (--perf benchmark with interactive site selection)
        \\  set|s <option> <on/off|value>      Toggle settings
        \\  help examples                      Show full usage examples
        \\
        \\Settings (shorthand):
        \\  model_check (mc)                   Model detection on use (default: on)
        \\  list_latency (ll)                  Latency check on list (default: on)
        \\  auto_archive (aa)                  Auto-archive unreachable sites (default: off)
        \\  auto_pick_compatible_model (ap)    Auto-pick compatible model on type mismatch (default: on)
        \\  list_sort (ls)                     List sort: time, alpha, tool, model (default: time)
        \\
        \\Types:
        \\  cx    Codex (OPENAI_API_KEY)
        \\  cc    Claude Code (ANTHROPIC_AUTH_TOKEN)
        \\  oc    OpenCode (~/.config/opencode/opencode.json)
        \\  nb    Nanobot (~/.nanobot/config.json)
        \\  ow    OpenClaw (~/.openclaw/openclaw.json)
        \\
        \\Options:
        \\  -h, --help             Show help
        \\  --examples             Show full usage examples
        \\  -v, --version          Show version (checks for updates)
        \\  --update               Check and apply update
        \\  -l, --lang <LANG>      Language: en, zh, ja
        \\
        ,
    };

    const hint = switch (lang) {
        .zh => "提示: 运行 'velora help examples' 查看完整用法示例。",
        .ja => "ヒント: 'velora help examples' で全ての使用例を表示。",
        .en => "Tip: run 'velora help examples' to see all usage examples.",
    };

    w.print("{s}{s}{s} v{s}\n\n", .{ cyan, title, reset, main_mod.version }) catch {};
    w.print("{s}{s}{s}", .{ accent, body, reset }) catch {};
    w.print("{s}{s}{s}\n", .{ gray, hint, reset }) catch {};
    w.flush() catch {};
}

fn printExamples(lang: i18n.Language) void {
    var stdout_buffer: [8192]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
    const w = &stdout_writer.interface;
    const caps = terminal.TermCaps.detect();

    const cyan = if (caps.color) output.Color.miku_cyan else "";
    const accent = if (caps.color) output.Color.miku_accent else "";
    const reset = if (caps.color) output.Color.reset else "";

    const title = switch (lang) {
        .zh => "velora 用法示例",
        .ja => "velora 使用例",
        .en => "velora usage examples",
    };

    const body = switch (lang) {
        .zh =>
        \\添加 / 编辑 / 删除站点:
        \\  velora add openai                              # 交互式添加
        \\  velora add cx openai https://api.example.com/v1 sk-xxx
        \\  velora add cc claude https://api.example.com sk-ant claude-opus-4-6
        \\  velora edit openai                             # 编辑现有站点
        \\  velora del openai                              # 删除站点
        \\
        \\应用站点到工具:
        \\  velora use openai                              # 自动选默认工具
        \\  velora use cc openai claude-opus-4-6           # 指定目标工具+模型
        \\  velora cx use openai                           # 缩写: 应用到 Codex
        \\  velora cc use claude
        \\  velora oc use openai claude-haiku-4-5-20251001
        \\  velora nb use openai
        \\  velora ow use openai
        \\
        \\查看站点列表:
        \\  velora list                                    # 默认: 并行连通性检测 + [← 当前使用工具] 标签
        \\  velora list -g                                 # 含已归档站点
        \\  velora list all                                # 详细信息（base_url, key, model）
        \\  velora list --sort=alpha                       # 排序: time / alpha / tool / model
        \\  velora list -s tool
        \\
        \\模型调用测试 (新增):
        \\  velora t                                       # 并行测试所有站点的模型可调用性
        \\  velora t openai                                # 测试单个站点
        \\  velora t --perf                                # 性能基准测试 (交互式选择站点)
        \\
        \\浏览模型 / 设置:
        \\  velora m openai
        \\  velora s mc off                                # 关闭 use 时模型检测
        \\  velora s ll off                                # 关闭 list 时延迟检测
        \\  velora s aa on                                 # 开启自动归档
        \\  velora s ap off                                # 关闭类型不匹配时的自动兼容模型选择
        \\  velora s ls alpha                              # 默认列表排序按 alpha
        \\
        ,
        .ja =>
        \\サイトの追加 / 編集 / 削除:
        \\  velora add openai                              # 対話式で追加
        \\  velora add cx openai https://api.example.com/v1 sk-xxx
        \\  velora add cc claude https://api.example.com sk-ant claude-opus-4-6
        \\  velora edit openai                             # 既存サイトを編集
        \\  velora del openai                              # サイト削除
        \\
        \\ツールへ適用:
        \\  velora use openai                              # デフォルトツールへ自動適用
        \\  velora use cc openai claude-opus-4-6           # ツールとモデルを指定
        \\  velora cx use openai                           # 略記: Codex へ適用
        \\  velora cc use claude
        \\  velora oc use openai claude-haiku-4-5-20251001
        \\  velora nb use openai
        \\  velora ow use openai
        \\
        \\サイト一覧:
        \\  velora list                                    # 並列接続テスト + [← 使用中ツール] タグ
        \\  velora list -g                                 # アーカイブ済みも含む
        \\  velora list all                                # 詳細表示
        \\  velora list --sort=alpha                       # ソート: time / alpha / tool / model
        \\  velora list -s tool
        \\
        \\モデル呼び出しテスト (新機能):
        \\  velora t                                       # 全サイトのモデル呼び出しを並列検証
        \\  velora t openai                                # 単一サイトのテスト
        \\  velora t --perf                                # ベンチマーク (対話的にサイト選択)
        \\
        \\モデル一覧 / 設定:
        \\  velora m openai
        \\  velora s mc off                                # use 時のモデル検出を無効
        \\  velora s ll off                                # list 時の遅延チェックを無効
        \\  velora s aa on                                 # 自動アーカイブを有効
        \\  velora s ap off                                # 互換モデル自動選択を無効
        \\  velora s ls alpha                              # 既定ソートを alpha に
        \\
        ,
        .en =>
        \\Add / edit / remove sites:
        \\  velora add openai                              # interactive add
        \\  velora add cx openai https://api.example.com/v1 sk-xxx
        \\  velora add cc claude https://api.example.com sk-ant claude-opus-4-6
        \\  velora edit openai                             # edit an existing site
        \\  velora del openai                              # remove a site
        \\
        \\Apply a site to a tool:
        \\  velora use openai                              # auto-pick default tool
        \\  velora use cc openai claude-opus-4-6           # explicit tool + model override
        \\  velora cx use openai                           # short form: apply to Codex
        \\  velora cc use claude
        \\  velora oc use openai claude-haiku-4-5-20251001
        \\  velora nb use openai
        \\  velora ow use openai
        \\
        \\Listing sites:
        \\  velora list                                    # parallel reachability check + [← in-use] tag
        \\  velora list -g                                 # include archived sites
        \\  velora list all                                # full details (base_url, key, model)
        \\  velora list --sort=alpha                       # sort: time / alpha / tool / model
        \\  velora list -s tool
        \\
        \\Model call tests (new):
        \\  velora t                                       # test every site's model in parallel
        \\  velora t openai                                # single-site test
        \\  velora t --perf                                # interactive benchmark (multi-select)
        \\
        \\Browse models / settings:
        \\  velora m openai
        \\  velora s mc off                                # disable model detection on use
        \\  velora s ll off                                # disable latency check on list
        \\  velora s aa on                                 # enable auto-archive
        \\  velora s ap off                                # disable compatible-model auto-pick
        \\  velora s ls alpha                              # default list sort to alpha
        \\
        ,
    };

    w.print("{s}{s}{s} v{s}\n\n", .{ cyan, title, reset, main_mod.version }) catch {};
    w.print("{s}{s}{s}", .{ accent, body, reset }) catch {};
    w.flush() catch {};
}

fn printVersion(lang: i18n.Language) void {
    var stdout_buffer: [256]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
    const w = &stdout_writer.interface;

    switch (lang) {
        .zh => w.print("VELORAv{s} - 多站点 API Key 管理器\n", .{main_mod.version}) catch {},
        .ja => w.print("VELORAv{s} - マルチサイト APIキー マネージャー\n", .{main_mod.version}) catch {},
        .en => w.print("VELORAv{s} - Multi-Site API Key Manager\n", .{main_mod.version}) catch {},
    }
    w.flush() catch {};
}
