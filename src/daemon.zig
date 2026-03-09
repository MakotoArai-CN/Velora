const std = @import("std");
const http = @import("http.zig");
const env = @import("env.zig");
const config_mod = @import("config.zig");
const output = @import("output.zig");
const terminal = @import("terminal.zig");
const i18n = @import("i18n.zig");

pub fn runOnce(allocator: std.mem.Allocator, w: *std.Io.Writer, caps: terminal.TermCaps, lang: i18n.Language) !bool {
    const binding = try config_mod.loadBinding(allocator) orelse return error.NoBinding;

    try output.printInfo(w, i18n.tr(lang, "Fetching API key from remote...", "正在从远程获取API Key...", "リモートからAPIキーを取得中..."), caps);
    try w.flush();

    const remote_key = http.fetchApiKey(allocator) catch |err| {
        try output.printError(w, i18n.tr(lang, "Failed to fetch API key from remote", "从远程获取API Key失败", "リモートからのAPIキー取得に失敗しました"), caps);
        try w.flush();
        return err;
    };
    defer allocator.free(remote_key);

    var masked_buf: [64]u8 = undefined;
    const masked = maskKey(&masked_buf, remote_key);
    try output.printKeyValue(w, i18n.tr(lang, "Remote Key:", "远程Key:", "リモートKey:"), masked, caps);

    const local_key = env.readCurrentKey(allocator, binding.location) catch null;
    defer if (local_key) |k| allocator.free(k);

    if (local_key) |lk| {
        if (std.mem.eql(u8, lk, remote_key)) {
            try output.printSuccess(w, i18n.tr(lang, "API key is up to date", "API Key已是最新", "APIキーは最新です"), caps);
            try w.flush();
            return false;
        }
        try output.printWarning(w, i18n.tr(lang, "API key mismatch, updating...", "API Key不一致，正在更新...", "APIキーが一致しません、更新中..."), caps);
    } else {
        try output.printInfo(w, i18n.tr(lang, "No local API key found, writing...", "未找到本地API Key，正在写入...", "ローカルAPIキーが見つかりません、書き込み中..."), caps);
    }
    try w.flush();

    env.writeKey(allocator, binding.location, remote_key) catch |err| {
        try output.printError(w, i18n.tr(lang, "Failed to write API key", "写入API Key失败", "APIキーの書き込みに失敗しました"), caps);
        try w.flush();
        return err;
    };

    try output.printSuccess(w, i18n.tr(lang, "API key updated successfully", "API Key更新成功", "APIキーの更新に成功しました"), caps);
    try w.flush();
    return true;
}

pub fn runLoop(allocator: std.mem.Allocator, w: *std.Io.Writer, caps: terminal.TermCaps, lang: i18n.Language, interval_minutes: u32) !void {
    const interval_ns: u64 = @as(u64, interval_minutes) * 60 * std.time.ns_per_s;

    try output.printSectionHeader(w, i18n.tr(lang, "Daemon Mode", "守护进程模式", "デーモンモード"), caps);
    try output.printKeyValue(w, i18n.tr(lang, "Interval:", "检测间隔:", "チェック間隔:"), blk: {
        var buf: [32]u8 = undefined;
        break :blk std.fmt.bufPrint(&buf, "{d} min", .{interval_minutes}) catch "?";
    }, caps);
    try output.printSeparator(w, caps);
    try w.flush();

    while (true) {
        var time_buf: [32]u8 = undefined;
        const time_str = getTimestamp(&time_buf);

        try output.printInfo(w, time_str, caps);
        try w.flush();

        _ = runOnce(allocator, w, caps, lang) catch {};

        try output.printSeparator(w, caps);
        try w.flush();

        std.Thread.sleep(interval_ns);
    }
}

fn maskKey(buf: []u8, key: []const u8) []const u8 {
    if (key.len <= 8) {
        return std.fmt.bufPrint(buf, "{s}****", .{key}) catch key;
    }
    const prefix = key[0..6];
    const suffix = key[key.len - 4 ..];
    return std.fmt.bufPrint(buf, "{s}...{s}", .{ prefix, suffix }) catch key;
}

fn getTimestamp(buf: []u8) []const u8 {
    const epoch_secs = @as(u64, @intCast(std.time.timestamp()));
    const day_secs = epoch_secs % 86400;
    const hours = day_secs / 3600;
    const minutes = (day_secs % 3600) / 60;
    const seconds = day_secs % 60;
    return std.fmt.bufPrint(buf, "[{d:0>2}:{d:0>2}:{d:0>2} UTC]", .{ hours, minutes, seconds }) catch "[-:-:-]";
}