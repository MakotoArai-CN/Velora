const std = @import("std");
const builtin = @import("builtin");

pub const TermCaps = struct {
    color: bool,
    unicode: bool,
    width: u32,

    pub fn detect() TermCaps {
        var caps: TermCaps = .{
            .color = false,
            .unicode = true,
            .width = 80,
        };

        switch (builtin.os.tag) {
            .windows => {
                caps.color = detectWindowsColor();
                caps.width = detectWindowsWidth();
            },
            else => {
                caps.color = detectPosixColor();
                caps.width = detectPosixWidth();
            },
        }

        return caps;
    }
};

fn detectPosixColor() bool {
    if (std.process.getEnvVarOwned(std.heap.page_allocator, "NO_COLOR") catch null) |no_color| {
        std.heap.page_allocator.free(no_color);
        return false;
    }

    if (std.process.getEnvVarOwned(std.heap.page_allocator, "TERM") catch null) |term| {
        defer std.heap.page_allocator.free(term);
        if (std.mem.eql(u8, term, "dumb")) return false;
        return true;
    }

    if (std.process.getEnvVarOwned(std.heap.page_allocator, "COLORTERM") catch null) |color_term| {
        std.heap.page_allocator.free(color_term);
        return true;
    }

    return std.posix.isatty(std.posix.STDOUT_FILENO);
}

fn detectPosixWidth() u32 {
    if (std.process.getEnvVarOwned(std.heap.page_allocator, "COLUMNS") catch null) |cols| {
        defer std.heap.page_allocator.free(cols);
        return std.fmt.parseInt(u32, cols, 10) catch 80;
    }
    return 80;
}

fn detectWindowsColor() bool {
    return true;
}

fn detectWindowsWidth() u32 {
    if (builtin.os.tag != .windows) return 80;
    const k32 = struct {
        extern "kernel32" fn GetConsoleScreenBufferInfo(
            hConsoleOutput: ?*anyopaque,
            lpConsoleScreenBufferInfo: *ConsoleScreenBufferInfo,
        ) callconv(.winapi) i32;
        extern "kernel32" fn GetStdHandle(nStdHandle: u32) callconv(.winapi) ?*anyopaque;

        const ConsoleScreenBufferInfo = extern struct {
            dwSize: extern struct { X: i16, Y: i16 },
            dwCursorPosition: extern struct { X: i16, Y: i16 },
            wAttributes: u16,
            srWindow: extern struct { Left: i16, Top: i16, Right: i16, Bottom: i16 },
            dwMaximumWindowSize: extern struct { X: i16, Y: i16 },
        };
    };

    const STD_OUTPUT_HANDLE: u32 = @bitCast(@as(i32, -11));
    const handle = k32.GetStdHandle(STD_OUTPUT_HANDLE) orelse return 80;
    var info: k32.ConsoleScreenBufferInfo = undefined;
    if (k32.GetConsoleScreenBufferInfo(handle, &info) != 0) {
        const w = info.srWindow.Right - info.srWindow.Left + 1;
        if (w > 0) return @intCast(w);
    }
    return 80;
}
