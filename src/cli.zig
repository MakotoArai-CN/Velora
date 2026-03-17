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
};

pub const EditArgs = struct {
    alias: []const u8,
};

pub const DelArgs = struct {
    alias: []const u8,
};

pub const ListArgs = struct {
    show_all: bool = false,
};

pub const UseArgs = struct {
    site_type: SiteType,
    alias: []const u8,
};

pub const Command = union(enum) {
    add: AddArgs,
    edit: EditArgs,
    del: DelArgs,
    list: ListArgs,
    use: UseArgs,
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
        printHelp(lang);
        return error.HelpRequested;
    } else if (eql(sub, "-v") or eql(sub, "--version") or eql(sub, "version")) {
        config.command = .version;
    } else if (eql(sub, "add")) {
        config.command = try parseAdd(rest);
    } else if (eql(sub, "edit")) {
        if (rest.len < 1) return error.InvalidArgument;
        config.command = .{ .edit = .{ .alias = rest[0] } };
    } else if (eql(sub, "del") or eql(sub, "rm") or eql(sub, "remove") or eql(sub, "delete")) {
        if (rest.len < 1) return error.InvalidArgument;
        config.command = .{ .del = .{ .alias = rest[0] } };
    } else if (eql(sub, "list") or eql(sub, "ls")) {
        var show_all = false;
        if (rest.len > 0 and eql(rest[0], "all")) {
            show_all = true;
        }
        config.command = .{ .list = .{ .show_all = show_all } };
    } else if (eql(sub, "cx") or eql(sub, "codex")) {
        config.command = try parseUse(.cx, rest);
    } else if (eql(sub, "cc") or eql(sub, "claude")) {
        config.command = try parseUse(.cc, rest);
    } else if (eql(sub, "oc") or eql(sub, "opencode")) {
        config.command = try parseUse(.oc, rest);
    } else if (eql(sub, "use")) {
        // velorause cx <alias> or velorause cc <alias>
        if (rest.len < 2) return error.InvalidArgument;
        const st = SiteType.fromString(rest[0]) orelse return error.InvalidArgument;
        config.command = .{ .use = .{ .site_type = st, .alias = rest[1] } };
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

    // Check if first arg is a type (cx/cc) -> direct mode: velora add<type> <alias> <url> <key>
    if (SiteType.fromString(rest[0])) |st| {
        if (rest.len >= 4) {
            return .{ .add = .{
                .alias = rest[1],
                .site_type = st,
                .base_url = rest[2],
                .api_key = rest[3],
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
    // veloracx use <alias> or veloracx <alias>
    if (rest.len >= 2 and eql(rest[0], "use")) {
        return .{ .use = .{ .site_type = st, .alias = rest[1] } };
    }
    if (rest.len >= 1 and !eql(rest[0], "use")) {
        // veloracx <alias> (shorthand)
        return .{ .use = .{ .site_type = st, .alias = rest[0] } };
    }
    return error.InvalidArgument;
}

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

fn parseLang(s: []const u8) ?i18n.Language {
    if (eql(s, "en")) return .en;
    if (eql(s, "zh")) return .zh;
    if (eql(s, "ja")) return .ja;
    return null;
}

fn printHelp(lang: i18n.Language) void {
    var stdout_buffer: [8192]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
    const w = &stdout_writer.interface;
    const caps = terminal.TermCaps.detect();

    const cyan = if (caps.color) output.Color.miku_cyan else "";
    const accent = if (caps.color) output.Color.miku_accent else "";
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
        \\  add <类型> <别名> <URL> <Key>      一次性添加站点 (类型: cx, cc)
        \\  edit <别名>                        编辑站点配置
        \\  del <别名>                         删除站点
        \\  list                               显示站点列表（含连通性检测）
        \\  list all                           显示详细站点信息
        \\  cx use <别名>                      应用站点到 Codex
        \\  cc use <别名>                      应用站点到 Claude Code
        \\  oc use <别名>                      应用站点到 OpenCode
        \\
        \\类型:
        \\  cx    Codex (OPENAI_API_KEY)
        \\  cc    Claude Code (ANTHROPIC_AUTH_TOKEN)
        \\  oc    OpenCode (~/.config/opencode/opencode.json)
        \\
        \\选项:
        \\  -h, --help             显示帮助
        \\  -v, --version          显示版本（检查更新）
        \\  --update               检查并自动更新
        \\  -l, --lang <LANG>      语言: en, zh, ja
        \\
        \\示例:
        \\  velora add openai
        \\  velora add cx openai https://api.example.com/v1 sk-xxx
        \\  velora cx use openai
        \\  velora cc use claude
        \\  velora oc use openai
        \\  velora list
        \\  velora list all
        \\  velora edit openai
        \\  velora del openai
        \\
        ,
        .ja =>
        \\使い方: velora <コマンド> [引数]
        \\
        \\コマンド:
        \\  add <エイリアス>                       サイトを対話式で追加
        \\  add <タイプ> <エイリアス> <URL> <Key>  サイトを一括で追加 (タイプ: cx, cc)
        \\  edit <エイリアス>                      サイトの設定を編集
        \\  del <エイリアス>                       サイトを削除
        \\  list                                  サイト一覧表示（接続確認付き）
        \\  list all                              サイト詳細表示
        \\  cx use <エイリアス>                    サイトをCodexに適用
        \\  cc use <エイリアス>                    サイトをClaude Codeに適用
        \\
        \\タイプ:
        \\  cx    Codex (OPENAI_API_KEY)
        \\  cc    Claude Code (ANTHROPIC_AUTH_TOKEN)
        \\
        \\オプション:
        \\  -h, --help             ヘルプを表示
        \\  -v, --version          バージョンを表示
        \\  -l, --lang <LANG>      言語: en, zh, ja
        \\
        \\例:
        \\  velora add openai
        \\  velora add cx openai https://api.example.com/v1 sk-xxx
        \\  velora cx use openai
        \\  velora cc use claude
        \\  velora list
        \\  velora list all
        \\  velora edit openai
        \\  velora del openai
        \\
        ,
        .en =>
        \\Usage: velora <command> [args]
        \\
        \\Commands:
        \\  add <alias>                        Add a site interactively
        \\  add <type> <alias> <url> <key>     Add a site directly (type: cx, cc)
        \\  edit <alias>                       Edit site configuration
        \\  del <alias>                        Delete a site
        \\  list                               List sites with connectivity check
        \\  list all                           List sites with full details
        \\  cx use <alias>                     Apply site config to Codex
        \\  cc use <alias>                     Apply site config to Claude Code
        \\  oc use <alias>                     Apply site config to OpenCode
        \\
        \\Types:
        \\  cx    Codex (OPENAI_API_KEY)
        \\  cc    Claude Code (ANTHROPIC_AUTH_TOKEN)
        \\  oc    OpenCode (~/.config/opencode/opencode.json)
        \\
        \\Options:
        \\  -h, --help             Show help
        \\  -v, --version          Show version (checks for updates)
        \\  --update               Check and apply update
        \\  -l, --lang <LANG>      Language: en, zh, ja
        \\
        \\Examples:
        \\  velora add openai
        \\  velora add cx openai https://api.example.com/v1 sk-xxx
        \\  velora cx use openai
        \\  velora cc use claude
        \\  velora oc use openai
        \\  velora list
        \\  velora list all
        \\  velora edit openai
        \\  velora del openai
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
