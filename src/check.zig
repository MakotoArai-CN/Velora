const std = @import("std");
const sites_mod = @import("sites.zig");

pub const ConnectivityResult = struct {
    reachable: bool,
    latency_ms: ?u64, // null if unreachable
};

pub const ModelInfo = struct {
    models_found: u32,
    has_expected: bool,
    is_reverse_proxy: bool,
};

pub const SiteStatus = struct {
    alias: []const u8,
    site: sites_mod.Site,
    conn: ConnectivityResult,
};

/// Check connectivity to a base_url by making an HTTP GET to /v1/models.
pub fn checkConnectivity(allocator: std.mem.Allocator, base_url: []const u8) ConnectivityResult {
    const start = std.time.milliTimestamp();

    // Build URL: base_url + /models (or /v1/models)
    var url_buf: [1024]u8 = undefined;
    const url = blk: {
        // If base_url already ends with /v1, just append /models
        if (std.mem.endsWith(u8, base_url, "/v1") or std.mem.endsWith(u8, base_url, "/v1/")) {
            const trimmed = std.mem.trimRight(u8, base_url, "/");
            break :blk std.fmt.bufPrint(&url_buf, "{s}/models", .{trimmed}) catch return .{ .reachable = false, .latency_ms = null };
        }
        break :blk std.fmt.bufPrint(&url_buf, "{s}/v1/models", .{std.mem.trimRight(u8, base_url, "/")}) catch return .{ .reachable = false, .latency_ms = null };
    };

    var client: std.http.Client = .{ .allocator = allocator };
    defer client.deinit();

    var response_writer: std.Io.Writer.Allocating = .init(allocator);
    defer response_writer.deinit();

    const result = client.fetch(.{
        .location = .{ .url = url },
        .method = .GET,
        .headers = .{
            .user_agent = .{ .override = "VA/2.0" },
            .accept_encoding = .{ .override = "identity" },
        },
        .response_writer = &response_writer.writer,
    }) catch return .{ .reachable = false, .latency_ms = null };

    const elapsed = @as(u64, @intCast(std.time.milliTimestamp() - start));
    const code = @intFromEnum(result.status);

    // 200, 401, 403 all mean the server is reachable
    if (code == 200 or code == 401 or code == 403 or code == 404) {
        return .{ .reachable = true, .latency_ms = elapsed };
    }

    return .{ .reachable = false, .latency_ms = elapsed };
}

/// Check all sites for connectivity. Returns array sorted by latency (reachable first).
pub fn checkAllSites(allocator: std.mem.Allocator, store: *const sites_mod.SitesStore) ![]SiteStatus {
    if (store.count == 0) return &[_]SiteStatus{};

    const statuses = try allocator.alloc(SiteStatus, store.count);
    errdefer allocator.free(statuses);

    for (0..store.count) |i| {
        const entry = store.entries[i];
        statuses[i] = .{
            .alias = entry.alias,
            .site = entry.site,
            .conn = checkConnectivity(allocator, entry.site.base_url),
        };
    }

    // Sort: reachable first by latency ascending, unreachable at end
    std.mem.sort(SiteStatus, statuses, {}, struct {
        fn lessThan(_: void, a: SiteStatus, b: SiteStatus) bool {
            if (a.conn.reachable and !b.conn.reachable) return true;
            if (!a.conn.reachable and b.conn.reachable) return false;
            const a_ms = a.conn.latency_ms orelse std.math.maxInt(u64);
            const b_ms = b.conn.latency_ms orelse std.math.maxInt(u64);
            return a_ms < b_ms;
        }
    }.lessThan);

    return statuses;
}

/// Detect models available at the endpoint. Requires API key for authentication.
pub fn detectModels(allocator: std.mem.Allocator, base_url: []const u8, api_key: []const u8, site_type: sites_mod.SiteType) ModelInfo {
    var url_buf: [1024]u8 = undefined;
    const url = blk: {
        if (std.mem.endsWith(u8, base_url, "/v1") or std.mem.endsWith(u8, base_url, "/v1/")) {
            const trimmed = std.mem.trimRight(u8, base_url, "/");
            break :blk std.fmt.bufPrint(&url_buf, "{s}/models", .{trimmed}) catch return .{ .models_found = 0, .has_expected = false, .is_reverse_proxy = false };
        }
        break :blk std.fmt.bufPrint(&url_buf, "{s}/v1/models", .{std.mem.trimRight(u8, base_url, "/")}) catch return .{ .models_found = 0, .has_expected = false, .is_reverse_proxy = false };
    };

    var auth_buf: [256]u8 = undefined;
    const auth_header = std.fmt.bufPrint(&auth_buf, "Bearer {s}", .{api_key}) catch return .{ .models_found = 0, .has_expected = false, .is_reverse_proxy = false };

    var client: std.http.Client = .{ .allocator = allocator };
    defer client.deinit();

    var response_writer: std.Io.Writer.Allocating = .init(allocator);
    defer response_writer.deinit();

    const extra_headers = [_]std.http.Header{
        .{ .name = "authorization", .value = auth_header },
    };

    const result = client.fetch(.{
        .location = .{ .url = url },
        .method = .GET,
        .headers = .{
            .user_agent = .{ .override = "VA/2.0" },
            .accept_encoding = .{ .override = "identity" },
        },
        .extra_headers = &extra_headers,
        .response_writer = &response_writer.writer,
    }) catch return .{ .models_found = 0, .has_expected = false, .is_reverse_proxy = false };

    if (@intFromEnum(result.status) != 200) {
        return .{ .models_found = 0, .has_expected = false, .is_reverse_proxy = false };
    }

    const body = response_writer.written();

    // Count model IDs and check for expected models
    var model_count: u32 = 0;
    var has_expected = false;
    var has_gpt = false;
    var has_claude = false;

    // Simple scan for "id": "model-name" patterns
    var search_pos: usize = 0;
    while (std.mem.indexOf(u8, body[search_pos..], "\"id\"")) |id_pos| {
        const abs_pos = search_pos + id_pos;
        const after_id = body[abs_pos + 4 ..];

        // Find value
        const colon = std.mem.indexOf(u8, after_id, ":") orelse break;
        const after_colon = after_id[colon + 1 ..];
        const q1 = std.mem.indexOf(u8, after_colon, "\"") orelse break;
        const val_start = after_colon[q1 + 1 ..];
        const q2 = std.mem.indexOf(u8, val_start, "\"") orelse break;
        const model_id = val_start[0..q2];

        model_count += 1;

        // Check for expected models
        switch (site_type) {
            .cx => {
                if (std.mem.indexOf(u8, model_id, "gpt-5") != null) {
                    has_expected = true;
                    has_gpt = true;
                }
                if (std.mem.indexOf(u8, model_id, "claude") != null) {
                    has_claude = true;
                }
            },
            .cc => {
                if (std.mem.indexOf(u8, model_id, "claude") != null) {
                    has_expected = true;
                    has_claude = true;
                }
                if (std.mem.indexOf(u8, model_id, "gpt") != null) {
                    has_gpt = true;
                }
            },
            .oc => {
                // OpenCode supports both openai and anthropic providers
                if (std.mem.indexOf(u8, model_id, "gpt-5") != null or
                    std.mem.indexOf(u8, model_id, "claude") != null)
                {
                    has_expected = true;
                }
                if (std.mem.indexOf(u8, model_id, "gpt") != null) has_gpt = true;
                if (std.mem.indexOf(u8, model_id, "claude") != null) has_claude = true;
            },
        }

        // Check for reverse proxy indicators
        if (std.mem.indexOf(u8, model_id, "kiro") != null) {
            has_gpt = true;
            has_claude = true;
        }

        search_pos = abs_pos + 4 + colon + 1 + q1 + 1 + q2 + 1;
        if (search_pos >= body.len) break;
    }

    return .{
        .models_found = model_count,
        .has_expected = has_expected,
        .is_reverse_proxy = has_gpt and has_claude,
    };
}

pub const ModelCallResult = struct {
    success: bool,
    error_msg: ?[]const u8 = null, // points into static string
    latency_ms: ?u64 = null,
    model_in_list: bool = false, // whether the model was found in /v1/models
};

/// Comprehensive model availability check:
/// 1. Check if the model exists in the /v1/models list
/// 2. Try calling the model with the appropriate API format (OpenAI or Anthropic)
/// 3. Also try alternative endpoint if the primary one fails (reverse proxy support)
pub fn testModelCall(allocator: std.mem.Allocator, base_url: []const u8, api_key: []const u8, model: []const u8, site_type: sites_mod.SiteType) ModelCallResult {
    const start = std.time.milliTimestamp();

    // Step 1: Check if model is in the model list
    const model_in_list = checkModelInList(allocator, base_url, api_key, model);

    // Step 2: Try calling the model with multiple API formats
    // Order of attempts per site type:
    //   cx: Responses API -> Chat Completions -> Anthropic Messages
    //   cc: Anthropic Messages -> Chat Completions -> Responses API
    //   oc: Chat Completions -> Responses API -> Anthropic Messages
    const attempts: [3]*const fn (std.mem.Allocator, []const u8, []const u8, []const u8) CallAttemptResult = switch (site_type) {
        .cx => .{ &tryResponsesCall, &tryOpenAICall, &tryAnthropicCall },
        .cc => .{ &tryAnthropicCall, &tryOpenAICall, &tryResponsesCall },
        .oc => .{ &tryOpenAICall, &tryResponsesCall, &tryAnthropicCall },
    };

    var first_error: ?[]const u8 = null;
    for (attempts) |attempt_fn| {
        const r = attempt_fn(allocator, base_url, api_key, model);
        if (r.success) {
            const elapsed = @as(u64, @intCast(std.time.milliTimestamp() - start));
            return .{ .success = true, .latency_ms = elapsed, .model_in_list = model_in_list };
        }
        if (first_error == null) first_error = r.error_msg;
    }

    const elapsed = @as(u64, @intCast(std.time.milliTimestamp() - start));
    return .{
        .success = false,
        .error_msg = first_error,
        .latency_ms = elapsed,
        .model_in_list = model_in_list,
    };
}

/// Check if a specific model exists in the /v1/models endpoint.
fn checkModelInList(allocator: std.mem.Allocator, base_url: []const u8, api_key: []const u8, model: []const u8) bool {
    var url_buf: [1024]u8 = undefined;
    const url = buildUrl(&url_buf, base_url, "/models") orelse return false;

    var auth_buf: [256]u8 = undefined;
    const auth_header = std.fmt.bufPrint(&auth_buf, "Bearer {s}", .{api_key}) catch return false;

    var client: std.http.Client = .{ .allocator = allocator };
    defer client.deinit();

    var response_writer: std.Io.Writer.Allocating = .init(allocator);
    defer response_writer.deinit();

    const extra_headers = [_]std.http.Header{
        .{ .name = "authorization", .value = auth_header },
    };

    const result = client.fetch(.{
        .location = .{ .url = url },
        .method = .GET,
        .headers = .{
            .user_agent = .{ .override = "VA/2.0" },
            .accept_encoding = .{ .override = "identity" },
        },
        .extra_headers = &extra_headers,
        .response_writer = &response_writer.writer,
    }) catch return false;

    if (@intFromEnum(result.status) != 200) return false;

    const body = response_writer.written();

    // Scan for exact model id match
    var search_pos: usize = 0;
    while (std.mem.indexOf(u8, body[search_pos..], "\"id\"")) |id_pos| {
        const abs_pos = search_pos + id_pos;
        const after_id = body[abs_pos + 4 ..];
        const colon = std.mem.indexOf(u8, after_id, ":") orelse break;
        const after_colon = after_id[colon + 1 ..];
        const q1 = std.mem.indexOf(u8, after_colon, "\"") orelse break;
        const val_start = after_colon[q1 + 1 ..];
        const q2 = std.mem.indexOf(u8, val_start, "\"") orelse break;
        const model_id = val_start[0..q2];

        if (std.mem.eql(u8, model_id, model)) return true;

        search_pos = abs_pos + 4 + colon + 1 + q1 + 1 + q2 + 1;
        if (search_pos >= body.len) break;
    }
    return false;
}

const CallAttemptResult = struct {
    success: bool,
    error_msg: ?[]const u8 = null,
};

/// Try OpenAI Responses API /v1/responses call (used by Codex with wire_api = "responses").
fn tryResponsesCall(allocator: std.mem.Allocator, base_url: []const u8, api_key: []const u8, model: []const u8) CallAttemptResult {
    var url_buf: [1024]u8 = undefined;
    const url = buildUrl(&url_buf, base_url, "/responses") orelse return .{ .success = false, .error_msg = "URL too long" };

    var auth_buf: [256]u8 = undefined;
    const auth_header = std.fmt.bufPrint(&auth_buf, "Bearer {s}", .{api_key}) catch return .{ .success = false, .error_msg = "Auth too long" };

    var body_buf: [512]u8 = undefined;
    const body = std.fmt.bufPrint(&body_buf,
        \\{{"model":"{s}","input":"hi","max_output_tokens":1}}
    , .{model}) catch return .{ .success = false, .error_msg = "Body too long" };

    const extra_headers = [_]std.http.Header{
        .{ .name = "authorization", .value = auth_header },
        .{ .name = "content-type", .value = "application/json" },
    };

    return doPost(allocator, url, &extra_headers, body);
}

/// Try OpenAI-compatible /v1/chat/completions call.
fn tryOpenAICall(allocator: std.mem.Allocator, base_url: []const u8, api_key: []const u8, model: []const u8) CallAttemptResult {
    var url_buf: [1024]u8 = undefined;
    const url = buildUrl(&url_buf, base_url, "/chat/completions") orelse return .{ .success = false, .error_msg = "URL too long" };

    var auth_buf: [256]u8 = undefined;
    const auth_header = std.fmt.bufPrint(&auth_buf, "Bearer {s}", .{api_key}) catch return .{ .success = false, .error_msg = "Auth too long" };

    var body_buf: [512]u8 = undefined;
    const body = std.fmt.bufPrint(&body_buf,
        \\{{"model":"{s}","messages":[{{"role":"user","content":"hi"}}],"max_tokens":1}}
    , .{model}) catch return .{ .success = false, .error_msg = "Body too long" };

    const extra_headers = [_]std.http.Header{
        .{ .name = "authorization", .value = auth_header },
        .{ .name = "content-type", .value = "application/json" },
    };

    return doPost(allocator, url, &extra_headers, body);
}

/// Try Anthropic-compatible /v1/messages call.
fn tryAnthropicCall(allocator: std.mem.Allocator, base_url: []const u8, api_key: []const u8, model: []const u8) CallAttemptResult {
    var url_buf: [1024]u8 = undefined;
    const url = buildUrl(&url_buf, base_url, "/messages") orelse return .{ .success = false, .error_msg = "URL too long" };

    var body_buf: [512]u8 = undefined;
    const body = std.fmt.bufPrint(&body_buf,
        \\{{"model":"{s}","messages":[{{"role":"user","content":"hi"}}],"max_tokens":1}}
    , .{model}) catch return .{ .success = false, .error_msg = "Body too long" };

    // Anthropic uses x-api-key header and anthropic-version header
    var key_buf: [256]u8 = undefined;
    _ = std.fmt.bufPrint(&key_buf, "{s}", .{api_key}) catch return .{ .success = false, .error_msg = "Key too long" };

    const extra_headers = [_]std.http.Header{
        .{ .name = "x-api-key", .value = api_key },
        .{ .name = "anthropic-version", .value = "2023-06-01" },
        .{ .name = "content-type", .value = "application/json" },
    };

    return doPost(allocator, url, &extra_headers, body);
}

fn doPost(allocator: std.mem.Allocator, url: []const u8, extra_headers: []const std.http.Header, body: []const u8) CallAttemptResult {
    var client: std.http.Client = .{ .allocator = allocator };
    defer client.deinit();

    var response_writer: std.Io.Writer.Allocating = .init(allocator);
    defer response_writer.deinit();

    const result = client.fetch(.{
        .location = .{ .url = url },
        .method = .POST,
        .headers = .{
            .user_agent = .{ .override = "VA/2.0" },
            .accept_encoding = .{ .override = "identity" },
        },
        .extra_headers = extra_headers,
        .payload = body,
        .response_writer = &response_writer.writer,
    }) catch return .{ .success = false, .error_msg = "Connection failed" };

    const code = @intFromEnum(result.status);
    if (code == 200) {
        return .{ .success = true };
    }

    // Try to extract error message from response body
    const resp_body = response_writer.written();
    if (resp_body.len > 0) {
        // Look for "message": "..." in error response
        if (extractErrorMessage(resp_body)) |_| {
            // We found an API error message, use the HTTP status for the user
        }
    }

    return .{
        .success = false,
        .error_msg = httpStatusMessage(code),
    };
}

fn httpStatusMessage(code: u10) []const u8 {
    return switch (code) {
        400 => "Bad request (400)",
        401 => "Authentication failed (401)",
        403 => "Access denied (403)",
        404 => "Endpoint/model not found (404)",
        408 => "Request timeout (408)",
        413 => "Request too large (413)",
        422 => "Invalid request format (422)",
        429 => "Rate limited (429)",
        500 => "Internal server error (500)",
        502 => "Bad gateway (502)",
        503 => "Service unavailable (503)",
        504 => "Gateway timeout (504)",
        else => "Request failed",
    };
}

/// Try to extract "message" field from JSON error response.
fn extractErrorMessage(body: []const u8) ?[]const u8 {
    // Look for "message" : "..."
    const key = "\"message\"";
    const pos = std.mem.indexOf(u8, body, key) orelse return null;
    const after = body[pos + key.len ..];
    const colon = std.mem.indexOf(u8, after, ":") orelse return null;
    const after_colon = after[colon + 1 ..];
    const q1 = std.mem.indexOf(u8, after_colon, "\"") orelse return null;
    const val_start = after_colon[q1 + 1 ..];
    const q2 = std.mem.indexOf(u8, val_start, "\"") orelse return null;
    return val_start[0..q2];
}

/// Build a URL by appending a path to base_url, handling /v1 suffix.
fn buildUrl(buf: []u8, base_url: []const u8, path: []const u8) ?[]const u8 {
    if (std.mem.endsWith(u8, base_url, "/v1") or std.mem.endsWith(u8, base_url, "/v1/")) {
        const trimmed = std.mem.trimRight(u8, base_url, "/");
        return std.fmt.bufPrint(buf, "{s}{s}", .{ trimmed, path }) catch null;
    }
    return std.fmt.bufPrint(buf, "{s}/v1{s}", .{ std.mem.trimRight(u8, base_url, "/"), path }) catch null;
}

/// Fetch all model IDs from /v1/models. Returns allocated slice of allocated strings.
/// Caller must free each string and the slice itself.
pub fn fetchModelList(allocator: std.mem.Allocator, base_url: []const u8, api_key: []const u8) ![][]const u8 {
    var url_buf: [1024]u8 = undefined;
    const url = buildUrl(&url_buf, base_url, "/models") orelse return error.InvalidUrl;

    var auth_buf: [256]u8 = undefined;
    const auth_header = std.fmt.bufPrint(&auth_buf, "Bearer {s}", .{api_key}) catch return error.InvalidUrl;

    var client: std.http.Client = .{ .allocator = allocator };
    defer client.deinit();

    var response_writer: std.Io.Writer.Allocating = .init(allocator);
    defer response_writer.deinit();

    const extra_headers = [_]std.http.Header{
        .{ .name = "authorization", .value = auth_header },
    };

    const result = client.fetch(.{
        .location = .{ .url = url },
        .method = .GET,
        .headers = .{
            .user_agent = .{ .override = "VA/2.0" },
            .accept_encoding = .{ .override = "identity" },
        },
        .extra_headers = &extra_headers,
        .response_writer = &response_writer.writer,
    }) catch return error.ConnectionFailed;

    if (@intFromEnum(result.status) != 200) return error.HttpError;

    const body = response_writer.written();

    // Collect all model IDs
    var list: std.ArrayListUnmanaged([]const u8) = .empty;
    errdefer {
        for (list.items) |item| allocator.free(item);
        list.deinit(allocator);
    }

    var search_pos: usize = 0;
    while (std.mem.indexOf(u8, body[search_pos..], "\"id\"")) |id_pos| {
        const abs_pos = search_pos + id_pos;
        const after_id = body[abs_pos + 4 ..];
        const colon = std.mem.indexOf(u8, after_id, ":") orelse break;
        const after_colon = after_id[colon + 1 ..];
        const q1 = std.mem.indexOf(u8, after_colon, "\"") orelse break;
        const val_start = after_colon[q1 + 1 ..];
        const q2 = std.mem.indexOf(u8, val_start, "\"") orelse break;
        const model_id = val_start[0..q2];

        try list.append(allocator, try allocator.dupe(u8, model_id));

        search_pos = abs_pos + 4 + colon + 1 + q1 + 1 + q2 + 1;
        if (search_pos >= body.len) break;
    }

    return list.toOwnedSlice(allocator);
}
