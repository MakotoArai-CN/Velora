const std = @import("std");

const api_host = "www.fuckopenai.net";
const api_path = "/api/v1/apikey";
const api_url = "https://" ++ api_host ++ api_path;
const browser_user_agent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/145.0.0.0 Safari/537.36";

const browser_headers = [_]std.http.Header{
    .{ .name = "accept", .value = "application/json, text/plain, */*" },
    .{ .name = "accept-language", .value = "zh-CN,zh;q=0.9,en;q=0.8" },
    .{ .name = "cache-control", .value = "no-cache" },
    .{ .name = "pragma", .value = "no-cache" },
    .{ .name = "sec-ch-ua-platform", .value = "\"Windows\"" },
    .{ .name = "sec-ch-ua", .value = "\"Not:A-Brand\";v=\"99\", \"Google Chrome\";v=\"145\", \"Chromium\";v=\"145\"" },
    .{ .name = "sec-ch-ua-mobile", .value = "?0" },
    .{ .name = "sec-fetch-site", .value = "same-origin" },
    .{ .name = "sec-fetch-mode", .value = "cors" },
    .{ .name = "sec-fetch-dest", .value = "empty" },
};

pub fn fetchApiKey(allocator: std.mem.Allocator) ![]u8 {
    var response_body: std.ArrayListUnmanaged(u8) = .empty;
    defer response_body.deinit(allocator);

    const result = try httpGet(allocator, &response_body);

    if (result.status_code != 200) {
        return error.HttpError;
    }

    const body = response_body.items;
    return parseApiKey(allocator, body);
}

fn httpGet(allocator: std.mem.Allocator, body_out: *std.ArrayListUnmanaged(u8)) !struct { status_code: u16 } {
    var client: std.http.Client = .{ .allocator = allocator };
    defer client.deinit();

    var response_writer: std.Io.Writer.Allocating = .init(allocator);
    defer response_writer.deinit();

    const result = try client.fetch(.{
        .location = .{ .url = api_url },
        .method = .GET,
        .headers = .{
            .user_agent = .{ .override = browser_user_agent },
            .accept_encoding = .{ .override = "identity" },
            .connection = .{ .override = "keep-alive" },
        },
        .extra_headers = &browser_headers,
        .response_writer = &response_writer.writer,
    });

    try body_out.appendSlice(allocator, response_writer.written());
    return .{ .status_code = @intFromEnum(result.status) };
}

fn parseApiKey(allocator: std.mem.Allocator, body: []const u8) ![]u8 {
    const key_field = "\"api_key\"";
    const key_pos = std.mem.indexOf(u8, body, key_field) orelse return error.InvalidResponse;

    const after_key = body[key_pos + key_field.len ..];

    const colon_pos = std.mem.indexOf(u8, after_key, ":") orelse return error.InvalidResponse;
    const after_colon = after_key[colon_pos + 1 ..];

    const quote_start = std.mem.indexOf(u8, after_colon, "\"") orelse return error.InvalidResponse;
    const value_start = after_colon[quote_start + 1 ..];

    const quote_end = std.mem.indexOf(u8, value_start, "\"") orelse return error.InvalidResponse;
    const api_key = value_start[0..quote_end];

    if (api_key.len == 0) return error.EmptyApiKey;
    if (!std.mem.startsWith(u8, api_key, "sk-")) return error.InvalidApiKeyFormat;

    const result = try allocator.alloc(u8, api_key.len);
    @memcpy(result, api_key);
    return result;
}

test "parse api key" {
    const body =
        \\{"api_key":"sk-MmYvTmpk7kl4WSySbc4FDaqHLTyiMn5guBKbvHp11vM3X7uU"}
    ;
    const key = try parseApiKey(std.testing.allocator, body);
    defer std.testing.allocator.free(key);
    try std.testing.expectEqualStrings("sk-MmYvTmpk7kl4WSySbc4FDaqHLTyiMn5guBKbvHp11vM3X7uU", key);
}
