const std = @import("std");
const i18n = @import("i18n.zig");
const output = @import("output.zig");
const terminal = @import("terminal.zig");
const main_mod = @import("main.zig");

pub const Command = enum {
    sync,
    daemon,
    setup,
    background_sync,
    autostart_enable,
    autostart_disable,
    install,
    uninstall,
    status,
};

pub const Config = struct {
    language: i18n.Language = .en,
    command: Command = .sync,
    interval_minutes: u32 = 60,
};

pub const ParseError = error{
    HelpRequested,
    VersionRequested,
    InvalidArgument,
    OutOfMemory,
};

pub fn parseArgs(allocator: std.mem.Allocator) ParseError!Config {
    var config: Config = .{};
    var lang_override: ?i18n.Language = null;

    var args = std.process.argsWithAllocator(allocator) catch return error.OutOfMemory;
    defer args.deinit();

    _ = args.skip();

    while (args.next()) |arg| {
        if (eql(arg, "-h") or eql(arg, "--help")) {
            const lang = lang_override orelse i18n.detect();
            printHelp(lang);
            return error.HelpRequested;
        } else if (eql(arg, "-v") or eql(arg, "--version")) {
            const lang = lang_override orelse i18n.detect();
            printVersion(lang);
            return error.VersionRequested;
        } else if (eql(arg, "-l") or eql(arg, "--lang")) {
            if (args.next()) |val| lang_override = parseLang(val);
        } else if (eql(arg, "-d") or eql(arg, "--daemon")) {
            config.command = .daemon;
        } else if (eql(arg, "-i") or eql(arg, "--interval")) {
            if (args.next()) |val| {
                config.interval_minutes = @max(std.fmt.parseInt(u32, val, 10) catch 60, 1);
            }
        } else if (eql(arg, "--setup")) {
            config.command = .setup;
        } else if (eql(arg, "--background-sync")) {
            config.command = .background_sync;
        } else if (eql(arg, "--autostart")) {
            config.command = .autostart_enable;
        } else if (eql(arg, "--no-autostart")) {
            config.command = .autostart_disable;
        } else if (eql(arg, "--install")) {
            config.command = .install;
        } else if (eql(arg, "-del") or eql(arg, "--del") or eql(arg, "--uninstall")) {
            config.command = .uninstall;
        } else if (eql(arg, "--status")) {
            config.command = .status;
        } else if (std.mem.startsWith(u8, arg, "-")) {
            return error.InvalidArgument;
        }
    }

    config.language = lang_override orelse i18n.detect();
    return config;
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
        .zh => "velora - OpenAI API Key 编排器",
        .ja => "velora - OpenAI APIキー オーケストレーター",
        .en => "velora - OpenAI API Key Orchestrator",
    };

    const body = switch (lang) {
        .zh =>
            \\用法: velora [选项]
            \\
            \\选项:
            \\  -h, --help             显示帮助
            \\  -v, --version          显示版本
            \\  -l, --lang <LANG>      语言: en, zh, ja
            \\  -d, --daemon           前台守护模式运行
            \\  -i, --interval <N>     轮询间隔（分钟，默认 60）
            \\      --setup            进入配置向导
            \\      --autostart        启用系统自启动
            \\      --no-autostart     关闭系统自启动
            \\      --install          安装到用户目录并加入 PATH
            \\      --del, --uninstall 彻底卸载并清理配置与自启动
            \\      --status           显示当前状态
            \\
            \\示例:
            \\  velora --setup
            \\  velora
            \\  velora --autostart --interval 30
            \\  velora --install
            \\  velora --uninstall
            \\
        ,
        .ja =>
            \\使い方: velora [オプション]
            \\
            \\オプション:
            \\  -h, --help             ヘルプを表示
            \\  -v, --version          バージョンを表示
            \\  -l, --lang <LANG>      言語: en, zh, ja
            \\  -d, --daemon           フォアグラウンドで常駐実行
            \\  -i, --interval <N>     間隔（分、既定 60）
            \\      --setup            セットアップを開始
            \\      --autostart        自動起動を有効化
            \\      --no-autostart     自動起動を無効化
            \\      --install          ユーザー環境へインストールして PATH に追加
            \\      --del, --uninstall 完全アンインストール
            \\      --status           現在の状態を表示
            \\
            \\例:
            \\  velora --setup
            \\  velora
            \\  velora --autostart --interval 30
            \\  velora --install
            \\  velora --uninstall
            \\
        ,
        .en =>
            \\Usage: velora [options]
            \\
            \\Options:
            \\  -h, --help             Show help
            \\  -v, --version          Show version
            \\  -l, --lang <LANG>      Language: en, zh, ja
            \\  -d, --daemon           Run in foreground daemon mode
            \\  -i, --interval <N>     Poll interval in minutes (default: 60)
            \\      --setup            Start interactive setup
            \\      --autostart        Enable autostart
            \\      --no-autostart     Disable autostart
            \\      --install          Install to user space and add to PATH
            \\      --del, --uninstall Fully uninstall and clean app data
            \\      --status           Show current status
            \\
            \\Examples:
            \\  velora --setup
            \\  velora
            \\  velora --autostart --interval 30
            \\  velora --install
            \\  velora --uninstall
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
        .zh => w.print("Velora v{s} - OpenAI API Key 编排器\n", .{main_mod.version}) catch {},
        .ja => w.print("Velora v{s} - OpenAI APIキー オーケストレーター\n", .{main_mod.version}) catch {},
        .en => w.print("Velora v{s} - OpenAI API Key Orchestrator\n", .{main_mod.version}) catch {},
    }
    w.flush() catch {};
}
