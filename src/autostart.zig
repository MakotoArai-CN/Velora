const std = @import("std");
const builtin = @import("builtin");
const app = @import("app.zig");
const config_mod = @import("config.zig");

const app_name = app.command_name;
const background_sync_arg = "--background-sync";

pub fn enable(allocator: std.mem.Allocator, exe_path: []const u8, interval: u32) !void {
    switch (builtin.os.tag) {
        .windows => try enableWindows(allocator, exe_path, interval),
        .macos => try enableMacos(allocator, exe_path, interval),
        .linux => try enableLinux(allocator, exe_path, interval),
        else => return error.UnsupportedPlatform,
    }
}

pub fn disable(allocator: std.mem.Allocator) !void {
    switch (builtin.os.tag) {
        .windows => try disableWindows(allocator),
        .macos => try disableMacos(allocator),
        .linux => try disableLinux(allocator),
        else => return error.UnsupportedPlatform,
    }
}

pub fn isEnabled(allocator: std.mem.Allocator) bool {
    switch (builtin.os.tag) {
        .windows => return isEnabledWindows(allocator),
        .macos => return isEnabledMacos(allocator),
        .linux => return isEnabledLinux(allocator),
        else => return false,
    }
}

fn enableWindows(allocator: std.mem.Allocator, exe_path: []const u8, interval: u32) !void {
    const task_action = try std.fmt.allocPrint(allocator, "\"{s}\" {s}", .{ exe_path, background_sync_arg });
    defer allocator.free(task_action);

    var interval_buf: [16]u8 = undefined;
    const interval_str = std.fmt.bufPrint(&interval_buf, "{d}", .{interval}) catch return error.FormatError;

    const args = [_][]const u8{
        "schtasks",
        "/create",
        "/tn",
        app_name,
        "/tr",
        task_action,
        "/sc",
        "MINUTE",
        "/mo",
        interval_str,
        "/f",
    };

    try runProcess(allocator, &args);
}

fn disableWindows(allocator: std.mem.Allocator) !void {
    const args = [_][]const u8{ "schtasks", "/delete", "/tn", app_name, "/f" };
    runProcess(allocator, &args) catch {};
}

fn isEnabledWindows(allocator: std.mem.Allocator) bool {
    const args = [_][]const u8{ "schtasks", "/query", "/tn", app_name };
    runProcess(allocator, &args) catch return false;
    return true;
}

fn enableMacos(allocator: std.mem.Allocator, exe_path: []const u8, interval: u32) !void {
    const home = config_mod.getHomeDir(allocator) orelse return error.NoHomeDir;
    defer allocator.free(home);
    const plist_dir = try std.fs.path.join(allocator, &.{ home, "Library", "LaunchAgents" });
    defer allocator.free(plist_dir);

    std.fs.makeDirAbsolute(plist_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };

    const plist_name = app.launchAgentName();
    const plist_path = try std.fs.path.join(allocator, &.{ plist_dir, plist_name });
    defer allocator.free(plist_path);

    const interval_secs = @as(u64, interval) * 60;

    var content_buf: [2048]u8 = undefined;
    const content = std.fmt.bufPrint(&content_buf,
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        \\<plist version="1.0">
        \\<dict>
        \\    <key>Label</key>
        \\    <string>com.{s}</string>
        \\    <key>ProgramArguments</key>
        \\    <array>
        \\        <string>{s}</string>
        \\        <string>{s}</string>
        \\    </array>
        \\    <key>StartInterval</key>
        \\    <integer>{d}</integer>
        \\    <key>RunAtLoad</key>
        \\    <true/>
        \\    <key>KeepAlive</key>
        \\    <false/>
        \\</dict>
        \\</plist>
        \\
    , .{ app_name, exe_path, background_sync_arg, interval_secs }) catch return error.FormatError;

    const file = try std.fs.createFileAbsolute(plist_path, .{});
    defer file.close();
    try file.writeAll(content);

    const load_args = [_][]const u8{ "launchctl", "load", plist_path };
    runProcess(allocator, &load_args) catch {};
}

fn disableMacos(allocator: std.mem.Allocator) !void {
    const home = config_mod.getHomeDir(allocator) orelse return error.NoHomeDir;
    defer allocator.free(home);
    const plist_name = app.launchAgentName();
    const plist_path = try std.fs.path.join(allocator, &.{ home, "Library", "LaunchAgents", plist_name });
    defer allocator.free(plist_path);

    const unload_args = [_][]const u8{ "launchctl", "unload", plist_path };
    runProcess(allocator, &unload_args) catch {};

    std.fs.deleteFileAbsolute(plist_path) catch {};
}

fn isEnabledMacos(allocator: std.mem.Allocator) bool {
    const home = config_mod.getHomeDir(allocator) orelse return false;
    defer allocator.free(home);
    const plist_name = app.launchAgentName();
    const plist_path = std.fs.path.join(allocator, &.{ home, "Library", "LaunchAgents", plist_name }) catch return false;
    defer allocator.free(plist_path);
    std.fs.accessAbsolute(plist_path, .{}) catch return false;
    return true;
}

fn enableLinux(allocator: std.mem.Allocator, exe_path: []const u8, interval: u32) !void {
    const home = config_mod.getHomeDir(allocator) orelse return error.NoHomeDir;
    defer allocator.free(home);

    const systemd_dir = try std.fs.path.join(allocator, &.{ home, ".config", "systemd", "user" });
    defer allocator.free(systemd_dir);

    makeNestedDir(systemd_dir) catch {};

    const service_path = try std.fs.path.join(allocator, &.{ systemd_dir, app_name ++ ".service" });
    defer allocator.free(service_path);

    var svc_buf: [2048]u8 = undefined;
    const svc_content = std.fmt.bufPrint(&svc_buf,
        \\[Unit]
        \\Description=Velora
        \\After=network-online.target
        \\Wants=network-online.target
        \\
        \\[Service]
        \\Type=oneshot
        \\ExecStart="{s}" {s}
        \\
        \\[Install]
        \\WantedBy=default.target
        \\
    , .{ exe_path, background_sync_arg }) catch return error.FormatError;

    const svc_file = try std.fs.createFileAbsolute(service_path, .{});
    defer svc_file.close();
    try svc_file.writeAll(svc_content);

    const timer_path = try std.fs.path.join(allocator, &.{ systemd_dir, app_name ++ ".timer" });
    defer allocator.free(timer_path);

    var tmr_buf: [1024]u8 = undefined;
    const tmr_content = std.fmt.bufPrint(&tmr_buf,
        \\[Unit]
        \\Description=Velora Timer
        \\
        \\[Timer]
        \\OnBootSec=1min
        \\OnUnitActiveSec={d}min
        \\Persistent=true
        \\
        \\[Install]
        \\WantedBy=timers.target
        \\
    , .{interval}) catch return error.FormatError;

    const tmr_file = try std.fs.createFileAbsolute(timer_path, .{});
    defer tmr_file.close();
    try tmr_file.writeAll(tmr_content);

    const reload_args = [_][]const u8{ "systemctl", "--user", "daemon-reload" };
    runProcess(allocator, &reload_args) catch {};
    const enable_args = [_][]const u8{ "systemctl", "--user", "enable", "--now", app_name ++ ".timer" };
    runProcess(allocator, &enable_args) catch {};
}

fn disableLinux(allocator: std.mem.Allocator) !void {
    const disable_args = [_][]const u8{ "systemctl", "--user", "disable", "--now", app_name ++ ".timer" };
    runProcess(allocator, &disable_args) catch {};

    const home = config_mod.getHomeDir(allocator) orelse return error.NoHomeDir;
    defer allocator.free(home);
    const systemd_dir = try std.fs.path.join(allocator, &.{ home, ".config", "systemd", "user" });
    defer allocator.free(systemd_dir);

    const service_path = try std.fs.path.join(allocator, &.{ systemd_dir, app_name ++ ".service" });
    defer allocator.free(service_path);
    std.fs.deleteFileAbsolute(service_path) catch {};

    const timer_path = try std.fs.path.join(allocator, &.{ systemd_dir, app_name ++ ".timer" });
    defer allocator.free(timer_path);
    std.fs.deleteFileAbsolute(timer_path) catch {};

    const reload_args = [_][]const u8{ "systemctl", "--user", "daemon-reload" };
    runProcess(allocator, &reload_args) catch {};
}

fn isEnabledLinux(allocator: std.mem.Allocator) bool {
    const home = config_mod.getHomeDir(allocator) orelse return false;
    defer allocator.free(home);
    const timer_path = std.fs.path.join(allocator, &.{ home, ".config", "systemd", "user", app_name ++ ".timer" }) catch return false;
    defer allocator.free(timer_path);
    std.fs.accessAbsolute(timer_path, .{}) catch return false;
    return true;
}

fn runProcess(allocator: std.mem.Allocator, argv: []const []const u8) !void {
    var child = std.process.Child.init(argv, allocator);
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;

    try child.spawn();
    const term = try child.wait();

    switch (term) {
        .Exited => |code| {
            if (code != 0) return error.CommandFailed;
        },
        else => return error.CommandFailed,
    }
}

fn makeNestedDir(path: []const u8) !void {
    var components = std.mem.splitScalar(u8, path, '/');
    var built: [4096]u8 = undefined;
    var pos: usize = 0;

    if (path.len > 0 and path[0] == '/') {
        built[0] = '/';
        pos = 1;
    }

    while (components.next()) |comp| {
        if (comp.len == 0) continue;
        if (pos > 1 or (pos == 1 and built[0] != '/')) {
            built[pos] = '/';
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
