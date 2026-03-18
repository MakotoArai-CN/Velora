const std = @import("std");
const builtin = @import("builtin");
const app = @import("app.zig");
const config_mod = @import("config.zig");

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

        std.fs.deleteFileAbsolute(exe_path) catch |err| switch (err) {
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

    std.fs.deleteTreeAbsolute(path) catch |err| switch (err) {
        error.FileNotFound => return .already_removed,
        else => return err,
    };

    return .removed;
}

fn replaceInstalledExecutable(source_path: []const u8, installed_path: []const u8) !void {
    std.fs.deleteFileAbsolute(installed_path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
    try std.fs.copyFileAbsolute(source_path, installed_path, .{});
}

fn filesEqualAbsolute(a_path: []const u8, b_path: []const u8) !bool {
    const a_file = try std.fs.openFileAbsolute(a_path, .{});
    defer a_file.close();
    const b_file = try std.fs.openFileAbsolute(b_path, .{});
    defer b_file.close();

    const a_stat = try a_file.stat();
    const b_stat = try b_file.stat();
    if (a_stat.size != b_stat.size) return false;

    var a_buf: [8192]u8 = undefined;
    var b_buf: [8192]u8 = undefined;

    while (true) {
        const a_read = try a_file.read(&a_buf);
        const b_read = try b_file.read(&b_buf);
        if (a_read != b_read) return false;
        if (a_read == 0) return true;
        if (!std.mem.eql(u8, a_buf[0..a_read], b_buf[0..b_read])) return false;
    }
}

fn pathExistsAbsolute(path: []const u8) bool {
    std.fs.accessAbsolute(path, .{}) catch return false;
    return true;
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

    {
        const file = std.fs.openFileAbsolute(path, .{}) catch {
            if (add) {
                const out_file = try std.fs.createFileAbsolute(path, .{});
                defer out_file.close();
                const export_line = try std.fmt.allocPrint(allocator, "{s}\nexport PATH=\"{s}:$PATH\"\n", .{ app.path_marker, bin_dir });
                defer allocator.free(export_line);
                try out_file.writeAll(export_line);
            }
            return;
        };
        defer file.close();
        var buf: [65536]u8 = undefined;
        const bytes_read = file.readAll(&buf) catch return;
        try content.appendSlice(allocator, buf[0..bytes_read]);
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
    var child = std.process.Child.init(&args, allocator);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;
    try child.spawn();
}
