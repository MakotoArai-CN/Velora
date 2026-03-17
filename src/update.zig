const std = @import("std");
const app = @import("app.zig");
const builtin = @import("builtin");

pub const UpdateInfo = struct {
    has_update: bool,
    latest_version: ?[]u8, // allocated, caller frees
    download_url: ?[]u8,   // allocated, caller frees
};

/// Check GitHub releases API for latest version.
/// Returns UpdateInfo; caller must free latest_version and download_url if non-null.
pub fn checkLatestVersion(allocator: std.mem.Allocator, current_version: []const u8) !UpdateInfo {
    var client: std.http.Client = .{ .allocator = allocator };
    defer client.deinit();

    var response_writer: std.Io.Writer.Allocating = .init(allocator);
    defer response_writer.deinit();

    const result = client.fetch(.{
        .location = .{ .url = app.github_releases_url },
        .method = .GET,
        .headers = .{
            .user_agent = .{ .override = "VA-updater/2.0" },
            .accept_encoding = .{ .override = "identity" },
        },
        .response_writer = &response_writer.writer,
    }) catch return error.NetworkError;

    if (@intFromEnum(result.status) != 200) return error.NetworkError;

    const body = response_writer.written();

    // Extract tag_name from JSON: "tag_name": "v2.0.0"
    const latest_tag = extractJsonStr(allocator, body, "tag_name") catch return error.ParseError;
    defer allocator.free(latest_tag);

    // Strip leading 'v' if present
    const latest = if (latest_tag.len > 0 and latest_tag[0] == 'v')
        latest_tag[1..]
    else
        latest_tag;

    const has_update = !std.mem.eql(u8, latest, current_version) and
        versionGt(latest, current_version);

    const latest_copy = try allocator.dupe(u8, latest);

    // Extract download URL for current platform
    const download_url = extractDownloadUrl(allocator, body) catch null;

    return .{
        .has_update = has_update,
        .latest_version = latest_copy,
        .download_url = download_url,
    };
}

/// Download and replace the current binary with the latest version.
pub fn performUpdate(allocator: std.mem.Allocator, download_url: []const u8) !void {
    var client: std.http.Client = .{ .allocator = allocator };
    defer client.deinit();

    var response_writer: std.Io.Writer.Allocating = .init(allocator);
    defer response_writer.deinit();

    const result = client.fetch(.{
        .location = .{ .url = download_url },
        .method = .GET,
        .headers = .{
            .user_agent = .{ .override = "VA-updater/2.0" },
            .accept_encoding = .{ .override = "identity" },
        },
        .response_writer = &response_writer.writer,
    }) catch return error.NetworkError;

    if (@intFromEnum(result.status) != 200) return error.DownloadFailed;

    const exe_data = response_writer.written();
    if (exe_data.len == 0) return error.DownloadFailed;

    // Write to a temp file next to the current binary, then replace
    var self_buf: [std.fs.max_path_bytes]u8 = undefined;
    const self_path = std.fs.selfExePath(&self_buf) catch return error.SelfPathError;

    var tmp_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmp_path = std.fmt.bufPrint(&tmp_buf, "{s}.new", .{self_path}) catch return error.PathError;

    {
        const tmp_file = try std.fs.createFileAbsolute(tmp_path, .{ .mode = 0o755 });
        defer tmp_file.close();
        try tmp_file.writeAll(exe_data);
    }

    // Replace current binary
    switch (builtin.os.tag) {
        .windows => {
            // On Windows: rename current to .old, rename new to current
            var old_buf: [std.fs.max_path_bytes]u8 = undefined;
            const old_path = std.fmt.bufPrint(&old_buf, "{s}.old", .{self_path}) catch return error.PathError;
            std.fs.renameAbsolute(self_path, old_path) catch {};
            try std.fs.renameAbsolute(tmp_path, self_path);
        },
        else => {
            try std.fs.renameAbsolute(tmp_path, self_path);
        },
    }
}

fn extractJsonStr(allocator: std.mem.Allocator, content: []const u8, field: []const u8) ![]u8 {
    var search_buf: [128]u8 = undefined;
    const search_key = std.fmt.bufPrint(&search_buf, "\"{s}\"", .{field}) catch return error.FormatError;

    const key_pos = std.mem.indexOf(u8, content, search_key) orelse return error.NotFound;
    const after_key = content[key_pos + search_key.len ..];
    const colon_pos = std.mem.indexOf(u8, after_key, ":") orelse return error.NotFound;
    const after_colon = after_key[colon_pos + 1 ..];
    const q1 = std.mem.indexOf(u8, after_colon, "\"") orelse return error.NotFound;
    const val_start = after_colon[q1 + 1 ..];
    const q2 = std.mem.indexOf(u8, val_start, "\"") orelse return error.NotFound;
    const val = val_start[0..q2];
    if (val.len == 0) return error.EmptyValue;
    return try allocator.dupe(u8, val);
}

fn extractDownloadUrl(allocator: std.mem.Allocator, body: []const u8) ![]u8 {
    // Look for browser_download_url matching current platform
    const platform_suffix = comptime platformSuffix();

    var search_pos: usize = 0;
    while (std.mem.indexOf(u8, body[search_pos..], "browser_download_url")) |pos| {
        const abs = search_pos + pos;
        const url = extractJsonStr(allocator, body[abs..], "browser_download_url") catch {
            search_pos = abs + 20;
            continue;
        };

        if (std.mem.indexOf(u8, url, platform_suffix) != null) {
            return url;
        }
        allocator.free(url);
        search_pos = abs + 20;
    }
    return error.NotFound;
}

fn platformSuffix() []const u8 {
    return switch (builtin.os.tag) {
        .windows => switch (builtin.cpu.arch) {
            .x86_64 => "windows-x86_64",
            .aarch64 => "windows-aarch64",
            else => "windows-x86_64",
        },
        .macos => switch (builtin.cpu.arch) {
            .aarch64 => "macos-aarch64",
            else => "macos-x86_64",
        },
        else => switch (builtin.cpu.arch) {
            .aarch64 => "linux-aarch64",
            else => "linux-x86_64",
        },
    };
}

/// Simple semver comparison: returns true if a > b.
/// Only handles X.Y.Z format.
fn versionGt(a: []const u8, b: []const u8) bool {
    var a_parts = std.mem.splitScalar(u8, a, '.');
    var b_parts = std.mem.splitScalar(u8, b, '.');

    for (0..3) |_| {
        const a_part = a_parts.next() orelse "0";
        const b_part = b_parts.next() orelse "0";
        const a_num = std.fmt.parseInt(u32, a_part, 10) catch 0;
        const b_num = std.fmt.parseInt(u32, b_part, 10) catch 0;
        if (a_num > b_num) return true;
        if (a_num < b_num) return false;
    }
    return false;
}
