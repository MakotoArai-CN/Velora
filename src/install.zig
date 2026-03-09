const std = @import("std");
const builtin = @import("builtin");
const app = @import("app.zig");
const autostart = @import("autostart.zig");
const config_mod = @import("config.zig");
const env = @import("env.zig");

pub fn install(allocator: std.mem.Allocator) ![]u8 {
    const source_path = try getSelfExePath(allocator);
    defer allocator.free(source_path);

    const bin_dir = try config_mod.ensureInstallBinDir(allocator);
    defer allocator.free(bin_dir);

    const installed_path = try config_mod.getInstalledExecutablePath(allocator);
    errdefer allocator.free(installed_path);

    if (!std.mem.eql(u8, source_path, installed_path)) {
        std.fs.deleteFileAbsolute(installed_path) catch {};
        try std.fs.copyFileAbsolute(source_path, installed_path, .{});
    }

    try ensureCommandOnPath(allocator, bin_dir);
    return installed_path;
}

pub fn uninstall(allocator: std.mem.Allocator) !void {
    const binding = config_mod.loadBinding(allocator) catch null;

    autostart.disable(allocator) catch {};

    if (binding) |b| {
        env.clearManagedKey(allocator, b.location) catch {};
    }

    const bin_dir = config_mod.getInstallBinDir(allocator) catch null;
    defer if (bin_dir) |path| allocator.free(path);
    if (bin_dir) |path| {
        removeCommandFromPath(allocator, path) catch {};
    }

    const app_dir = config_mod.getAppDir(allocator) catch null;
    defer if (app_dir) |path| allocator.free(path);

    if (app_dir) |path| {
        const installed_path = config_mod.getInstalledExecutablePath(allocator) catch null;
        defer if (installed_path) |exe_path| allocator.free(exe_path);

        if (installed_path) |exe_path| {
            const self_path = getSelfExePath(allocator) catch null;
            defer if (self_path) |p| allocator.free(p);

            if (builtin.os.tag == .windows and self_path != null and std.mem.eql(u8, self_path.?, exe_path)) {
                scheduleWindowsSelfDelete(allocator, exe_path, path) catch {};
            } else {
                std.fs.deleteTreeAbsolute(path) catch |err| switch (err) {
                    error.FileNotFound => {},
                    else => return err,
                };
            }
        } else {
            std.fs.deleteTreeAbsolute(path) catch |err| switch (err) {
                error.FileNotFound => {},
                else => return err,
            };
        }
    }

    config_mod.deleteLegacyBinding(allocator) catch {};
}

fn getSelfExePath(allocator: std.mem.Allocator) ![]u8 {
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try std.fs.selfExePath(&path_buf);
    return try allocator.dupe(u8, path);
}

fn ensureCommandOnPath(allocator: std.mem.Allocator, bin_dir: []const u8) !void {
    switch (builtin.os.tag) {
        .windows => try ensureCommandOnPathWindows(allocator, bin_dir),
        else => try ensureCommandOnPathPosix(allocator, bin_dir),
    }
}

fn removeCommandFromPath(allocator: std.mem.Allocator, bin_dir: []const u8) !void {
    switch (builtin.os.tag) {
        .windows => try removeCommandFromPathWindows(allocator, bin_dir),
        else => try removeCommandFromPathPosix(allocator, bin_dir),
    }
}

fn ensureCommandOnPathWindows(allocator: std.mem.Allocator, bin_dir: []const u8) !void {
    const current = try readWindowsUserPath(allocator);
    defer allocator.free(current);

    if (pathContainsWindows(current, bin_dir)) return;

    const updated = if (current.len == 0)
        try allocator.dupe(u8, bin_dir)
    else
        try std.fmt.allocPrint(allocator, "{s};{s}", .{ current, bin_dir });
    defer allocator.free(updated);

    try writeWindowsUserPath(allocator, updated);
}

fn removeCommandFromPathWindows(allocator: std.mem.Allocator, bin_dir: []const u8) !void {
    const current = try readWindowsUserPath(allocator);
    defer allocator.free(current);

    const updated = try removePathSegment(allocator, current, ';', bin_dir, true);
    defer allocator.free(updated);
    try writeWindowsUserPath(allocator, updated);
}

fn readWindowsUserPath(allocator: std.mem.Allocator) ![]u8 {
    const args = [_][]const u8{
        "powershell.exe",
        "-NoProfile",
        "-Command",
        "[Environment]::GetEnvironmentVariable('Path', 'User')",
    };
    return try runAndCaptureStdout(allocator, &args);
}

fn writeWindowsUserPath(allocator: std.mem.Allocator, value: []const u8) !void {
    const escaped = try std.mem.replaceOwned(u8, allocator, value, "'", "''");
    defer allocator.free(escaped);

    const script = try std.fmt.allocPrint(allocator, "[Environment]::SetEnvironmentVariable('Path', '{s}', 'User')", .{escaped});
    defer allocator.free(script);

    const args = [_][]const u8{ "powershell.exe", "-NoProfile", "-Command", script };
    try run(allocator, &args);
}

fn ensureCommandOnPathPosix(allocator: std.mem.Allocator, bin_dir: []const u8) !void {
    const home = config_mod.getHomeDir(allocator) orelse return error.NoHomeDir;
    defer allocator.free(home);

    const shell_files = [_][]const u8{ ".bashrc", ".zshrc", ".profile", ".bash_profile" };
    var written = false;

    for (shell_files) |fname| {
        const path = try std.fs.path.join(allocator, &.{ home, fname });
        defer allocator.free(path);

        const exists = blk: {
            std.fs.accessAbsolute(path, .{}) catch break :blk false;
            break :blk true;
        };

        if (exists) {
            try updatePathShellFile(allocator, path, bin_dir, true);
            written = true;
        }
    }

    if (!written) {
        const profile_path = try std.fs.path.join(allocator, &.{ home, ".profile" });
        defer allocator.free(profile_path);
        try updatePathShellFile(allocator, profile_path, bin_dir, true);
    }
}

fn removeCommandFromPathPosix(allocator: std.mem.Allocator, bin_dir: []const u8) !void {
    const home = config_mod.getHomeDir(allocator) orelse return;
    defer allocator.free(home);

    const shell_files = [_][]const u8{ ".bashrc", ".zshrc", ".profile", ".bash_profile" };
    for (shell_files) |fname| {
        const path = try std.fs.path.join(allocator, &.{ home, fname });
        defer allocator.free(path);
        updatePathShellFile(allocator, path, bin_dir, false) catch {};
    }
}

fn updatePathShellFile(allocator: std.mem.Allocator, path: []const u8, bin_dir: []const u8, add: bool) !void {
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

    const export_line = try std.fmt.allocPrint(allocator, "export PATH=\"{s}:$PATH\"", .{bin_dir});
    defer allocator.free(export_line);

    var new_content: std.ArrayListUnmanaged(u8) = .empty;
    defer new_content.deinit(allocator);

    var found_marker = false;
    var line_iter = std.mem.splitScalar(u8, content.items, '\n');
    while (line_iter.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (std.mem.eql(u8, trimmed, app.path_marker)) {
            found_marker = true;
            _ = line_iter.next();
            continue;
        }

        try new_content.appendSlice(allocator, line);
        if (line_iter.peek() != null) try new_content.append(allocator, '\n');
    }

    if (add and !found_marker) {
        if (new_content.items.len > 0 and new_content.items[new_content.items.len - 1] != '\n') {
            try new_content.append(allocator, '\n');
        }
        try new_content.appendSlice(allocator, app.path_marker);
        try new_content.append(allocator, '\n');
        try new_content.appendSlice(allocator, export_line);
        try new_content.append(allocator, '\n');
    }

    const file = try std.fs.createFileAbsolute(path, .{});
    defer file.close();
    try file.writeAll(new_content.items);
}

fn pathContainsWindows(path_value: []const u8, segment: []const u8) bool {
    var it = std.mem.splitScalar(u8, path_value, ';');
    while (it.next()) |part| {
        const trimmed = std.mem.trim(u8, part, " \t\r\n");
        if (std.ascii.eqlIgnoreCase(trimmed, segment)) return true;
    }
    return false;
}

fn removePathSegment(allocator: std.mem.Allocator, path_value: []const u8, delimiter: u8, segment: []const u8, case_insensitive: bool) ![]u8 {
    var new_value: std.ArrayListUnmanaged(u8) = .empty;
    defer new_value.deinit(allocator);

    var it = std.mem.splitScalar(u8, path_value, delimiter);
    while (it.next()) |part| {
        const trimmed = std.mem.trim(u8, part, " \t\r\n");
        const matches = if (case_insensitive)
            std.ascii.eqlIgnoreCase(trimmed, segment)
        else
            std.mem.eql(u8, trimmed, segment);
        if (matches or trimmed.len == 0) continue;

        if (new_value.items.len > 0) try new_value.append(allocator, delimiter);
        try new_value.appendSlice(allocator, trimmed);
    }

    return try allocator.dupe(u8, new_value.items);
}

fn runAndCaptureStdout(allocator: std.mem.Allocator, argv: []const []const u8) ![]u8 {
    var stdout_data: std.ArrayListUnmanaged(u8) = .empty;
    defer stdout_data.deinit(allocator);
    var stderr_data: std.ArrayListUnmanaged(u8) = .empty;
    defer stderr_data.deinit(allocator);

    var child = std.process.Child.init(argv, allocator);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;

    try child.spawn();
    try child.collectOutput(allocator, &stdout_data, &stderr_data, 65536);
    const term = try child.wait();

    switch (term) {
        .Exited => |code| if (code != 0) return error.CommandFailed,
        else => return error.CommandFailed,
    }

    return try allocator.dupe(u8, std.mem.trim(u8, stdout_data.items, " \t\r\n"));
}

fn run(allocator: std.mem.Allocator, argv: []const []const u8) !void {
    var child = std.process.Child.init(argv, allocator);
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;

    try child.spawn();
    const term = try child.wait();

    switch (term) {
        .Exited => |code| if (code != 0) return error.CommandFailed,
        else => return error.CommandFailed,
    }
}

fn scheduleWindowsSelfDelete(allocator: std.mem.Allocator, exe_path: []const u8, app_dir: []const u8) !void {
    const cmd = try std.fmt.allocPrint(allocator, "ping 127.0.0.1 -n 3 > nul & del /f /q \"{s}\" & rmdir /s /q \"{s}\"", .{ exe_path, app_dir });
    defer allocator.free(cmd);

    const args = [_][]const u8{ "cmd", "/c", cmd };
    var child = std.process.Child.init(&args, allocator);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;
    try child.spawn();
}
