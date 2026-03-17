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
