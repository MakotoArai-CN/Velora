const std = @import("std");
const builtin = @import("builtin");
const sites_mod = @import("sites.zig");
const config_mod = @import("config.zig");
const app = @import("app.zig");

pub const ConnectivityResult = struct {
    reachable: bool,
    latency_ms: ?u64, // null if unreachable
};

pub const ProviderType = enum {
    official, // Official API (api.openai.com, api.anthropic.com, etc.)
    relay, // Relay/proxy with single provider models
    reverse_proxy, // Reverse proxy with mixed provider models (GPT + Claude)
    reverse_eng, // Reverse engineered / unofficial
    unknown, // Cannot determine

    pub fn displayName(self: ProviderType, lang: @import("i18n.zig").Language) []const u8 {
        const i18n = @import("i18n.zig");
        return switch (self) {
            .official => i18n.tr(lang, "Official API", "\xe5\xae\x98\xe6\x96\xb9 API", "\xe5\x85\xac\xe5\xbc\x8f API"),
            .relay => i18n.tr(lang, "Relay", "\xe4\xb8\xad\xe8\xbd\xac\xe7\xab\x99", "\xe4\xb8\xad\xe7\xb6\x99"),
            .reverse_proxy => i18n.tr(lang, "Reverse Proxy", "\xe5\x8f\x8d\xe5\x90\x91\xe4\xbb\xa3\xe7\x90\x86", "\xe3\x83\xaa\xe3\x83\x90\xe3\x83\xbc\xe3\x82\xb9\xe3\x83\x97\xe3\x83\xad\xe3\x82\xad\xe3\x82\xb7"),
            .reverse_eng => i18n.tr(lang, "Reverse Engineered", "\xe9\x80\x86\xe5\x90\x91", "\xe3\x83\xaa\xe3\x83\x90\xe3\x83\xbc\xe3\x82\xb9"),
            .unknown => i18n.tr(lang, "Unknown", "\xe6\x9c\xaa\xe7\x9f\xa5", "\xe4\xb8\x8d\xe6\x98\x8e"),
        };
    }
};

pub const ModelInfo = struct {
    models_found: u32,
    has_expected: bool,
    provider_type: ProviderType,
};

pub const SiteStatus = struct {
    alias: []const u8,
    site: sites_mod.Site,
    conn: ConnectivityResult,
};

/// Check connectivity to a base_url by making an HTTP GET to /v1/models.
/// Has a 10-second timeout to prevent hanging.
pub fn checkConnectivity(allocator: std.mem.Allocator, base_url: []const u8) ConnectivityResult {
    const timeout_ms: i64 = 10000;
    const start = std.time.milliTimestamp();

    const Context = struct {
        allocator: std.mem.Allocator,
        base_url: []u8,
        result: ConnectivityResult = .{ .reachable = false, .latency_ms = null },
        done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
        refs: std.atomic.Value(u32) = std.atomic.Value(u32).init(2),
    };

    const Impl = struct {
        fn release(c: *Context) void {
            if (c.refs.fetchSub(1, .acq_rel) == 1) {
                std.heap.page_allocator.free(c.base_url);
                std.heap.page_allocator.destroy(c);
            }
        }

        fn run(c: *Context) void {
            c.result = checkConnectivityInner(c.allocator, c.base_url);
            c.done.store(true, .release);
            release(c);
        }
    };

    const owned_base_url = std.heap.page_allocator.dupe(u8, base_url) catch {
        return checkConnectivityInner(allocator, base_url);
    };
    errdefer std.heap.page_allocator.free(owned_base_url);

    const ctx = std.heap.page_allocator.create(Context) catch {
        std.heap.page_allocator.free(owned_base_url);
        return checkConnectivityInner(allocator, base_url);
    };
    ctx.* = .{
        .allocator = std.heap.page_allocator,
        .base_url = owned_base_url,
    };

    const thread = std.Thread.spawn(.{}, Impl.run, .{ctx}) catch {
        Impl.release(ctx);
        return checkConnectivityInner(allocator, base_url);
    };

    while (std.time.milliTimestamp() - start < timeout_ms) {
        if (ctx.done.load(.acquire)) {
            thread.join();
            const result = ctx.result;
            Impl.release(ctx);
            return result;
        }
        std.Thread.sleep(50 * std.time.ns_per_ms);
    }

    thread.detach();
    Impl.release(ctx);
    return .{ .reachable = false, .latency_ms = null };
}

fn checkConnectivityInner(allocator: std.mem.Allocator, base_url: []const u8) ConnectivityResult {
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

/// Detect models available at the endpoint. Has a 10-second timeout.
pub fn detectModels(allocator: std.mem.Allocator, base_url: []const u8, api_key: []const u8, site_type: sites_mod.SiteType) ModelInfo {
    const timeout_ms: i64 = 10000;
    const start = std.time.milliTimestamp();

    const Context = struct {
        allocator: std.mem.Allocator,
        base_url: []u8,
        api_key: []u8,
        site_type: sites_mod.SiteType,
        result: ModelInfo = .{ .models_found = 0, .has_expected = false, .provider_type = .unknown },
        done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
        refs: std.atomic.Value(u32) = std.atomic.Value(u32).init(2),
    };

    const Impl = struct {
        fn release(c: *Context) void {
            if (c.refs.fetchSub(1, .acq_rel) == 1) {
                std.heap.page_allocator.free(c.base_url);
                std.heap.page_allocator.free(c.api_key);
                std.heap.page_allocator.destroy(c);
            }
        }

        fn run(c: *Context) void {
            c.result = detectModelsInner(c.allocator, c.base_url, c.api_key, c.site_type);
            c.done.store(true, .release);
            release(c);
        }
    };

    const owned_url = std.heap.page_allocator.dupe(u8, base_url) catch {
        return detectModelsInner(allocator, base_url, api_key, site_type);
    };
    const owned_key = std.heap.page_allocator.dupe(u8, api_key) catch {
        std.heap.page_allocator.free(owned_url);
        return detectModelsInner(allocator, base_url, api_key, site_type);
    };

    const ctx = std.heap.page_allocator.create(Context) catch {
        std.heap.page_allocator.free(owned_url);
        std.heap.page_allocator.free(owned_key);
        return detectModelsInner(allocator, base_url, api_key, site_type);
    };
    ctx.* = .{
        .allocator = std.heap.page_allocator,
        .base_url = owned_url,
        .api_key = owned_key,
        .site_type = site_type,
    };

    const thread = std.Thread.spawn(.{}, Impl.run, .{ctx}) catch {
        Impl.release(ctx);
        return detectModelsInner(allocator, base_url, api_key, site_type);
    };

    while (std.time.milliTimestamp() - start < timeout_ms) {
        if (ctx.done.load(.acquire)) {
            thread.join();
            const result = ctx.result;
            Impl.release(ctx);
            return result;
        }
        std.Thread.sleep(50 * std.time.ns_per_ms);
    }

    thread.detach();
    Impl.release(ctx);
    return .{ .models_found = 0, .has_expected = false, .provider_type = .unknown };
}

fn detectModelsInner(allocator: std.mem.Allocator, base_url: []const u8, api_key: []const u8, site_type: sites_mod.SiteType) ModelInfo {
    // Step 1: Check domain for official/reverse-engineered indicators
    const domain_type = classifyDomain(base_url);

    var url_buf: [1024]u8 = undefined;
    const url = blk: {
        if (std.mem.endsWith(u8, base_url, "/v1") or std.mem.endsWith(u8, base_url, "/v1/")) {
            const trimmed = std.mem.trimRight(u8, base_url, "/");
            break :blk std.fmt.bufPrint(&url_buf, "{s}/models", .{trimmed}) catch return .{ .models_found = 0, .has_expected = false, .provider_type = .unknown };
        }
        break :blk std.fmt.bufPrint(&url_buf, "{s}/v1/models", .{std.mem.trimRight(u8, base_url, "/")}) catch return .{ .models_found = 0, .has_expected = false, .provider_type = .unknown };
    };

    var auth_buf: [256]u8 = undefined;
    const auth_header = std.fmt.bufPrint(&auth_buf, "Bearer {s}", .{api_key}) catch return .{ .models_found = 0, .has_expected = false, .provider_type = .unknown };

    var client: std.http.Client = .{ .allocator = allocator };
    defer client.deinit();

    var response_writer: std.Io.Writer.Allocating = .init(allocator);
    defer response_writer.deinit();

    const extra_headers = [_]std.http.Header{
        .{ .name = "authorization", .value = auth_header },
        .{ .name = "x-api-key", .value = api_key },
        .{ .name = "anthropic-version", .value = "2023-06-01" },
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
    }) catch return .{ .models_found = 0, .has_expected = false, .provider_type = .unknown };

    if (@intFromEnum(result.status) != 200) {
        return .{ .models_found = 0, .has_expected = false, .provider_type = .unknown };
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
            .oc, .nb, .ow => {
                // OpenCode/Nanobot/OpenClaw support both openai and anthropic providers
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
        .provider_type = classifyProvider(domain_type, has_gpt, has_claude, model_count),
    };
}

/// Classify provider type based on domain detection and model list analysis.
fn classifyProvider(domain_type: ProviderType, has_gpt: bool, has_claude: bool, model_count: u32) ProviderType {
    // Domain-based detection takes priority for official/reverse_eng
    if (domain_type == .official) return .official;
    if (domain_type == .reverse_eng) return .reverse_eng;

    // Model-list-based detection
    if (model_count == 0) return .unknown;
    if (has_gpt and has_claude) return .reverse_proxy;
    if (has_gpt or has_claude) return .relay;
    return .unknown;
}

/// Classify domain from URL to detect official APIs and known reverse-engineered services.
fn classifyDomain(base_url: []const u8) ProviderType {
    // Extract host from URL
    const host = extractHost(base_url);

    // Official API domains
    const official_domains = [_][]const u8{
        "api.openai.com",
        "api.anthropic.com",
        "generativelanguage.googleapis.com",
        "api.mistral.ai",
        "api.cohere.ai",
        "api.groq.com",
        "api.deepseek.com",
        "api.together.xyz",
        "openrouter.ai",
        "api.fireworks.ai",
    };
    for (official_domains) |domain| {
        if (std.mem.eql(u8, host, domain)) return .official;
    }

    // Known reverse-engineered patterns in domain
    const reverse_eng_patterns = [_][]const u8{
        "free",
        "reverse",
        "nai",
        "fuclaude",
        "freeapi",
        "chatanywhere",
    };
    for (reverse_eng_patterns) |pattern| {
        if (std.mem.indexOf(u8, host, pattern) != null) return .reverse_eng;
    }

    return .unknown;
}

/// Extract hostname from a URL string.
fn extractHost(url: []const u8) []const u8 {
    // Skip scheme (https:// or http://)
    var start: usize = 0;
    if (std.mem.indexOf(u8, url, "://")) |pos| {
        start = pos + 3;
    }
    // Find end of host (port, path, or end of string)
    var end = start;
    while (end < url.len and url[end] != '/' and url[end] != ':' and url[end] != '?') {
        end += 1;
    }
    return url[start..end];
}

pub const ModelCallResult = struct {
    success: bool,
    error_msg: ?[]const u8 = null, // points into static string
    latency_ms: ?u64 = null,
    model_in_list: bool = false, // whether the model was found in /v1/models
};

/// Comprehensive model availability check with timeout:
/// 1. Check if the model exists in the /v1/models list
/// 2. Try calling the model with the appropriate API format (OpenAI or Anthropic)
/// 3. Also try alternative endpoint if the primary one fails (reverse proxy support)
/// Uses a background thread with polling to avoid hanging indefinitely.
pub fn testModelCall(allocator: std.mem.Allocator, base_url: []const u8, api_key: []const u8, model: []const u8, site_type: sites_mod.SiteType) ModelCallResult {
    const timeout_ms: i64 = 15000; // 15 second total timeout
    const start = std.time.milliTimestamp();
    const check_model = normalizeModelForApiCheck(model);
    const model_in_list = checkModelInList(allocator, base_url, api_key, check_model);

    // Run in a thread so we can enforce a timeout.
    // Heap-allocate context so detached threads never touch a dead stack frame.
    const Context = struct {
        allocator: std.mem.Allocator,
        base_url: []u8,
        api_key: []u8,
        model: []u8,
        site_type: sites_mod.SiteType,
        result: ModelCallResult,
        done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
        refs: std.atomic.Value(u32) = std.atomic.Value(u32).init(2),
    };

    const Impl = struct {
        fn release(c: *Context) void {
            if (c.refs.fetchSub(1, .acq_rel) == 1) {
                std.heap.page_allocator.free(c.base_url);
                std.heap.page_allocator.free(c.api_key);
                std.heap.page_allocator.free(c.model);
                std.heap.page_allocator.destroy(c);
            }
        }

        fn run(c: *Context) void {
            c.result = testModelCallAttempts(c.allocator, c.base_url, c.api_key, c.model, c.site_type, c.result.model_in_list);
            c.done.store(true, .release);
            release(c);
        }
    };

    const owned_url = std.heap.page_allocator.dupe(u8, base_url) catch {
        return testModelCallAttempts(allocator, base_url, api_key, model, site_type, model_in_list);
    };
    const owned_key = std.heap.page_allocator.dupe(u8, api_key) catch {
        std.heap.page_allocator.free(owned_url);
        return testModelCallAttempts(allocator, base_url, api_key, model, site_type, model_in_list);
    };
    const owned_model = std.heap.page_allocator.dupe(u8, model) catch {
        std.heap.page_allocator.free(owned_url);
        std.heap.page_allocator.free(owned_key);
        return testModelCallAttempts(allocator, base_url, api_key, model, site_type, model_in_list);
    };

    const ctx = std.heap.page_allocator.create(Context) catch {
        std.heap.page_allocator.free(owned_url);
        std.heap.page_allocator.free(owned_key);
        std.heap.page_allocator.free(owned_model);
        return testModelCallAttempts(allocator, base_url, api_key, model, site_type, model_in_list);
    };
    ctx.* = .{
        .allocator = std.heap.page_allocator,
        .base_url = owned_url,
        .api_key = owned_key,
        .model = owned_model,
        .site_type = site_type,
        .result = .{ .success = false, .error_msg = "Timeout", .model_in_list = model_in_list },
    };

    const thread = std.Thread.spawn(.{}, Impl.run, .{ctx}) catch {
        Impl.release(ctx);
        return testModelCallAttempts(allocator, base_url, api_key, model, site_type, model_in_list);
    };

    // Poll until done or timeout
    while (std.time.milliTimestamp() - start < timeout_ms) {
        if (ctx.done.load(.acquire)) {
            thread.join();
            const result = ctx.result;
            Impl.release(ctx);
            return result;
        }
        std.Thread.sleep(50 * std.time.ns_per_ms);
    }

    // Timeout reached - detach thread and return timeout result
    thread.detach();
    Impl.release(ctx);
    const elapsed = @as(u64, @intCast(std.time.milliTimestamp() - start));
    return .{
        .success = false,
        .error_msg = "Request timeout (15s)",
        .latency_ms = elapsed,
        .model_in_list = model_in_list,
    };
}

/// Inner implementation without timeout (runs in thread).
fn testModelCallAttempts(allocator: std.mem.Allocator, base_url: []const u8, api_key: []const u8, model: []const u8, site_type: sites_mod.SiteType, model_in_list: bool) ModelCallResult {
    const start = std.time.milliTimestamp();
    const call_model = normalizeModelForApiCheck(model);
    const attempts = callAttemptOrder(site_type, call_model);

    var first_error: ?[]const u8 = null;
    for (attempts) |attempt_fn| {
        const r = runAttemptWithTimeout(attempt_fn, allocator, base_url, api_key, call_model, 4500);
        if (r.success) {
            const elapsed = @as(u64, @intCast(std.time.milliTimestamp() - start));
            return .{ .success = true, .latency_ms = elapsed, .model_in_list = model_in_list };
        }
        if (first_error == null) first_error = r.error_msg;
    }

    if (!std.mem.eql(u8, call_model, model)) {
        const original_attempts = callAttemptOrder(site_type, model);
        for (original_attempts) |attempt_fn| {
            const r = runAttemptWithTimeout(attempt_fn, allocator, base_url, api_key, model, 3000);
            if (r.success) {
                const elapsed = @as(u64, @intCast(std.time.milliTimestamp() - start));
                return .{ .success = true, .latency_ms = elapsed, .model_in_list = model_in_list };
            }
            if (first_error == null) first_error = r.error_msg;
        }
    }

    const elapsed = @as(u64, @intCast(std.time.milliTimestamp() - start));
    return .{
        .success = false,
        .error_msg = first_error,
        .latency_ms = elapsed,
        .model_in_list = model_in_list,
    };
}

const AttemptFn = *const fn (std.mem.Allocator, []const u8, []const u8, []const u8) CallAttemptResult;

fn callAttemptOrder(site_type: sites_mod.SiteType, model: []const u8) [3]AttemptFn {
    return switch (classifyModelFamily(model)) {
        .openai => switch (site_type) {
            .cx => .{ &tryResponsesCall, &tryOpenAICall, &tryAnthropicCall },
            .cc, .oc, .nb, .ow => .{ &tryOpenAICall, &tryResponsesCall, &tryAnthropicCall },
        },
        .claude => .{ &tryAnthropicCall, &tryOpenAICall, &tryResponsesCall },
        .unknown => switch (site_type) {
            .cx => .{ &tryResponsesCall, &tryOpenAICall, &tryAnthropicCall },
            .cc => .{ &tryAnthropicCall, &tryOpenAICall, &tryResponsesCall },
            .oc, .nb, .ow => .{ &tryOpenAICall, &tryResponsesCall, &tryAnthropicCall },
        },
    };
}

fn runAttemptWithTimeout(attempt_fn: AttemptFn, allocator: std.mem.Allocator, base_url: []const u8, api_key: []const u8, model: []const u8, timeout_ms: i64) CallAttemptResult {
    _ = allocator;
    const start = std.time.milliTimestamp();

    const Context = struct {
        attempt_fn: AttemptFn,
        allocator: std.mem.Allocator,
        base_url: []const u8,
        api_key: []const u8,
        model: []const u8,
        result: CallAttemptResult = .{ .success = false, .error_msg = "Request timeout" },
        done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
        refs: std.atomic.Value(u32) = std.atomic.Value(u32).init(2),
    };

    const Impl = struct {
        fn release(c: *Context) void {
            if (c.refs.fetchSub(1, .acq_rel) == 1) {
                std.heap.page_allocator.destroy(c);
            }
        }

        fn run(c: *Context) void {
            c.result = c.attempt_fn(c.allocator, c.base_url, c.api_key, c.model);
            c.done.store(true, .release);
            release(c);
        }
    };

    const ctx = std.heap.page_allocator.create(Context) catch {
        return attempt_fn(std.heap.page_allocator, base_url, api_key, model);
    };
    ctx.* = .{
        .attempt_fn = attempt_fn,
        .allocator = std.heap.page_allocator,
        .base_url = base_url,
        .api_key = api_key,
        .model = model,
    };

    const thread = std.Thread.spawn(.{}, Impl.run, .{ctx}) catch {
        Impl.release(ctx);
        return attempt_fn(std.heap.page_allocator, base_url, api_key, model);
    };

    while (std.time.milliTimestamp() - start < timeout_ms) {
        if (ctx.done.load(.acquire)) {
            thread.join();
            const result = ctx.result;
            Impl.release(ctx);
            return result;
        }
        std.Thread.sleep(50 * std.time.ns_per_ms);
    }

    thread.detach();
    Impl.release(ctx);
    return .{ .success = false, .error_msg = "Request timeout" };
}

fn normalizeModelForApiCheck(model: []const u8) []const u8 {
    if (std.mem.lastIndexOfScalar(u8, model, '[')) |open| {
        if (open > 0 and model[model.len - 1] == ']') {
            return model[0..open];
        }
    }
    return model;
}

/// Check if a specific model exists in the /v1/models endpoint.
fn checkModelInList(allocator: std.mem.Allocator, base_url: []const u8, api_key: []const u8, model: []const u8) bool {
    const check_model = normalizeModelForApiCheck(model);
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
        .{ .name = "x-api-key", .value = api_key },
        .{ .name = "anthropic-version", .value = "2023-06-01" },
    };

    const result = client.fetch(.{
        .location = .{ .url = url },
        .method = .GET,
        .keep_alive = false,
        .headers = defaultFetchHeaders(),
        .extra_headers = &extra_headers,
        .response_writer = &response_writer.writer,
    }) catch return false;

    if (@intFromEnum(result.status) != 200) return false;

    const body = response_writer.written();

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

        if (std.mem.eql(u8, model_id, check_model)) return true;

        search_pos = abs_pos + 4 + colon + 1 + q1 + 1 + q2 + 1;
        if (search_pos >= body.len) break;
    }
    return false;
}

fn defaultFetchHeaders() std.http.Client.Request.Headers {
    return .{
        .user_agent = .{ .override = "VA/2.0" },
        .accept_encoding = .{ .override = "identity" },
        .connection = .{ .override = "close" },
    };
}

fn normalizeTimeoutError(msg: ?[]const u8) ?[]const u8 {
    if (msg) |m| {
        if (std.mem.eql(u8, m, "Request timeout")) return "Request timeout";
        return m;
    }
    return null;
}

fn normalizeAttemptError(r: CallAttemptResult) CallAttemptResult {
    return .{ .success = r.success, .error_msg = normalizeTimeoutError(r.error_msg) };
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
        .{ .name = "connection", .value = "close" },
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
        .{ .name = "connection", .value = "close" },
    };

    return doPost(allocator, url, &extra_headers, body);
}

/// Try Anthropic-compatible /v1/messages call.
fn tryAnthropicCall(allocator: std.mem.Allocator, base_url: []const u8, api_key: []const u8, model: []const u8) CallAttemptResult {
    // Try with /v1 prefix first (standard Anthropic API and most proxies)
    var url_buf: [1024]u8 = undefined;
    const url = buildUrl(&url_buf, base_url, "/messages") orelse return .{ .success = false, .error_msg = "URL too long" };

    const result = doAnthropicPost(allocator, url, api_key, model);
    if (result.success) return result;

    // If that failed, also try without /v1 prefix for proxies that don't use /v1 path
    // e.g. base_url = "https://proxy.example.com" -> try /messages directly
    if (!std.mem.endsWith(u8, base_url, "/v1") and !std.mem.endsWith(u8, base_url, "/v1/")) {
        var url_buf2: [1024]u8 = undefined;
        const trimmed = std.mem.trimRight(u8, base_url, "/");
        const url2 = std.fmt.bufPrint(&url_buf2, "{s}/messages", .{trimmed}) catch return result;
        const result2 = doAnthropicPost(allocator, url2, api_key, model);
        if (result2.success) return result2;
    }

    return result;
}

fn doAnthropicPost(allocator: std.mem.Allocator, url: []const u8, api_key: []const u8, model: []const u8) CallAttemptResult {
    var body_buf: [512]u8 = undefined;
    const body = std.fmt.bufPrint(&body_buf,
        \\{{"model":"{s}","messages":[{{"role":"user","content":"hi"}}],"max_tokens":1}}
    , .{model}) catch return .{ .success = false, .error_msg = "Body too long" };

    // Anthropic accepts both x-api-key and Authorization: Bearer
    var auth_buf: [256]u8 = undefined;
    const bearer = std.fmt.bufPrint(&auth_buf, "Bearer {s}", .{api_key}) catch return .{ .success = false, .error_msg = "Auth too long" };

    const extra_headers = [_]std.http.Header{
        .{ .name = "x-api-key", .value = api_key },
        .{ .name = "authorization", .value = bearer },
        .{ .name = "anthropic-version", .value = "2023-06-01" },
        .{ .name = "content-type", .value = "application/json" },
        .{ .name = "connection", .value = "close" },
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
        .keep_alive = false,
        .headers = defaultFetchHeaders(),
        .extra_headers = extra_headers,
        .payload = body,
        .response_writer = &response_writer.writer,
    }) catch return .{ .success = false, .error_msg = "Connection failed" };

    const code = @intFromEnum(result.status);
    // 200 = success, 201 = created (some proxies)
    // 400 with specific error means the API is reachable and model is valid
    // (e.g. content policy, billing errors still mean the model exists)
    if (code == 200 or code == 201) {
        return .{ .success = true };
    }

    // Try to extract error message from response body
    const resp_body = response_writer.written();

    // Some errors indicate the model IS callable but blocked by policy/billing
    // 400: bad request could mean model exists but request format issue
    // 429: rate limited means model exists
    // 402/payment required: model exists but needs payment
    if (code == 429) {
        return .{ .success = true }; // rate limited = model works
    }

    if (resp_body.len > 0) {
        if (std.mem.indexOf(u8, resp_body, "error code: 1010") != null or
            std.mem.indexOf(u8, resp_body, "error code: 1020") != null)
        {
            return .{ .success = false, .error_msg = httpStatusMessage(code) };
        }
        if (extractErrorMessage(resp_body)) |msg| {
            // These error messages indicate model is accessible
            if (std.mem.indexOf(u8, msg, "rate") != null or
                std.mem.indexOf(u8, msg, "limit") != null or
                std.mem.indexOf(u8, msg, "quota") != null or
                std.mem.indexOf(u8, msg, "billing") != null or
                std.mem.indexOf(u8, msg, "credit") != null or
                std.mem.indexOf(u8, msg, "balance") != null or
                std.mem.indexOf(u8, msg, "overloaded") != null)
            {
                return .{ .success = true };
            }
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
        .{ .name = "x-api-key", .value = api_key },
        .{ .name = "anthropic-version", .value = "2023-06-01" },
    };

    const result = client.fetch(.{
        .location = .{ .url = url },
        .method = .GET,
        .keep_alive = false,
        .headers = defaultFetchHeaders(),
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


pub const ModelFamily = enum {
    openai,
    claude,
    unknown,
};

pub const ProbeSupport = struct {
    tool_type: sites_mod.SiteType,
    supported: bool,
    recommended_model: ?[]const u8 = null,
    call_ok: bool = false,
};

pub const AddProbeResult = struct {
    normalized_base_url: []const u8,
    provider_type: ProviderType,
    model_count: u32,
    supports_gpt: bool,
    supports_claude: bool,
    recommended_cx: ?[]const u8 = null,
    recommended_cc: ?[]const u8 = null,
    recommended_oc: ?[]const u8 = null,
    recommended_nb: ?[]const u8 = null,
    recommended_ow: ?[]const u8 = null,
};

pub fn normalizeBaseUrlForProbe(allocator: std.mem.Allocator, base_url: []const u8) ![]u8 {
    const trimmed = std.mem.trimRight(u8, base_url, "/");
    if (trimmed.len == 0) return allocator.dupe(u8, base_url);
    if (std.mem.endsWith(u8, trimmed, "/v1") or
        std.mem.endsWith(u8, trimmed, "/v1/messages") or
        std.mem.endsWith(u8, trimmed, "/v1/models") or
        std.mem.endsWith(u8, trimmed, "/v1/chat/completions") or
        std.mem.endsWith(u8, trimmed, "/v1/responses"))
    {
        return allocator.dupe(u8, trimmed);
    }
    if (std.mem.indexOf(u8, trimmed, "/v") != null) {
        if (std.mem.lastIndexOfScalar(u8, trimmed, '/')) |slash| {
            const tail = trimmed[slash..];
            if (std.mem.startsWith(u8, tail, "/v") and tail.len >= 3 and std.ascii.isDigit(tail[2])) {
                return allocator.dupe(u8, trimmed);
            }
        }
    }
    var buf: [1024]u8 = undefined;
    const normalized = std.fmt.bufPrint(&buf, "{s}/v1", .{trimmed}) catch return allocator.dupe(u8, trimmed);
    return allocator.dupe(u8, normalized);
}

pub fn probeAddEndpoint(allocator: std.mem.Allocator, base_url: []const u8, api_key: []const u8) !AddProbeResult {
    const normalized = try normalizeBaseUrlForProbe(allocator, base_url);
    errdefer allocator.free(normalized);

    const models = fetchModelList(allocator, normalized, api_key) catch try allocator.alloc([]const u8, 0);
    defer {
        for (models) |m| allocator.free(m);
        allocator.free(models);
    }

    var supports_gpt = false;
    var supports_claude = false;
    for (models) |m| {
        switch (classifyModelFamily(m)) {
            .openai => supports_gpt = true,
            .claude => supports_claude = true,
            .unknown => {},
        }
    }

    const cx_model = pickBestCompatibleModel(models, .cx);
    const cc_model = blk: {
        if (modelExistsInList(models, "claude-opus-4-6")) break :blk "claude-opus-4-6";
        break :blk pickBestCompatibleModel(models, .cc);
    };
    const oc_model = pickBestCompatibleModel(models, .oc);
    const nb_model = pickBestCompatibleModel(models, .nb);
    const ow_model = pickBestCompatibleModel(models, .ow);

    return .{
        .normalized_base_url = normalized,
        .provider_type = classifyProvider(classifyDomain(normalized), supports_gpt, supports_claude, @intCast(models.len)),
        .model_count = @intCast(models.len),
        .supports_gpt = supports_gpt,
        .supports_claude = supports_claude,
        .recommended_cx = if (cx_model) |m| try allocator.dupe(u8, m) else null,
        .recommended_cc = if (cc_model) |m| try allocator.dupe(u8, m) else null,
        .recommended_oc = if (oc_model) |m| try allocator.dupe(u8, m) else null,
        .recommended_nb = if (nb_model) |m| try allocator.dupe(u8, m) else null,
        .recommended_ow = if (ow_model) |m| try allocator.dupe(u8, m) else null,
    };
}

pub fn freeAddProbeResult(allocator: std.mem.Allocator, result: *AddProbeResult) void {
    allocator.free(result.normalized_base_url);
    if (result.recommended_cx) |m| allocator.free(m);
    if (result.recommended_cc) |m| allocator.free(m);
    if (result.recommended_oc) |m| allocator.free(m);
    if (result.recommended_nb) |m| allocator.free(m);
    if (result.recommended_ow) |m| allocator.free(m);
}

pub fn recommendedModelForProbe(result: AddProbeResult, tool_type: sites_mod.SiteType) ?[]const u8 {
    return switch (tool_type) {
        .cx => result.recommended_cx,
        .cc => result.recommended_cc,
        .oc => result.recommended_oc,
        .nb => result.recommended_nb,
        .ow => result.recommended_ow,
    };
}

pub fn probeSupportsTool(result: AddProbeResult, tool_type: sites_mod.SiteType) bool {
    return recommendedModelForProbe(result, tool_type) != null;
}

pub fn testRecommendedModelCall(allocator: std.mem.Allocator, result: AddProbeResult, api_key: []const u8, tool_type: sites_mod.SiteType) bool {
    const model = recommendedModelForProbe(result, tool_type) orelse return false;
    const call = testModelCall(allocator, result.normalized_base_url, api_key, model, tool_type);
    return call.success;
}

pub fn makeProbeSupport(allocator: std.mem.Allocator, result: AddProbeResult, api_key: []const u8, tool_type: sites_mod.SiteType) ProbeSupport {
    const recommended = recommendedModelForProbe(result, tool_type);
    return .{
        .tool_type = tool_type,
        .supported = recommended != null,
        .recommended_model = recommended,
        .call_ok = if (recommended != null) testRecommendedModelCall(allocator, result, api_key, tool_type) else false,
    };
}

pub fn inferDefaultToolsFromProbe(result: AddProbeResult, buf: *[5]sites_mod.SiteType) []const sites_mod.SiteType {
    var count: usize = 0;
    inline for ([_]sites_mod.SiteType{ .cx, .cc, .oc, .nb, .ow }) |tool| {
        if (probeSupportsTool(result, tool)) {
            buf[count] = tool;
            count += 1;
        }
    }
    return buf[0..count];
}

pub fn recommendedPrimaryType(result: AddProbeResult) sites_mod.SiteType {
    if (result.recommended_cc != null) return .cc;
    if (result.recommended_cx != null) return .cx;
    if (result.recommended_oc != null) return .oc;
    if (result.recommended_nb != null) return .nb;
    if (result.recommended_ow != null) return .ow;
    return .cx;
}

pub fn normalizeBaseUrlDisplayChanged(original: []const u8, normalized: []const u8) bool {
    return !std.mem.eql(u8, std.mem.trimRight(u8, original, "/"), normalized);
}

pub fn defaultProbeModel(tool_type: sites_mod.SiteType) []const u8 {
    return sites_mod.defaultModelForType(tool_type);
}

pub fn probeSummaryHasSupport(result: AddProbeResult) bool {
    return result.recommended_cx != null or result.recommended_cc != null or result.recommended_oc != null or result.recommended_nb != null or result.recommended_ow != null;
}

pub fn probeModelCount(result: AddProbeResult) u32 {
    return result.model_count;
}

pub fn probeProviderType(result: AddProbeResult) ProviderType {
    return result.provider_type;
}

pub fn probeSupportsClaude(result: AddProbeResult) bool {
    return result.supports_claude;
}

pub fn probeSupportsGpt(result: AddProbeResult) bool {
    return result.supports_gpt;
}

pub fn probeRecommendedTools(result: AddProbeResult, buf: *[5]sites_mod.SiteType) []const sites_mod.SiteType {
    return inferDefaultToolsFromProbe(result, buf);
}

pub fn probeSuggestedSiteType(result: AddProbeResult) sites_mod.SiteType {
    return recommendedPrimaryType(result);
}

pub fn probeNormalizedBaseUrl(result: AddProbeResult) []const u8 {
    return result.normalized_base_url;
}

pub fn probeRecommendedModel(result: AddProbeResult, tool_type: sites_mod.SiteType) ?[]const u8 {
    return recommendedModelForProbe(result, tool_type);
}

pub fn probeHasTool(result: AddProbeResult, tool_type: sites_mod.SiteType) bool {
    return probeSupportsTool(result, tool_type);
}

pub fn probeToolSupport(allocator: std.mem.Allocator, result: AddProbeResult, api_key: []const u8, tool_type: sites_mod.SiteType) ProbeSupport {
    return makeProbeSupport(allocator, result, api_key, tool_type);
}

pub fn probeDefaultTools(result: AddProbeResult, buf: *[5]sites_mod.SiteType) []const sites_mod.SiteType {
    return inferDefaultToolsFromProbe(result, buf);
}

pub fn probePrimaryType(result: AddProbeResult) sites_mod.SiteType {
    return recommendedPrimaryType(result);
}

pub fn normalizedAddBaseUrl(allocator: std.mem.Allocator, base_url: []const u8) ![]u8 {
    return normalizeBaseUrlForProbe(allocator, base_url);
}

pub fn classifyModelFamily(model: []const u8) ModelFamily {
    const normalized = normalizeModelForApiCheck(model);
    if (std.mem.startsWith(u8, normalized, "claude-")) return .claude;
    if (std.mem.startsWith(u8, normalized, "gpt") or
        std.mem.startsWith(u8, normalized, "o1") or
        std.mem.startsWith(u8, normalized, "o3") or
        std.mem.startsWith(u8, normalized, "o4"))
    {
        return .openai;
    }
    return .unknown;
}

pub fn isModelCompatibleForTool(target_type: sites_mod.SiteType, model: []const u8) bool {
    return supportsModelFamily(target_type, classifyModelFamily(model));
}

pub fn modelExistsInList(models: []const []const u8, model: []const u8) bool {
    const normalized = normalizeModelForApiCheck(model);
    for (models) |candidate| {
        if (std.mem.eql(u8, normalizeModelForApiCheck(candidate), normalized)) return true;
    }
    return false;
}

pub fn pickBestCompatibleModel(models: []const []const u8, target_type: sites_mod.SiteType) ?[]const u8 {
    var best: ?[]const u8 = null;
    var best_score: i64 = std.math.minInt(i64);

    for (models) |candidate| {
        if (!isModelCompatibleForTool(target_type, candidate)) continue;
        const score = modelRank(target_type, candidate);
        if (score > best_score) {
            best_score = score;
            best = candidate;
        }
    }

    return best;
}

fn supportsModelFamily(target_type: sites_mod.SiteType, family: ModelFamily) bool {
    return switch (target_type) {
        .cx, .nb, .ow => family == .openai,
        .cc => family == .claude,
        .oc => family == .openai or family == .claude,
    };
}

fn modelRank(target_type: sites_mod.SiteType, model: []const u8) i64 {
    const normalized = normalizeModelForApiCheck(model);
    const family = classifyModelFamily(normalized);
    if (!supportsModelFamily(target_type, family)) return std.math.minInt(i64);

    var score: i64 = modelVersionScore(normalized);

    switch (family) {
        .openai => {
            if (std.mem.indexOf(u8, normalized, "mini") == null) score += 1_000_000;
            if (std.mem.indexOf(u8, normalized, "codex") == null) score += 500_000;
        },
        .claude => {
            if (target_type == .cc) {
                if (std.mem.startsWith(u8, normalized, "claude-opus")) score += 30_000_000;
                if (std.mem.startsWith(u8, normalized, "claude-sonnet")) score += 20_000_000;
                if (std.mem.startsWith(u8, normalized, "claude-haiku")) score += 10_000_000;
            } else {
                if (std.mem.startsWith(u8, normalized, "claude-opus")) score += 3_000_000;
                if (std.mem.startsWith(u8, normalized, "claude-sonnet")) score += 2_000_000;
                if (std.mem.startsWith(u8, normalized, "claude-haiku")) score += 1_000_000;
            }
        },
        .unknown => {},
    }

    return score;
}

fn modelVersionScore(model: []const u8) i64 {
    var score: i64 = 0;
    var factor: i64 = 1_000_000;
    var i: usize = 0;

    while (i < model.len and factor > 0) {
        if (!std.ascii.isDigit(model[i])) {
            i += 1;
            continue;
        }

        var value: i64 = 0;
        while (i < model.len and std.ascii.isDigit(model[i])) : (i += 1) {
            value = value * 10 + @as(i64, model[i] - '0');
        }

        score += value * factor;
        factor = @divTrunc(factor, 100);
    }

    return score;
}

test "model family classification" {
    try std.testing.expectEqual(ModelFamily.openai, classifyModelFamily("gpt-5.4"));
    try std.testing.expectEqual(ModelFamily.openai, classifyModelFamily("o3"));
    try std.testing.expectEqual(ModelFamily.claude, classifyModelFamily("claude-opus-4-6[1m]"));
    try std.testing.expectEqual(ModelFamily.unknown, classifyModelFamily("gemini-2.5-pro"));
}

test "pick best compatible model" {
    const cc_best = pickBestCompatibleModel(&.{ "claude-haiku-4-5-20251001", "claude-opus-4-6", "gpt-5.4" }, .cc);
    try std.testing.expect(cc_best != null);
    try std.testing.expectEqualStrings("claude-opus-4-6", cc_best.?);

    const nb_best = pickBestCompatibleModel(&.{ "gpt-5.4-mini", "gpt-5.4", "claude-sonnet-4-6" }, .nb);
    try std.testing.expect(nb_best != null);
    try std.testing.expectEqualStrings("gpt-5.4", nb_best.?);
}

/// Check if a CLI tool is available.
/// PATH executable OR existing config file counts as installed/available.
pub fn isToolInstalled(tool_type: sites_mod.SiteType) bool {
    const names: []const []const u8 = switch (tool_type) {
        .cx => &.{ "codex", "cx" },
        .cc => &.{ "claude" },
        .oc => &.{ "opencode" },
        .nb => &.{ "nanobot" },
        .ow => &.{ "openclaw" },
    };
    for (names) |name| {
        if (findExecutableInPath(name)) return true;
    }
    return hasToolConfigFile(tool_type);
}

fn findExecutableInPath(exe_name: []const u8) bool {
    const path_sep: u8 = if (builtin.os.tag == .windows) ';' else ':';
    const path_env = std.process.getEnvVarOwned(std.heap.page_allocator, "PATH") catch return false;
    defer std.heap.page_allocator.free(path_env);

    var iter = std.mem.splitScalar(u8, path_env, path_sep);
    while (iter.next()) |dir| {
        if (dir.len == 0) continue;
        var full_buf: [1024]u8 = undefined;

        if (builtin.os.tag == .windows) {
            // Check .exe and .cmd suffixes on Windows
            const suffixes = [_][]const u8{ ".exe", ".cmd", "" };
            for (suffixes) |suffix| {
                const full = std.fmt.bufPrint(&full_buf, "{s}\\{s}{s}", .{ dir, exe_name, suffix }) catch continue;
                std.fs.accessAbsolute(full, .{}) catch continue;
                return true;
            }
        } else {
            const full = std.fmt.bufPrint(&full_buf, "{s}/{s}", .{ dir, exe_name }) catch continue;
            std.fs.accessAbsolute(full, .{}) catch continue;
            return true;
        }
    }
    return false;
}

fn hasToolConfigFile(tool_type: sites_mod.SiteType) bool {
    const home = config_mod.getHomeDir(std.heap.page_allocator) orelse return false;
    defer std.heap.page_allocator.free(home);

    const path = switch (tool_type) {
        .cx => std.fs.path.join(std.heap.page_allocator, &.{ home, app.codex_config_dir, app.codex_config_filename }) catch return false,
        .cc => std.fs.path.join(std.heap.page_allocator, &.{ home, app.claude_config_dir, app.claude_settings_filename }) catch return false,
        .oc => std.fs.path.join(std.heap.page_allocator, &.{ home, app.opencode_config_dir_parts[0], app.opencode_config_dir_parts[1], app.opencode_config_filename }) catch return false,
        .nb => std.fs.path.join(std.heap.page_allocator, &.{ home, app.nanobot_config_dir, app.nanobot_config_filename }) catch return false,
        .ow => std.fs.path.join(std.heap.page_allocator, &.{ home, app.openclaw_config_dir, app.openclaw_config_filename }) catch return false,
    };
    defer std.heap.page_allocator.free(path);

    std.fs.accessAbsolute(path, .{}) catch return false;
    return true;
}
