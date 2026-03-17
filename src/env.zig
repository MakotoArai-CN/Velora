const std = @import("std");
const builtin = @import("builtin");
const config_mod = @import("config.zig");

/// Write an environment variable to persistent storage (Windows registry / POSIX shell rc files).
/// This is the main public API for the new multi-site manager.
pub fn writeEnvVar(allocator: std.mem.Allocator, env_name: []const u8, value: []const u8) !void {
    switch (builtin.os.tag) {
        .windows => try writeEnvVarWindows(allocator, env_name, value),
        else => try writeEnvVarPosix(allocator, env_name, value),
    }
}

/// Read an environment variable from persistent storage.
pub fn readEnvVar(allocator: std.mem.Allocator, env_name: []const u8) !?[]u8 {
    switch (builtin.os.tag) {
        .windows => return readEnvVarWindows(allocator, env_name),
        else => return readEnvVarPosix(allocator, env_name),
    }
}

/// Clear an environment variable from persistent storage.
pub fn clearEnvVar(allocator: std.mem.Allocator, env_name: []const u8) !void {
    switch (builtin.os.tag) {
        .windows => try clearEnvVarWindows(allocator, env_name),
        else => try clearEnvVarPosix(allocator, env_name),
    }
}

// --- POSIX Implementation ---

fn readEnvVarPosix(allocator: std.mem.Allocator, env_name: []const u8) !?[]u8 {
    if (std.process.getEnvVarOwned(allocator, env_name) catch null) |val| {
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

        const key = readKeyFromShellFile(allocator, path, env_name) catch continue;
        if (key) |k| return k;
    }

    return null;
}

fn readKeyFromShellFile(allocator: std.mem.Allocator, path: []const u8, env_name: []const u8) !?[]u8 {
    const file = std.fs.openFileAbsolute(path, .{}) catch return null;
    defer file.close();

    var buf: [32768]u8 = undefined;
    const bytes_read = file.readAll(&buf) catch return null;
    const content = buf[0..bytes_read];

    // Build dynamic prefixes
    var export_prefix_buf: [256]u8 = undefined;
    const export_prefix = std.fmt.bufPrint(&export_prefix_buf, "export {s}=", .{env_name}) catch return null;
    var plain_prefix_buf: [256]u8 = undefined;
    const plain_prefix = std.fmt.bufPrint(&plain_prefix_buf, "{s}=", .{env_name}) catch return null;

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
            if (val.len > 0) {
                return try allocator.dupe(u8, val);
            }
        }
    }

    return null;
}

fn writeEnvVarPosix(allocator: std.mem.Allocator, env_name: []const u8, value: []const u8) !void {
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
            try updateShellFile(allocator, path, env_name, value);
            written = true;
        }
    }

    if (!written) {
        const bashrc_path = try std.fs.path.join(allocator, &.{ home, ".bashrc" });
        defer allocator.free(bashrc_path);
        try updateShellFile(allocator, bashrc_path, env_name, value);
    }
}

fn updateShellFile(allocator: std.mem.Allocator, path: []const u8, env_name: []const u8, new_value: []const u8) !void {
    var content: std.ArrayListUnmanaged(u8) = .empty;
    defer content.deinit(allocator);

    {
        const file = std.fs.openFileAbsolute(path, .{}) catch {
            // File doesn't exist yet, will create
            const out_file = try std.fs.createFileAbsolute(path, .{});
            defer out_file.close();
            var line_buf: [512]u8 = undefined;
            const new_line = std.fmt.bufPrint(&line_buf, "export {s}={s}\n", .{ env_name, new_value }) catch return error.FormatError;
            try out_file.writeAll(new_line);
            return;
        };
        defer file.close();
        var buf: [65536]u8 = undefined;
        const bytes_read = file.readAll(&buf) catch return error.ReadError;
        try content.appendSlice(allocator, buf[0..bytes_read]);
    }

    // Build dynamic prefixes
    var export_prefix_buf: [256]u8 = undefined;
    const export_prefix = std.fmt.bufPrint(&export_prefix_buf, "export {s}=", .{env_name}) catch return error.FormatError;
    var plain_prefix_buf: [256]u8 = undefined;
    const plain_prefix = std.fmt.bufPrint(&plain_prefix_buf, "{s}=", .{env_name}) catch return error.FormatError;

    var new_content: std.ArrayListUnmanaged(u8) = .empty;
    defer new_content.deinit(allocator);

    var found = false;
    var line_iter = std.mem.splitScalar(u8, content.items, '\n');
    while (line_iter.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (std.mem.startsWith(u8, trimmed, export_prefix) or
            std.mem.startsWith(u8, trimmed, plain_prefix))
        {
            // Write without quotes - the value is written bare
            var line_buf: [512]u8 = undefined;
            const new_line = std.fmt.bufPrint(&line_buf, "export {s}={s}", .{ env_name, new_value }) catch continue;
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
        var line_buf: [512]u8 = undefined;
        const new_line = std.fmt.bufPrint(&line_buf, "export {s}={s}\n", .{ env_name, new_value }) catch return error.FormatError;
        try new_content.appendSlice(allocator, new_line);
    }

    const file = try std.fs.createFileAbsolute(path, .{});
    defer file.close();
    try file.writeAll(new_content.items);
}

fn clearEnvVarPosix(allocator: std.mem.Allocator, env_name: []const u8) !void {
    const home = config_mod.getHomeDir(allocator) orelse return error.NoHomeDir;
    defer allocator.free(home);

    const shell_files = [_][]const u8{ ".bashrc", ".zshrc", ".profile", ".bash_profile" };
    for (shell_files) |fname| {
        const path = try std.fs.path.join(allocator, &.{ home, fname });
        defer allocator.free(path);
        removeEnvFromShellFile(allocator, path, env_name) catch {};
    }
}

fn removeEnvFromShellFile(allocator: std.mem.Allocator, path: []const u8, env_name: []const u8) !void {
    var content: std.ArrayListUnmanaged(u8) = .empty;
    defer content.deinit(allocator);

    const file = std.fs.openFileAbsolute(path, .{}) catch return;
    defer file.close();

    var buf: [65536]u8 = undefined;
    const bytes_read = file.readAll(&buf) catch return;
    try content.appendSlice(allocator, buf[0..bytes_read]);

    var new_content: std.ArrayListUnmanaged(u8) = .empty;
    defer new_content.deinit(allocator);

    var export_prefix_buf: [256]u8 = undefined;
    const export_prefix = std.fmt.bufPrint(&export_prefix_buf, "export {s}=", .{env_name}) catch return;
    var plain_prefix_buf: [256]u8 = undefined;
    const plain_prefix = std.fmt.bufPrint(&plain_prefix_buf, "{s}=", .{env_name}) catch return;

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

// --- Windows Implementation ---

fn readEnvVarWindows(allocator: std.mem.Allocator, env_name: []const u8) !?[]u8 {
    // Try process environment first
    if (std.process.getEnvVarOwned(allocator, env_name) catch null) |val| {
        errdefer allocator.free(val);
        if (val.len > 0) {
            // Strip extra quotes if present (fix for setx bug)
            const stripped = stripQuotes(val);
            if (stripped.len != val.len) {
                const clean = try allocator.dupe(u8, stripped);
                allocator.free(val);
                return clean;
            }
            return val;
        }
        allocator.free(val);
    }
    // Fall back to registry via PowerShell
    return readWindowsPersistentEnv(allocator, env_name);
}

fn readWindowsPersistentEnv(allocator: std.mem.Allocator, env_name: []const u8) !?[]u8 {
    if (builtin.os.tag != .windows) return null;

    var cmd_buf: [512]u8 = undefined;
    const cmd = std.fmt.bufPrint(&cmd_buf, "[Environment]::GetEnvironmentVariable('{s}', 'User')", .{env_name}) catch return null;

    var stdout_data: std.ArrayListUnmanaged(u8) = .empty;
    defer stdout_data.deinit(allocator);
    var stderr_data: std.ArrayListUnmanaged(u8) = .empty;
    defer stderr_data.deinit(allocator);

    const args = [_][]const u8{
        "powershell.exe",
        "-NoProfile",
        "-Command",
        cmd,
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
    if (output.len > 0) {
        // Strip any residual quotes from previous setx bug
        const clean = stripQuotes(output);
        return try allocator.dupe(u8, clean);
    }

    return null;
}

/// Write env var to Windows User registry using PowerShell.
/// This replaces the old setx approach to avoid the quote-wrapping bug.
fn writeEnvVarWindows(allocator: std.mem.Allocator, env_name: []const u8, value: []const u8) !void {
    if (builtin.os.tag != .windows) return;

    // Use PowerShell [Environment]::SetEnvironmentVariable() instead of setx
    // to avoid the quote-inclusion bug where setx stores literal " characters
    var cmd_buf: [1024]u8 = undefined;
    const cmd = std.fmt.bufPrint(&cmd_buf, "[Environment]::SetEnvironmentVariable('{s}', '{s}', 'User')", .{ env_name, value }) catch return error.FormatError;

    const args = [_][]const u8{ "powershell.exe", "-NoProfile", "-Command", cmd };

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

fn clearEnvVarWindows(allocator: std.mem.Allocator, env_name: []const u8) !void {
    if (builtin.os.tag != .windows) return;

    var cmd_buf: [512]u8 = undefined;
    const cmd = std.fmt.bufPrint(&cmd_buf, "[Environment]::SetEnvironmentVariable('{s}', $null, 'User')", .{env_name}) catch return error.FormatError;

    const args = [_][]const u8{
        "powershell.exe",
        "-NoProfile",
        "-Command",
        cmd,
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

// --- Utility functions ---

pub fn stripQuotes(s: []const u8) []const u8 {
    if (s.len >= 2) {
        if ((s[0] == '"' and s[s.len - 1] == '"') or
            (s[0] == '\'' and s[s.len - 1] == '\''))
        {
            return s[1 .. s.len - 1];
        }
    }
    return s;
}

pub fn extractJsonValue(allocator: std.mem.Allocator, content: []const u8, field: []const u8) ![]u8 {
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

pub fn extractTomlValue(allocator: std.mem.Allocator, content: []const u8, key: []const u8) ![]u8 {
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
