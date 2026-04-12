const std = @import("std");
const builtin = @import("builtin");
const config_mod = @import("config.zig");
const app = @import("app.zig");
const env_mod = @import("env.zig");
const sites_mod = @import("sites.zig");
const output = @import("output.zig");
const terminal = @import("terminal.zig");
const i18n = @import("i18n.zig");

/// Apply a site's configuration to Codex.
/// Updates ~/.codex/config.toml base_url and sets the OPENAI_API_KEY env var.
pub fn applyToCodex(allocator: std.mem.Allocator, w: *std.Io.Writer, caps: terminal.TermCaps, lang: i18n.Language, site: sites_mod.Site, tool_model: []const u8) !void {
    try output.printInfo(w, i18n.tr(lang, "Applying to Codex...", "正在应用到 Codex...", "Codexに適用中..."), caps);
    try w.flush();

    const model = tool_model;

    // 1. Update base_url and model in ~/.codex/config.toml
    const toml_updated = updateCodexToml(allocator, site.base_url, model) catch |err| {
        try output.printWarning(w, i18n.tr(lang, "Failed to update Codex config.toml", "更新 Codex config.toml 失败", "Codex config.toml の更新に失敗しました"), caps);
        try w.flush();
        return err;
    };

    if (toml_updated) {
        try output.printSuccess(w, i18n.tr(lang, "Updated base_url and model in config.toml", "已更新 config.toml 中的 base_url 和 model", "config.toml の base_url と model を更新しました"), caps);
    }

    // 2. Read env_key from config.toml (defaults to OPENAI_API_KEY)
    const default_env_key: EnvKeyResult = .{ .key = "OPENAI_API_KEY", .owned = false };
    const env_key = readCodexEnvKeyName(allocator) catch default_env_key;
    defer if (env_key.owned) allocator.free(@constCast(env_key.key));

    // 3. Set the environment variable
    env_mod.writeEnvVar(allocator, env_key.key, site.api_key) catch |err| {
        try output.printError(w, i18n.tr(lang, "Failed to set environment variable", "设置环境变量失败", "環境変数の設定に失敗しました"), caps);
        try w.flush();
        return err;
    };

    var key_info_buf: [128]u8 = undefined;
    var masked_buf: [64]u8 = undefined;
    const masked = sites_mod.maskKey(&masked_buf, site.api_key);
    const key_info = std.fmt.bufPrint(&key_info_buf, "{s} = {s}", .{ env_key.key, masked }) catch "?";
    try output.printSuccess(w, key_info, caps);
    try output.printKeyValue(w, "Base URL:", site.base_url, caps);
    try output.printKeyValue(w, "Model:", model, caps);
    try w.flush();
}

/// Apply a site's configuration to Claude Code.
/// Updates ~/.claude/settings.json env block AND sets env vars.
pub fn applyToClaudeCode(allocator: std.mem.Allocator, w: *std.Io.Writer, caps: terminal.TermCaps, lang: i18n.Language, site: sites_mod.Site, tool_model: []const u8) !void {
    try output.printInfo(w, i18n.tr(lang, "Applying to Claude Code...", "正在应用到 Claude Code...", "Claude Codeに適用中..."), caps);
    try w.flush();

    const model = tool_model;

    // 1. Update ~/.claude/settings.json
    updateClaudeSettings(allocator, site.api_key, site.base_url, model) catch |err| {
        try output.printError(w, i18n.tr(lang, "Failed to update Claude Code settings", "更新 Claude Code 设置失败", "Claude Code 設定の更新に失敗しました"), caps);
        try w.flush();
        return err;
    };

    // 2. Also set environment variables (ANTHROPIC_AUTH_TOKEN + ANTHROPIC_BASE_URL)
    env_mod.writeEnvVar(allocator, "ANTHROPIC_AUTH_TOKEN", site.api_key) catch {};
    env_mod.writeEnvVar(allocator, "ANTHROPIC_BASE_URL", site.base_url) catch {};

    var masked_buf: [64]u8 = undefined;
    const masked = sites_mod.maskKey(&masked_buf, site.api_key);

    var info_buf: [128]u8 = undefined;
    const info = std.fmt.bufPrint(&info_buf, "ANTHROPIC_AUTH_TOKEN = {s}", .{masked}) catch "?";
    try output.printSuccess(w, info, caps);
    try output.printKeyValue(w, "Base URL:", site.base_url, caps);
    try output.printKeyValue(w, "Model:", model, caps);
    try w.flush();
}

// --- Codex TOML editing ---

fn getCodexTomlPath(allocator: std.mem.Allocator) ![]u8 {
    const home = config_mod.getHomeDir(allocator) orelse return error.NoHomeDir;
    defer allocator.free(home);
    return try std.fs.path.join(allocator, &.{ home, app.codex_config_dir, app.codex_config_filename });
}

fn updateCodexToml(allocator: std.mem.Allocator, new_base_url: []const u8, new_model: []const u8) !bool {
    const path = try getCodexTomlPath(allocator);
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

    if (!has_file) return false;

    var result: std.ArrayListUnmanaged(u8) = .empty;
    defer result.deinit(allocator);

    var in_proxy_section = false;
    var base_url_replaced = false;
    var model_replaced = false;
    var saw_section = false;
    var line_iter = std.mem.splitScalar(u8, existing.items, '\n');

    while (line_iter.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");

        // Track TOML sections
        if (trimmed.len > 0 and trimmed[0] == '[') {
            if (in_proxy_section and !base_url_replaced) {
                var base_url_buf: [512]u8 = undefined;
                const base_url_line = std.fmt.bufPrint(&base_url_buf, "base_url = \"{s}\"", .{new_base_url}) catch "";
                try result.appendSlice(allocator, base_url_line);
                try result.append(allocator, '\n');
                base_url_replaced = true;
            }
            if (!saw_section and !model_replaced) {
                var model_buf: [512]u8 = undefined;
                const model_line = std.fmt.bufPrint(&model_buf, "model = \"{s}\"", .{new_model}) catch "";
                try result.appendSlice(allocator, model_line);
                try result.append(allocator, '\n');
                model_replaced = true;
            }
            saw_section = true;
            in_proxy_section = std.mem.indexOf(u8, trimmed, "model_providers.proxy") != null;
        }

        if (!saw_section) {
            if (std.mem.indexOf(u8, trimmed, "=")) |eq_pos| {
                const key = std.mem.trim(u8, trimmed[0..eq_pos], " \t");
                if (std.mem.eql(u8, key, "model")) {
                    var line_buf: [512]u8 = undefined;
                    const new_line = std.fmt.bufPrint(&line_buf, "model = \"{s}\"", .{new_model}) catch line;
                    try result.appendSlice(allocator, new_line);
                    if (line_iter.peek() != null) try result.append(allocator, '\n');
                    model_replaced = true;
                    continue;
                }
            }
        }

        if (in_proxy_section and !base_url_replaced) {
            // Check for base_url line
            if (std.mem.indexOf(u8, trimmed, "=")) |eq_pos| {
                const key = std.mem.trim(u8, trimmed[0..eq_pos], " \t");
                if (std.mem.eql(u8, key, "base_url")) {
                    var line_buf: [512]u8 = undefined;
                    const new_line = std.fmt.bufPrint(&line_buf, "base_url = \"{s}\"", .{new_base_url}) catch {
                        try result.appendSlice(allocator, line);
                        if (line_iter.peek() != null) try result.append(allocator, '\n');
                        continue;
                    };
                    try result.appendSlice(allocator, new_line);
                    if (line_iter.peek() != null) try result.append(allocator, '\n');
                    base_url_replaced = true;
                    continue;
                }
            }
        }

        try result.appendSlice(allocator, line);
        if (line_iter.peek() != null) try result.append(allocator, '\n');
    }

    if (!model_replaced) {
        if (result.items.len > 0 and result.items[result.items.len - 1] != '\n') {
            try result.append(allocator, '\n');
        }
        var model_buf: [512]u8 = undefined;
        const model_line = std.fmt.bufPrint(&model_buf, "model = \"{s}\"", .{new_model}) catch "";
        try result.appendSlice(allocator, model_line);
        try result.append(allocator, '\n');
    }

    if (in_proxy_section and !base_url_replaced) {
        if (result.items.len > 0 and result.items[result.items.len - 1] != '\n') {
            try result.append(allocator, '\n');
        }
        var base_url_buf: [512]u8 = undefined;
        const base_url_line = std.fmt.bufPrint(&base_url_buf, "base_url = \"{s}\"", .{new_base_url}) catch "";
        try result.appendSlice(allocator, base_url_line);
        try result.append(allocator, '\n');
    }

    const file = try std.fs.createFileAbsolute(path, .{});
    defer file.close();
    try file.writeAll(result.items);

    return true;
}

const EnvKeyResult = struct {
    key: []const u8,
    owned: bool,
};

fn readCodexEnvKeyName(allocator: std.mem.Allocator) !EnvKeyResult {
    const path = try getCodexTomlPath(allocator);
    defer allocator.free(path);

    const file = std.fs.openFileAbsolute(path, .{}) catch return .{ .key = "OPENAI_API_KEY", .owned = false };
    defer file.close();

    var buf: [65536]u8 = undefined;
    const bytes_read = file.readAll(&buf) catch return .{ .key = "OPENAI_API_KEY", .owned = false };
    const content = buf[0..bytes_read];

    var in_proxy = false;
    var line_iter = std.mem.splitScalar(u8, content, '\n');
    while (line_iter.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len > 0 and trimmed[0] == '[') {
            in_proxy = std.mem.indexOf(u8, trimmed, "model_providers.proxy") != null;
        }
        if (in_proxy) {
            if (std.mem.indexOf(u8, trimmed, "=")) |eq_pos| {
                const key = std.mem.trim(u8, trimmed[0..eq_pos], " \t");
                if (std.mem.eql(u8, key, "env_key")) {
                    const val = std.mem.trim(u8, trimmed[eq_pos + 1 ..], " \t");
                    const unquoted = env_mod.stripQuotes(val);
                    if (unquoted.len > 0) {
                        return .{ .key = try allocator.dupe(u8, unquoted), .owned = true };
                    }
                }
            }
        }
    }
    return .{ .key = "OPENAI_API_KEY", .owned = false };
}

// --- Claude Code JSON editing ---

fn getClaudeSettingsPath(allocator: std.mem.Allocator) ![]u8 {
    const home = config_mod.getHomeDir(allocator) orelse return error.NoHomeDir;
    defer allocator.free(home);
    return try std.fs.path.join(allocator, &.{ home, app.claude_config_dir, app.claude_settings_filename });
}

fn updateClaudeSettings(allocator: std.mem.Allocator, api_key: []const u8, base_url: []const u8, model: []const u8) !void {
    const path = try getClaudeSettingsPath(allocator);
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

    if (!has_file) {
        // Create new settings file with just the env block
        var result: std.ArrayListUnmanaged(u8) = .empty;
        defer result.deinit(allocator);
        try result.appendSlice(allocator, "{\n  \"env\": {\n    \"ANTHROPIC_AUTH_TOKEN\": \"");
        try result.appendSlice(allocator, api_key);
        try result.appendSlice(allocator, "\",\n    \"ANTHROPIC_BASE_URL\": \"");
        try result.appendSlice(allocator, base_url);
        try result.appendSlice(allocator, "\"\n  },\n  \"model\": \"");
        try result.appendSlice(allocator, model);
        try result.appendSlice(allocator, "\"\n}\n");

        // Ensure directory exists
        const dir_path = std.fs.path.dirname(path) orelse return error.InvalidPath;
        std.fs.makeDirAbsolute(dir_path) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };

        const file = try std.fs.createFileAbsolute(path, .{});
        defer file.close();
        try file.writeAll(result.items);
        return;
    }

    // Parse and modify existing JSON
    const content = existing.items;

    // Strategy: find "env" block, replace ANTHROPIC_AUTH_TOKEN and ANTHROPIC_BASE_URL values
    var result: std.ArrayListUnmanaged(u8) = .empty;
    defer result.deinit(allocator);

    // Process line by line for simple key-value replacement within the env block
    var in_env = false;
    var env_depth: i32 = 0;
    var auth_token_found = false;
    var base_url_found = false;
    var line_iter = std.mem.splitScalar(u8, content, '\n');

    while (line_iter.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");

        // Detect entering env block
        if (!in_env and std.mem.indexOf(u8, trimmed, "\"env\"") != null) {
            in_env = true;
            env_depth = 0;
            // Check if { is on same line
            if (std.mem.indexOf(u8, trimmed, "{") != null) {
                env_depth = 1;
            }
            try result.appendSlice(allocator, line);
            if (line_iter.peek() != null) try result.append(allocator, '\n');
            continue;
        }

        if (in_env and env_depth == 0) {
            // Looking for the opening brace
            if (std.mem.indexOf(u8, trimmed, "{") != null) {
                env_depth = 1;
            }
            try result.appendSlice(allocator, line);
            if (line_iter.peek() != null) try result.append(allocator, '\n');
            continue;
        }

        if (in_env and env_depth > 0) {
            // Count braces
            for (trimmed) |ch| {
                if (ch == '{') env_depth += 1;
                if (ch == '}') env_depth -= 1;
            }

            if (env_depth <= 0) {
                // Closing brace of env block - inject missing keys before closing
                if (!auth_token_found or !base_url_found) {
                    if (!auth_token_found) {
                        try result.appendSlice(allocator, "    \"ANTHROPIC_AUTH_TOKEN\": \"");
                        try result.appendSlice(allocator, api_key);
                        try result.appendSlice(allocator, "\",\n");
                    }
                    if (!base_url_found) {
                        try result.appendSlice(allocator, "    \"ANTHROPIC_BASE_URL\": \"");
                        try result.appendSlice(allocator, base_url);
                        try result.appendSlice(allocator, "\",\n");
                    }
                }
                in_env = false;
                try result.appendSlice(allocator, line);
                if (line_iter.peek() != null) try result.append(allocator, '\n');
                continue;
            }

            // Replace ANTHROPIC_AUTH_TOKEN value
            if (std.mem.indexOf(u8, trimmed, "\"ANTHROPIC_AUTH_TOKEN\"") != null) {
                try result.appendSlice(allocator, "    \"ANTHROPIC_AUTH_TOKEN\": \"");
                try result.appendSlice(allocator, api_key);
                // Check if line has trailing comma
                if (trimmed.len > 0 and trimmed[trimmed.len - 1] == ',') {
                    try result.appendSlice(allocator, "\",\n");
                } else {
                    try result.appendSlice(allocator, "\"\n");
                }
                auth_token_found = true;
                continue;
            }

            // Replace ANTHROPIC_BASE_URL value
            if (std.mem.indexOf(u8, trimmed, "\"ANTHROPIC_BASE_URL\"") != null) {
                try result.appendSlice(allocator, "    \"ANTHROPIC_BASE_URL\": \"");
                try result.appendSlice(allocator, base_url);
                if (trimmed.len > 0 and trimmed[trimmed.len - 1] == ',') {
                    try result.appendSlice(allocator, "\",\n");
                } else {
                    try result.appendSlice(allocator, "\"\n");
                }
                base_url_found = true;
                continue;
            }

            // Keep other env lines as-is
            try result.appendSlice(allocator, line);
            if (line_iter.peek() != null) try result.append(allocator, '\n');
            continue;
        }

        // Outside env block, keep as-is
        try result.appendSlice(allocator, line);
        if (line_iter.peek() != null) try result.append(allocator, '\n');
    }

    const updated = try upsertTopLevelJsonStringField(allocator, result.items, "model", model);
    defer allocator.free(updated);

    const file = try std.fs.createFileAbsolute(path, .{});
    defer file.close();
    try file.writeAll(updated);
}

// --- OpenCode JSON editing ---

pub fn applyToOpenCode(allocator: std.mem.Allocator, w: *std.Io.Writer, caps: terminal.TermCaps, lang: i18n.Language, site: sites_mod.Site, tool_model: []const u8) !void {
    try output.printInfo(w, i18n.tr(lang, "Applying to OpenCode...", "正在应用到 OpenCode...", "OpenCodeに適用中..."), caps);
    try w.flush();

    const model = tool_model;

    updateOpenCodeConfig(allocator, site.api_key, site.base_url, model) catch |err| {
        try output.printError(w, i18n.tr(lang, "Failed to update OpenCode config", "更新 OpenCode 配置失败", "OpenCode 設定の更新に失敗しました"), caps);
        try w.flush();
        return err;
    };

    var masked_buf: [64]u8 = undefined;
    const masked = sites_mod.maskKey(&masked_buf, site.api_key);
    var info_buf: [128]u8 = undefined;
    const info = std.fmt.bufPrint(&info_buf, "apiKey = {s}", .{masked}) catch "?";
    try output.printSuccess(w, info, caps);
    try output.printKeyValue(w, "Base URL:", site.base_url, caps);
    try output.printKeyValue(w, "Model:", model, caps);
    try w.flush();
}

fn getOpenCodeConfigPath(allocator: std.mem.Allocator) ![]u8 {
    const home = config_mod.getHomeDir(allocator) orelse return error.NoHomeDir;
    defer allocator.free(home);
    return try std.fs.path.join(allocator, &.{ home, ".config", "opencode", app.opencode_config_filename });
}

fn updateOpenCodeConfig(allocator: std.mem.Allocator, api_key: []const u8, base_url: []const u8, model: []const u8) !void {
    const path = try getOpenCodeConfigPath(allocator);
    defer allocator.free(path);

    // Ensure directory exists
    const dir_path = std.fs.path.dirname(path) orelse return error.InvalidPath;
    std.fs.makeDirAbsolute(dir_path) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };

    var existing: std.ArrayListUnmanaged(u8) = .empty;
    defer existing.deinit(allocator);

    const has_file = blk: {
        const file = std.fs.openFileAbsolute(path, .{}) catch break :blk false;
        defer file.close();
        var buf: [131072]u8 = undefined;
        const bytes_read = file.readAll(&buf) catch break :blk false;
        existing.appendSlice(allocator, buf[0..bytes_read]) catch break :blk false;
        break :blk true;
    };

    if (!has_file) {
        // Create new config with openai provider
        try writeNewOpenCodeConfig(allocator, path, api_key, base_url, model);
        return;
    }

    // Update existing: find provider.openai.options.baseURL and apiKey
    const content = existing.items;
    var result: std.ArrayListUnmanaged(u8) = .empty;
    defer result.deinit(allocator);

    var base_url_found = false;
    var api_key_found = false;
    var in_openai_options = false;
    var options_depth: i32 = 0;
    var brace_depth: i32 = 0;
    var in_string = false;
    var escaped = false;

    // Line-by-line approach for updating known keys
    var line_iter = std.mem.splitScalar(u8, content, '\n');
    while (line_iter.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");

        // Track entry into "options" block under openai provider
        if (std.mem.indexOf(u8, trimmed, "\"options\"") != null and
            std.mem.indexOf(u8, trimmed, "{") != null)
        {
            in_openai_options = true;
            options_depth = 1;
            brace_depth += 1;
            try result.appendSlice(allocator, line);
            if (line_iter.peek() != null) try result.append(allocator, '\n');
            continue;
        }

        if (in_openai_options) {
            // Track brace depth
            for (trimmed) |ch| {
                if (escaped) { escaped = false; continue; }
                if (ch == '\\' and in_string) { escaped = true; continue; }
                if (ch == '"') { in_string = !in_string; continue; }
                if (in_string) continue;
                if (ch == '{') options_depth += 1;
                if (ch == '}') options_depth -= 1;
            }

            if (options_depth <= 0) {
                in_openai_options = false;
                // Inject missing keys before closing brace
                if (!base_url_found) {
                    var line_buf: [512]u8 = undefined;
                    const new_line = std.fmt.bufPrint(&line_buf, "        \"baseURL\": \"{s}\",\n", .{base_url}) catch "";
                    try result.appendSlice(allocator, new_line);
                }
                if (!api_key_found) {
                    var line_buf: [512]u8 = undefined;
                    const new_line = std.fmt.bufPrint(&line_buf, "        \"apiKey\": \"{s}\"\n", .{api_key}) catch "";
                    try result.appendSlice(allocator, new_line);
                }
                try result.appendSlice(allocator, line);
                if (line_iter.peek() != null) try result.append(allocator, '\n');
                continue;
            }

            // Replace baseURL
            if (std.mem.indexOf(u8, trimmed, "\"baseURL\"") != null) {
                var line_buf: [512]u8 = undefined;
                const trailing_comma = trimmed.len > 0 and trimmed[trimmed.len - 1] == ',';
                const new_line = std.fmt.bufPrint(&line_buf, "        \"baseURL\": \"{s}\"{s}", .{
                    base_url,
                    if (trailing_comma) "," else "",
                }) catch line;
                try result.appendSlice(allocator, new_line);
                if (line_iter.peek() != null) try result.append(allocator, '\n');
                base_url_found = true;
                continue;
            }

            // Replace apiKey
            if (std.mem.indexOf(u8, trimmed, "\"apiKey\"") != null) {
                var line_buf: [512]u8 = undefined;
                const trailing_comma = trimmed.len > 0 and trimmed[trimmed.len - 1] == ',';
                const new_line = std.fmt.bufPrint(&line_buf, "        \"apiKey\": \"{s}\"{s}", .{
                    api_key,
                    if (trailing_comma) "," else "",
                }) catch line;
                try result.appendSlice(allocator, new_line);
                if (line_iter.peek() != null) try result.append(allocator, '\n');
                api_key_found = true;
                continue;
            }
        }

        try result.appendSlice(allocator, line);
        if (line_iter.peek() != null) try result.append(allocator, '\n');
    }

    const updated = try upsertTopLevelJsonStringField(allocator, result.items, "model", model);
    defer allocator.free(updated);

    const file = try std.fs.createFileAbsolute(path, .{});
    defer file.close();
    try file.writeAll(updated);
}

fn writeNewOpenCodeConfig(allocator: std.mem.Allocator, path: []const u8, api_key: []const u8, base_url: []const u8, model: []const u8) !void {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(allocator);

    try out.appendSlice(allocator,
        "{\n" ++
        "  \"provider\": {\n" ++
        "    \"openai\": {\n" ++
        "      \"options\": {\n"
    );
    var url_buf: [512]u8 = undefined;
    const url_line = std.fmt.bufPrint(&url_buf, "        \"baseURL\": \"{s}\",\n", .{base_url}) catch "";
    try out.appendSlice(allocator, url_line);
    var key_buf: [512]u8 = undefined;
    const key_line = std.fmt.bufPrint(&key_buf, "        \"apiKey\": \"{s}\"\n", .{api_key}) catch "";
    try out.appendSlice(allocator, key_line);
    try out.appendSlice(allocator,
        "      }\n" ++
        "    }\n" ++
        "  },\n" ++
        "  \"model\": \""
    );
    try out.appendSlice(allocator, model);
    try out.appendSlice(allocator,
        "\",\n" ++
        "  \"$schema\": \"https://opencode.ai/config.json\"\n" ++
        "}\n"
    );

    const file = try std.fs.createFileAbsolute(path, .{});
    defer file.close();
    try file.writeAll(out.items);
}

fn upsertTopLevelJsonStringField(allocator: std.mem.Allocator, content: []const u8, field: []const u8, value: []const u8) ![]u8 {
    var depth: i32 = 0;
    var i: usize = 0;

    while (i < content.len) {
        const ch = content[i];
        switch (ch) {
            '{' => {
                depth += 1;
                i += 1;
            },
            '}' => {
                depth -= 1;
                i += 1;
            },
            '"' => {
                const key_end = findJsonStringEnd(content, i + 1) orelse break;
                if (depth == 1) {
                    const key = content[i + 1 .. key_end];
                    var pos = skipJsonWhitespace(content, key_end + 1);
                    if (pos < content.len and content[pos] == ':') {
                        pos = skipJsonWhitespace(content, pos + 1);
                        if (std.mem.eql(u8, key, field) and pos < content.len and content[pos] == '"') {
                            const value_end = findJsonStringEnd(content, pos + 1) orelse break;
                            var updated: std.ArrayListUnmanaged(u8) = .empty;
                            defer updated.deinit(allocator);
                            try updated.appendSlice(allocator, content[0 .. pos + 1]);
                            try updated.appendSlice(allocator, value);
                            try updated.appendSlice(allocator, content[value_end..]);
                            return updated.toOwnedSlice(allocator);
                        }
                    }
                }
                i = key_end + 1;
            },
            else => i += 1,
        }
    }

    const object_start = std.mem.indexOfScalar(u8, content, '{') orelse return try allocator.dupe(u8, content);
    const insert_pos = skipJsonWhitespace(content, object_start + 1);
    const has_members = insert_pos < content.len and content[insert_pos] != '}';

    var updated: std.ArrayListUnmanaged(u8) = .empty;
    defer updated.deinit(allocator);

    try updated.appendSlice(allocator, content[0..insert_pos]);
    if (has_members) {
        try updated.appendSlice(allocator, "\n  \"");
        try updated.appendSlice(allocator, field);
        try updated.appendSlice(allocator, "\": \"");
        try updated.appendSlice(allocator, value);
        try updated.appendSlice(allocator, "\",");
        if (content[insert_pos] != '\n') {
            try updated.append(allocator, '\n');
        }
    } else {
        try updated.appendSlice(allocator, "\n  \"");
        try updated.appendSlice(allocator, field);
        try updated.appendSlice(allocator, "\": \"");
        try updated.appendSlice(allocator, value);
        try updated.appendSlice(allocator, "\"\n");
    }
    try updated.appendSlice(allocator, content[insert_pos..]);
    return updated.toOwnedSlice(allocator);
}

fn skipJsonWhitespace(content: []const u8, start: usize) usize {
    var pos = start;
    while (pos < content.len and std.ascii.isWhitespace(content[pos])) : (pos += 1) {}
    return pos;
}

fn findJsonStringEnd(content: []const u8, start: usize) ?usize {
    var pos = start;
    var esc = false;
    while (pos < content.len) : (pos += 1) {
        const ch = content[pos];
        if (esc) {
            esc = false;
            continue;
        }
        if (ch == '\\') {
            esc = true;
            continue;
        }
        if (ch == '"') return pos;
    }
    return null;
}

// --- Nanobot JSON editing ---

/// Apply a site's configuration to Nanobot.
/// Updates ~/.nanobot/config.json providers.openai and agents.defaults.model fields.
pub fn applyToNanobot(allocator: std.mem.Allocator, w: *std.Io.Writer, caps: terminal.TermCaps, lang: i18n.Language, site: sites_mod.Site, tool_model: []const u8) !void {
    try output.printInfo(w, i18n.tr(lang, "Applying to Nanobot...", "正在应用到 Nanobot...", "Nanobotに適用中..."), caps);
    try w.flush();

    const model = tool_model;

    updateNanobotConfig(allocator, site.api_key, site.base_url, model) catch |err| {
        try output.printError(w, i18n.tr(lang, "Failed to update Nanobot config", "更新 Nanobot 配置失败", "Nanobot 設定の更新に失敗しました"), caps);
        try w.flush();
        return err;
    };

    var masked_buf: [64]u8 = undefined;
    const masked = sites_mod.maskKey(&masked_buf, site.api_key);
    var info_buf: [128]u8 = undefined;
    const info = std.fmt.bufPrint(&info_buf, "providers.openai.apiKey = {s}", .{masked}) catch "?";
    try output.printSuccess(w, info, caps);
    try output.printKeyValue(w, "Base URL:", site.base_url, caps);
    try output.printKeyValue(w, "Model:", model, caps);
    try w.flush();
}

fn getNanobotConfigPath(allocator: std.mem.Allocator) ![]u8 {
    const home = config_mod.getHomeDir(allocator) orelse return error.NoHomeDir;
    defer allocator.free(home);
    return try std.fs.path.join(allocator, &.{ home, app.nanobot_config_dir, app.nanobot_config_filename });
}

fn updateNanobotConfig(allocator: std.mem.Allocator, api_key: []const u8, base_url: []const u8, model: []const u8) !void {
    const path = try getNanobotConfigPath(allocator);
    defer allocator.free(path);

    // Ensure directory exists
    const dir_path = std.fs.path.dirname(path) orelse return error.InvalidPath;
    std.fs.makeDirAbsolute(dir_path) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };

    var existing: std.ArrayListUnmanaged(u8) = .empty;
    defer existing.deinit(allocator);

    const has_file = blk: {
        const file = std.fs.openFileAbsolute(path, .{}) catch break :blk false;
        defer file.close();
        var buf: [131072]u8 = undefined;
        const bytes_read = file.readAll(&buf) catch break :blk false;
        existing.appendSlice(allocator, buf[0..bytes_read]) catch break :blk false;
        break :blk true;
    };

    if (!has_file) {
        // Create minimal nanobot config
        try writeNewNanobotConfig(allocator, path, api_key, base_url, model);
        return;
    }

    // Update existing config: replace providers.openai fields and agents.defaults.model
    const content = existing.items;
    var result: std.ArrayListUnmanaged(u8) = .empty;
    defer result.deinit(allocator);

    var line_iter = std.mem.splitScalar(u8, content, '\n');
    while (line_iter.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");

        // Replace apiKey in openai provider block
        if (std.mem.indexOf(u8, trimmed, "\"apiKey\"") != null and std.mem.indexOf(u8, trimmed, ":") != null) {
            // Check context - we're updating openai provider's apiKey
            // Simple heuristic: replace apiKey lines that are within providers context
            const trailing_comma = trimmed.len > 0 and trimmed[trimmed.len - 1] == ',';
            var indent_count: usize = 0;
            for (line) |ch| {
                if (ch == ' ') {
                    indent_count += 1;
                } else break;
            }
            // Only replace at provider indentation depth (typically 4+ spaces)
            if (indent_count >= 4) {
                var line_buf: [512]u8 = undefined;
                var indent_buf: [32]u8 = undefined;
                const indent = indent_buf[0..@min(indent_count, 32)];
                @memset(indent, ' ');
                const new_line = std.fmt.bufPrint(&line_buf, "{s}\"apiKey\": \"{s}\"{s}", .{
                    indent,
                    api_key,
                    if (trailing_comma) "," else "",
                }) catch line;
                try result.appendSlice(allocator, new_line);
                if (line_iter.peek() != null) try result.append(allocator, '\n');
                continue;
            }
        }

        // Replace apiBase in openai provider block
        if (std.mem.indexOf(u8, trimmed, "\"apiBase\"") != null and std.mem.indexOf(u8, trimmed, ":") != null) {
            var indent_count: usize = 0;
            for (line) |ch| {
                if (ch == ' ') {
                    indent_count += 1;
                } else break;
            }
            if (indent_count >= 4) {
                const trailing_comma = trimmed.len > 0 and trimmed[trimmed.len - 1] == ',';
                var line_buf: [512]u8 = undefined;
                var indent_buf: [32]u8 = undefined;
                const indent = indent_buf[0..@min(indent_count, 32)];
                @memset(indent, ' ');
                const new_line = std.fmt.bufPrint(&line_buf, "{s}\"apiBase\": \"{s}\"{s}", .{
                    indent,
                    base_url,
                    if (trailing_comma) "," else "",
                }) catch line;
                try result.appendSlice(allocator, new_line);
                if (line_iter.peek() != null) try result.append(allocator, '\n');
                continue;
            }
        }

        // Replace agents.defaults.model
        if (std.mem.indexOf(u8, trimmed, "\"model\"") != null and std.mem.indexOf(u8, trimmed, ":") != null) {
            // Check if it's the model under agents.defaults (typically indentation 6)
            var indent_count: usize = 0;
            for (line) |ch| {
                if (ch == ' ') {
                    indent_count += 1;
                } else break;
            }
            if (indent_count >= 6 and indent_count <= 8) {
                const trailing_comma = trimmed.len > 0 and trimmed[trimmed.len - 1] == ',';
                var line_buf: [512]u8 = undefined;
                var indent_buf: [32]u8 = undefined;
                const indent = indent_buf[0..@min(indent_count, 32)];
                @memset(indent, ' ');
                // Nanobot model format: "openai/<model>" or just the model name
                var model_val_buf: [256]u8 = undefined;
                const model_val = if (std.mem.indexOf(u8, model, "/") != null)
                    model
                else
                    std.fmt.bufPrint(&model_val_buf, "openai/{s}", .{model}) catch model;
                const new_line = std.fmt.bufPrint(&line_buf, "{s}\"model\": \"{s}\"{s}", .{
                    indent,
                    model_val,
                    if (trailing_comma) "," else "",
                }) catch line;
                try result.appendSlice(allocator, new_line);
                if (line_iter.peek() != null) try result.append(allocator, '\n');
                continue;
            }
        }

        try result.appendSlice(allocator, line);
        if (line_iter.peek() != null) try result.append(allocator, '\n');
    }

    const file = try std.fs.createFileAbsolute(path, .{});
    defer file.close();
    try file.writeAll(result.items);
}

fn writeNewNanobotConfig(allocator: std.mem.Allocator, path: []const u8, api_key: []const u8, base_url: []const u8, model: []const u8) !void {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(allocator);

    // Build model value with openai/ prefix if needed
    var model_val_buf: [256]u8 = undefined;
    const model_val = if (std.mem.indexOf(u8, model, "/") != null)
        model
    else
        std.fmt.bufPrint(&model_val_buf, "openai/{s}", .{model}) catch model;

    try out.appendSlice(allocator, "{\n  \"agents\": {\n    \"defaults\": {\n      \"model\": \"");
    try out.appendSlice(allocator, model_val);
    try out.appendSlice(allocator, "\",\n      \"provider\": \"auto\"\n    }\n  },\n  \"providers\": {\n    \"openai\": {\n      \"apiKey\": \"");
    try out.appendSlice(allocator, api_key);
    try out.appendSlice(allocator, "\",\n      \"apiBase\": \"");
    try out.appendSlice(allocator, base_url);
    try out.appendSlice(allocator, "\",\n      \"extraHeaders\": null\n    }\n  }\n}\n");

    const file = try std.fs.createFileAbsolute(path, .{});
    defer file.close();
    try file.writeAll(out.items);
}

// --- OpenClaw JSON editing ---

/// Apply a site's configuration to OpenClaw.
/// Updates ~/.openclaw/openclaw.json models.providers and agents.defaults.model.primary fields.
pub fn applyToOpenClaw(allocator: std.mem.Allocator, w: *std.Io.Writer, caps: terminal.TermCaps, lang: i18n.Language, site: sites_mod.Site, tool_model: []const u8) !void {
    try output.printInfo(w, i18n.tr(lang, "Applying to OpenClaw...", "正在应用到 OpenClaw...", "OpenClawに適用中..."), caps);
    try w.flush();

    const model = tool_model;

    updateOpenClawConfig(allocator, site.api_key, site.base_url, model) catch |err| {
        try output.printError(w, i18n.tr(lang, "Failed to update OpenClaw config", "更新 OpenClaw 配置失败", "OpenClaw 設定の更新に失敗しました"), caps);
        try w.flush();
        return err;
    };

    var masked_buf: [64]u8 = undefined;
    const masked = sites_mod.maskKey(&masked_buf, site.api_key);
    var info_buf: [128]u8 = undefined;
    const info = std.fmt.bufPrint(&info_buf, "models.providers.velora.apiKey = {s}", .{masked}) catch "?";
    try output.printSuccess(w, info, caps);
    try output.printKeyValue(w, "Base URL:", site.base_url, caps);
    try output.printKeyValue(w, "Model:", model, caps);
    try w.flush();
}

fn getOpenClawConfigPath(allocator: std.mem.Allocator) ![]u8 {
    const home = config_mod.getHomeDir(allocator) orelse return error.NoHomeDir;
    defer allocator.free(home);
    return try std.fs.path.join(allocator, &.{ home, app.openclaw_config_dir, app.openclaw_config_filename });
}

fn updateOpenClawConfig(allocator: std.mem.Allocator, api_key: []const u8, base_url: []const u8, model: []const u8) !void {
    const path = try getOpenClawConfigPath(allocator);
    defer allocator.free(path);

    // Ensure directory exists
    const dir_path = std.fs.path.dirname(path) orelse return error.InvalidPath;
    std.fs.makeDirAbsolute(dir_path) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };

    var existing: std.ArrayListUnmanaged(u8) = .empty;
    defer existing.deinit(allocator);

    const has_file = blk: {
        const file = std.fs.openFileAbsolute(path, .{}) catch break :blk false;
        defer file.close();
        var buf: [131072]u8 = undefined;
        const bytes_read = file.readAll(&buf) catch break :blk false;
        existing.appendSlice(allocator, buf[0..bytes_read]) catch break :blk false;
        break :blk true;
    };

    if (!has_file) {
        try writeNewOpenClawConfig(allocator, path, api_key, base_url, model);
        return;
    }

    // For OpenClaw, rewrite the whole file with updated provider and model
    // This is simpler than line-by-line editing for the nested JSON5 structure
    const content = existing.items;

    // Try to update "primary" field under agents.defaults.model
    var result: std.ArrayListUnmanaged(u8) = .empty;
    defer result.deinit(allocator);

    // For existing files, do line-by-line replacement of known fields
    var line_iter = std.mem.splitScalar(u8, content, '\n');
    var in_velora_provider = false;
    while (line_iter.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");

        // Track if we're inside a "velora" provider block
        if (std.mem.indexOf(u8, trimmed, "\"velora\"") != null and std.mem.indexOf(u8, trimmed, "{") != null) {
            in_velora_provider = true;
        }

        if (in_velora_provider) {
            if (std.mem.indexOf(u8, trimmed, "\"apiKey\"") != null) {
                const trailing_comma = trimmed.len > 0 and trimmed[trimmed.len - 1] == ',';
                try result.appendSlice(allocator, "        \"apiKey\": \"");
                try result.appendSlice(allocator, api_key);
                try result.append(allocator, '"');
                if (trailing_comma) try result.append(allocator, ',');
                if (line_iter.peek() != null) try result.append(allocator, '\n');
                continue;
            }
            if (std.mem.indexOf(u8, trimmed, "\"baseUrl\"") != null) {
                const trailing_comma = trimmed.len > 0 and trimmed[trimmed.len - 1] == ',';
                try result.appendSlice(allocator, "        \"baseUrl\": \"");
                try result.appendSlice(allocator, base_url);
                try result.append(allocator, '"');
                if (trailing_comma) try result.append(allocator, ',');
                if (line_iter.peek() != null) try result.append(allocator, '\n');
                continue;
            }
            // End of velora provider block
            if (std.mem.eql(u8, trimmed, "}") or std.mem.eql(u8, trimmed, "},")) {
                in_velora_provider = false;
            }
        }

        // Replace "primary" field under agents.defaults.model
        if (std.mem.indexOf(u8, trimmed, "\"primary\"") != null and std.mem.indexOf(u8, trimmed, ":") != null) {
            const trailing_comma = trimmed.len > 0 and trimmed[trimmed.len - 1] == ',';
            var indent_count: usize = 0;
            for (line) |ch| {
                if (ch == ' ') indent_count += 1 else break;
            }
            var indent_buf: [32]u8 = undefined;
            const indent = indent_buf[0..@min(indent_count, 32)];
            @memset(indent, ' ');
            var model_val_buf: [256]u8 = undefined;
            const model_val = std.fmt.bufPrint(&model_val_buf, "velora/{s}", .{model}) catch model;
            var line_buf: [512]u8 = undefined;
            const new_line = std.fmt.bufPrint(&line_buf, "{s}\"primary\": \"{s}\"{s}", .{
                indent, model_val, if (trailing_comma) "," else "",
            }) catch line;
            try result.appendSlice(allocator, new_line);
            if (line_iter.peek() != null) try result.append(allocator, '\n');
            continue;
        }

        try result.appendSlice(allocator, line);
        if (line_iter.peek() != null) try result.append(allocator, '\n');
    }

    const file = try std.fs.createFileAbsolute(path, .{});
    defer file.close();
    try file.writeAll(result.items);
}

fn writeNewOpenClawConfig(allocator: std.mem.Allocator, path: []const u8, api_key: []const u8, base_url: []const u8, model: []const u8) !void {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(allocator);

    var model_val_buf: [256]u8 = undefined;
    const model_val = std.fmt.bufPrint(&model_val_buf, "velora/{s}", .{model}) catch model;

    try out.appendSlice(allocator,
        "{\n" ++
        "  \"models\": {\n" ++
        "    \"providers\": {\n" ++
        "      \"velora\": {\n"
    );
    var url_buf: [512]u8 = undefined;
    const url_line = std.fmt.bufPrint(&url_buf, "        \"baseUrl\": \"{s}\",\n", .{base_url}) catch "";
    try out.appendSlice(allocator, url_line);
    var key_buf: [512]u8 = undefined;
    const key_line = std.fmt.bufPrint(&key_buf, "        \"apiKey\": \"{s}\",\n", .{api_key}) catch "";
    try out.appendSlice(allocator, key_line);
    try out.appendSlice(allocator,
        "        \"api\": \"openai-completions\"\n" ++
        "      }\n" ++
        "    }\n" ++
        "  },\n" ++
        "  \"agents\": {\n" ++
        "    \"defaults\": {\n" ++
        "      \"model\": {\n" ++
        "        \"primary\": \""
    );
    try out.appendSlice(allocator, model_val);
    try out.appendSlice(allocator,
        "\"\n" ++
        "      }\n" ++
        "    }\n" ++
        "  }\n" ++
        "}\n"
    );

    const file = try std.fs.createFileAbsolute(path, .{});
    defer file.close();
    try file.writeAll(out.items);
}
