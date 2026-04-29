const std = @import("std");
const builtin = @import("builtin");
const app = @import("app.zig");
const config_mod = @import("config.zig");
const io_compat = @import("io_compat.zig");

pub const InstallStatus = enum {
    installed,
    already_installed,
    already_installed_busy,
};

pub const InstallResult = struct {
    path: []u8,
    status: InstallStatus,
};

pub const UninstallStatus = enum {
    removed,
    already_removed,
    scheduled_cleanup,
};

pub fn install(allocator: std.mem.Allocator) !InstallResult {
    const source_path = try getSelfExePath(allocator);
    defer allocator.free(source_path);

    const bin_dir = try config_mod.ensureInstallBinDir(allocator);
    defer allocator.free(bin_dir);

    const installed_path = try config_mod.getInstalledExecutablePath(allocator);
    errdefer allocator.free(installed_path);

    var status: InstallStatus = .installed;

    if (std.mem.eql(u8, source_path, installed_path)) {
        status = .already_installed;
    } else if (pathExistsAbsolute(installed_path) and try filesEqualAbsolute(source_path, installed_path)) {
        status = .already_installed;
    } else {
        replaceInstalledExecutable(source_path, installed_path) catch |err| {
            if (builtin.os.tag == .windows and err == error.AccessDenied and pathExistsAbsolute(installed_path)) {
                status = .already_installed_busy;
            } else {
                return err;
            }
        };
    }

    try ensureCommandOnPath(allocator, bin_dir);
    return .{ .path = installed_path, .status = status };
}

pub fn uninstall(allocator: std.mem.Allocator) !UninstallStatus {
    const bin_dir = config_mod.getInstallBinDir(allocator) catch null;
    defer if (bin_dir) |path| allocator.free(path);
    if (bin_dir) |path| {
        removeCommandFromPath(allocator, path) catch {};
    }

    const app_dir = config_mod.getAppDir(allocator) catch null;
    defer if (app_dir) |path| allocator.free(path);
    if (app_dir == null) return .already_removed;

    const path = app_dir.?;
    if (!pathExistsAbsolute(path)) return .already_removed;

    if (builtin.os.tag == .windows) {
        const installed_path = config_mod.getInstalledExecutablePath(allocator) catch null;
        defer if (installed_path) |exe_path| allocator.free(exe_path);

        try scheduleWindowsCleanup(allocator, installed_path, path);
        return .scheduled_cleanup;
    }

    const installed_path = config_mod.getInstalledExecutablePath(allocator) catch null;
    defer if (installed_path) |exe_path| allocator.free(exe_path);

    const self_path = getSelfExePath(allocator) catch null;
    defer if (self_path) |exe_path| allocator.free(exe_path);

    if (installed_path) |exe_path| {
        if (builtin.os.tag == .windows and self_path != null and std.mem.eql(u8, self_path.?, exe_path)) {
            try scheduleWindowsCleanup(allocator, exe_path, path);
            return .scheduled_cleanup;
        }

        io_compat.deleteFileAbsolute(exe_path) catch |err| switch (err) {
            error.FileNotFound => {},
            error.AccessDenied => {
                if (builtin.os.tag == .windows) {
                    try scheduleWindowsCleanup(allocator, exe_path, path);
                    return .scheduled_cleanup;
                }
                return err;
            },
            else => return err,
        };
    }

    if (!io_compat.pathExists(path)) return .already_removed;
    try io_compat.deleteTreeAbsolute(path);

    return .removed;
}

fn replaceInstalledExecutable(source_path: []const u8, installed_path: []const u8) !void {
    io_compat.deleteFileAbsolute(installed_path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
    try io_compat.copyFileAbsolute(source_path, installed_path);
}

fn filesEqualAbsolute(a_path: []const u8, b_path: []const u8) !bool {
    const io = io_compat.io();
    const a_file = try std.Io.Dir.openFileAbsolute(io, a_path, .{});
    defer a_file.close(io);
    const b_file = try std.Io.Dir.openFileAbsolute(io, b_path, .{});
    defer b_file.close(io);

    const a_len = try a_file.length(io);
    const b_len = try b_file.length(io);
    if (a_len != b_len) return false;

    var a_buf: [8192]u8 = undefined;
    var b_buf: [8192]u8 = undefined;
    var a_reader = a_file.reader(io, &a_buf);
    var b_reader = b_file.reader(io, &b_buf);
    const a_iface = &a_reader.interface;
    const b_iface = &b_reader.interface;

    while (true) {
        const a_slice = a_iface.peekGreedy(1) catch |err| switch (err) {
            error.EndOfStream => return true,
            else => return err,
        };
        const b_slice = b_iface.peekGreedy(1) catch return false;
        const n = @min(a_slice.len, b_slice.len);
        if (!std.mem.eql(u8, a_slice[0..n], b_slice[0..n])) return false;
        a_iface.toss(n);
        b_iface.toss(n);
    }
}

fn pathExistsAbsolute(path: []const u8) bool {
    return io_compat.pathExists(path);
}

fn getSelfExePath(allocator: std.mem.Allocator) ![]u8 {
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try io_compat.selfExePath(&path_buf);
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

        if (io_compat.pathExists(path)) {
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

    const has_file = io_compat.readFileIntoList(allocator, path, &content);
    if (!has_file) {
        if (add) {
            const export_line = try std.fmt.allocPrint(allocator, "{s}\nexport PATH=\"{s}:$PATH\"\n", .{ app.path_marker, bin_dir });
            defer allocator.free(export_line);
            try io_compat.writeFileAll(path, export_line);
        }
        return;
    }

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

    try io_compat.writeFileAll(path, new_content.items);
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
    const result = std.process.run(allocator, io_compat.io(), .{ .argv = argv }) catch return error.CommandFailed;
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    switch (result.term) {
        .exited => |code| if (code != 0) return error.CommandFailed,
        else => return error.CommandFailed,
    }

    return try allocator.dupe(u8, std.mem.trim(u8, result.stdout, " \t\r\n"));
}

fn run(allocator: std.mem.Allocator, argv: []const []const u8) !void {
    const result = std.process.run(allocator, io_compat.io(), .{ .argv = argv }) catch return error.CommandFailed;
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    switch (result.term) {
        .exited => |code| if (code != 0) return error.CommandFailed,
        else => return error.CommandFailed,
    }
}

fn scheduleWindowsCleanup(allocator: std.mem.Allocator, exe_path: ?[]const u8, app_dir: []const u8) !void {
    const escaped_exe = try std.mem.replaceOwned(u8, allocator, exe_path orelse "", "'", "''");
    defer allocator.free(escaped_exe);
    const escaped_dir = try std.mem.replaceOwned(u8, allocator, app_dir, "'", "''");
    defer allocator.free(escaped_dir);

    const script = try std.fmt.allocPrint(
        allocator,
        "$exe='{s}'; $dir='{s}'; for ($i=0; $i -lt 40; $i++) {{ if ($exe.Length -gt 0) {{ Remove-Item -LiteralPath $exe -Force -ErrorAction SilentlyContinue }}; Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue; if (-not (Test-Path -LiteralPath $dir)) {{ exit 0 }}; Start-Sleep -Milliseconds 500 }}",
        .{ escaped_exe, escaped_dir },
    );
    defer allocator.free(script);

    const args = [_][]const u8{ "powershell.exe", "-NoProfile", "-WindowStyle", "Hidden", "-Command", script };
    // Fire-and-forget: the current process must exit before the cleanup script
    // can delete the running executable on Windows.
    _ = std.process.spawn(io_compat.io(), .{
        .argv = &args,
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
        .create_no_window = true,
    }) catch return;
}
