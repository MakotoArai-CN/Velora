const std = @import("std");
const config_mod = @import("config.zig");
const app = @import("app.zig");
const env_mod = @import("env.zig");

pub const SiteType = enum {
    cx, // Codex
    cc, // Claude Code
    oc, // OpenCode
    nb, // Nanobot
    ow, // OpenClaw

    pub fn toString(self: SiteType) []const u8 {
        return switch (self) {
            .cx => "cx",
            .cc => "cc",
            .oc => "oc",
            .nb => "nb",
            .ow => "ow",
        };
    }

    pub fn displayName(self: SiteType) []const u8 {
        return switch (self) {
            .cx => "Codex",
            .cc => "Claude Code",
            .oc => "OpenCode",
            .nb => "Nanobot",
            .ow => "OpenClaw",
        };
    }

    pub fn fromString(s: []const u8) ?SiteType {
        if (std.mem.eql(u8, s, "cx") or std.mem.eql(u8, s, "codex")) return .cx;
        if (std.mem.eql(u8, s, "cc") or std.mem.eql(u8, s, "claude")) return .cc;
        if (std.mem.eql(u8, s, "oc") or std.mem.eql(u8, s, "opencode")) return .oc;
        if (std.mem.eql(u8, s, "nb") or std.mem.eql(u8, s, "nanobot")) return .nb;
        if (std.mem.eql(u8, s, "ow") or std.mem.eql(u8, s, "openclaw")) return .ow;
        return null;
    }
};

pub fn defaultModelForType(site_type: SiteType) []const u8 {
    return switch (site_type) {
        .cc => app.default_model_cc,
        .cx => app.default_model_cx,
        .oc => app.default_model_oc,
        .nb => app.default_model_nb,
        .ow => app.default_model_ow,
    };
}

pub const SiteSelectionMode = enum {
    manual_defaults,
    last_used,
    profile_score,

    pub fn toString(self: SiteSelectionMode) []const u8 {
        return switch (self) {
            .manual_defaults => "manual_defaults",
            .last_used => "last_used",
            .profile_score => "profile_score",
        };
    }

    pub fn fromString(s: []const u8) ?SiteSelectionMode {
        if (std.mem.eql(u8, s, "manual_defaults")) return .manual_defaults;
        if (std.mem.eql(u8, s, "last_used")) return .last_used;
        if (std.mem.eql(u8, s, "profile_score")) return .profile_score;
        return null;
    }
};

pub const SortMode = enum {
    time, // insertion order (default)
    alpha, // alphabetical by alias name
    tool, // group by site_type (cx, cc, oc, nb, ow)
    model, // group by model family (openai, claude, unknown)

    pub fn toString(self: SortMode) []const u8 {
        return switch (self) {
            .time => "time",
            .alpha => "alpha",
            .tool => "tool",
            .model => "model",
        };
    }

    pub fn fromString(s: []const u8) ?SortMode {
        if (std.mem.eql(u8, s, "time")) return .time;
        if (std.mem.eql(u8, s, "alpha")) return .alpha;
        if (std.mem.eql(u8, s, "tool")) return .tool;
        if (std.mem.eql(u8, s, "model")) return .model;
        return null;
    }
};

pub const Site = struct {
    site_type: SiteType,
    base_url: []const u8,
    api_key: []const u8,
    model: []const u8 = "", // empty = use default for site_type
    archived: bool = false,
    default_tools_mask: u8 = 0,
    selection_mode: SiteSelectionMode = .manual_defaults,
    last_used_tool: ?SiteType = null,

    // Per-tool model overrides (empty = not configured for that tool)
    models_cx: []const u8 = "",
    models_cc: []const u8 = "",
    models_oc: []const u8 = "",
    models_nb: []const u8 = "",
    models_ow: []const u8 = "",

    pub fn effectiveModel(self: Site) []const u8 {
        if (self.model.len > 0) return self.model;
        return defaultModelForType(self.site_type);
    }

    pub fn modelOverrideForTool(self: Site, tool_type: SiteType) []const u8 {
        return switch (tool_type) {
            .cx => self.models_cx,
            .cc => self.models_cc,
            .oc => self.models_oc,
            .nb => self.models_nb,
            .ow => self.models_ow,
        };
    }

    /// Get model for a specific tool type. Falls back to:
    /// 1. Per-tool override (models_xx)
    /// 2. Primary model (if site_type matches)
    /// 3. Default for the tool type
    pub fn effectiveModelForTool(self: Site, tool_type: SiteType) []const u8 {
        const override = self.modelOverrideForTool(tool_type);
        if (override.len > 0) return override;
        if (self.site_type == tool_type) return self.effectiveModel();
        return defaultModelForType(tool_type);
    }
};

pub fn toolMask(tool_type: SiteType) u8 {
    return switch (tool_type) {
        .cx => 1 << 0,
        .cc => 1 << 1,
        .oc => 1 << 2,
        .nb => 1 << 3,
        .ow => 1 << 4,
    };
}

pub fn hasDefaultTool(site: Site, tool_type: SiteType) bool {
    const mask = if (site.default_tools_mask == 0) toolMask(site.site_type) else site.default_tools_mask;
    return (mask & toolMask(tool_type)) != 0;
}

pub fn implicitTargetTool(site: Site) SiteType {
    if (site.selection_mode == .last_used) {
        if (site.last_used_tool) |tool| {
            if (hasDefaultTool(site, tool)) return tool;
        }
    }
    for ([_]SiteType{ .cx, .cc, .oc, .nb, .ow }) |tool| {
        if (hasDefaultTool(site, tool)) return tool;
    }
    return site.site_type;
}

pub fn ensureLegacyDefaultTool(site: *Site) void {
    if (site.default_tools_mask == 0) {
        site.default_tools_mask = toolMask(site.site_type);
    }
}

pub fn setDefaultTool(site: *Site, tool_type: SiteType, enabled: bool) void {
    const mask = toolMask(tool_type);
    if (enabled) {
        site.default_tools_mask |= mask;
    } else {
        site.default_tools_mask &= ~mask;
    }
}

pub fn defaultToolsSummary(site: Site, buf: []u8) []const u8 {
    var fbs = std.io.fixedBufferStream(buf);
    const w = fbs.writer();
    var first = true;
    for ([_]SiteType{ .cx, .cc, .oc, .nb, .ow }) |tool| {
        if (!hasDefaultTool(site, tool)) continue;
        if (!first) w.writeAll(", ") catch {};
        w.writeAll(tool.toString()) catch {};
        first = false;
    }
    if (first) return site.site_type.toString();
    return fbs.getWritten();
}

pub fn availableDefaultTools(site: Site, buf: *[5]SiteType) []const SiteType {
    var count: usize = 0;
    for ([_]SiteType{ .cx, .cc, .oc, .nb, .ow }) |tool| {
        if (hasDefaultTool(site, tool)) {
            buf[count] = tool;
            count += 1;
        }
    }
    if (count == 0) {
        buf[0] = site.site_type;
        return buf[0..1];
    }
    return buf[0..count];
}

pub fn updateLastUsed(site: *Site, tool_type: SiteType) void {
    site.last_used_tool = tool_type;
}

pub fn defaultToolCount(site: Site) u8 {
    var count: u8 = 0;
    for ([_]SiteType{ .cx, .cc, .oc, .nb, .ow }) |tool| {
        if (hasDefaultTool(site, tool)) count += 1;
    }
    return count;
}

pub fn firstDefaultTool(site: Site) SiteType {
    for ([_]SiteType{ .cx, .cc, .oc, .nb, .ow }) |tool| {
        if (hasDefaultTool(site, tool)) return tool;
    }
    return site.site_type;
}

pub fn setLegacyDefaults(site: *Site) void {
    site.default_tools_mask = toolMask(site.site_type);
    if (site.last_used_tool == null) site.last_used_tool = site.site_type;
}

pub fn ensureSelectionState(site: *Site) void {
    ensureLegacyDefaultTool(site);
    if (site.selection_mode == .last_used and site.last_used_tool == null) {
        site.last_used_tool = firstDefaultTool(site.*);
    }
}

pub fn setDefaultTools(site: *Site, tools: []const SiteType) void {
    site.default_tools_mask = 0;
    for (tools) |tool| setDefaultTool(site, tool, true);
    ensureLegacyDefaultTool(site);
}

fn toolModelField(site: *Site, tool_type: SiteType) *[]const u8 {
    return switch (tool_type) {
        .cx => &site.models_cx,
        .cc => &site.models_cc,
        .oc => &site.models_oc,
        .nb => &site.models_nb,
        .ow => &site.models_ow,
    };
}

pub fn setToolModelOverride(store: *SitesStore, allocator: std.mem.Allocator, alias: []const u8, tool_type: SiteType, model: []const u8) !bool {
    for (store.entries[0..store.count]) |*entry| {
        if (!std.mem.eql(u8, entry.alias, alias)) continue;
        const field = toolModelField(&entry.site, tool_type);
        if (field.*.len > 0) allocator.free(field.*);
        field.* = if (model.len > 0) try allocator.dupe(u8, model) else @as([]const u8, "");
        return true;
    }
    return false;
}

pub fn clearToolModelOverride(store: *SitesStore, allocator: std.mem.Allocator, alias: []const u8, tool_type: SiteType) bool {
    for (store.entries[0..store.count]) |*entry| {
        if (!std.mem.eql(u8, entry.alias, alias)) continue;
        const field = toolModelField(&entry.site, tool_type);
        if (field.*.len > 0) allocator.free(field.*);
        field.* = "";
        return true;
    }
    return false;
}

pub fn updateArchived(store: *SitesStore, alias: []const u8, archived: bool) bool {
    for (store.entries[0..store.count]) |*entry| {
        if (!std.mem.eql(u8, entry.alias, alias)) continue;
        entry.site.archived = archived;
        return true;
    }
    return false;
}

pub fn findEntry(store: *SitesStore, alias: []const u8) ?*SiteEntry {
    for (store.entries[0..store.count]) |*entry| {
        if (std.mem.eql(u8, entry.alias, alias)) return entry;
    }
    return null;
}

pub fn findEntryConst(store: *const SitesStore, alias: []const u8) ?*const SiteEntry {
    for (store.entries[0..store.count]) |*entry| {
        if (std.mem.eql(u8, entry.alias, alias)) return entry;
    }
    return null;
}

pub const SiteEntry = struct {
    alias: []const u8,
    site: Site,
};

pub const MAX_SITES = 64;

pub const Settings = struct {
    model_check: bool = true, // enable model detection on 'use'
    list_latency: bool = true, // enable latency check on 'list'
    auto_archive: bool = false, // enable auto-archive of unreachable sites
    auto_pick_compatible_model: bool = true, // auto-pick compatible model on target mismatch
    list_sort: SortMode = .time, // default sort mode for 'list'
};

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
            if (entry.site.model.len > 0) allocator.free(entry.site.model);
            if (entry.site.models_cx.len > 0) allocator.free(entry.site.models_cx);
            if (entry.site.models_cc.len > 0) allocator.free(entry.site.models_cc);
            if (entry.site.models_oc.len > 0) allocator.free(entry.site.models_oc);
            if (entry.site.models_nb.len > 0) allocator.free(entry.site.models_nb);
            if (entry.site.models_ow.len > 0) allocator.free(entry.site.models_ow);
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

        const new_url = try allocator.dupe(u8, site.base_url);
        errdefer allocator.free(new_url);
        const new_key = try allocator.dupe(u8, site.api_key);
        errdefer allocator.free(new_key);
        const new_model = if (site.model.len > 0) try allocator.dupe(u8, site.model) else @as([]const u8, "");
        errdefer if (new_model.len > 0) allocator.free(new_model);
        const new_mcx = if (site.models_cx.len > 0) try allocator.dupe(u8, site.models_cx) else @as([]const u8, "");
        errdefer if (new_mcx.len > 0) allocator.free(new_mcx);
        const new_mcc = if (site.models_cc.len > 0) try allocator.dupe(u8, site.models_cc) else @as([]const u8, "");
        errdefer if (new_mcc.len > 0) allocator.free(new_mcc);
        const new_moc = if (site.models_oc.len > 0) try allocator.dupe(u8, site.models_oc) else @as([]const u8, "");
        errdefer if (new_moc.len > 0) allocator.free(new_moc);
        const new_mnb = if (site.models_nb.len > 0) try allocator.dupe(u8, site.models_nb) else @as([]const u8, "");
        errdefer if (new_mnb.len > 0) allocator.free(new_mnb);
        const new_mow = if (site.models_ow.len > 0) try allocator.dupe(u8, site.models_ow) else @as([]const u8, "");
        errdefer if (new_mow.len > 0) allocator.free(new_mow);

        // Check if alias exists - update in place
        for (self.entries[0..self.count]) |*entry| {
            if (std.mem.eql(u8, entry.alias, alias)) {
                allocator.free(entry.site.base_url);
                allocator.free(entry.site.api_key);
                if (entry.site.model.len > 0) allocator.free(entry.site.model);
                if (entry.site.models_cx.len > 0) allocator.free(entry.site.models_cx);
                if (entry.site.models_cc.len > 0) allocator.free(entry.site.models_cc);
                if (entry.site.models_oc.len > 0) allocator.free(entry.site.models_oc);
                if (entry.site.models_nb.len > 0) allocator.free(entry.site.models_nb);
                if (entry.site.models_ow.len > 0) allocator.free(entry.site.models_ow);
                entry.site = .{
                    .site_type = site.site_type,
                    .base_url = new_url,
                    .api_key = new_key,
                    .model = new_model,
                    .archived = site.archived,
                    .default_tools_mask = site.default_tools_mask,
                    .selection_mode = site.selection_mode,
                    .last_used_tool = site.last_used_tool,
                    .models_cx = new_mcx,
                    .models_cc = new_mcc,
                    .models_oc = new_moc,
                    .models_nb = new_mnb,
                    .models_ow = new_mow,
                };
                return;
            }
        }

        // Add new entry
        if (self.count >= MAX_SITES) return error.TooManySites;
        const stored_alias = try allocator.dupe(u8, alias);
        errdefer allocator.free(stored_alias);
        self.entries[self.count] = .{
            .alias = stored_alias,
            .site = .{
                .site_type = site.site_type,
                .base_url = new_url,
                .api_key = new_key,
                .model = new_model,
                .archived = site.archived,
                .default_tools_mask = site.default_tools_mask,
                .selection_mode = site.selection_mode,
                .last_used_tool = site.last_used_tool,
                .models_cx = new_mcx,
                .models_cc = new_mcc,
                .models_oc = new_moc,
                .models_nb = new_mnb,
                .models_ow = new_mow,
            },
        };
        self.count += 1;
    }

    fn freeEntry(self: *SitesStore, allocator: std.mem.Allocator, index: usize) void {
        const entry = self.entries[index];
        allocator.free(entry.alias);
        allocator.free(entry.site.base_url);
        allocator.free(entry.site.api_key);
        if (entry.site.model.len > 0) allocator.free(entry.site.model);
        if (entry.site.models_cx.len > 0) allocator.free(entry.site.models_cx);
        if (entry.site.models_cc.len > 0) allocator.free(entry.site.models_cc);
        if (entry.site.models_oc.len > 0) allocator.free(entry.site.models_oc);
        if (entry.site.models_nb.len > 0) allocator.free(entry.site.models_nb);
        if (entry.site.models_ow.len > 0) allocator.free(entry.site.models_ow);
    }

    pub fn remove(self: *SitesStore, allocator: std.mem.Allocator, alias: []const u8) bool {
        for (0..self.count) |i| {
            if (std.mem.eql(u8, self.entries[i].alias, alias)) {
                self.freeEntry(allocator, i);
                var j = i;
                while (j + 1 < self.count) : (j += 1) {
                    self.entries[j] = self.entries[j + 1];
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

pub fn loadSettings(allocator: std.mem.Allocator) Settings {
    var settings: Settings = .{};

    const path = getSitesFilePath(allocator) catch return settings;
    defer allocator.free(path);

    const file = std.fs.openFileAbsolute(path, .{}) catch return settings;
    defer file.close();

    var buf: [65536]u8 = undefined;
    const bytes_read = file.readAll(&buf) catch return settings;
    const content = buf[0..bytes_read];

    const settings_key = "\"settings\"";
    const settings_pos = std.mem.indexOf(u8, content, settings_key) orelse return settings;
    const after = content[settings_pos + settings_key.len ..];
    const obj_start = std.mem.indexOf(u8, after, "{") orelse return settings;
    const body = after[obj_start + 1 ..];
    const inner = findMatchingBrace(body) orelse return settings;

    const mc = env_mod.extractJsonValue(allocator, body[0 .. inner.len + 1], "model_check") catch null;
    defer if (mc) |s| allocator.free(s);
    if (mc) |v| {
        if (std.mem.eql(u8, v, "false")) settings.model_check = false;
    }

    const ll = env_mod.extractJsonValue(allocator, body[0 .. inner.len + 1], "list_latency") catch null;
    defer if (ll) |s| allocator.free(s);
    if (ll) |v| {
        if (std.mem.eql(u8, v, "false")) settings.list_latency = false;
    }

    const aa = env_mod.extractJsonValue(allocator, body[0 .. inner.len + 1], "auto_archive") catch null;
    defer if (aa) |s| allocator.free(s);
    if (aa) |v| {
        if (std.mem.eql(u8, v, "true")) settings.auto_archive = true;
    }

    const ap = env_mod.extractJsonValue(allocator, body[0 .. inner.len + 1], "auto_pick_compatible_model") catch null;
    defer if (ap) |s| allocator.free(s);
    if (ap) |v| {
        if (std.mem.eql(u8, v, "false")) settings.auto_pick_compatible_model = false;
    }

    const ls = env_mod.extractJsonValue(allocator, body[0 .. inner.len + 1], "list_sort") catch null;
    defer if (ls) |s| allocator.free(s);
    if (ls) |v| {
        if (SortMode.fromString(v)) |mode| settings.list_sort = mode;
    }

    return settings;
}

pub fn saveSettings(allocator: std.mem.Allocator, settings: Settings) !void {
    // Load existing file, replace/insert settings block, preserve everything else
    const path = try getSitesFilePath(allocator);
    defer allocator.free(path);

    var existing: std.ArrayListUnmanaged(u8) = .empty;
    defer existing.deinit(allocator);

    const has_file = blk: {
        const file = std.fs.openFileAbsolute(path, .{}) catch break :blk false;
        defer file.close();
        var buf: [65536]u8 = undefined;
        const bytes_read = file.readAll(&buf) catch break :blk false;
        existing.appendSlice(allocator, buf[0..bytes_read]) catch break :blk false;
        break :blk true;
    };

    if (!has_file or existing.items.len == 0) {
        // Write new file with just settings
        var out: std.ArrayListUnmanaged(u8) = .empty;
        defer out.deinit(allocator);
        try out.appendSlice(allocator, "{\n  \"settings\": {\n    \"model_check\": ");
        try out.appendSlice(allocator, if (settings.model_check) "true" else "false");
        try out.appendSlice(allocator, ",\n    \"list_latency\": ");
        try out.appendSlice(allocator, if (settings.list_latency) "true" else "false");
        try out.appendSlice(allocator, ",\n    \"auto_archive\": ");
        try out.appendSlice(allocator, if (settings.auto_archive) "true" else "false");
        try out.appendSlice(allocator, ",\n    \"auto_pick_compatible_model\": ");
        try out.appendSlice(allocator, if (settings.auto_pick_compatible_model) "true" else "false");
        try out.appendSlice(allocator, ",\n    \"list_sort\": \"");
        try out.appendSlice(allocator, settings.list_sort.toString());
        try out.appendSlice(allocator, "\"\n  },\n  \"sites\": {}\n}\n");
        const file = try std.fs.createFileAbsolute(path, .{});
        defer file.close();
        try file.writeAll(out.items);
        return;
    }

    const content = existing.items;

    // Build new settings block text
    var settings_text_buf: [640]u8 = undefined;
    const settings_text = std.fmt.bufPrint(&settings_text_buf,
        \\  "settings": {{
        \\    "model_check": {s},
        \\    "list_latency": {s},
        \\    "auto_archive": {s},
        \\    "auto_pick_compatible_model": {s},
        \\    "list_sort": "{s}"
        \\  }}
    , .{
        if (settings.model_check) "true" else "false",
        if (settings.list_latency) "true" else "false",
        if (settings.auto_archive) "true" else "false",
        if (settings.auto_pick_compatible_model) "true" else "false",
        settings.list_sort.toString(),
    }) catch return;

    // Try to find and replace existing settings block
    const settings_key = "\"settings\"";
    if (std.mem.indexOf(u8, content, settings_key)) |sk_pos| {
        // Find the { after "settings"
        const after_key = content[sk_pos..];
        const brace_offset = std.mem.indexOf(u8, after_key, "{") orelse return;
        const brace_start = sk_pos + brace_offset;
        // Find matching }
        const inner_start = brace_start + 1;
        const inner_body = content[inner_start..];
        const inner = findMatchingBrace(inner_body) orelse return;
        const block_end = inner_start + inner.len + 1; // includes closing }

        // Find the start of the "settings" line (backtrack to find indentation)
        var line_start = sk_pos;
        while (line_start > 0 and content[line_start - 1] != '\n') : (line_start -= 1) {}

        var out: std.ArrayListUnmanaged(u8) = .empty;
        defer out.deinit(allocator);
        try out.appendSlice(allocator, content[0..line_start]);
        try out.appendSlice(allocator, settings_text);
        try out.appendSlice(allocator, content[block_end..]);

        const file = try std.fs.createFileAbsolute(path, .{});
        defer file.close();
        try file.writeAll(out.items);
    } else {
        // No settings block yet - insert after opening {
        const first_brace = std.mem.indexOfScalar(u8, content, '{') orelse return;
        var out: std.ArrayListUnmanaged(u8) = .empty;
        defer out.deinit(allocator);
        try out.appendSlice(allocator, content[0 .. first_brace + 1]);
        try out.appendSlice(allocator, "\n");
        try out.appendSlice(allocator, settings_text);
        try out.appendSlice(allocator, ",\n");
        try out.appendSlice(allocator, content[first_brace + 1 ..]);

        const file = try std.fs.createFileAbsolute(path, .{});
        defer file.close();
        try file.writeAll(out.items);
    }
}

/// Helper: unescape a heap-allocated JSON string value in place.
/// Since unescaping always produces output <= input length, this is safe.
/// Returns the new (possibly shorter) slice into the same allocation.
fn unescapeInPlace(s: []u8) []const u8 {
    var pos: usize = 0;
    var i: usize = 0;
    while (i < s.len) {
        if (s[i] == '\\' and i + 1 < s.len) {
            const next = s[i + 1];
            switch (next) {
                '\\' => {
                    s[pos] = '\\';
                    pos += 1;
                    i += 2;
                },
                '"' => {
                    s[pos] = '"';
                    pos += 1;
                    i += 2;
                },
                'n' => {
                    s[pos] = '\n';
                    pos += 1;
                    i += 2;
                },
                'r' => {
                    s[pos] = '\r';
                    pos += 1;
                    i += 2;
                },
                't' => {
                    s[pos] = '\t';
                    pos += 1;
                    i += 2;
                },
                'b' => {
                    s[pos] = 0x08;
                    pos += 1;
                    i += 2;
                },
                'f' => {
                    s[pos] = 0x0C;
                    pos += 1;
                    i += 2;
                },
                '/' => {
                    s[pos] = '/';
                    pos += 1;
                    i += 2;
                },
                else => {
                    s[pos] = s[i];
                    pos += 1;
                    i += 1;
                },
            }
        } else {
            s[pos] = s[i];
            pos += 1;
            i += 1;
        }
    }
    return s[0..pos];
}

/// Unescape extracted JSON value (heap-allocated). Returns the original ptr
/// with potentially shorter length. Caller must still free with original alloc size.
fn unescapeExtracted(val: ?[]u8) ?[]const u8 {
    if (val) |v| {
        if (std.mem.indexOf(u8, v, "\\") == null) return v; // fast path: no escapes
        return unescapeInPlace(v);
    }
    return null;
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
        // Find closing quote, handling escaped quotes
        var alias_end: usize = 0;
        {
            var ai: usize = 0;
            while (ai < sites_inner[alias_start..].len) : (ai += 1) {
                if (sites_inner[alias_start + ai] == '\\' and ai + 1 < sites_inner[alias_start..].len) {
                    ai += 1;
                    continue;
                }
                if (sites_inner[alias_start + ai] == '"') break;
            }
            alias_end = ai;
        }
        const raw_alias = sites_inner[alias_start..][0..alias_end];
        // Unescape alias into stack buffer
        var alias_unescape_buf: [256]u8 = undefined;
        const alias = unescapeJsonString(&alias_unescape_buf, raw_alias);

        // Find the opening brace of this entry
        const after_alias = sites_inner[alias_start + alias_end + 1 ..];
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
        const model = env_mod.extractJsonValue(allocator, entry_body[0 .. entry_inner.len + 1], "model") catch null;
        defer if (model) |s| allocator.free(s);

        if (site_type_str) |st| {
            if (SiteType.fromString(st)) |stype| {
                // Extract archived/default-selection flags
                const archived_str = env_mod.extractJsonValue(allocator, entry_body[0 .. entry_inner.len + 1], "archived") catch null;
                defer if (archived_str) |s| allocator.free(s);
                const is_archived = if (archived_str) |a| std.mem.eql(u8, a, "true") else false;

                const default_tools_mask_str = env_mod.extractJsonValue(allocator, entry_body[0 .. entry_inner.len + 1], "default_tools_mask") catch null;
                defer if (default_tools_mask_str) |s| allocator.free(s);
                const default_tools_mask = if (default_tools_mask_str) |v| std.fmt.parseInt(u8, v, 10) catch 0 else 0;

                const selection_mode_str = env_mod.extractJsonValue(allocator, entry_body[0 .. entry_inner.len + 1], "selection_mode") catch null;
                defer if (selection_mode_str) |s| allocator.free(s);
                const selection_mode = if (selection_mode_str) |v| SiteSelectionMode.fromString(v) orelse .manual_defaults else .manual_defaults;

                const last_used_tool_str = env_mod.extractJsonValue(allocator, entry_body[0 .. entry_inner.len + 1], "last_used_tool") catch null;
                defer if (last_used_tool_str) |s| allocator.free(s);
                const last_used_tool = if (last_used_tool_str) |v| SiteType.fromString(v) else null;

                // Extract per-tool model overrides from "models" sub-object
                var m_cx: []const u8 = "";
                var m_cc: []const u8 = "";
                var m_oc: []const u8 = "";
                var m_nb: []const u8 = "";
                var m_ow: []const u8 = "";

                const models_key = "\"models\"";
                if (std.mem.indexOf(u8, entry_body[0 .. entry_inner.len + 1], models_key)) |mk_pos| {
                    const after_mk = entry_body[mk_pos + models_key.len .. entry_inner.len + 1];
                    if (std.mem.indexOf(u8, after_mk, "{")) |mo_start| {
                        const mo_body = after_mk[mo_start + 1 ..];
                        if (findMatchingBrace(mo_body)) |mo_inner| {
                            const mo_slice = mo_body[0 .. mo_inner.len + 1];
                            m_cx = env_mod.extractJsonValue(allocator, mo_slice, "cx") catch "";
                            m_cc = env_mod.extractJsonValue(allocator, mo_slice, "cc") catch "";
                            m_oc = env_mod.extractJsonValue(allocator, mo_slice, "oc") catch "";
                            m_nb = env_mod.extractJsonValue(allocator, mo_slice, "nb") catch "";
                            m_ow = env_mod.extractJsonValue(allocator, mo_slice, "ow") catch "";
                        }
                    }
                }
                defer {
                    if (m_cx.len > 0) allocator.free(m_cx);
                    if (m_cc.len > 0) allocator.free(m_cc);
                    if (m_oc.len > 0) allocator.free(m_oc);
                    if (m_nb.len > 0) allocator.free(m_nb);
                    if (m_ow.len > 0) allocator.free(m_ow);
                }

                // Unescape user-data fields (base_url, api_key, model) that may contain JSON escapes
                var ue_url_buf: [1024]u8 = undefined;
                var ue_key_buf: [1024]u8 = undefined;
                var ue_model_buf: [512]u8 = undefined;
                const ue_url: []const u8 = if (base_url) |v| unescapeJsonString(&ue_url_buf, v) else "";
                const ue_key: []const u8 = if (api_key) |v| unescapeJsonString(&ue_key_buf, v) else "";
                const ue_model: []const u8 = if (model) |v| unescapeJsonString(&ue_model_buf, v) else "";

                // Unescape per-tool model overrides
                var ue_mcx_buf: [256]u8 = undefined;
                var ue_mcc_buf: [256]u8 = undefined;
                var ue_moc_buf: [256]u8 = undefined;
                var ue_mnb_buf: [256]u8 = undefined;
                var ue_mow_buf: [256]u8 = undefined;
                const ue_mcx: []const u8 = if (m_cx.len > 0) unescapeJsonString(&ue_mcx_buf, m_cx) else "";
                const ue_mcc: []const u8 = if (m_cc.len > 0) unescapeJsonString(&ue_mcc_buf, m_cc) else "";
                const ue_moc: []const u8 = if (m_oc.len > 0) unescapeJsonString(&ue_moc_buf, m_oc) else "";
                const ue_mnb: []const u8 = if (m_nb.len > 0) unescapeJsonString(&ue_mnb_buf, m_nb) else "";
                const ue_mow: []const u8 = if (m_ow.len > 0) unescapeJsonString(&ue_mow_buf, m_ow) else "";

                var site = Site{
                    .site_type = stype,
                    .base_url = ue_url,
                    .api_key = ue_key,
                    .model = ue_model,
                    .archived = is_archived,
                    .default_tools_mask = default_tools_mask,
                    .selection_mode = selection_mode,
                    .last_used_tool = last_used_tool,
                    .models_cx = ue_mcx,
                    .models_cc = ue_mcc,
                    .models_oc = ue_moc,
                    .models_nb = ue_mnb,
                    .models_ow = ue_mow,
                };
                ensureSelectionState(&site);
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

    // Read existing file to preserve settings block
    var settings_block: std.ArrayListUnmanaged(u8) = .empty;
    defer settings_block.deinit(allocator);
    {
        const file = std.fs.openFileAbsolute(path, .{}) catch null;
        if (file) |f| {
            defer f.close();
            var buf: [65536]u8 = undefined;
            const bytes_read = f.readAll(&buf) catch 0;
            const content = buf[0..bytes_read];
            const settings_key = "\"settings\"";
            if (std.mem.indexOf(u8, content, settings_key)) |sk_pos| {
                // Find the line start
                var line_start = sk_pos;
                while (line_start > 0 and content[line_start - 1] != '\n') : (line_start -= 1) {}
                // Find the matching brace
                const after_key = content[sk_pos + settings_key.len ..];
                if (std.mem.indexOf(u8, after_key, "{")) |brace_off| {
                    const inner_start = sk_pos + settings_key.len + brace_off + 1;
                    if (findMatchingBrace(content[inner_start..])) |inner| {
                        const block_end = inner_start + inner.len + 1;
                        try settings_block.appendSlice(allocator, content[line_start..block_end]);
                    }
                }
            }
        }
    }

    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(allocator);

    try out.appendSlice(allocator, "{\n");

    // Write preserved settings block
    if (settings_block.items.len > 0) {
        try out.appendSlice(allocator, settings_block.items);
        try out.appendSlice(allocator, ",\n");
    }

    try out.appendSlice(allocator, "  \"sites\": {");

    for (0..store.count) |i| {
        const entry = store.entries[i];
        if (i > 0) {
            try out.append(allocator, ',');
        }
        try out.appendSlice(allocator, "\n    \"");
        try appendEscaped(&out, allocator, entry.alias);
        try out.appendSlice(allocator, "\": {\n      \"type\": \"");
        try out.appendSlice(allocator, entry.site.site_type.toString());
        try out.appendSlice(allocator, "\",\n      \"base_url\": \"");
        try appendEscaped(&out, allocator, entry.site.base_url);
        try out.appendSlice(allocator, "\",\n      \"api_key\": \"");
        try appendEscaped(&out, allocator, entry.site.api_key);
        try out.appendSlice(allocator, "\",\n      \"model\": \"");
        try appendEscaped(&out, allocator, entry.site.effectiveModel());
        try out.append(allocator, '"');

        // Write archived flag if true
        if (entry.site.archived) {
            try out.appendSlice(allocator, ",\n      \"archived\": true");
        }

        const tools_mask = if (entry.site.default_tools_mask == 0) toolMask(entry.site.site_type) else entry.site.default_tools_mask;
        try out.appendSlice(allocator, ",\n      \"default_tools_mask\": ");
        {
            var mask_buf: [8]u8 = undefined;
            const mask_str = std.fmt.bufPrint(&mask_buf, "{d}", .{tools_mask}) catch "0";
            try out.appendSlice(allocator, mask_str);
        }
        try out.appendSlice(allocator, ",\n      \"selection_mode\": \"");
        try out.appendSlice(allocator, entry.site.selection_mode.toString());
        try out.append(allocator, '"');
        if (entry.site.last_used_tool) |last_tool| {
            try out.appendSlice(allocator, ",\n      \"last_used_tool\": \"");
            try out.appendSlice(allocator, last_tool.toString());
            try out.append(allocator, '"');
        }

        // Write per-tool model overrides if any exist
        const has_overrides = entry.site.models_cx.len > 0 or
            entry.site.models_cc.len > 0 or
            entry.site.models_oc.len > 0 or
            entry.site.models_nb.len > 0 or
            entry.site.models_ow.len > 0;

        if (has_overrides) {
            try out.appendSlice(allocator, ",\n      \"models\": {");
            var first = true;
            if (entry.site.models_cx.len > 0) {
                if (!first) try out.append(allocator, ',');
                try out.appendSlice(allocator, "\n        \"cx\": \"");
                try appendEscaped(&out, allocator, entry.site.models_cx);
                try out.append(allocator, '"');
                first = false;
            }
            if (entry.site.models_cc.len > 0) {
                if (!first) try out.append(allocator, ',');
                try out.appendSlice(allocator, "\n        \"cc\": \"");
                try appendEscaped(&out, allocator, entry.site.models_cc);
                try out.append(allocator, '"');
                first = false;
            }
            if (entry.site.models_oc.len > 0) {
                if (!first) try out.append(allocator, ',');
                try out.appendSlice(allocator, "\n        \"oc\": \"");
                try appendEscaped(&out, allocator, entry.site.models_oc);
                try out.append(allocator, '"');
                first = false;
            }
            if (entry.site.models_nb.len > 0) {
                if (!first) try out.append(allocator, ',');
                try out.appendSlice(allocator, "\n        \"nb\": \"");
                try appendEscaped(&out, allocator, entry.site.models_nb);
                try out.append(allocator, '"');
                first = false;
            }
            if (entry.site.models_ow.len > 0) {
                if (!first) try out.append(allocator, ',');
                try out.appendSlice(allocator, "\n        \"ow\": \"");
                try appendEscaped(&out, allocator, entry.site.models_ow);
                try out.append(allocator, '"');
                first = false;
            }
            try out.appendSlice(allocator, "\n      }");
        }

        try out.appendSlice(allocator, "\n    }");
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

/// Escape a string for safe embedding inside a JSON string value.
/// Handles: \ → \\, " → \", control chars (newline, tab, etc.) → \n, \t, etc.
/// Returns a slice of `buf` containing the escaped string.
pub fn escapeJsonString(buf: []u8, input: []const u8) []const u8 {
    var pos: usize = 0;
    for (input) |ch| {
        switch (ch) {
            '\\' => {
                if (pos + 2 > buf.len) break;
                buf[pos] = '\\';
                buf[pos + 1] = '\\';
                pos += 2;
            },
            '"' => {
                if (pos + 2 > buf.len) break;
                buf[pos] = '\\';
                buf[pos + 1] = '"';
                pos += 2;
            },
            '\n' => {
                if (pos + 2 > buf.len) break;
                buf[pos] = '\\';
                buf[pos + 1] = 'n';
                pos += 2;
            },
            '\r' => {
                if (pos + 2 > buf.len) break;
                buf[pos] = '\\';
                buf[pos + 1] = 'r';
                pos += 2;
            },
            '\t' => {
                if (pos + 2 > buf.len) break;
                buf[pos] = '\\';
                buf[pos + 1] = 't';
                pos += 2;
            },
            0x08 => { // backspace
                if (pos + 2 > buf.len) break;
                buf[pos] = '\\';
                buf[pos + 1] = 'b';
                pos += 2;
            },
            0x0C => { // form feed
                if (pos + 2 > buf.len) break;
                buf[pos] = '\\';
                buf[pos + 1] = 'f';
                pos += 2;
            },
            else => {
                if (pos + 1 > buf.len) break;
                buf[pos] = ch;
                pos += 1;
            },
        }
    }
    return buf[0..pos];
}

/// Unescape a JSON string value: \\ → \, \" → ", \n → newline, etc.
/// Returns a slice of `buf` containing the unescaped string.
pub fn unescapeJsonString(buf: []u8, input: []const u8) []const u8 {
    var pos: usize = 0;
    var i: usize = 0;
    while (i < input.len) {
        if (pos >= buf.len) break;
        if (input[i] == '\\' and i + 1 < input.len) {
            const next = input[i + 1];
            switch (next) {
                '\\' => {
                    buf[pos] = '\\';
                    pos += 1;
                    i += 2;
                },
                '"' => {
                    buf[pos] = '"';
                    pos += 1;
                    i += 2;
                },
                'n' => {
                    buf[pos] = '\n';
                    pos += 1;
                    i += 2;
                },
                'r' => {
                    buf[pos] = '\r';
                    pos += 1;
                    i += 2;
                },
                't' => {
                    buf[pos] = '\t';
                    pos += 1;
                    i += 2;
                },
                'b' => {
                    buf[pos] = 0x08;
                    pos += 1;
                    i += 2;
                },
                'f' => {
                    buf[pos] = 0x0C;
                    pos += 1;
                    i += 2;
                },
                '/' => {
                    buf[pos] = '/';
                    pos += 1;
                    i += 2;
                },
                else => {
                    // Unknown escape: keep as-is
                    buf[pos] = input[i];
                    pos += 1;
                    i += 1;
                },
            }
        } else {
            buf[pos] = input[i];
            pos += 1;
            i += 1;
        }
    }
    return buf[0..pos];
}

/// Check if a string contains characters that need JSON escaping.
pub fn needsJsonEscape(input: []const u8) bool {
    for (input) |ch| {
        switch (ch) {
            '\\', '"', '\n', '\r', '\t', 0x08, 0x0C => return true,
            else => {},
        }
    }
    return false;
}

/// Helper: escape and append a JSON string value to an output list.
/// Uses a stack buffer for escaping, falls back to raw if buffer too small.
fn appendEscaped(out: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, input: []const u8) !void {
    if (!needsJsonEscape(input)) {
        try out.appendSlice(allocator, input);
        return;
    }
    var esc_buf: [2048]u8 = undefined;
    const escaped = escapeJsonString(&esc_buf, input);
    try out.appendSlice(allocator, escaped);
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
    try std.testing.expectEqual(SiteType.nb, SiteType.fromString("nb").?);
    try std.testing.expectEqual(SiteType.nb, SiteType.fromString("nanobot").?);
    try std.testing.expectEqual(SiteType.ow, SiteType.fromString("ow").?);
    try std.testing.expectEqual(SiteType.ow, SiteType.fromString("openclaw").?);
    try std.testing.expectEqual(@as(?SiteType, null), SiteType.fromString("unknown"));
}

test "mask key" {
    var buf: [64]u8 = undefined;
    const masked = maskKey(&buf, "sk-abcdefghijklmnop");
    try std.testing.expectEqualStrings("sk-abc...mnop", masked);
}

test "effective model uses per-type defaults" {
    const cx_site = Site{ .site_type = .cx, .base_url = "", .api_key = "" };
    const cc_site = Site{ .site_type = .cc, .base_url = "", .api_key = "" };
    const oc_site = Site{ .site_type = .oc, .base_url = "", .api_key = "" };
    const nb_site = Site{ .site_type = .nb, .base_url = "", .api_key = "" };
    const ow_site = Site{ .site_type = .ow, .base_url = "", .api_key = "" };

    try std.testing.expectEqualStrings(app.default_model_cx, cx_site.effectiveModel());
    try std.testing.expectEqualStrings(app.default_model_cc, cc_site.effectiveModel());
    try std.testing.expectEqualStrings(app.default_model_oc, oc_site.effectiveModel());
    try std.testing.expectEqualStrings(app.default_model_nb, nb_site.effectiveModel());
    try std.testing.expectEqualStrings(app.default_model_ow, ow_site.effectiveModel());
}

test "effectiveModelForTool with per-tool overrides" {
    const site = Site{
        .site_type = .cc,
        .base_url = "",
        .api_key = "",
        .model = "claude-opus-4-6",
        .models_cx = "gpt-5.4",
    };
    // Primary type uses primary model
    try std.testing.expectEqualStrings("claude-opus-4-6", site.effectiveModelForTool(.cc));
    // Override type uses per-tool model
    try std.testing.expectEqualStrings("gpt-5.4", site.effectiveModelForTool(.cx));
    // Non-configured tool type uses its default
    try std.testing.expectEqualStrings(app.default_model_oc, site.effectiveModelForTool(.oc));
}

test "remove frees entry and shifts remaining sites" {
    var store: SitesStore = .{};
    defer store.deinit(std.testing.allocator);

    try store.addOrUpdate(std.testing.allocator, "smartprobe", .{
        .site_type = .cx,
        .base_url = "https://example.com/v1",
        .api_key = "sk-1",
        .model = "gpt-5.4",
        .models_cc = "claude-opus-4-6",
    });
    try store.addOrUpdate(std.testing.allocator, "smartprobe2", .{
        .site_type = .cc,
        .base_url = "https://example.org",
        .api_key = "sk-2",
        .model = "claude-opus-4-6",
    });

    try std.testing.expectEqual(@as(usize, 2), store.count);
    try std.testing.expect(store.remove(std.testing.allocator, "smartprobe"));
    try std.testing.expectEqual(@as(usize, 1), store.count);
    try std.testing.expect(store.getSite("smartprobe") == null);
    try std.testing.expect(store.getSite("smartprobe2") != null);
}

test "escapeJsonString escapes backslash and quote" {
    var buf: [256]u8 = undefined;
    const result = escapeJsonString(&buf, "hello\\world\"test");
    try std.testing.expectEqualStrings("hello\\\\world\\\"test", result);
}

test "escapeJsonString escapes control characters" {
    var buf: [256]u8 = undefined;
    const result = escapeJsonString(&buf, "line1\nline2\ttab");
    try std.testing.expectEqualStrings("line1\\nline2\\ttab", result);
}

test "escapeJsonString passthrough clean string" {
    var buf: [256]u8 = undefined;
    const result = escapeJsonString(&buf, "sk-abc123");
    try std.testing.expectEqualStrings("sk-abc123", result);
}

test "unescapeJsonString round-trip" {
    var esc_buf: [256]u8 = undefined;
    var unesc_buf: [256]u8 = undefined;
    const original = "key\\with\"quotes\nand\tnewlines";
    const escaped = escapeJsonString(&esc_buf, original);
    const unescaped = unescapeJsonString(&unesc_buf, escaped);
    try std.testing.expectEqualStrings(original, unescaped);
}

test "unescapeJsonString clean string unchanged" {
    var buf: [256]u8 = undefined;
    const result = unescapeJsonString(&buf, "hello world");
    try std.testing.expectEqualStrings("hello world", result);
}

test "needsJsonEscape detects special chars" {
    try std.testing.expect(needsJsonEscape("has\\backslash"));
    try std.testing.expect(needsJsonEscape("has\"quote"));
    try std.testing.expect(needsJsonEscape("has\nnewline"));
    try std.testing.expect(!needsJsonEscape("clean-string"));
    try std.testing.expect(!needsJsonEscape("sk-abc123"));
}
