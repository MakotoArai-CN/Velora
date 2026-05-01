const std = @import("std");
const i18n = @import("i18n.zig");
const output = @import("output.zig");
const terminal = @import("terminal.zig");
const sites = @import("sites.zig");
const io_compat = @import("io_compat.zig");
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

pub const CcsArgs = struct {
    path: ?[]const u8 = null,
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
    import_ccs: CcsArgs,
    export_ccs: CcsArgs,
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

pub fn parseArgs(_: std.mem.Allocator, raw_argv: []const [:0]const u8) ParseError!Config {
    // Caller (main) supplies argv from `init.minimal.args.toSlice(arena)`.
    // Skip argv[0] (program name).
    const args_slice: []const [:0]const u8 = if (raw_argv.len > 0) raw_argv[1..] else raw_argv;

    // Collect all args into a buffer.
    var args_buf: [32][]const u8 = undefined;
    var arg_count: usize = 0;
    for (args_slice) |arg| {
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
    } else if (eql(sub, "import")) {
        if (containsHelpArg(rest)) {
            printHelp(lang);
            return error.HelpRequested;
        }
        if (rest.len < 1 or !isCcsFormat(rest[0])) return error.InvalidArgument;
        config.command = .{ .import_ccs = .{ .path = if (rest.len >= 2) rest[1] else null } };
    } else if (eql(sub, "export")) {
        if (containsHelpArg(rest)) {
            printHelp(lang);
            return error.HelpRequested;
        }
        if (rest.len < 1 or !isCcsFormat(rest[0])) return error.InvalidArgument;
        config.command = .{ .export_ccs = .{ .path = if (rest.len >= 2) rest[1] else null } };
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

fn containsHelpArg(args: []const []const u8) bool {
    for (args) |arg| {
        if (isHelpArg(arg)) return true;
    }
    return false;
}

fn isCcsFormat(s: []const u8) bool {
    return eql(s, "ccs") or eql(s, "cc-switch") or eql(s, "ccswitch");
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
    if (eql(s, "alm") or eql(s, "am")) return "auto_load_models";
    if (eql(s, "ls") or eql(s, "sort")) return "list_sort";
    if (eql(s, "msm") or eql(s, "select")) return "model_select_mode";
    if (eql(s, "mt") or eql(s, "timeout")) return "model_call_timeout_ms";
    return s;
}

fn printHelp(lang: i18n.Language) void {
    var stdout_buffer: [8192]u8 = undefined;
    var stdout_writer: std.Io.File.Writer = undefined;
    const w = io_compat.stdoutWriter(&stdout_buffer, &stdout_writer);
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
        \\站点:
        \\  add <别名>
        \\  add <类型> <别名> <URL> <Key> [模型]
        \\  edit <别名>
        \\  del <别名>
        \\  list [all|-g|--sort=<time|alpha|tool|model>]
        \\
        \\应用:
        \\  use <别名> [模型]
        \\  use <类型> <别名> [模型]
        \\  cx|cc|oc|nb|ow <别名> [模型]
        \\
        \\工具:
        \\  models <别名>
        \\  test [别名] [-p|--perf]
        \\  import ccs [配置文件]
        \\  export ccs [配置文件或目录]
        \\  set <选项> <on|off|值>
        \\
        \\类型: cx Codex, cc Claude Code, oc OpenCode, nb Nanobot, ow OpenClaw
        \\选项: -l/--lang <en|zh|ja>, -v/--version, --update, -h/--help
        \\
        ,
        .ja =>
        \\使い方: velora <コマンド> [引数]
        \\
        \\サイト:
        \\  add <エイリアス>
        \\  add <タイプ> <エイリアス> <URL> <Key> [モデル]
        \\  edit <エイリアス>
        \\  del <エイリアス>
        \\  list [all|-g|--sort=<time|alpha|tool|model>]
        \\
        \\適用:
        \\  use <エイリアス> [モデル]
        \\  use <タイプ> <エイリアス> [モデル]
        \\  cx|cc|oc|nb|ow <エイリアス> [モデル]
        \\
        \\ツール:
        \\  models <エイリアス>
        \\  test [エイリアス] [-p|--perf]
        \\  import ccs [設定ファイル]
        \\  export ccs [設定ファイルまたはディレクトリ]
        \\  set <項目> <on|off|値>
        \\
        \\タイプ: cx Codex, cc Claude Code, oc OpenCode, nb Nanobot, ow OpenClaw
        \\オプション: -l/--lang <en|zh|ja>, -v/--version, --update, -h/--help
        \\
        ,
        .en =>
        \\Usage: velora <command> [args]
        \\
        \\Sites:
        \\  add <alias>
        \\  add <type> <alias> <url> <key> [model]
        \\  edit <alias>
        \\  del <alias>
        \\  list [all|-g|--sort=<time|alpha|tool|model>]
        \\
        \\Apply:
        \\  use <alias> [model]
        \\  use <type> <alias> [model]
        \\  cx|cc|oc|nb|ow <alias> [model]
        \\
        \\Tools:
        \\  models <alias>
        \\  test [alias] [-p|--perf]
        \\  import ccs [config-file]
        \\  export ccs [config-file-or-dir]
        \\  set <option> <on|off|value>
        \\
        \\Types: cx Codex, cc Claude Code, oc OpenCode, nb Nanobot, ow OpenClaw
        \\Options: -l/--lang <en|zh|ja>, -v/--version, --update, -h/--help
        \\
        ,
    };

    const hint = switch (lang) {
        .zh => "完整说明见 README.md。",
        .ja => "詳細は README.md を参照してください。",
        .en => "See README.md for full documentation.",
    };

    w.print("{s}{s}{s} v{s}\n\n", .{ cyan, title, reset, main_mod.version }) catch {};
    w.print("{s}{s}{s}", .{ accent, body, reset }) catch {};
    w.print("{s}{s}{s}\n", .{ gray, hint, reset }) catch {};
    w.flush() catch {};
}

fn printExamples(lang: i18n.Language) void {
    var stdout_buffer: [8192]u8 = undefined;
    var stdout_writer: std.Io.File.Writer = undefined;
    const w = io_compat.stdoutWriter(&stdout_buffer, &stdout_writer);
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
        \\  velora s alm off                               # 关闭添加/编辑时自动加载模型列表
        \\  velora s msm keyboard                          # 使用方向键选择模型
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
        \\  velora s alm off                               # 追加/編集時のモデル一覧自動取得を無効
        \\  velora s msm keyboard                          # 矢印キーでモデル選択
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
        \\  velora s alm off                               # disable model-list picker on add/edit
        \\  velora s msm keyboard                          # choose models with arrow keys
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
    var stdout_writer: std.Io.File.Writer = undefined;
    const w = io_compat.stdoutWriter(&stdout_buffer, &stdout_writer);

    switch (lang) {
        .zh => w.print("VELORAv{s} - 多站点 API Key 管理器\n", .{main_mod.version}) catch {},
        .ja => w.print("VELORAv{s} - マルチサイト APIキー マネージャー\n", .{main_mod.version}) catch {},
        .en => w.print("VELORAv{s} - Multi-Site API Key Manager\n", .{main_mod.version}) catch {},
    }
    w.flush() catch {};
}
