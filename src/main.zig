const std = @import("std");
const builtin = @import("builtin");
const cli = @import("cli.zig");
const output = @import("output.zig");
const terminal = @import("terminal.zig");
const i18n = @import("i18n.zig");
const config_mod = @import("config.zig");
const env = @import("env.zig");
const daemon = @import("daemon.zig");
const autostart = @import("autostart.zig");
const install_mod = @import("install.zig");
const http = @import("http.zig");

pub const version = "1.0.0";

pub fn main() !void {
    var gpa_impl: std.heap.DebugAllocator(.{}) = .init;
    const gpa, const is_debug = gpa: {
        break :gpa switch (builtin.mode) {
            .Debug, .ReleaseSafe => .{ gpa_impl.allocator(), true },
            .ReleaseFast, .ReleaseSmall => .{ std.heap.smp_allocator, false },
        };
    };
    defer if (is_debug) {
        _ = gpa_impl.deinit();
    };

    const config = cli.parseArgs(gpa) catch |err| {
        switch (err) {
            error.HelpRequested, error.VersionRequested => return,
            error.InvalidArgument => {
                var stderr_buffer: [512]u8 = undefined;
                var stderr_writer = std.fs.File.stderr().writer(&stderr_buffer);
                const w = &stderr_writer.interface;
                w.print("Unknown argument. Use --help for usage.\n", .{}) catch {};
                w.flush() catch {};
                return;
            },
            error.OutOfMemory => {
                var stderr_buffer: [512]u8 = undefined;
                var stderr_writer = std.fs.File.stderr().writer(&stderr_buffer);
                const w = &stderr_writer.interface;
                w.print("Out of memory.\n", .{}) catch {};
                w.flush() catch {};
                return;
            },
        }
    };

    var stdout_buffer: [8192]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
    var discard_buffer: [1]u8 = undefined;
    var discard_writer = std.Io.Writer.Discarding.init(&discard_buffer);
    const w: *std.Io.Writer = switch (config.command) {
        .background_sync => &discard_writer.writer,
        else => &stdout_writer.interface,
    };
    const caps = terminal.TermCaps.detect();
    const lang = config.language;

    if (config.command != .background_sync) {
        try output.printBanner(w, caps, version);
        try w.flush();
    }

    switch (config.command) {
        .setup => try runSetup(gpa, w, caps, lang, config.interval_minutes),
        .sync => try runSync(gpa, w, caps, lang),
        .daemon => try runDaemon(gpa, w, caps, lang, config.interval_minutes),
        .background_sync => try runBackgroundSync(gpa, lang),
        .autostart_enable => try runAutostartEnable(gpa, w, caps, lang, config.interval_minutes),
        .autostart_disable => try runAutostartDisable(gpa, w, caps, lang),
        .install => try runInstall(gpa, w, caps, lang),
        .uninstall => try runUninstall(gpa, w, caps, lang),
        .status => try runStatus(gpa, w, caps, lang),
    }
}

fn runSetup(allocator: std.mem.Allocator, w: *std.Io.Writer, caps: terminal.TermCaps, lang: i18n.Language, interval: u32) !void {
    _ = try configureInteractively(allocator, w, caps, lang, interval);

    try output.printSeparator(w, caps);
    try output.printInfo(w, i18n.tr(lang, "Running initial sync...", "正在执行首次同步...", "初回同期を実行中..."), caps);
    try w.flush();

    _ = daemon.runOnce(allocator, w, caps, lang) catch {};

    try output.printSeparator(w, caps);
    try w.flush();
}

fn configureInteractively(allocator: std.mem.Allocator, w: *std.Io.Writer, caps: terminal.TermCaps, lang: i18n.Language, interval: u32) !config_mod.BindingConfig {
    try output.printSectionHeader(w, i18n.tr(lang, "Setup", "配置向导", "セットアップ"), caps);

    try output.printInfo(w, i18n.tr(lang, "Where should OPENAI_API_KEY be stored?", "OPENAI_API_KEY应该存储在哪里？", "OPENAI_API_KEYをどこに保存しますか？"), caps);

    try output.printMenuItem(w, 1, i18n.tr(lang, "Environment variable (shell rc files / Windows registry)", "环境变量（shell配置文件 / Windows注册表）", "環境変数（シェル設定ファイル / Windowsレジストリ）"), caps);
    try output.printMenuItem(w, 2, i18n.tr(lang, config_mod.display_auth_json_path, config_mod.display_auth_json_path, config_mod.display_auth_json_path), caps);
    try output.printMenuItem(w, 3, i18n.tr(lang, config_mod.display_config_toml_path, config_mod.display_config_toml_path, config_mod.display_config_toml_path), caps);
    try output.printMenuItem(w, 4, i18n.tr(lang, "Auto-detect existing configuration", "自动检测已有配置", "既存設定を自動検出"), caps);

    try output.printPrompt(w, i18n.tr(lang, "Choose [1-4]:", "请选择 [1-4]:", "選択してください [1-4]:"), caps);
    try w.flush();

    var input_buf: [16]u8 = undefined;
    const input_len = std.fs.File.stdin().read(&input_buf) catch 0;
    const input = std.mem.trim(u8, input_buf[0..input_len], " \t\r\n");

    const location: config_mod.StorageLocation = blk: {
        if (std.mem.eql(u8, input, "1")) {
            break :blk .env;
        } else if (std.mem.eql(u8, input, "2")) {
            break :blk .auth_json;
        } else if (std.mem.eql(u8, input, "3")) {
            break :blk .config_toml;
        } else if (std.mem.eql(u8, input, "4")) {
            try output.printInfo(w, i18n.tr(lang, "Scanning for existing OPENAI_API_KEY...", "正在扫描已有的OPENAI_API_KEY...", "既存のOPENAI_API_KEYをスキャン中..."), caps);
            try w.flush();

            const detected = env.detectExistingLocation(allocator) catch null;
            if (detected) |loc| {
                const loc_name: []const u8 = switch (loc) {
                    .env => "Environment variable",
                    .auth_json => config_mod.display_auth_json_path,
                    .config_toml => config_mod.display_config_toml_path,
                };
                try output.printSuccess(w, loc_name, caps);
                try w.flush();
                break :blk loc;
            } else {
                try output.printWarning(w, i18n.tr(lang, "No existing config found, defaulting to environment variable", "未检测到已有配置，默认使用环境变量", "既存設定が見つかりません、環境変数をデフォルトにします"), caps);
                try w.flush();
                break :blk .env;
            }
        } else {
            try output.printWarning(w, i18n.tr(lang, "Invalid choice, defaulting to environment variable", "无效选择，默认使用环境变量", "無効な選択、環境変数をデフォルトにします"), caps);
            try w.flush();
            break :blk .env;
        }
    };

    const binding: config_mod.BindingConfig = .{
        .location = location,
        .interval_minutes = interval,
    };

    config_mod.saveBinding(allocator, binding) catch |err| {
        try output.printError(w, i18n.tr(lang, "Failed to save configuration", "保存配置失败", "設定の保存に失敗しました"), caps);
        try w.flush();
        return err;
    };

    try output.printSuccess(w, i18n.tr(lang, "Configuration saved", "配置已保存", "設定を保存しました"), caps);
    try w.flush();
    return binding;
}

fn tryAutoConfigure(allocator: std.mem.Allocator, interval: u32) !?config_mod.BindingConfig {
    const detected = try env.detectExistingLocation(allocator);
    const location = detected orelse return null;

    const binding: config_mod.BindingConfig = .{
        .location = location,
        .interval_minutes = interval,
    };
    try config_mod.saveBinding(allocator, binding);
    return binding;
}

fn ensureBindingInteractive(allocator: std.mem.Allocator, w: *std.Io.Writer, caps: terminal.TermCaps, lang: i18n.Language, interval: u32) !config_mod.BindingConfig {
    if (try config_mod.loadBinding(allocator)) |binding| {
        return binding;
    }

    if (try tryAutoConfigure(allocator, interval)) |binding| {
        return binding;
    }

    return try configureInteractively(allocator, w, caps, lang, interval);
}

fn ensureBindingSilently(allocator: std.mem.Allocator) !?config_mod.BindingConfig {
    if (try config_mod.loadBinding(allocator)) |binding| {
        return binding;
    }

    return try tryAutoConfigure(allocator, 60);
}

fn runSync(allocator: std.mem.Allocator, w: *std.Io.Writer, caps: terminal.TermCaps, lang: i18n.Language) !void {
    _ = try ensureBindingInteractive(allocator, w, caps, lang, 60);

    try output.printSectionHeader(w, i18n.tr(lang, "Sync", "同步", "同期"), caps);
    try w.flush();

    _ = daemon.runOnce(allocator, w, caps, lang) catch {};

    try output.printSeparator(w, caps);
    try w.flush();
}

fn runDaemon(allocator: std.mem.Allocator, w: *std.Io.Writer, caps: terminal.TermCaps, lang: i18n.Language, interval: u32) !void {
    var binding = try ensureBindingInteractive(allocator, w, caps, lang, interval);
    if (interval != 60) {
        binding.interval_minutes = interval;
        config_mod.saveBinding(allocator, binding) catch {};
    }

    try daemon.runLoop(allocator, w, caps, lang, binding.interval_minutes);
}

fn runBackgroundSync(allocator: std.mem.Allocator, lang: i18n.Language) !void {
    _ = try ensureBindingSilently(allocator) orelse return;

    var discard_buffer: [1]u8 = undefined;
    var discard_writer = std.Io.Writer.Discarding.init(&discard_buffer);
    const silent_caps: terminal.TermCaps = .{
        .color = false,
        .unicode = false,
        .width = 80,
    };

    _ = daemon.runOnce(allocator, &discard_writer.writer, silent_caps, lang) catch {};
}

fn runAutostartEnable(allocator: std.mem.Allocator, w: *std.Io.Writer, caps: terminal.TermCaps, lang: i18n.Language, interval: u32) !void {
    var binding = try ensureBindingInteractive(allocator, w, caps, lang, interval);
    if (interval != 60) {
        binding.interval_minutes = interval;
        config_mod.saveBinding(allocator, binding) catch {};
    }

    try output.printSectionHeader(w, i18n.tr(lang, "Autostart", "自启动", "自動起動"), caps);

    const exe_path = getExePath(allocator) catch {
        try output.printError(w, i18n.tr(lang, "Cannot determine executable path", "无法确定可执行文件路径", "実行ファイルパスを特定できません"), caps);
        try w.flush();
        return;
    };
    defer allocator.free(exe_path);

    autostart.enable(allocator, exe_path, interval) catch |err| {
        try output.printError(w, i18n.tr(lang, "Failed to enable autostart", "启用自启动失败", "自動起動の有効化に失敗しました"), caps);
        try w.flush();
        return err;
    };

    try output.printSuccess(w, i18n.tr(lang, "Autostart enabled", "自启动已启用", "自動起動が有効化されました"), caps);
    try w.flush();
}

fn runAutostartDisable(allocator: std.mem.Allocator, w: *std.Io.Writer, caps: terminal.TermCaps, lang: i18n.Language) !void {
    try output.printSectionHeader(w, i18n.tr(lang, "Autostart", "自启动", "自動起動"), caps);

    autostart.disable(allocator) catch |err| {
        try output.printError(w, i18n.tr(lang, "Failed to disable autostart", "禁用自启动失败", "自動起動の無効化に失敗しました"), caps);
        try w.flush();
        return err;
    };

    try output.printSuccess(w, i18n.tr(lang, "Autostart disabled", "自启动已禁用", "自動起動が無効化されました"), caps);
    try w.flush();
}

fn runInstall(allocator: std.mem.Allocator, w: *std.Io.Writer, caps: terminal.TermCaps, lang: i18n.Language) !void {
    try output.printSectionHeader(w, i18n.tr(lang, "Install", "安装", "インストール"), caps);

    const installed_path = install_mod.install(allocator) catch |err| {
        try output.printError(w, i18n.tr(lang, "Install failed", "安装失败", "インストールに失敗しました"), caps);
        try w.flush();
        return err;
    };
    defer allocator.free(installed_path);

    try output.printSuccess(w, i18n.tr(lang, "Installed successfully", "安装成功", "インストールしました"), caps);
    try output.printKeyValue(w, i18n.tr(lang, "Executable:", "可执行文件:", "実行ファイル:"), installed_path, caps);
    try output.printKeyValue(w, i18n.tr(lang, "PATH:", "PATH:", "PATH:"), config_mod.display_install_bin_path, caps);
    try w.flush();
}

fn runUninstall(allocator: std.mem.Allocator, w: *std.Io.Writer, caps: terminal.TermCaps, lang: i18n.Language) !void {
    try output.printSectionHeader(w, i18n.tr(lang, "Uninstall", "卸载", "アンインストール"), caps);

    install_mod.uninstall(allocator) catch |err| {
        try output.printError(w, i18n.tr(lang, "Uninstall failed", "卸载失败", "アンインストールに失敗しました"), caps);
        try w.flush();
        return err;
    };

    try output.printSuccess(w, i18n.tr(lang, "Uninstalled successfully", "卸载完成", "アンインストールしました"), caps);
    try w.flush();
}

fn runStatus(allocator: std.mem.Allocator, w: *std.Io.Writer, caps: terminal.TermCaps, lang: i18n.Language) !void {
    try output.printSectionHeader(w, i18n.tr(lang, "Status", "状态", "ステータス"), caps);

    const binding = config_mod.loadBinding(allocator) catch null;

    if (binding) |b| {
        const loc_name: []const u8 = switch (b.location) {
            .env => i18n.tr(lang, "Environment variable", "环境变量", "環境変数"),
            .auth_json => config_mod.display_auth_json_path,
            .config_toml => config_mod.display_config_toml_path,
        };
        try output.printKeyValue(w, i18n.tr(lang, "Storage:", "存储位置:", "保存場所:"), loc_name, caps);

        var interval_buf: [32]u8 = undefined;
        const interval_str = std.fmt.bufPrint(&interval_buf, "{d} min", .{b.interval_minutes}) catch "?";
        try output.printKeyValue(w, i18n.tr(lang, "Interval:", "检测间隔:", "チェック間隔:"), interval_str, caps);

        const local_key = env.readCurrentKey(allocator, b.location) catch null;
        defer if (local_key) |k| allocator.free(k);

        if (local_key) |lk| {
            var masked_buf: [64]u8 = undefined;
            const masked = maskKey(&masked_buf, lk);
            try output.printKeyValue(w, i18n.tr(lang, "Current Key:", "当前Key:", "現在のKey:"), masked, caps);
        } else {
            try output.printKeyValue(w, i18n.tr(lang, "Current Key:", "当前Key:", "現在のKey:"), i18n.tr(lang, "(not set)", "(未设置)", "(未設定)"), caps);
        }
    } else {
        try output.printWarning(w, i18n.tr(lang, "Not configured. Run with --setup.", "尚未配置，请使用 --setup", "未設定です。--setup を実行してください"), caps);
    }

    const autostart_enabled = autostart.isEnabled(allocator);
    const autostart_str = if (autostart_enabled)
        i18n.tr(lang, "Enabled", "已启用", "有効")
    else
        i18n.tr(lang, "Disabled", "已禁用", "無効");
    try output.printKeyValue(w, i18n.tr(lang, "Autostart:", "自启动:", "自動起動:"), autostart_str, caps);

    try output.printSeparator(w, caps);
    try w.flush();
}

fn getExePath(allocator: std.mem.Allocator) ![]u8 {
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try std.fs.selfExePath(&path_buf);
    return try allocator.dupe(u8, path);
}

fn maskKey(buf: []u8, key: []const u8) []const u8 {
    if (key.len <= 8) {
        return std.fmt.bufPrint(buf, "{s}****", .{key}) catch key;
    }
    const prefix = key[0..6];
    const suffix = key[key.len - 4 ..];
    return std.fmt.bufPrint(buf, "{s}...{s}", .{ prefix, suffix }) catch key;
}

test {
    _ = @import("http.zig");
    _ = @import("config.zig");
}
