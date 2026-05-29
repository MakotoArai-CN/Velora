const std = @import("std");
const builtin = @import("builtin");
const app = @import("app.zig");
const io_compat = @import("io_compat.zig");

pub const display_sites_path = app.display_sites_path;
pub const display_install_bin_path = app.display_install_bin_path;

pub fn getHomeDir(allocator: std.mem.Allocator) ?[]u8 {
    const env_name = switch (builtin.os.tag) {
        .windows => "USERPROFILE",
        else => "HOME",
    };

    return io_compat.getEnv(allocator, env_name);
}

pub fn getAppDir(allocator: std.mem.Allocator) ![]u8 {
    const home = getHomeDir(allocator) orelse return error.NoHomeDir;
    defer allocator.free(home);
    return try std.fs.path.join(allocator, &.{ home, app.config_dir_name });
}

pub fn getLegacyAppDir(allocator: std.mem.Allocator) ![]u8 {
    const home = getHomeDir(allocator) orelse return error.NoHomeDir;
    defer allocator.free(home);
    return try std.fs.path.join(allocator, &.{ home, app.legacy_config_dir_name });
}

pub fn ensureAppDir(allocator: std.mem.Allocator) ![]u8 {
    const app_dir = try getAppDir(allocator);
    errdefer allocator.free(app_dir);

    try io_compat.makeDirIfMissing(app_dir);
    try copyLegacySitesIfMissing(allocator, app_dir);
    return app_dir;
}

pub fn getInstallBinDir(allocator: std.mem.Allocator) ![]u8 {
    const app_dir = try getAppDir(allocator);
    defer allocator.free(app_dir);
    return try std.fs.path.join(allocator, &.{ app_dir, app.install_bin_dir_name });
}

pub fn ensureInstallBinDir(allocator: std.mem.Allocator) ![]u8 {
    const bin_dir = try getInstallBinDir(allocator);
    errdefer allocator.free(bin_dir);
    try makeNestedDir(bin_dir);
    return bin_dir;
}

pub fn getInstalledExecutablePath(allocator: std.mem.Allocator) ![]u8 {
    const bin_dir = try getInstallBinDir(allocator);
    defer allocator.free(bin_dir);
    return try std.fs.path.join(allocator, &.{ bin_dir, app.executableName() });
}

fn copyLegacySitesIfMissing(allocator: std.mem.Allocator, app_dir: []const u8) !void {
    const target_path = try std.fs.path.join(allocator, &.{ app_dir, app.sites_filename });
    defer allocator.free(target_path);
    if (io_compat.pathExists(target_path)) return;

    const legacy_dir = getLegacyAppDir(allocator) catch return;
    defer allocator.free(legacy_dir);

    const legacy_path = try std.fs.path.join(allocator, &.{ legacy_dir, app.sites_filename });
    defer allocator.free(legacy_path);
    if (!io_compat.pathExists(legacy_path)) return;

    io_compat.copyFileAbsolute(legacy_path, target_path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
}

fn makeNestedDir(path: []const u8) !void {
    var built: [std.fs.max_path_bytes]u8 = undefined;
    var pos: usize = 0;
    var rest = path;

    if (path.len >= 3 and std.ascii.isAlphabetic(path[0]) and path[1] == ':' and (path[2] == '\\' or path[2] == '/')) {
        built[0] = path[0];
        built[1] = ':';
        built[2] = '\\';
        pos = 3;
        rest = path[3..];
    } else if (path.len > 0 and (path[0] == '/' or path[0] == '\\')) {
        built[0] = path[0];
        pos = 1;
        rest = path[1..];
    } else {
        return error.BadPathName;
    }

    var components = std.mem.splitAny(u8, rest, "/\\");

    while (components.next()) |comp| {
        if (comp.len == 0 or std.mem.eql(u8, comp, ".")) continue;

        if (pos > 0 and built[pos - 1] != '\\' and built[pos - 1] != '/') {
            built[pos] = std.fs.path.sep;
            pos += 1;
        }

        @memcpy(built[pos .. pos + comp.len], comp);
        pos += comp.len;

        try io_compat.makeDirIfMissing(built[0..pos]);
    }
}
