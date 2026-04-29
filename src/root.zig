//! By convention, root.zig is the root source file when making a library.
const std = @import("std");
const io_compat = @import("io_compat.zig");

pub fn bufferedPrint() !void {
    var stdout_buffer: [1024]u8 = undefined;
    var stdout_writer: std.Io.File.Writer = undefined;
    const stdout = io_compat.stdoutWriter(&stdout_buffer, &stdout_writer);

    try stdout.print("Run `zig build test` to run the tests.\n", .{});

    try stdout.flush();
}

pub fn add(a: i32, b: i32) i32 {
    return a + b;
}

test "basic add functionality" {
    try std.testing.expect(add(3, 7) == 10);
}
