const std = @import("std");
const builtin = @import("builtin");

pub const Language = enum {
    en,
    zh,
    ja,
};

pub fn detect() Language {
    switch (builtin.os.tag) {
        .windows => return detectWindows(),
        else => return detectPosix(),
    }
}

fn detectPosix() Language {
    const env_vars = [_][]const u8{ "LC_ALL", "LC_MESSAGES", "LANG" };
    for (env_vars) |name| {
        const val = std.process.getEnvVarOwned(std.heap.page_allocator, name) catch continue;
        defer std.heap.page_allocator.free(val);

        if (fromLocale(val)) |lang| return lang;
    }
    return .en;
}

fn detectWindows() Language {
    if (builtin.os.tag != .windows) return .en;
    const k32 = struct {
        extern "kernel32" fn GetUserDefaultUILanguage() callconv(.winapi) u16;
    };
    const lang_id = k32.GetUserDefaultUILanguage() & 0xFF;
    return switch (lang_id) {
        0x04 => .zh,
        0x11 => .ja,
        else => .en,
    };
}

fn fromLocale(locale: []const u8) ?Language {
    if (locale.len >= 2) {
        if (std.mem.startsWith(u8, locale, "zh")) return .zh;
        if (std.mem.startsWith(u8, locale, "ja")) return .ja;
    }
    return null;
}

pub fn tr(lang: Language, en: []const u8, zh: []const u8, ja: []const u8) []const u8 {
    return switch (lang) {
        .en => en,
        .zh => zh,
        .ja => ja,
    };
}
