const std = @import("std");
const builtin = @import("builtin");
const config_mod = @import("config.zig");

const env_key_name = "OPENAI_API_KEY";

pub fn readCurrentKey(allocator: std.mem.Allocator, location: config_mod.StorageLocation) !?[]u8 {
    return switch (location) {
        .env => readFromEnv(allocator),
        .auth_json => readFromAuthJson(allocator),
        .config_toml => readFromConfigToml(allocator),
    };
}

pub fn writeKey(allocator: std.mem.Allocator, location: config_mod.StorageLocation, key: []const u8) !void {
    switch (location) {
        .env => try writeToEnv(allocator, key),
        .auth_json => try writeToAuthJson(allocator, key),
        .config_toml => try writeToConfigToml(allocator, key),
    }
}

pub fn clearManagedKey(allocator: std.mem.Allocator, location: config_mod.StorageLocation) !void {
    switch (location) {
        .env => try clearEnvKey(allocator),
        .auth_json => try clearAuthJson(allocator),
        .config_toml => try clearConfigToml(allocator),
    }
}

pub fn detectExistingLocation(allocator: std.mem.Allocator) !?config_mod.StorageLocation {
    if (try readFromEnv(allocator)) |k| {
        allocator.free(k);
        return .env;
    }
    if (try readFromAuthJson(allocator)) |k| {
        allocator.free(k);
        return .auth_json;
    }
    if (try readFromConfigToml(allocator)) |k| {
        allocator.free(k);
        return .config_toml;
    }
    return null;
}

fn readFromEnv(allocator: std.mem.Allocator) !?[]u8 {
    switch (builtin.os.tag) {
        .windows => return readFromEnvWindows(allocator),
        else => return readFromEnvPosix(allocator),
    }
}

fn readFromEnvPosix(allocator: std.mem.Allocator) !?[]u8 {
    if (std.process.getEnvVarOwned(allocator, env_key_name) catch null) |val| {
        errdefer allocator.free(val);
        if (val.len > 0) {
            return val;
        }
        allocator.free(val);
    }

    const home = config_mod.getHomeDir(allocator) orelse return null;
    defer allocator.free(home);
    const shell_files = [_][]const u8{ ".bashrc", ".zshrc", ".profile", ".bash_profile" };

    for (shell_files) |fname| {
        const path = std.fs.path.join(allocator, &.{ home, fname }) catch continue;
        defer allocator.free(path);

        const key = readKeyFromShellFile(allocator, path) catch continue;
        if (key) |k| return k;
    }

    return null;
}

fn readKeyFromShellFile(allocator: std.mem.Allocator, path: []const u8) !?[]u8 {
    const file = std.fs.openFileAbsolute(path, .{}) catch return null;
    defer file.close();

    var buf: [32768]u8 = undefined;
    const bytes_read = file.readAll(&buf) catch return null;
    const content = buf[0..bytes_read];

    const export_prefix = "export " ++ env_key_name ++ "=";
    const plain_prefix = env_key_name ++ "=";

    var line_iter = std.mem.splitScalar(u8, content, '\n');
    while (line_iter.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0 or trimmed[0] == '#') continue;

        var value_part: ?[]const u8 = null;
        if (std.mem.startsWith(u8, trimmed, export_prefix)) {
            value_part = trimmed[export_prefix.len..];
        } else if (std.mem.startsWith(u8, trimmed, plain_prefix)) {
            value_part = trimmed[plain_prefix.len..];
        }

        if (value_part) |vp| {
            const val = stripQuotes(vp);
            if (val.len > 0 and std.mem.startsWith(u8, val, "sk-")) {
                return try allocator.dupe(u8, val);
            }
        }
    }

    return null;
}

fn stripQuotes(s: []const u8) []const u8 {
    if (s.len >= 2) {
        if ((s[0] == '"' and s[s.len - 1] == '"') or
            (s[0] == '\'' and s[s.len - 1] == '\''))
        {
            return s[1 .. s.len - 1];
        }
    }
    return s;
}

fn readFromEnvWindows(allocator: std.mem.Allocator) !?[]u8 {
    if (std.process.getEnvVarOwned(allocator, env_key_name) catch null) |val| {
        errdefer allocator.free(val);
        if (val.len > 0) {
            return val;
        }
        allocator.free(val);
    }
    return readWindowsPersistentEnvKey(allocator);
}

fn readWindowsPersistentEnvKey(allocator: std.mem.Allocator) !?[]u8 {
    if (builtin.os.tag != .windows) return null;

    var stdout_data: std.ArrayListUnmanaged(u8) = .empty;
    defer stdout_data.deinit(allocator);
    var stderr_data: std.ArrayListUnmanaged(u8) = .empty;
    defer stderr_data.deinit(allocator);

    const args = [_][]const u8{
        "powershell.exe",
        "-NoProfile",
        "-Command",
        "[Environment]::GetEnvironmentVariable('" ++ env_key_name ++ "', 'User')",
    };

    var child = std.process.Child.init(&args, allocator);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;

    child.spawn() catch return null;
    child.collectOutput(allocator, &stdout_data, &stderr_data, 8192) catch return null;
    const term = child.wait() catch return null;

    switch (term) {
        .Exited => |code| {
            if (code != 0) return null;
        },
        else => return null,
    }

    const output = std.mem.trim(u8, stdout_data.items, " \t\r\n");
    if (output.len > 0 and std.mem.startsWith(u8, output, "sk-")) {
        return try allocator.dupe(u8, output);
    }

    return null;
}

fn readFromAuthJson(allocator: std.mem.Allocator) !?[]u8 {
    const path = config_mod.getAuthJsonPath(allocator) catch return null;
    defer allocator.free(path);

    if (try readAuthJsonAtPath(allocator, path)) |key| return key;

    const legacy_path = config_mod.getLegacyAuthJsonPath(allocator) catch return null;
    defer allocator.free(legacy_path);
    return try readAuthJsonAtPath(allocator, legacy_path);
}

fn readFromConfigToml(allocator: std.mem.Allocator) !?[]u8 {
    const path = config_mod.getConfigTomlPath(allocator) catch return null;
    defer allocator.free(path);

    if (try readConfigTomlAtPath(allocator, path)) |key| return key;

    const legacy_path = config_mod.getLegacyConfigTomlPath(allocator) catch return null;
    defer allocator.free(legacy_path);
    return try readConfigTomlAtPath(allocator, legacy_path);
}

fn readAuthJsonAtPath(allocator: std.mem.Allocator, path: []const u8) !?[]u8 {
    const file = std.fs.openFileAbsolute(path, .{}) catch return null;
    defer file.close();

    var buf: [4096]u8 = undefined;
    const bytes_read = file.readAll(&buf) catch return null;
    const content = buf[0..bytes_read];

    return extractJsonValue(allocator, content, "api_key") catch
        extractJsonValue(allocator, content, "OPENAI_API_KEY") catch
        return null;
}

fn readConfigTomlAtPath(allocator: std.mem.Allocator, path: []const u8) !?[]u8 {
    const file = std.fs.openFileAbsolute(path, .{}) catch return null;
    defer file.close();

    var buf: [4096]u8 = undefined;
    const bytes_read = file.readAll(&buf) catch return null;
    const content = buf[0..bytes_read];

    return extractTomlValue(allocator, content, "api_key") catch
        extractTomlValue(allocator, content, "OPENAI_API_KEY") catch
        return null;
}

fn extractJsonValue(allocator: std.mem.Allocator, content: []const u8, field: []const u8) ![]u8 {
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

fn extractTomlValue(allocator: std.mem.Allocator, content: []const u8, key: []const u8) ![]u8 {
    var line_iter = std.mem.splitScalar(u8, content, '\n');
    while (line_iter.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0 or trimmed[0] == '#' or trimmed[0] == '[') continue;

        if (std.mem.indexOf(u8, trimmed, "=")) |eq_pos| {
            const k = std.mem.trim(u8, trimmed[0..eq_pos], " \t");
            if (std.mem.eql(u8, k, key)) {
                const v = std.mem.trim(u8, trimmed[eq_pos + 1 ..], " \t");
                const val = stripQuotes(v);
                if (val.len > 0) {
                    return try allocator.dupe(u8, val);
                }
            }
        }
    }
    return error.NotFound;
}

fn writeToEnv(allocator: std.mem.Allocator, key: []const u8) !void {
    switch (builtin.os.tag) {
        .windows => try writeToEnvWindows(allocator, key),
        else => try writeToEnvPosix(allocator, key),
    }
}

fn clearEnvKey(allocator: std.mem.Allocator) !void {
    switch (builtin.os.tag) {
        .windows => try clearEnvKeyWindows(allocator),
        else => try clearEnvKeyPosix(allocator),
    }
}

fn writeToEnvPosix(allocator: std.mem.Allocator, key: []const u8) !void {
    const home = config_mod.getHomeDir(allocator) orelse return error.NoHomeDir;
    defer allocator.free(home);

    const shell_files = [_][]const u8{ ".bashrc", ".zshrc", ".profile" };
    var written = false;

    for (shell_files) |fname| {
        const path = try std.fs.path.join(allocator, &.{ home, fname });
        defer allocator.free(path);

        const exists = blk: {
            std.fs.accessAbsolute(path, .{}) catch break :blk false;
            break :blk true;
        };

        if (exists) {
            try updateShellFile(allocator, path, key);
            written = true;
        }
    }

    if (!written) {
        const bashrc_path = try std.fs.path.join(allocator, &.{ home, ".bashrc" });
        defer allocator.free(bashrc_path);
        try updateShellFile(allocator, bashrc_path, key);
    }
}

fn updateShellFile(allocator: std.mem.Allocator, path: []const u8, new_key: []const u8) !void {
    var content: std.ArrayListUnmanaged(u8) = .empty;
    defer content.deinit(allocator);

    const existing = blk: {
        const file = std.fs.openFileAbsolute(path, .{}) catch break :blk false;
        defer file.close();
        var buf: [65536]u8 = undefined;
        const bytes_read = file.readAll(&buf) catch break :blk false;
        try content.appendSlice(allocator, buf[0..bytes_read]);
        break :blk true;
    };
    _ = existing;

    const export_line_prefix = "export " ++ env_key_name ++ "=";

    var new_content: std.ArrayListUnmanaged(u8) = .empty;
    defer new_content.deinit(allocator);

    var found = false;
    var line_iter = std.mem.splitScalar(u8, content.items, '\n');
    while (line_iter.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (std.mem.startsWith(u8, trimmed, export_line_prefix) or
            std.mem.startsWith(u8, trimmed, env_key_name ++ "="))
        {
            var line_buf: [256]u8 = undefined;
            const new_line = std.fmt.bufPrint(&line_buf, "export {s}=\"{s}\"", .{ env_key_name, new_key }) catch continue;
            try new_content.appendSlice(allocator, new_line);
            try new_content.append(allocator, '\n');
            found = true;
        } else {
            try new_content.appendSlice(allocator, line);
            if (line_iter.peek() != null) {
                try new_content.append(allocator, '\n');
            }
        }
    }

    if (!found) {
        if (new_content.items.len > 0 and new_content.items[new_content.items.len - 1] != '\n') {
            try new_content.append(allocator, '\n');
        }
        var line_buf: [256]u8 = undefined;
        const new_line = std.fmt.bufPrint(&line_buf, "export {s}=\"{s}\"\n", .{ env_key_name, new_key }) catch return error.FormatError;
        try new_content.appendSlice(allocator, new_line);
    }

    const file = try std.fs.createFileAbsolute(path, .{});
    defer file.close();
    try file.writeAll(new_content.items);
}

fn writeToEnvWindows(allocator: std.mem.Allocator, key: []const u8) !void {
    if (builtin.os.tag != .windows) return;

    var cmd_buf: [512]u8 = undefined;
    const cmd = std.fmt.bufPrint(&cmd_buf, "setx {s} \"{s}\"", .{ env_key_name, key }) catch return error.FormatError;

    const args = [_][]const u8{ "cmd", "/c", cmd };

    var stdout_data: std.ArrayListUnmanaged(u8) = .empty;
    defer stdout_data.deinit(allocator);
    var stderr_data: std.ArrayListUnmanaged(u8) = .empty;
    defer stderr_data.deinit(allocator);

    var child = std.process.Child.init(&args, allocator);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;

    try child.spawn();
    try child.collectOutput(allocator, &stdout_data, &stderr_data, 8192);
    _ = try child.wait();
}

fn clearEnvKeyPosix(allocator: std.mem.Allocator) !void {
    const home = config_mod.getHomeDir(allocator) orelse return error.NoHomeDir;
    defer allocator.free(home);

    const shell_files = [_][]const u8{ ".bashrc", ".zshrc", ".profile", ".bash_profile" };
    for (shell_files) |fname| {
        const path = try std.fs.path.join(allocator, &.{ home, fname });
        defer allocator.free(path);
        removeEnvFromShellFile(allocator, path) catch {};
    }
}

fn clearEnvKeyWindows(allocator: std.mem.Allocator) !void {
    const args = [_][]const u8{
        "powershell.exe",
        "-NoProfile",
        "-Command",
        "[Environment]::SetEnvironmentVariable('OPENAI_API_KEY', $null, 'User')",
    };

    var child = std.process.Child.init(&args, allocator);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;

    var stdout_data: std.ArrayListUnmanaged(u8) = .empty;
    defer stdout_data.deinit(allocator);
    var stderr_data: std.ArrayListUnmanaged(u8) = .empty;
    defer stderr_data.deinit(allocator);

    try child.spawn();
    try child.collectOutput(allocator, &stdout_data, &stderr_data, 8192);
    _ = try child.wait();
}

fn removeEnvFromShellFile(allocator: std.mem.Allocator, path: []const u8) !void {
    var content: std.ArrayListUnmanaged(u8) = .empty;
    defer content.deinit(allocator);

    const file = std.fs.openFileAbsolute(path, .{}) catch return;
    defer file.close();

    var buf: [65536]u8 = undefined;
    const bytes_read = file.readAll(&buf) catch return;
    try content.appendSlice(allocator, buf[0..bytes_read]);

    var new_content: std.ArrayListUnmanaged(u8) = .empty;
    defer new_content.deinit(allocator);

    const export_prefix = "export " ++ env_key_name ++ "=";
    const plain_prefix = env_key_name ++ "=";

    var line_iter = std.mem.splitScalar(u8, content.items, '\n');
    while (line_iter.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (std.mem.startsWith(u8, trimmed, export_prefix) or std.mem.startsWith(u8, trimmed, plain_prefix)) {
            continue;
        }

        try new_content.appendSlice(allocator, line);
        if (line_iter.peek() != null) try new_content.append(allocator, '\n');
    }

    const out_file = try std.fs.createFileAbsolute(path, .{});
    defer out_file.close();
    try out_file.writeAll(new_content.items);
}

fn clearAuthJson(allocator: std.mem.Allocator) !void {
    const path = config_mod.getAuthJsonPath(allocator) catch return;
    defer allocator.free(path);
    std.fs.deleteFileAbsolute(path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
}

fn clearConfigToml(allocator: std.mem.Allocator) !void {
    const path = config_mod.getConfigTomlPath(allocator) catch return;
    defer allocator.free(path);
    std.fs.deleteFileAbsolute(path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
}

fn writeToAuthJson(allocator: std.mem.Allocator, key: []const u8) !void {
    const path = try config_mod.getAuthJsonPath(allocator);
    defer allocator.free(path);

    const dir_path = std.fs.path.dirname(path) orelse return error.InvalidPath;
    std.fs.makeDirAbsolute(dir_path) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };

    var content_buf: [1024]u8 = undefined;
    const content = std.fmt.bufPrint(&content_buf, "{{\n  \"api_key\": \"{s}\"\n}}\n", .{key}) catch return error.FormatError;

    const file = try std.fs.createFileAbsolute(path, .{});
    defer file.close();
    try file.writeAll(content);
}

fn writeToConfigToml(allocator: std.mem.Allocator, key: []const u8) !void {
    const path = try config_mod.getConfigTomlPath(allocator);
    defer allocator.free(path);

    const dir_path = std.fs.path.dirname(path) orelse return error.InvalidPath;
    std.fs.makeDirAbsolute(dir_path) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };

    var existing_content: std.ArrayListUnmanaged(u8) = .empty;
    defer existing_content.deinit(allocator);

    const has_existing = blk: {
        const file = std.fs.openFileAbsolute(path, .{}) catch break :blk false;
        defer file.close();
        var buf: [16384]u8 = undefined;
        const bytes_read = file.readAll(&buf) catch break :blk false;
        existing_content.appendSlice(allocator, buf[0..bytes_read]) catch break :blk false;
        break :blk true;
    };

    var new_content: std.ArrayListUnmanaged(u8) = .empty;
    defer new_content.deinit(allocator);

    if (has_existing) {
        var found = false;
        var line_iter = std.mem.splitScalar(u8, existing_content.items, '\n');
        while (line_iter.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " \t\r");
            if (std.mem.startsWith(u8, trimmed, "api_key") or
                std.mem.startsWith(u8, trimmed, "OPENAI_API_KEY"))
            {
                var line_buf: [256]u8 = undefined;
                const new_line = std.fmt.bufPrint(&line_buf, "api_key = \"{s}\"", .{key}) catch continue;
                try new_content.appendSlice(allocator, new_line);
                try new_content.append(allocator, '\n');
                found = true;
            } else {
                try new_content.appendSlice(allocator, line);
                if (line_iter.peek() != null) {
                    try new_content.append(allocator, '\n');
                }
            }
        }

        if (!found) {
            if (new_content.items.len > 0 and new_content.items[new_content.items.len - 1] != '\n') {
                try new_content.append(allocator, '\n');
            }
            var line_buf: [256]u8 = undefined;
            const new_line = std.fmt.bufPrint(&line_buf, "api_key = \"{s}\"\n", .{key}) catch return error.FormatError;
            try new_content.appendSlice(allocator, new_line);
        }
    } else {
        var line_buf: [256]u8 = undefined;
        const new_line = std.fmt.bufPrint(&line_buf, "api_key = \"{s}\"\n", .{key}) catch return error.FormatError;
        try new_content.appendSlice(allocator, new_line);
    }

    const file = try std.fs.createFileAbsolute(path, .{});
    defer file.close();
    try file.writeAll(new_content.items);
}
