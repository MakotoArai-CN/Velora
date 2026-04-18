const std = @import("std");
const builtin = @import("builtin");
const config_mod = @import("config.zig");
const app = @import("app.zig");
const env_mod = @import("env.zig");
const sites_mod = @import("sites.zig");

/// Read entire file into an ArrayListUnmanaged via chunked reads.
/// Returns false if the file could not be opened or read.
fn readFileIntoList(allocator: std.mem.Allocator, path: []const u8, list: *std.ArrayListUnmanaged(u8)) bool {
    const file = std.fs.openFileAbsolute(path, .{}) catch return false;
    defer file.close();
    const stat = file.stat() catch return false;
    const file_size: usize = @intCast(@min(stat.size, 16 * 1024 * 1024));
    list.ensureTotalCapacity(allocator, file_size + 1) catch return false;
    var buf: [65536]u8 = undefined;
    while (true) {
        const n = file.read(&buf) catch return false;
        if (n == 0) break;
        list.appendSlice(allocator, buf[0..n]) catch return false;
    }
    return true;
}

fn normalizeBaseUrl(allocator: std.mem.Allocator, raw: []const u8) ![]u8 {
    const trimmed = std.mem.trimRight(u8, raw, "/ \t\r\n");
    return try allocator.dupe(u8, trimmed);
}

fn dupeTrimmed(allocator: std.mem.Allocator, raw: []const u8) ![]u8 {
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    return try allocator.dupe(u8, trimmed);
}

/// Codex stores its key in an environment variable named by `env_key`
/// (default `OPENAI_API_KEY`) rather than in the TOML file. Returns the
/// currently-set value of that env var, or null if not set.
fn readCodexApiKeyFromEnv(allocator: std.mem.Allocator, env_key_name: []const u8) ?[]u8 {
    const val = std.process.getEnvVarOwned(allocator, env_key_name) catch return null;
    if (val.len == 0) {
        allocator.free(val);
        return null;
    }
    return val;
}

const CodexConfigFields = struct {
    base_url: ?[]u8 = null,
    api_key: ?[]u8 = null,
};

fn readCodexConfig(allocator: std.mem.Allocator) CodexConfigFields {
    const home = config_mod.getHomeDir(allocator) orelse return .{};
    defer allocator.free(home);
    const path = std.fs.path.join(allocator, &.{ home, app.codex_config_dir, app.codex_config_filename }) catch return .{};
    defer allocator.free(path);

    var content: std.ArrayListUnmanaged(u8) = .empty;
    defer content.deinit(allocator);
    if (!readFileIntoList(allocator, path, &content)) {
        // No config file: fall back to the default OPENAI_API_KEY env var
        return .{ .api_key = readCodexApiKeyFromEnv(allocator, "OPENAI_API_KEY") };
    }

    var base_url: ?[]u8 = null;
    var env_key_name: []const u8 = "OPENAI_API_KEY";
    var env_key_owned: ?[]u8 = null;
    defer if (env_key_owned) |v| allocator.free(v);

    var in_proxy = false;
    var line_iter = std.mem.splitScalar(u8, content.items, '\n');
    while (line_iter.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len > 0 and trimmed[0] == '[') {
            in_proxy = std.mem.indexOf(u8, trimmed, "model_providers.proxy") != null;
            continue;
        }
        if (!in_proxy) continue;
        if (std.mem.indexOf(u8, trimmed, "=")) |eq_pos| {
            const key = std.mem.trim(u8, trimmed[0..eq_pos], " \t");
            const raw_val = std.mem.trim(u8, trimmed[eq_pos + 1 ..], " \t");
            const unquoted = env_mod.stripQuotes(raw_val);
            if (unquoted.len == 0) continue;

            if (std.mem.eql(u8, key, "base_url") and base_url == null) {
                base_url = normalizeBaseUrl(allocator, unquoted) catch null;
            } else if (std.mem.eql(u8, key, "env_key") and env_key_owned == null) {
                env_key_owned = allocator.dupe(u8, unquoted) catch null;
                if (env_key_owned) |v| env_key_name = v;
            }
        }
    }

    return .{
        .base_url = base_url,
        .api_key = readCodexApiKeyFromEnv(allocator, env_key_name),
    };
}

const ClaudeConfigFields = struct {
    base_url: ?[]u8 = null,
    api_key: ?[]u8 = null,
};

fn readClaudeConfig(allocator: std.mem.Allocator) ClaudeConfigFields {
    var result: ClaudeConfigFields = .{};

    const home = config_mod.getHomeDir(allocator) orelse {
        fillClaudeFromEnv(allocator, &result);
        return result;
    };
    defer allocator.free(home);
    const path = std.fs.path.join(allocator, &.{ home, app.claude_config_dir, app.claude_settings_filename }) catch {
        fillClaudeFromEnv(allocator, &result);
        return result;
    };
    defer allocator.free(path);

    var content: std.ArrayListUnmanaged(u8) = .empty;
    defer content.deinit(allocator);
    if (!readFileIntoList(allocator, path, &content)) {
        fillClaudeFromEnv(allocator, &result);
        return result;
    }

    var in_env = false;
    var env_depth: i32 = 0;
    var line_iter = std.mem.splitScalar(u8, content.items, '\n');
    while (line_iter.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");

        if (!in_env and std.mem.indexOf(u8, trimmed, "\"env\"") != null) {
            in_env = true;
            env_depth = 0;
            if (std.mem.indexOf(u8, trimmed, "{") != null) env_depth = 1;
            continue;
        }

        if (in_env and env_depth == 0) {
            if (std.mem.indexOf(u8, trimmed, "{") != null) env_depth = 1;
            continue;
        }

        if (in_env and env_depth > 0) {
            for (trimmed) |ch| {
                if (ch == '{') env_depth += 1;
                if (ch == '}') env_depth -= 1;
            }
            if (env_depth <= 0) {
                in_env = false;
                continue;
            }
            if (result.base_url == null and std.mem.indexOf(u8, trimmed, "\"ANTHROPIC_BASE_URL\"") != null) {
                if (extractJsonLineStringValue(trimmed)) |val| {
                    result.base_url = normalizeBaseUrl(allocator, val) catch null;
                }
                continue;
            }
            if (result.api_key == null and std.mem.indexOf(u8, trimmed, "\"ANTHROPIC_AUTH_TOKEN\"") != null) {
                if (extractJsonLineStringValue(trimmed)) |val| {
                    result.api_key = dupeTrimmed(allocator, val) catch null;
                }
                continue;
            }
        }
    }

    if (result.base_url == null or result.api_key == null) fillClaudeFromEnv(allocator, &result);
    return result;
}

fn fillClaudeFromEnv(allocator: std.mem.Allocator, result: *ClaudeConfigFields) void {
    if (result.base_url == null) {
        if (std.process.getEnvVarOwned(allocator, "ANTHROPIC_BASE_URL") catch null) |val| {
            if (val.len > 0) {
                result.base_url = normalizeBaseUrl(allocator, val) catch null;
            }
            allocator.free(val);
        }
    }
    if (result.api_key == null) {
        if (std.process.getEnvVarOwned(allocator, "ANTHROPIC_AUTH_TOKEN") catch null) |val| {
            if (val.len > 0) {
                result.api_key = dupeTrimmed(allocator, val) catch null;
            }
            allocator.free(val);
        }
    }
}

const OpenCodeConfigFields = struct {
    base_url: ?[]u8 = null,
    api_key: ?[]u8 = null,
};

fn readOpenCodeConfig(allocator: std.mem.Allocator) OpenCodeConfigFields {
    const home = config_mod.getHomeDir(allocator) orelse return .{};
    defer allocator.free(home);
    const path = std.fs.path.join(allocator, &.{ home, ".config", "opencode", app.opencode_config_filename }) catch return .{};
    defer allocator.free(path);

    var content: std.ArrayListUnmanaged(u8) = .empty;
    defer content.deinit(allocator);
    if (!readFileIntoList(allocator, path, &content)) return .{};

    var result: OpenCodeConfigFields = .{};
    var in_openai = false;
    var openai_depth: i32 = 0;
    var in_options = false;
    var options_depth: i32 = 0;

    var line_iter = std.mem.splitScalar(u8, content.items, '\n');
    while (line_iter.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");

        if (!in_openai and std.mem.indexOf(u8, trimmed, "\"openai\"") != null and
            std.mem.indexOf(u8, trimmed, "{") != null)
        {
            in_openai = true;
            openai_depth = 1;
            continue;
        }

        if (in_openai and !in_options) {
            updateDepthTrackingQuoted(trimmed, &openai_depth);
            if (openai_depth <= 0) {
                in_openai = false;
                continue;
            }
            if (std.mem.indexOf(u8, trimmed, "\"options\"") != null and
                std.mem.indexOf(u8, trimmed, "{") != null)
            {
                in_options = true;
                options_depth = 1;
                continue;
            }
            continue;
        }

        if (in_options) {
            if (result.base_url == null and std.mem.indexOf(u8, trimmed, "\"baseURL\"") != null) {
                if (extractJsonLineStringValue(trimmed)) |val| {
                    result.base_url = normalizeBaseUrl(allocator, val) catch null;
                }
            } else if (result.api_key == null and std.mem.indexOf(u8, trimmed, "\"apiKey\"") != null) {
                if (extractJsonLineStringValue(trimmed)) |val| {
                    result.api_key = dupeTrimmed(allocator, val) catch null;
                }
            }
            updateDepthTrackingQuoted(trimmed, &options_depth);
            if (options_depth <= 0) {
                in_options = false;
                openai_depth -= 1;
                if (openai_depth <= 0) in_openai = false;
            }
        }
    }
    return result;
}

const NanobotConfigFields = struct {
    base_url: ?[]u8 = null,
    api_key: ?[]u8 = null,
};

fn readNanobotConfig(allocator: std.mem.Allocator) NanobotConfigFields {
    const home = config_mod.getHomeDir(allocator) orelse return .{};
    defer allocator.free(home);
    const path = std.fs.path.join(allocator, &.{ home, app.nanobot_config_dir, app.nanobot_config_filename }) catch return .{};
    defer allocator.free(path);

    var content: std.ArrayListUnmanaged(u8) = .empty;
    defer content.deinit(allocator);
    if (!readFileIntoList(allocator, path, &content)) return .{};

    var result: NanobotConfigFields = .{};
    var line_iter = std.mem.splitScalar(u8, content.items, '\n');
    while (line_iter.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (std.mem.indexOf(u8, trimmed, ":") == null) continue;
        var indent: usize = 0;
        for (line) |ch| {
            if (ch == ' ') indent += 1 else break;
        }
        if (indent < 4) continue;

        if (result.base_url == null and std.mem.indexOf(u8, trimmed, "\"apiBase\"") != null) {
            if (extractJsonLineStringValue(trimmed)) |val| {
                result.base_url = normalizeBaseUrl(allocator, val) catch null;
            }
        } else if (result.api_key == null and std.mem.indexOf(u8, trimmed, "\"apiKey\"") != null) {
            if (extractJsonLineStringValue(trimmed)) |val| {
                result.api_key = dupeTrimmed(allocator, val) catch null;
            }
        }
    }
    return result;
}

const OpenClawConfigFields = struct {
    base_url: ?[]u8 = null,
    api_key: ?[]u8 = null,
};

fn readOpenClawConfig(allocator: std.mem.Allocator) OpenClawConfigFields {
    const home = config_mod.getHomeDir(allocator) orelse return .{};
    defer allocator.free(home);
    const path = std.fs.path.join(allocator, &.{ home, app.openclaw_config_dir, app.openclaw_config_filename }) catch return .{};
    defer allocator.free(path);

    var content: std.ArrayListUnmanaged(u8) = .empty;
    defer content.deinit(allocator);
    if (!readFileIntoList(allocator, path, &content)) return .{};

    var result: OpenClawConfigFields = .{};
    var in_velora = false;
    var line_iter = std.mem.splitScalar(u8, content.items, '\n');
    while (line_iter.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (std.mem.indexOf(u8, trimmed, "\"velora\"") != null and std.mem.indexOf(u8, trimmed, "{") != null) {
            in_velora = true;
            continue;
        }
        if (!in_velora) continue;
        if (result.base_url == null and std.mem.indexOf(u8, trimmed, "\"baseUrl\"") != null) {
            if (extractJsonLineStringValue(trimmed)) |val| {
                result.base_url = normalizeBaseUrl(allocator, val) catch null;
            }
        } else if (result.api_key == null and std.mem.indexOf(u8, trimmed, "\"apiKey\"") != null) {
            if (extractJsonLineStringValue(trimmed)) |val| {
                result.api_key = dupeTrimmed(allocator, val) catch null;
            }
        }
        if (std.mem.eql(u8, trimmed, "}") or std.mem.eql(u8, trimmed, "},")) {
            in_velora = false;
        }
    }
    return result;
}

/// Extract the string value after `: "..."` on a single JSON line.
/// Returns a slice into the input buffer — do not free.
fn extractJsonLineStringValue(line: []const u8) ?[]const u8 {
    const colon = std.mem.indexOf(u8, line, ":") orelse return null;
    const after = line[colon + 1 ..];
    const q1 = std.mem.indexOfScalar(u8, after, '"') orelse return null;
    const val_start = after[q1 + 1 ..];
    var i: usize = 0;
    while (i < val_start.len) : (i += 1) {
        if (val_start[i] == '\\' and i + 1 < val_start.len) {
            i += 1;
            continue;
        }
        if (val_start[i] == '"') return val_start[0..i];
    }
    return null;
}

fn updateDepthTrackingQuoted(trimmed: []const u8, depth: *i32) void {
    var in_str = false;
    var esc = false;
    for (trimmed) |ch| {
        if (esc) {
            esc = false;
            continue;
        }
        if (in_str) {
            if (ch == '\\') {
                esc = true;
                continue;
            }
            if (ch == '"') in_str = false;
            continue;
        }
        switch (ch) {
            '"' => in_str = true,
            '{' => depth.* += 1,
            '}' => depth.* -= 1,
            else => {},
        }
    }
}

/// Fields captured from each tool's live config (and env vars, where applicable).
/// Each slot may be null when the tool has no config or the field is missing.
pub const ToolState = struct {
    base_url: ?[]u8 = null,
    api_key: ?[]u8 = null,
};

/// Currently-applied config snapshot for each of the five tools. Used to
/// attach "[← cc, oc]" style tags to matching sites in `velora ls`.
pub const CurrentTools = struct {
    cx: ToolState = .{},
    cc: ToolState = .{},
    oc: ToolState = .{},
    nb: ToolState = .{},
    ow: ToolState = .{},

    pub fn load(allocator: std.mem.Allocator) CurrentTools {
        const codex = readCodexConfig(allocator);
        const claude = readClaudeConfig(allocator);
        const opencode = readOpenCodeConfig(allocator);
        const nanobot = readNanobotConfig(allocator);
        const openclaw = readOpenClawConfig(allocator);
        return .{
            .cx = .{ .base_url = codex.base_url, .api_key = codex.api_key },
            .cc = .{ .base_url = claude.base_url, .api_key = claude.api_key },
            .oc = .{ .base_url = opencode.base_url, .api_key = opencode.api_key },
            .nb = .{ .base_url = nanobot.base_url, .api_key = nanobot.api_key },
            .ow = .{ .base_url = openclaw.base_url, .api_key = openclaw.api_key },
        };
    }

    pub fn deinit(self: *CurrentTools, allocator: std.mem.Allocator) void {
        for ([_]*ToolState{ &self.cx, &self.cc, &self.oc, &self.nb, &self.ow }) |slot| {
            if (slot.base_url) |v| allocator.free(v);
            if (slot.api_key) |v| allocator.free(v);
            slot.* = .{};
        }
    }

    /// Returns a bitmask (via sites_mod.toolMask) of tools whose active config
    /// matches the given site. A tool counts as matched when the tool's current
    /// api_key matches the site's (strongest signal — keys are per-provider unique),
    /// or when the tool's current base_url matches. Either signal is enough:
    /// this handles both URL-drift (same site, user tweaked URL) and cases where
    /// we cannot read the tool's key (Codex stores it only in env vars).
    pub fn matchSite(self: CurrentTools, base_url: []const u8, api_key: []const u8) u8 {
        var mask: u8 = 0;
        const norm_url = std.mem.trimRight(u8, base_url, "/ \t\r\n");
        const norm_key = std.mem.trim(u8, api_key, " \t\r\n");
        inline for ([_]struct { t: sites_mod.SiteType, s: ToolState }{
            .{ .t = .cx, .s = self.cx },
            .{ .t = .cc, .s = self.cc },
            .{ .t = .oc, .s = self.oc },
            .{ .t = .nb, .s = self.nb },
            .{ .t = .ow, .s = self.ow },
        }) |item| {
            var hit = false;
            if (item.s.api_key) |cur_key| {
                if (norm_key.len > 0 and std.mem.eql(u8, cur_key, norm_key)) hit = true;
            }
            if (!hit) {
                if (item.s.base_url) |cur_url| {
                    if (norm_url.len > 0 and std.ascii.eqlIgnoreCase(cur_url, norm_url)) hit = true;
                }
            }
            if (hit) mask |= sites_mod.toolMask(item.t);
        }
        return mask;
    }
};

test "extractJsonLineStringValue handles standard line" {
    const line = "    \"ANTHROPIC_BASE_URL\": \"https://example.com\",";
    const got = extractJsonLineStringValue(line).?;
    try std.testing.expectEqualStrings("https://example.com", got);
}

test "extractJsonLineStringValue handles escaped quote" {
    const line = "    \"x\": \"a\\\"b\"";
    const got = extractJsonLineStringValue(line).?;
    try std.testing.expectEqualStrings("a\\\"b", got);
}

test "matchSite matches on base_url" {
    const allocator = std.testing.allocator;
    var tools = CurrentTools{
        .cc = .{ .base_url = try allocator.dupe(u8, "https://example.com") },
    };
    defer tools.deinit(allocator);

    try std.testing.expectEqual(sites_mod.toolMask(.cc), tools.matchSite("https://example.com", ""));
    try std.testing.expectEqual(sites_mod.toolMask(.cc), tools.matchSite("https://example.com/", ""));
    try std.testing.expectEqual(@as(u8, 0), tools.matchSite("https://other.example.com", ""));
}

test "matchSite matches on api_key when url differs" {
    const allocator = std.testing.allocator;
    var tools = CurrentTools{
        .cc = .{
            .base_url = try allocator.dupe(u8, "https://anyrouter.top"),
            .api_key = try allocator.dupe(u8, "sk-secret"),
        },
    };
    defer tools.deinit(allocator);

    // URL differs but api_key matches — still a hit
    const mask = tools.matchSite("https://real-backend.example", "sk-secret");
    try std.testing.expect((mask & sites_mod.toolMask(.cc)) != 0);
}

test "matchSite combines multiple tools" {
    const allocator = std.testing.allocator;
    var tools = CurrentTools{
        .cc = .{ .base_url = try allocator.dupe(u8, "https://api.example.com") },
        .oc = .{ .base_url = try allocator.dupe(u8, "https://api.example.com") },
    };
    defer tools.deinit(allocator);

    const mask = tools.matchSite("https://api.example.com", "");
    try std.testing.expect((mask & sites_mod.toolMask(.cc)) != 0);
    try std.testing.expect((mask & sites_mod.toolMask(.oc)) != 0);
    try std.testing.expectEqual(@as(u8, 0), mask & sites_mod.toolMask(.cx));
}

test "matchSite ignores empty api_key on both sides" {
    const allocator = std.testing.allocator;
    var tools = CurrentTools{
        .cc = .{ .api_key = try allocator.dupe(u8, "") },
    };
    defer tools.deinit(allocator);

    try std.testing.expectEqual(@as(u8, 0), tools.matchSite("https://x.example", ""));
}
