const std = @import("std");
const config_mod = @import("config.zig");
const app = @import("app.zig");
const env_mod = @import("env.zig");

pub const SiteType = enum {
    cx, // Codex
    cc, // Claude Code
    oc, // OpenCode

    pub fn toString(self: SiteType) []const u8 {
        return switch (self) {
            .cx => "cx",
            .cc => "cc",
            .oc => "oc",
        };
    }

    pub fn displayName(self: SiteType) []const u8 {
        return switch (self) {
            .cx => "Codex",
            .cc => "Claude Code",
            .oc => "OpenCode",
        };
    }

    pub fn fromString(s: []const u8) ?SiteType {
        if (std.mem.eql(u8, s, "cx") or std.mem.eql(u8, s, "codex")) return .cx;
        if (std.mem.eql(u8, s, "cc") or std.mem.eql(u8, s, "claude")) return .cc;
        if (std.mem.eql(u8, s, "oc") or std.mem.eql(u8, s, "opencode")) return .oc;
        return null;
    }
};

pub const Site = struct {
    site_type: SiteType,
    base_url: []const u8,
    api_key: []const u8,
};

pub const SiteEntry = struct {
    alias: []const u8,
    site: Site,
};

pub const MAX_SITES = 64;

pub const SitesStore = struct {
    entries: [MAX_SITES]SiteEntry = undefined,
    count: usize = 0,
    allocator: std.mem.Allocator = undefined,
    initialized: bool = false,

    pub fn deinit(self: *SitesStore, allocator: std.mem.Allocator) void {
        if (!self.initialized) return;
        for (self.entries[0..self.count]) |entry| {
            allocator.free(entry.alias);
            allocator.free(entry.site.base_url);
            allocator.free(entry.site.api_key);
        }
        self.count = 0;
        self.initialized = false;
    }

    pub fn getSite(self: *const SitesStore, alias: []const u8) ?Site {
        for (self.entries[0..self.count]) |entry| {
            if (std.mem.eql(u8, entry.alias, alias)) {
                return entry.site;
            }
        }
        return null;
    }

    pub fn addOrUpdate(self: *SitesStore, allocator: std.mem.Allocator, alias: []const u8, site: Site) !void {
        self.initialized = true;
        // Check if alias exists - update in place
        for (self.entries[0..self.count]) |*entry| {
            if (std.mem.eql(u8, entry.alias, alias)) {
                // Free old strings
                allocator.free(entry.site.base_url);
                allocator.free(entry.site.api_key);
                // Dupe new strings individually (no arena realloc issue)
                const new_url = try allocator.dupe(u8, site.base_url);
                const new_key = try allocator.dupe(u8, site.api_key);
                entry.site = .{
                    .site_type = site.site_type,
                    .base_url = new_url,
                    .api_key = new_key,
                };
                return;
            }
        }
        // Add new entry
        if (self.count >= MAX_SITES) return error.TooManySites;
        const stored_alias = try allocator.dupe(u8, alias);
        const stored_url = try allocator.dupe(u8, site.base_url);
        const stored_key = try allocator.dupe(u8, site.api_key);
        self.entries[self.count] = .{
            .alias = stored_alias,
            .site = .{
                .site_type = site.site_type,
                .base_url = stored_url,
                .api_key = stored_key,
            },
        };
        self.count += 1;
    }

    pub fn remove(self: *SitesStore, alias: []const u8) bool {
        for (0..self.count) |i| {
            if (std.mem.eql(u8, self.entries[i].alias, alias)) {
                if (i + 1 < self.count) {
                    const dest = self.entries[i .. self.count - 1];
                    const src = self.entries[i + 1 .. self.count];
                    @memcpy(dest, src);
                }
                self.count -= 1;
                return true;
            }
        }
        return false;
    }
};

pub fn getSitesFilePath(allocator: std.mem.Allocator) ![]u8 {
    const home = config_mod.getHomeDir(allocator) orelse return error.NoHomeDir;
    defer allocator.free(home);
    const dir = try std.fs.path.join(allocator, &.{ home, app.config_dir_name });
    defer allocator.free(dir);

    // Ensure directory exists
    std.fs.makeDirAbsolute(dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };

    return try std.fs.path.join(allocator, &.{ dir, app.sites_filename });
}

pub fn loadSites(allocator: std.mem.Allocator) !SitesStore {
    var store: SitesStore = .{};
    errdefer store.deinit(allocator);

    const path = getSitesFilePath(allocator) catch return store;
    defer allocator.free(path);

    const file = std.fs.openFileAbsolute(path, .{}) catch return store;
    defer file.close();

    var buf: [65536]u8 = undefined;
    const bytes_read = file.readAll(&buf) catch return store;
    const content = buf[0..bytes_read];

    if (content.len == 0) return store;

    // Parse JSON manually: find each alias block within "sites": { ... }
    const sites_key = "\"sites\"";
    const sites_pos = std.mem.indexOf(u8, content, sites_key) orelse return store;
    const after_sites = content[sites_pos + sites_key.len ..];

    // Find the opening brace of the sites object
    const obj_start = std.mem.indexOf(u8, after_sites, "{") orelse return store;
    const sites_body = after_sites[obj_start + 1 ..];

    // Find matching closing brace (handle nesting)
    const sites_inner = findMatchingBrace(sites_body) orelse return store;

    // Parse each alias entry
    var pos: usize = 0;
    while (pos < sites_inner.len) {
        // Find next quoted key (alias name)
        const q1 = std.mem.indexOf(u8, sites_inner[pos..], "\"") orelse break;
        const alias_start = pos + q1 + 1;
        const q2 = std.mem.indexOf(u8, sites_inner[alias_start..], "\"") orelse break;
        const alias = sites_inner[alias_start..][0..q2];

        // Find the opening brace of this entry
        const after_alias = sites_inner[alias_start + q2 + 1 ..];
        const entry_brace = std.mem.indexOf(u8, after_alias, "{") orelse break;
        const entry_body = after_alias[entry_brace + 1 ..];
        const entry_inner = findMatchingBrace(entry_body) orelse break;

        // Extract fields from the entry
        const site_type_str = env_mod.extractJsonValue(allocator, entry_body[0 .. entry_inner.len + 1], "type") catch null;
        defer if (site_type_str) |s| allocator.free(s);
        const base_url = env_mod.extractJsonValue(allocator, entry_body[0 .. entry_inner.len + 1], "base_url") catch null;
        defer if (base_url) |s| allocator.free(s);
        const api_key = env_mod.extractJsonValue(allocator, entry_body[0 .. entry_inner.len + 1], "api_key") catch null;
        defer if (api_key) |s| allocator.free(s);

        if (site_type_str) |st| {
            if (SiteType.fromString(st)) |stype| {
                const site = Site{
                    .site_type = stype,
                    .base_url = base_url orelse "",
                    .api_key = api_key orelse "",
                };
                store.addOrUpdate(allocator, alias, site) catch break;
            }
        }

        // Advance past this entry
        const entry_end_offset = @intFromPtr(entry_inner.ptr) - @intFromPtr(sites_inner.ptr) + entry_inner.len + 1;
        pos = entry_end_offset;
    }

    return store;
}

pub fn saveSites(allocator: std.mem.Allocator, store: *const SitesStore) !void {
    const path = try getSitesFilePath(allocator);
    defer allocator.free(path);

    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(allocator);

    try out.appendSlice(allocator, "{\n  \"sites\": {");

    for (0..store.count) |i| {
        const entry = store.entries[i];
        if (i > 0) {
            try out.append(allocator, ',');
        }
        try out.appendSlice(allocator, "\n    \"");
        try out.appendSlice(allocator, entry.alias);
        try out.appendSlice(allocator, "\": {\n      \"type\": \"");
        try out.appendSlice(allocator, entry.site.site_type.toString());
        try out.appendSlice(allocator, "\",\n      \"base_url\": \"");
        try out.appendSlice(allocator, entry.site.base_url);
        try out.appendSlice(allocator, "\",\n      \"api_key\": \"");
        try out.appendSlice(allocator, entry.site.api_key);
        try out.appendSlice(allocator, "\"\n    }");
    }

    if (store.count > 0) {
        try out.append(allocator, '\n');
        try out.appendSlice(allocator, "  ");
    }
    try out.appendSlice(allocator, "}\n}\n");

    const file = try std.fs.createFileAbsolute(path, .{});
    defer file.close();
    try file.writeAll(out.items);
}

fn findMatchingBrace(content: []const u8) ?[]const u8 {
    var depth: i32 = 1;
    var i: usize = 0;
    var in_string = false;
    var escaped = false;

    while (i < content.len) : (i += 1) {
        const ch = content[i];
        if (escaped) {
            escaped = false;
            continue;
        }
        if (ch == '\\' and in_string) {
            escaped = true;
            continue;
        }
        if (ch == '"') {
            in_string = !in_string;
            continue;
        }
        if (in_string) continue;

        if (ch == '{') {
            depth += 1;
        } else if (ch == '}') {
            depth -= 1;
            if (depth == 0) {
                return content[0..i];
            }
        }
    }
    return null;
}

pub fn maskKey(buf: []u8, key: []const u8) []const u8 {
    if (key.len <= 8) {
        return std.fmt.bufPrint(buf, "{s}****", .{key}) catch key;
    }
    const prefix = key[0..6];
    const suffix = key[key.len - 4 ..];
    return std.fmt.bufPrint(buf, "{s}...{s}", .{ prefix, suffix }) catch key;
}

test "site type from string" {
    try std.testing.expectEqual(SiteType.cx, SiteType.fromString("cx").?);
    try std.testing.expectEqual(SiteType.cc, SiteType.fromString("cc").?);
    try std.testing.expectEqual(SiteType.cx, SiteType.fromString("codex").?);
    try std.testing.expectEqual(SiteType.cc, SiteType.fromString("claude").?);
    try std.testing.expectEqual(@as(?SiteType, null), SiteType.fromString("unknown"));
}

test "mask key" {
    var buf: [64]u8 = undefined;
    const masked = maskKey(&buf, "sk-abcdefghijklmnop");
    try std.testing.expectEqualStrings("sk-abc...mnop", masked);
}
