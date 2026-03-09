const std = @import("std");
const builtin = @import("builtin");
const app = @import("app.zig");

pub const StorageLocation = enum {
    env,
    auth_json,
    config_toml,
};

pub const BindingConfig = struct {
    location: StorageLocation,
    interval_minutes: u32,
};

pub const display_auth_json_path = "~/.velora/auth.json";
pub const display_config_toml_path = "~/.velora/config.toml";
pub const display_binding_path = "~/.velora/velora.conf";
pub const display_install_bin_path = "~/.velora/bin";

pub fn getHomeDir(allocator: std.mem.Allocator) ?[]u8 {
    const env_name = switch (builtin.os.tag) {
        .windows => "USERPROFILE",
        else => "HOME",
    };

    return std.process.getEnvVarOwned(allocator, env_name) catch null;
}

pub fn getAppDir(allocator: std.mem.Allocator) ![]u8 {
    const home = getHomeDir(allocator) orelse return error.NoHomeDir;
    defer allocator.free(home);
    return try std.fs.path.join(allocator, &.{ home, app.config_dir_name });
}

pub fn ensureAppDir(allocator: std.mem.Allocator) ![]u8 {
    const app_dir = try getAppDir(allocator);
    errdefer allocator.free(app_dir);

    std.fs.makeDirAbsolute(app_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
    return app_dir;
}

pub fn getConfigDir(allocator: std.mem.Allocator) ![]u8 {
    return ensureAppDir(allocator);
}

pub fn getLegacyConfigDir(allocator: std.mem.Allocator) ![]u8 {
    const home = getHomeDir(allocator) orelse return error.NoHomeDir;
    defer allocator.free(home);
    return try std.fs.path.join(allocator, &.{ home, app.legacy_config_dir_name });
}

pub fn getBindingPath(allocator: std.mem.Allocator) ![]u8 {
    const dir = try ensureAppDir(allocator);
    defer allocator.free(dir);
    return try std.fs.path.join(allocator, &.{ dir, app.binding_filename });
}

pub fn getLegacyBindingPath(allocator: std.mem.Allocator) ![]u8 {
    const dir = try getLegacyConfigDir(allocator);
    defer allocator.free(dir);
    return try std.fs.path.join(allocator, &.{ dir, app.legacy_binding_filename });
}

pub fn loadBinding(allocator: std.mem.Allocator) !?BindingConfig {
    const binding_path = getBindingPath(allocator) catch return try loadLegacyBinding(allocator);
    defer allocator.free(binding_path);

    if (try loadBindingFromPath(binding_path)) |binding| {
        return binding;
    }
    return try loadLegacyBinding(allocator);
}

fn loadLegacyBinding(allocator: std.mem.Allocator) !?BindingConfig {
    const legacy_path = getLegacyBindingPath(allocator) catch return null;
    defer allocator.free(legacy_path);
    return try loadBindingFromPath(legacy_path);
}

fn loadBindingFromPath(path: []const u8) !?BindingConfig {
    const file = std.fs.openFileAbsolute(path, .{}) catch return null;
    defer file.close();

    var buf: [256]u8 = undefined;
    const stat = file.stat() catch return null;
    const size = @min(stat.size, buf.len);
    const bytes_read = file.readAll(&buf) catch return null;
    if (bytes_read < size) return null;
    return parseBinding(buf[0..bytes_read]);
}

fn parseBinding(content: []const u8) ?BindingConfig {
    var location: ?StorageLocation = null;
    var interval: u32 = 60;

    var line_iter = std.mem.splitScalar(u8, content, '\n');
    while (line_iter.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0 or trimmed[0] == '#') continue;

        if (std.mem.indexOf(u8, trimmed, "=")) |eq_pos| {
            const key = std.mem.trim(u8, trimmed[0..eq_pos], " \t");
            const val = std.mem.trim(u8, trimmed[eq_pos + 1 ..], " \t");

            if (std.mem.eql(u8, key, "location")) {
                if (std.mem.eql(u8, val, "env")) {
                    location = .env;
                } else if (std.mem.eql(u8, val, "auth_json")) {
                    location = .auth_json;
                } else if (std.mem.eql(u8, val, "config_toml")) {
                    location = .config_toml;
                }
            } else if (std.mem.eql(u8, key, "interval")) {
                interval = std.fmt.parseInt(u32, val, 10) catch 60;
            }
        }
    }

    if (location) |loc| {
        return .{
            .location = loc,
            .interval_minutes = @max(interval, 1),
        };
    }
    return null;
}

pub fn saveBinding(allocator: std.mem.Allocator, binding: BindingConfig) !void {
    const path = try getBindingPath(allocator);
    defer allocator.free(path);

    const loc_str: []const u8 = switch (binding.location) {
        .env => "env",
        .auth_json => "auth_json",
        .config_toml => "config_toml",
    };

    const file = try std.fs.createFileAbsolute(path, .{});
    defer file.close();

    var buf: [512]u8 = undefined;
    const content = std.fmt.bufPrint(&buf, "# velora configuration\nlocation={s}\ninterval={d}\n", .{ loc_str, binding.interval_minutes }) catch return error.FormatError;
    try file.writeAll(content);
}

pub fn deleteLegacyBinding(allocator: std.mem.Allocator) !void {
    const path = getLegacyBindingPath(allocator) catch return;
    defer allocator.free(path);
    std.fs.deleteFileAbsolute(path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
}

pub fn deleteAppData(allocator: std.mem.Allocator) !void {
    const app_dir = getAppDir(allocator) catch return;
    defer allocator.free(app_dir);
    std.fs.deleteTreeAbsolute(app_dir) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
}

pub fn getAuthJsonPath(allocator: std.mem.Allocator) ![]u8 {
    const dir = try ensureAppDir(allocator);
    defer allocator.free(dir);
    return try std.fs.path.join(allocator, &.{ dir, app.auth_json_filename });
}

pub fn getLegacyAuthJsonPath(allocator: std.mem.Allocator) ![]u8 {
    const dir = try getLegacyConfigDir(allocator);
    defer allocator.free(dir);
    return try std.fs.path.join(allocator, &.{ dir, app.auth_json_filename });
}

pub fn getConfigTomlPath(allocator: std.mem.Allocator) ![]u8 {
    const dir = try ensureAppDir(allocator);
    defer allocator.free(dir);
    return try std.fs.path.join(allocator, &.{ dir, app.config_toml_filename });
}

pub fn getLegacyConfigTomlPath(allocator: std.mem.Allocator) ![]u8 {
    const dir = try getLegacyConfigDir(allocator);
    defer allocator.free(dir);
    return try std.fs.path.join(allocator, &.{ dir, app.config_toml_filename });
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

        std.fs.makeDirAbsolute(built[0..pos]) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };
    }
}

test "parse binding config" {
    const content = "location=env\ninterval=30\n";
    const binding = parseBinding(content).?;
    try std.testing.expectEqual(StorageLocation.env, binding.location);
    try std.testing.expectEqual(@as(u32, 30), binding.interval_minutes);
}
