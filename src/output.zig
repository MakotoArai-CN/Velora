const std = @import("std");
const terminal = @import("terminal.zig");
const i18n = @import("i18n.zig");
const app = @import("app.zig");

pub const Color = struct {
    pub const reset = "\x1b[0m";
    pub const bold = "\x1b[1m";
    pub const dim = "\x1b[2m";

    pub const miku_cyan = "\x1b[38;2;57;197;187m";
    pub const miku_teal = "\x1b[38;2;0;170;170m";
    pub const miku_dark = "\x1b[38;2;20;120;120m";
    pub const miku_light = "\x1b[38;2;134;220;215m";
    pub const miku_accent = "\x1b[38;2;225;80;126m";
    pub const miku_pink = "\x1b[38;2;238;130;170m";
    pub const miku_white = "\x1b[38;2;230;245;245m";
    pub const miku_gray = "\x1b[38;2;140;180;178m";
    pub const miku_green = "\x1b[38;2;80;200;160m";
    pub const miku_yellow = "\x1b[38;2;230;200;80m";
    pub const miku_red = "\x1b[38;2;220;80;80m";

    pub const bg_miku = "\x1b[48;2;57;197;187m";
    pub const bg_dark = "\x1b[48;2;20;40;40m";
};

fn c(caps: terminal.TermCaps, code: []const u8) []const u8 {
    return if (caps.color) code else "";
}

fn contentWidth(caps: terminal.TermCaps) u32 {
    const w = if (caps.width > 4) caps.width - 4 else 40;
    return @max(w, 40);
}

fn boxTopLeft(caps: terminal.TermCaps) []const u8 {
    return if (caps.unicode) "╔" else "+";
}
fn boxTopRight(caps: terminal.TermCaps) []const u8 {
    return if (caps.unicode) "╗" else "+";
}
fn boxBottomLeft(caps: terminal.TermCaps) []const u8 {
    return if (caps.unicode) "╚" else "+";
}
fn boxBottomRight(caps: terminal.TermCaps) []const u8 {
    return if (caps.unicode) "╝" else "+";
}
fn boxHorizontal(caps: terminal.TermCaps) []const u8 {
    return if (caps.unicode) "═" else "=";
}
fn boxVertical(caps: terminal.TermCaps) []const u8 {
    return if (caps.unicode) "║" else "|";
}
fn boxSeparator(caps: terminal.TermCaps) []const u8 {
    return if (caps.unicode) "─" else "-";
}

pub fn displayWidth(s: []const u8) u32 {
    var width: u32 = 0;
    var i: usize = 0;
    while (i < s.len) {
        const byte = s[i];
        const seq_len: usize = if (byte < 0x80)
            1
        else if (byte < 0xE0)
            2
        else if (byte < 0xF0)
            3
        else
            4;
        if (i + seq_len > s.len) break;

        if (seq_len == 1) {
            width += 1;
        } else {
            var cp: u21 = switch (seq_len) {
                2 => @as(u21, byte & 0x1F) << 6 | @as(u21, s[i + 1] & 0x3F),
                3 => @as(u21, byte & 0x0F) << 12 | @as(u21, s[i + 1] & 0x3F) << 6 | @as(u21, s[i + 2] & 0x3F),
                4 => @as(u21, byte & 0x07) << 18 | @as(u21, s[i + 1] & 0x3F) << 12 | @as(u21, s[i + 2] & 0x3F) << 6 | @as(u21, s[i + 3] & 0x3F),
                else => 0,
            };
            _ = &cp;
            width += if (isCjkWide(cp)) @as(u32, 2) else @as(u32, 1);
        }
        i += seq_len;
    }
    return width;
}

fn isCjkWide(cp: u21) bool {
    return (cp >= 0x1100 and cp <= 0x115F) or
        (cp >= 0x2E80 and cp <= 0x303E) or
        (cp >= 0x3040 and cp <= 0x33BF) or
        (cp >= 0x3400 and cp <= 0x4DBF) or
        (cp >= 0x4E00 and cp <= 0x9FFF) or
        (cp >= 0xA000 and cp <= 0xA4CF) or
        (cp >= 0xAC00 and cp <= 0xD7AF) or
        (cp >= 0xF900 and cp <= 0xFAFF) or
        (cp >= 0xFE30 and cp <= 0xFE4F) or
        (cp >= 0xFF01 and cp <= 0xFF60) or
        (cp >= 0xFFE0 and cp <= 0xFFE6) or
        (cp >= 0x20000 and cp <= 0x2FA1F);
}

fn writePadded(w: *std.Io.Writer, s: []const u8, target_width: u32) !void {
    try w.print("{s}", .{s});
    const actual = displayWidth(s);
    if (actual < target_width) {
        var remaining = target_width - actual;
        while (remaining > 0) : (remaining -= 1) {
            try w.print(" ", .{});
        }
    }
}

pub fn printBanner(w: *std.Io.Writer, caps: terminal.TermCaps, version: []const u8) !void {
    const inner = contentWidth(caps);

    try w.print("{s}{s}", .{ c(caps, Color.miku_cyan), c(caps, Color.bold) });

    if (caps.unicode and inner >= 50) {
        const art = [_][]const u8{
            "██╗   ██╗███████╗██╗      ██████╗ ██████╗  █████╗ ",
            "██║   ██║██╔════╝██║     ██╔═══██╗██╔══██╗██╔══██╗",
            "██║   ██║█████╗  ██║     ██║   ██║██████╔╝███████║",
            "╚██╗ ██╔╝██╔══╝  ██║     ██║   ██║██╔══██╗██╔══██║",
            " ╚████╔╝ ███████╗███████╗╚██████╔╝██║  ██║██║  ██║",
            "  ╚═══╝  ╚══════╝╚══════╝ ╚═════╝ ╚═╝  ╚═╝╚═╝  ╚═╝",
        };

        try printBoxBorder(w, caps, inner, boxTopLeft(caps), boxTopRight(caps));
        try printBoxRow(w, caps, inner, "");
        for (art) |line| {
            try printBoxRow(w, caps, inner, line);
        }
        try printBoxRow(w, caps, inner, "");
        try printBoxBorder(w, caps, inner, boxBottomLeft(caps), boxBottomRight(caps));
    }

    try w.print("{s}", .{c(caps, Color.reset)});
    try w.print("{s}  {s} - {s} v{s}{s}\n\n", .{
        c(caps, Color.miku_light),
        app.display_name,
        app.subtitle_en,
        version,
        c(caps, Color.reset),
    });
}

fn printBoxBorder(w: *std.Io.Writer, caps: terminal.TermCaps, inner: u32, left: []const u8, right: []const u8) !void {
    try w.print("  {s}", .{left});
    var i: u32 = 0;
    while (i < inner) : (i += 1) {
        try w.print("{s}", .{boxHorizontal(caps)});
    }
    try w.print("{s}\n", .{right});
}

fn printBoxRow(w: *std.Io.Writer, caps: terminal.TermCaps, inner: u32, content: []const u8) !void {
    const content_w = displayWidth(content);
    const padding = if (inner > content_w) inner - content_w else 0;
    const left_pad = padding / 2;
    const right_pad = padding - left_pad;

    try w.print("  {s}", .{boxVertical(caps)});
    var j: u32 = 0;
    while (j < left_pad) : (j += 1) {
        try w.print(" ", .{});
    }
    if (content.len > 0) {
        try w.print("{s}", .{content});
    }
    var k: u32 = 0;
    while (k < right_pad) : (k += 1) {
        try w.print(" ", .{});
    }
    try w.print("{s}\n", .{boxVertical(caps)});
}

pub fn printSectionHeader(w: *std.Io.Writer, title: []const u8, caps: terminal.TermCaps) !void {
    const inner_width = contentWidth(caps);
    const title_len: u32 = displayWidth(title);
    const padding = if (inner_width > title_len) inner_width - title_len else 0;
    const left_pad = padding / 2;
    const right_pad = padding - left_pad;

    try w.print("\n{s}{s}", .{ c(caps, Color.miku_accent), c(caps, Color.bold) });
    try w.print("  {s}", .{boxTopLeft(caps)});
    var i: u32 = 0;
    while (i < inner_width) : (i += 1) {
        try w.print("{s}", .{boxHorizontal(caps)});
    }
    try w.print("{s}\n", .{boxTopRight(caps)});

    try w.print("  {s}", .{boxVertical(caps)});
    var j: u32 = 0;
    while (j < left_pad) : (j += 1) {
        try w.print(" ", .{});
    }
    try w.print("{s}{s}{s}{s}", .{ c(caps, Color.miku_cyan), title, c(caps, Color.miku_accent), c(caps, Color.bold) });
    var k: u32 = 0;
    while (k < right_pad) : (k += 1) {
        try w.print(" ", .{});
    }
    try w.print("{s}\n", .{boxVertical(caps)});

    try w.print("  {s}", .{boxBottomLeft(caps)});
    var l: u32 = 0;
    while (l < inner_width) : (l += 1) {
        try w.print("{s}", .{boxHorizontal(caps)});
    }
    try w.print("{s}{s}\n", .{ boxBottomRight(caps), c(caps, Color.reset) });
}

pub fn printKeyValue(w: *std.Io.Writer, key: []const u8, value: []const u8, caps: terminal.TermCaps) !void {
    try w.print("  {s}", .{c(caps, Color.miku_gray)});
    try writePadded(w, key, 24);
    try w.print("{s}{s}{s}{s}\n", .{ c(caps, Color.reset), c(caps, Color.miku_white), value, c(caps, Color.reset) });
}

pub fn printSeparator(w: *std.Io.Writer, caps: terminal.TermCaps) !void {
    const width = contentWidth(caps);
    try w.print("  {s}", .{c(caps, Color.miku_pink)});
    var i: u32 = 0;
    while (i < width) : (i += 1) {
        try w.print("{s}", .{boxSeparator(caps)});
    }
    try w.print("{s}\n", .{c(caps, Color.reset)});
}

pub fn printSuccess(w: *std.Io.Writer, msg: []const u8, caps: terminal.TermCaps) !void {
    const check = if (caps.unicode) "✓" else "[OK]";
    try w.print("  {s}{s}{s} {s}{s}{s}\n", .{
        c(caps, Color.miku_green),
        c(caps, Color.bold),
        check,
        c(caps, Color.reset),
        c(caps, Color.miku_white),
        msg,
    });
    try w.print("{s}", .{c(caps, Color.reset)});
}

pub fn printWarning(w: *std.Io.Writer, msg: []const u8, caps: terminal.TermCaps) !void {
    const warn = if (caps.unicode) "⚠" else "[!]";
    try w.print("  {s}{s}{s} {s}{s}{s}\n", .{
        c(caps, Color.miku_yellow),
        c(caps, Color.bold),
        warn,
        c(caps, Color.reset),
        c(caps, Color.miku_yellow),
        msg,
    });
    try w.print("{s}", .{c(caps, Color.reset)});
}

pub fn printError(w: *std.Io.Writer, msg: []const u8, caps: terminal.TermCaps) !void {
    const err_sym = if (caps.unicode) "✗" else "[X]";
    try w.print("  {s}{s}{s} {s}{s}{s}\n", .{
        c(caps, Color.miku_red),
        c(caps, Color.bold),
        err_sym,
        c(caps, Color.reset),
        c(caps, Color.miku_red),
        msg,
    });
    try w.print("{s}", .{c(caps, Color.reset)});
}

pub fn printInfo(w: *std.Io.Writer, msg: []const u8, caps: terminal.TermCaps) !void {
    const info_sym = if (caps.unicode) "●" else "[*]";
    try w.print("  {s}{s} {s}{s}{s}\n", .{
        c(caps, Color.miku_cyan),
        info_sym,
        c(caps, Color.miku_white),
        msg,
        c(caps, Color.reset),
    });
}

pub fn printMenuItem(w: *std.Io.Writer, index: u8, label: []const u8, caps: terminal.TermCaps) !void {
    try w.print("    {s}{s}[{d}]{s} {s}{s}{s}\n", .{
        c(caps, Color.miku_accent),
        c(caps, Color.bold),
        index,
        c(caps, Color.reset),
        c(caps, Color.miku_light),
        label,
        c(caps, Color.reset),
    });
}

pub fn printPrompt(w: *std.Io.Writer, msg: []const u8, caps: terminal.TermCaps) !void {
    try w.print("  {s}{s}{s}{s} ", .{
        c(caps, Color.miku_accent),
        c(caps, Color.bold),
        msg,
        c(caps, Color.reset),
    });
}
