const std = @import("std");
const builtin = @import("builtin");

pub const TermCaps = struct {
    color: bool = false,
    unicode: bool = false,
    width: u32 = 80,

    pub fn detect() TermCaps {
        var caps = TermCaps{};
        switch (builtin.os.tag) {
            .windows => detectWindows(&caps),
            else => detectPosix(&caps),
        }
        return caps;
    }
};

fn detectWindows(caps: *TermCaps) void {
    const windows = std.os.windows;
    const k32 = struct {
        const CONSOLE_SCREEN_BUFFER_INFO = extern struct {
            dwSize: extern struct { X: i16, Y: i16 },
            dwCursorPosition: extern struct { X: i16, Y: i16 },
            wAttributes: u16,
            srWindow: extern struct { Left: i16, Top: i16, Right: i16, Bottom: i16 },
            dwMaximumWindowSize: extern struct { X: i16, Y: i16 },
        };

        extern "kernel32" fn GetStdHandle(nStdHandle: windows.DWORD) callconv(.winapi) ?windows.HANDLE;
        extern "kernel32" fn GetConsoleMode(hConsole: windows.HANDLE, lpMode: *windows.DWORD) callconv(.winapi) windows.BOOL;
        extern "kernel32" fn SetConsoleMode(hConsole: windows.HANDLE, dwMode: windows.DWORD) callconv(.winapi) windows.BOOL;
        extern "kernel32" fn SetConsoleOutputCP(wCodePageID: windows.UINT) callconv(.winapi) windows.BOOL;
        extern "kernel32" fn GetConsoleScreenBufferInfo(hConsole: windows.HANDLE, lpInfo: *CONSOLE_SCREEN_BUFFER_INFO) callconv(.winapi) windows.BOOL;
    };

    const STD_OUTPUT_HANDLE: windows.DWORD = @bitCast(@as(i32, -11));
    const ENABLE_VIRTUAL_TERMINAL_PROCESSING: windows.DWORD = 0x0004;

    const handle = k32.GetStdHandle(STD_OUTPUT_HANDLE) orelse return;

    // Redirected stdout should stay plain ASCII/no-color.
    var mode: windows.DWORD = 0;
    if (k32.GetConsoleMode(handle, &mode) == 0) return;

    if (k32.SetConsoleMode(handle, mode | ENABLE_VIRTUAL_TERMINAL_PROCESSING) != 0) {
        caps.color = true;
    }

    // Match Zenith: use UTF-8 code page so cmd.exe / older consoles don't garble UTF-8 output.
    if (k32.SetConsoleOutputCP(65001) != 0) {
        caps.unicode = true;
    }

    var csbi: k32.CONSOLE_SCREEN_BUFFER_INFO = undefined;
    if (k32.GetConsoleScreenBufferInfo(handle, &csbi) != 0) {
        const w = csbi.srWindow.Right - csbi.srWindow.Left + 1;
        if (w > 0) caps.width = @intCast(w);
    }
}

fn detectPosix(caps: *TermCaps) void {
    const fd = std.posix.STDOUT_FILENO;
    if (!std.posix.isatty(fd)) return;

    caps.unicode = true;

    const no_color = std.process.getEnvVarOwned(std.heap.page_allocator, "NO_COLOR") catch null;
    defer if (no_color) |s| std.heap.page_allocator.free(s);

    const term = std.process.getEnvVarOwned(std.heap.page_allocator, "TERM") catch null;
    defer if (term) |s| std.heap.page_allocator.free(s);

    if (no_color == null and (term == null or !std.mem.eql(u8, term.?, "dumb"))) {
        caps.color = true;
    }

    var ws: std.posix.winsize = undefined;
    const rc = std.posix.system.ioctl(fd, std.posix.T.IOCGWINSZ, @intFromPtr(&ws));
    const ok = if (@TypeOf(rc) == usize) (@as(isize, @bitCast(rc)) == 0) else (rc == 0);
    if (ok and ws.col > 0) {
        caps.width = ws.col;
        return;
    }

    if (std.process.getEnvVarOwned(std.heap.page_allocator, "COLUMNS") catch null) |cols| {
        defer std.heap.page_allocator.free(cols);
        caps.width = std.fmt.parseInt(u32, cols, 10) catch 80;
    }
}
