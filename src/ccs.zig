const std = @import("std");
const builtin = @import("builtin");
const app = @import("app.zig");
const config_mod = @import("config.zig");
const env_mod = @import("env.zig");
const sites_mod = @import("sites.zig");
const io_compat = @import("io_compat.zig");

pub const ImportResult = struct {
    path: []const u8,
    imported: usize = 0,
    skipped: usize = 0,
};

pub const ExportResult = struct {
    path: []const u8,
    exported: usize = 0,
    skipped: usize = 0,
};

const ProfileRef = struct {
    name: []const u8,
    settings_path: []const u8,
};

pub fn freeImportResult(allocator: std.mem.Allocator, result: ImportResult) void {
    allocator.free(result.path);
}

pub fn freeExportResult(allocator: std.mem.Allocator, result: ExportResult) void {
    allocator.free(result.path);
}

pub fn defaultConfigPath(allocator: std.mem.Allocator) ![]u8 {
    const home = config_mod.getHomeDir(allocator) orelse return error.NoHomeDir;
    defer allocator.free(home);
    return try std.fs.path.join(allocator, &.{ home, ".ccs", "config.yaml" });
}

pub fn importConfig(allocator: std.mem.Allocator, path_arg: ?[]const u8, store: *sites_mod.SitesStore) !ImportResult {
    const config_path = try resolveConfigPath(allocator, path_arg);
    errdefer allocator.free(config_path);

    var content: std.ArrayListUnmanaged(u8) = .empty;
    defer content.deinit(allocator);
    if (!io_compat.readFileIntoList(allocator, config_path, &content)) return error.ConfigNotFound;

    const profiles = try parseProfiles(allocator, config_path, content.items);
    defer freeProfiles(allocator, profiles);

    var result = ImportResult{ .path = config_path };
    for (profiles) |profile| {
        const imported = importProfile(allocator, profile, store) catch false;
        if (imported) {
            result.imported += 1;
        } else {
            result.skipped += 1;
        }
    }
    return result;
}

pub fn exportConfig(allocator: std.mem.Allocator, path_arg: ?[]const u8, store: *const sites_mod.SitesStore) !ExportResult {
    const config_path = try resolveConfigPath(allocator, path_arg);
    errdefer allocator.free(config_path);

    const config_dir = std.fs.path.dirname(config_path) orelse return error.InvalidPath;
    try makeNestedDir(config_dir);

    var profiles_yaml: std.ArrayListUnmanaged(u8) = .empty;
    defer profiles_yaml.deinit(allocator);

    var first_profile: ?[]u8 = null;
    defer if (first_profile) |name| allocator.free(name);

    var result = ExportResult{ .path = config_path };

    for (store.entries[0..store.count]) |entry| {
        const model = entry.site.effectiveModelForTool(.cc);
        if (!sites_mod.modelCompatibleForTool(.cc, model)) {
            result.skipped += 1;
            continue;
        }

        const profile_name = try sanitizeProfileName(allocator, entry.alias);
        defer allocator.free(profile_name);
        if (first_profile == null) first_profile = try allocator.dupe(u8, profile_name);

        const settings_filename = try std.fmt.allocPrint(allocator, "{s}.settings.json", .{profile_name});
        defer allocator.free(settings_filename);
        const settings_path = try std.fs.path.join(allocator, &.{ config_dir, settings_filename });
        defer allocator.free(settings_path);

        try writeSettingsFile(allocator, settings_path, entry.site.base_url, entry.site.api_key, model);

        try profiles_yaml.appendSlice(allocator, "  ");
        try appendYamlKey(&profiles_yaml, allocator, profile_name);
        try profiles_yaml.appendSlice(allocator, ":\n    settings_file: ");
        try appendYamlSingleQuotedPath(&profiles_yaml, allocator, settings_path);
        try profiles_yaml.append(allocator, '\n');

        result.exported += 1;
    }

    if (result.exported == 0) return error.NoExportableProfiles;

    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(allocator);

    try out.appendSlice(allocator, "version: 13\n");
    try out.appendSlice(allocator, "default: ");
    try appendYamlSingleQuoted(&out, allocator, first_profile.?);
    try out.appendSlice(allocator, "\nprofiles:\n");
    try out.appendSlice(allocator, profiles_yaml.items);
    try out.appendSlice(allocator,
        \\cliproxy:
        \\  providers: {}
        \\proxy:
        \\  profile_ports: {}
        \\thinking:
        \\  mode: auto
        \\  budget: 8192
        \\browser:
        \\  claude:
        \\    enabled: false
        \\    policy: manual
        \\  codex:
        \\    enabled: false
        \\    policy: manual
        \\
    );

    try io_compat.writeFileAll(config_path, out.items);
    return result;
}

fn importProfile(allocator: std.mem.Allocator, profile: ProfileRef, store: *sites_mod.SitesStore) !bool {
    var content: std.ArrayListUnmanaged(u8) = .empty;
    defer content.deinit(allocator);
    if (!io_compat.readFileIntoList(allocator, profile.settings_path, &content)) return false;

    const api_key_raw = env_mod.extractJsonValue(allocator, content.items, "ANTHROPIC_AUTH_TOKEN") catch return false;
    defer allocator.free(api_key_raw);
    const base_url_raw = env_mod.extractJsonValue(allocator, content.items, "ANTHROPIC_BASE_URL") catch return false;
    defer allocator.free(base_url_raw);

    const model_raw = readFirstJsonValue(allocator, content.items, &.{
        "ANTHROPIC_MODEL",
        "ANTHROPIC_DEFAULT_OPUS_MODEL",
        "ANTHROPIC_DEFAULT_SONNET_MODEL",
        "ANTHROPIC_DEFAULT_HAIKU_MODEL",
    }) catch null;
    defer if (model_raw) |m| allocator.free(m);

    var key_buf: [2048]u8 = undefined;
    var url_buf: [1024]u8 = undefined;
    var model_buf: [512]u8 = undefined;
    const api_key = sites_mod.unescapeJsonString(&key_buf, api_key_raw);
    const base_url = sites_mod.unescapeJsonString(&url_buf, base_url_raw);
    const model = if (model_raw) |m|
        sites_mod.unescapeJsonString(&model_buf, m)
    else
        sites_mod.defaultModelForType(.cc);

    if (api_key.len == 0 or base_url.len == 0) return false;
    if (!sites_mod.modelCompatibleForTool(.cc, model)) return false;

    var imported = if (sites_mod.findEntryConst(store, profile.name)) |existing|
        existing.site
    else
        sites_mod.Site{
            .site_type = .cc,
            .base_url = base_url,
            .api_key = api_key,
            .model = model,
            .default_tools_mask = sites_mod.toolMask(.cc),
        };

    imported.base_url = base_url;
    imported.api_key = api_key;
    if (imported.site_type == .cc or imported.model.len == 0) imported.model = model;
    imported.models_cc = model;
    sites_mod.setDefaultTool(&imported, .cc, true);
    sites_mod.ensureSelectionState(&imported);

    try store.addOrUpdate(allocator, profile.name, imported);
    return true;
}

fn readFirstJsonValue(allocator: std.mem.Allocator, content: []const u8, fields: []const []const u8) !?[]u8 {
    for (fields) |field| {
        if (env_mod.extractJsonValue(allocator, content, field)) |value| {
            return value;
        } else |_| {}
    }
    return null;
}

fn resolveConfigPath(allocator: std.mem.Allocator, path_arg: ?[]const u8) ![]u8 {
    if (path_arg == null) return defaultConfigPath(allocator);

    const expanded = try expandUserPath(allocator, path_arg.?);
    errdefer allocator.free(expanded);

    if (std.mem.endsWith(u8, expanded, ".yaml") or std.mem.endsWith(u8, expanded, ".yml")) {
        return expanded;
    }

    const joined = try std.fs.path.join(allocator, &.{ expanded, "config.yaml" });
    allocator.free(expanded);
    return joined;
}

fn expandUserPath(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    if (path.len > 0 and path[0] == '~') {
        const home = config_mod.getHomeDir(allocator) orelse return error.NoHomeDir;
        defer allocator.free(home);
        var rest = path[1..];
        if (rest.len > 0 and (rest[0] == '/' or rest[0] == '\\')) rest = rest[1..];
        if (rest.len == 0) return allocator.dupe(u8, home);
        return try std.fs.path.join(allocator, &.{ home, rest });
    }

    if (std.fs.path.isAbsolute(path)) return allocator.dupe(u8, path);
    return try std.fs.path.resolve(allocator, &.{path});
}

fn parseProfiles(allocator: std.mem.Allocator, config_path: []const u8, content: []const u8) ![]ProfileRef {
    var list: std.ArrayListUnmanaged(ProfileRef) = .empty;
    errdefer freeProfiles(allocator, list.items);

    const config_dir = std.fs.path.dirname(config_path) orelse return error.InvalidPath;
    var in_profiles = false;
    var current_name: ?[]u8 = null;
    var current_settings: ?[]u8 = null;

    const Parser = struct {
        fn finish(
            alloc: std.mem.Allocator,
            dir: []const u8,
            out: *std.ArrayListUnmanaged(ProfileRef),
            name_ptr: *?[]u8,
            settings_ptr: *?[]u8,
        ) !void {
            const name = name_ptr.* orelse return;
            name_ptr.* = null;
            errdefer alloc.free(name);

            const raw_settings = settings_ptr.* orelse {
                alloc.free(name);
                return;
            };
            settings_ptr.* = null;
            defer alloc.free(raw_settings);

            const settings_path = try resolveSettingsPath(alloc, dir, raw_settings);
            errdefer alloc.free(settings_path);
            try out.append(alloc, .{ .name = name, .settings_path = settings_path });
        }
    };

    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trimEnd(u8, raw_line, "\r");
        const trimmed = std.mem.trim(u8, line, " \t");
        if (trimmed.len == 0 or trimmed[0] == '#') continue;
        const indent = leadingSpaces(line);

        if (!in_profiles) {
            if (indent == 0 and std.mem.eql(u8, trimmed, "profiles:")) in_profiles = true;
            continue;
        }

        if (indent == 0) break;

        if (indent == 2 and trimmed.len > 1 and trimmed[trimmed.len - 1] == ':') {
            try Parser.finish(allocator, config_dir, &list, &current_name, &current_settings);
            const raw_name = std.mem.trim(u8, trimmed[0 .. trimmed.len - 1], " \t");
            current_name = try allocator.dupe(u8, stripYamlQuotes(raw_name));
            continue;
        }

        if (current_name == null or indent < 4) continue;
        const colon = std.mem.indexOfScalar(u8, trimmed, ':') orelse continue;
        const key = std.mem.trim(u8, trimmed[0..colon], " \t");
        const value = std.mem.trim(u8, trimmed[colon + 1 ..], " \t");
        if (std.mem.eql(u8, key, "settings_file") or std.mem.eql(u8, key, "settings")) {
            if (current_settings) |old| allocator.free(old);
            current_settings = try allocator.dupe(u8, stripYamlQuotes(value));
        }
    }
    try Parser.finish(allocator, config_dir, &list, &current_name, &current_settings);

    return list.toOwnedSlice(allocator);
}

fn resolveSettingsPath(allocator: std.mem.Allocator, config_dir: []const u8, raw_path: []const u8) ![]u8 {
    if (raw_path.len > 0 and raw_path[0] == '~') return expandUserPath(allocator, raw_path);
    if (std.fs.path.isAbsolute(raw_path)) return allocator.dupe(u8, raw_path);
    return try std.fs.path.join(allocator, &.{ config_dir, raw_path });
}

fn freeProfiles(allocator: std.mem.Allocator, profiles: []ProfileRef) void {
    for (profiles) |profile| {
        allocator.free(profile.name);
        allocator.free(profile.settings_path);
    }
    allocator.free(profiles);
}

fn leadingSpaces(line: []const u8) usize {
    var count: usize = 0;
    while (count < line.len and line[count] == ' ') : (count += 1) {}
    return count;
}

fn stripYamlQuotes(value: []const u8) []const u8 {
    const trimmed = std.mem.trim(u8, value, " \t");
    if (trimmed.len >= 2) {
        if ((trimmed[0] == '"' and trimmed[trimmed.len - 1] == '"') or
            (trimmed[0] == '\'' and trimmed[trimmed.len - 1] == '\''))
        {
            return trimmed[1 .. trimmed.len - 1];
        }
    }
    return trimmed;
}

fn sanitizeProfileName(allocator: std.mem.Allocator, alias: []const u8) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);

    for (alias) |ch| {
        const ok = std.ascii.isAlphanumeric(ch) or ch == '-' or ch == '_' or ch == '.';
        try out.append(allocator, if (ok) ch else '_');
    }
    if (out.items.len == 0) try out.appendSlice(allocator, app.command_name);
    return out.toOwnedSlice(allocator);
}

fn appendYamlKey(out: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, key: []const u8) !void {
    const simple = blk: {
        if (key.len == 0) break :blk false;
        for (key) |ch| {
            if (!(std.ascii.isAlphanumeric(ch) or ch == '-' or ch == '_' or ch == '.')) break :blk false;
        }
        break :blk true;
    };
    if (simple) {
        try out.appendSlice(allocator, key);
    } else {
        try appendYamlSingleQuoted(out, allocator, key);
    }
}

fn appendYamlSingleQuotedPath(out: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, path: []const u8) !void {
    try out.append(allocator, '\'');
    for (path) |ch| {
        const normalized = if (ch == '\\') '/' else ch;
        if (normalized == '\'') try out.append(allocator, '\'');
        try out.append(allocator, normalized);
    }
    try out.append(allocator, '\'');
}

fn appendYamlSingleQuoted(out: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, value: []const u8) !void {
    try out.append(allocator, '\'');
    for (value) |ch| {
        if (ch == '\'') try out.append(allocator, '\'');
        try out.append(allocator, ch);
    }
    try out.append(allocator, '\'');
}

fn writeSettingsFile(allocator: std.mem.Allocator, path: []const u8, base_url: []const u8, api_key: []const u8, model: []const u8) !void {
    const dir = std.fs.path.dirname(path) orelse return error.InvalidPath;
    try makeNestedDir(dir);

    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(allocator);

    try out.appendSlice(allocator, "{\n  \"env\": {\n    \"ANTHROPIC_AUTH_TOKEN\": \"");
    try appendJsonEscaped(&out, allocator, api_key);
    try out.appendSlice(allocator, "\",\n    \"ANTHROPIC_BASE_URL\": \"");
    try appendJsonEscaped(&out, allocator, base_url);
    try out.appendSlice(allocator, "\",\n    \"ANTHROPIC_MODEL\": \"");
    try appendJsonEscaped(&out, allocator, model);
    try out.appendSlice(allocator, "\"");

    if (std.mem.startsWith(u8, model, "claude-opus")) {
        try out.appendSlice(allocator, ",\n    \"ANTHROPIC_DEFAULT_OPUS_MODEL\": \"");
        try appendJsonEscaped(&out, allocator, model);
        try out.append(allocator, '"');
    } else if (std.mem.startsWith(u8, model, "claude-sonnet")) {
        try out.appendSlice(allocator, ",\n    \"ANTHROPIC_DEFAULT_SONNET_MODEL\": \"");
        try appendJsonEscaped(&out, allocator, model);
        try out.append(allocator, '"');
    } else if (std.mem.startsWith(u8, model, "claude-haiku")) {
        try out.appendSlice(allocator, ",\n    \"ANTHROPIC_DEFAULT_HAIKU_MODEL\": \"");
        try appendJsonEscaped(&out, allocator, model);
        try out.append(allocator, '"');
    }

    try out.appendSlice(allocator, "\n  }\n}\n");
    try io_compat.writeFileAll(path, out.items);
}

fn appendJsonEscaped(out: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, input: []const u8) !void {
    var buf: [4096]u8 = undefined;
    const escaped = sites_mod.escapeJsonString(&buf, input);
    try out.appendSlice(allocator, escaped);
}

fn makeNestedDir(path: []const u8) !void {
    if (path.len == 0) return;

    var built: [std.fs.max_path_bytes]u8 = undefined;
    var pos: usize = 0;
    var rest = path;

    if (builtin.os.tag == .windows and path.len >= 3 and std.ascii.isAlphabetic(path[0]) and path[1] == ':' and (path[2] == '\\' or path[2] == '/')) {
        built[0] = path[0];
        built[1] = ':';
        built[2] = path[2];
        pos = 3;
        rest = path[3..];
    } else if (path.len > 0 and (path[0] == '/' or path[0] == '\\')) {
        built[0] = path[0];
        pos = 1;
        rest = path[1..];
    } else {
        return error.BadPathName;
    }

    var components = std.mem.splitAny(u8, rest, "/\\");
    while (components.next()) |comp| {
        if (comp.len == 0 or std.mem.eql(u8, comp, ".")) continue;
        if (pos > 0 and built[pos - 1] != '\\' and built[pos - 1] != '/') {
            built[pos] = std.fs.path.sep;
            pos += 1;
        }
        @memcpy(built[pos .. pos + comp.len], comp);
        pos += comp.len;
        try io_compat.makeDirIfMissing(built[0..pos]);
    }
}

test "parse CCS profiles with settings_file" {
    const yaml =
        \\version: 13
        \\profiles:
        \\  glm:
        \\    type: api
        \\    settings_file: /home/me/.ccs/glm.settings.json
        \\  kimi:
        \\    settings: ./kimi.settings.json
        \\thinking:
        \\  mode: auto
        \\
    ;

    const profiles = try parseProfiles(std.testing.allocator, "/home/me/.ccs/config.yaml", yaml);
    defer freeProfiles(std.testing.allocator, profiles);

    try std.testing.expectEqual(@as(usize, 2), profiles.len);
    try std.testing.expectEqualStrings("glm", profiles[0].name);
    try std.testing.expect(std.mem.endsWith(u8, profiles[0].settings_path, ".ccs/glm.settings.json") or
        std.mem.endsWith(u8, profiles[0].settings_path, ".ccs\\glm.settings.json"));
    try std.testing.expectEqualStrings("kimi", profiles[1].name);
}

test "sanitize profile name" {
    const got = try sanitizeProfileName(std.testing.allocator, "my site/cc");
    defer std.testing.allocator.free(got);
    try std.testing.expectEqualStrings("my_site_cc", got);
}
