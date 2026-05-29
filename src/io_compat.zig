//! Compatibility shims for Zig 0.16's I/O-as-Interface migration.
//!
//! Most of avm's I/O is synchronous and would gain nothing from explicit async
//! control flow. To minimize signature churn from the 0.15->0.16 migration, we
//! keep the call sites routed through this module while using the `Io` instance
//! that Zig passes to `main` at startup.
const std = @import("std");

/// Set by main() at startup. Tests may fall back to Zig's debug singleton.
var g_io: ?std.Io = null;

/// Set by main() at startup. Used by getEnv to look up environment variables.
/// In 0.16, env is no longer global state; main receives it via init.environ_map.
var g_environ_map: ?*const std.process.Environ.Map = null;

pub fn setIo(new_io: std.Io) void {
    g_io = new_io;
}

pub fn setEnvironMap(map: *const std.process.Environ.Map) void {
    g_environ_map = map;
}

/// Shared `Io` instance. In normal CLI execution this is `init.io`; the fallback
/// is only for unit tests that call helpers without running through `main`.
pub fn io() std.Io {
    return g_io orelse std.Io.Threaded.global_single_threaded.io();
}

/// Read entire file into a list. Returns false on any I/O failure.
pub fn readFileIntoList(allocator: std.mem.Allocator, path: []const u8, list: *std.ArrayListUnmanaged(u8)) bool {
    const file = std.Io.Dir.openFileAbsolute(io(), path, .{}) catch return false;
    defer file.close(io());

    var read_buf: [65536]u8 = undefined;
    var file_reader = file.reader(io(), &read_buf);
    const reader = &file_reader.interface;

    while (true) {
        const slice = reader.peekGreedy(1) catch |err| switch (err) {
            error.EndOfStream => return true,
            else => return false,
        };
        list.appendSlice(allocator, slice) catch return false;
        reader.toss(slice.len);
    }
    return true;
}

/// Write all bytes to a new file (creating/truncating).
pub fn writeFileAll(path: []const u8, data: []const u8) !void {
    const file = try std.Io.Dir.createFileAbsolute(io(), path, .{ .permissions = .default_file });
    defer file.close(io());
    try file.writeStreamingAll(io(), data);
}

/// Open file for reading. Caller closes via `closeFile`.
pub fn openFileRead(path: []const u8) ?std.Io.File {
    return std.Io.Dir.openFileAbsolute(io(), path, .{}) catch null;
}

/// Create file for writing (truncates if existing). Caller closes via `closeFile`.
pub fn createFileWrite(path: []const u8) !std.Io.File {
    return try std.Io.Dir.createFileAbsolute(io(), path, .{ .permissions = .default_file });
}

pub fn createFileExecutable(path: []const u8) !std.Io.File {
    return try std.Io.Dir.createFileAbsolute(io(), path, .{ .permissions = .executable_file });
}

pub fn closeFile(file: std.Io.File) void {
    file.close(io());
}

/// `std.fs.makeDirAbsolute` replacement; ignores `PathAlreadyExists`.
pub fn makeDirIfMissing(path: []const u8) !void {
    std.Io.Dir.createDirAbsolute(io(), path, .default_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
}

pub fn renameAbsolute(old_path: []const u8, new_path: []const u8) !void {
    try std.Io.Dir.renameAbsolute(old_path, new_path, io());
}

pub fn deleteFileAbsolute(path: []const u8) !void {
    try std.Io.Dir.deleteFileAbsolute(io(), path);
}

pub fn deleteTreeAbsolute(path: []const u8) !void {
    try std.Io.Dir.cwd().deleteTree(io(), path);
}

pub fn copyFileAbsolute(src_path: []const u8, dst_path: []const u8) !void {
    try std.Io.Dir.copyFileAbsolute(src_path, dst_path, io(), .{});
}

/// Existence check.
pub fn pathExists(path: []const u8) bool {
    std.Io.Dir.accessAbsolute(io(), path, .{}) catch return false;
    return true;
}

/// Get an environment variable owned by the caller. Returns null if missing or empty.
pub fn getEnv(allocator: std.mem.Allocator, name: []const u8) ?[]u8 {
    if (g_environ_map) |map| {
        const val = map.get(name) orelse return null;
        if (val.len == 0) return null;
        return allocator.dupe(u8, val) catch null;
    }
    return null;
}

pub fn selfExePath(buf: []u8) ![]const u8 {
    const len = try std.process.executablePath(io(), buf);
    return buf[0..len];
}

pub fn stdoutWriter(buffer: []u8, out_writer: *std.Io.File.Writer) *std.Io.Writer {
    out_writer.* = std.Io.File.stdout().writer(io(), buffer);
    return &out_writer.interface;
}

pub fn stderrWriter(buffer: []u8, out_writer: *std.Io.File.Writer) *std.Io.Writer {
    out_writer.* = std.Io.File.stderr().writer(io(), buffer);
    return &out_writer.interface;
}

/// Replacement for the removed `std.time.milliTimestamp()`.
pub fn milliTimestamp() i64 {
    return std.Io.Timestamp.now(io(), .real).toMilliseconds();
}

/// Replacement for `std.Thread.sleep(ns)`.
pub fn sleepNs(nanoseconds: u64) void {
    const dur: std.Io.Duration = .{ .nanoseconds = @intCast(nanoseconds) };
    std.Io.sleep(io(), dur, .awake) catch {};
}

/// Build an `std.http.Client` correctly populated for Zig 0.16.
///
/// The HTTPS path inside `std.http.Client.fetch` reads `client.now.?` to
/// validate certificates. If `client.now` is null and the CA bundle has not
/// been pre-rescanned, it panics. Pre-populate `now` from the real clock.
pub fn httpClient(allocator: std.mem.Allocator) std.http.Client {
    return .{
        .allocator = allocator,
        .io = io(),
        .now = std.Io.Clock.real.now(io()),
    };
}
