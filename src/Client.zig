//! Client for the Remote Browser REST API: sends a request, retries it when that can help, and
//! parses the JSON response.

const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const curl = @import("curl.zig");

const Allocator = std.mem.Allocator;
const json = std.json;

const Client = @This();

pub const default_timeout_ms: u32 = 60_000;
pub const default_max_retries: u32 = 2;
const max_retry_delay: f64 = 60;
const max_response_size = 16 * 1024 * 1024;
const user_agent = "remotebrowser-cli/" ++ build_options.version;
const use_libcurl = build_options.libcurl;

/// Allocates the HTTP connections. Must be thread-safe if the client is shared between threads.
gpa: Allocator,
/// Allocates the parsed responses and the error messages, which the caller frees all at once.
arena: Allocator,
/// Empty for the login endpoints, which need no authentication.
api_key: []const u8,
/// Without the trailing slash.
base_url: []const u8,
/// Milliseconds to wait for the server, per attempt.
timeout_ms: u32 = default_timeout_ms,
max_retries: u32 = default_max_retries,
/// Tests replace this to skip the waits between retries.
sleep: *const fn (seconds: f64) void = defaultSleep,
http: if (use_libcurl) curl.Session else std.http.Client,
/// Set when a method returns error.ApiFailed.
last_error: ?ApiError = null,

pub const ApiError = struct {
    /// The HTTP status code, or null when no response arrived.
    status: ?u16 = null,
    message: []const u8,
    retry_after: ?f64 = null,
    timed_out: bool = false,
    /// The parsed response body, so callers can read error codes such as OAuth's "error" field.
    body: std.json.Value = .null,
};

pub const Error = error{ ApiFailed, OutOfMemory };

pub const Options = struct {
    api_key: []const u8,
    base_url: []const u8,
    timeout_ms: u32 = default_timeout_ms,
    max_retries: u32 = default_max_retries,
};

pub fn init(gpa: Allocator, arena: Allocator, options: Options) Client {
    return .{
        .gpa = gpa,
        .arena = arena,
        .api_key = options.api_key,
        .base_url = std.mem.trimRight(u8, options.base_url, "/"),
        .timeout_ms = options.timeout_ms,
        .max_retries = options.max_retries,
        .http = if (use_libcurl) .{} else .{ .allocator = gpa },
    };
}

pub fn deinit(client: *Client) void {
    client.http.deinit();
}

pub fn errorMessage(client: *const Client) []const u8 {
    return if (client.last_error) |err| err.message else "unknown error";
}

/// The "error" field of the last error response, such as "authorization_pending".
pub fn errorCode(client: *const Client) ?[]const u8 {
    const err = client.last_error orelse return null;
    if (err.body != .object) return null;
    const value = err.body.object.get("error") orelse return null;
    return if (value == .string) value.string else null;
}

/// Sends a request and returns the parsed JSON response, or a string when the body is not JSON,
/// or null when it is empty. A null body sends no body.
pub fn request(client: *Client, method: std.http.Method, path: []const u8, body: ?[]const u8) Error!json.Value {
    var attempt: u32 = 0;
    while (true) : (attempt += 1) {
        if (client.makeRequest(method, path, body)) |value| {
            client.last_error = null;
            return value;
        } else |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.ApiFailed => {
                const api_error = client.last_error.?;
                if (attempt >= client.max_retries or !shouldRetry(api_error)) return error.ApiFailed;
                client.sleep(retryDelay(api_error, attempt));
            },
        }
    }
}

fn fail(client: *Client, api_error: ApiError) error{ApiFailed} {
    client.last_error = api_error;
    return error.ApiFailed;
}

fn connectionError(client: *Client, timed_out: bool) error{ApiFailed} {
    return client.fail(if (timed_out)
        .{ .message = "Request timed out.", .timed_out = true }
    else
        .{ .message = "Connection error." });
}

const Response = struct {
    status: u16,
    retry_after: ?f64,
    body: []const u8,
};

fn makeRequest(client: *Client, method: std.http.Method, path: []const u8, body: ?[]const u8) Error!json.Value {
    const url = try std.mem.concat(client.arena, u8, &.{ client.base_url, path });
    const uri = std.Uri.parse(url) catch return client.invalidUrl(url);
    const response = if (use_libcurl)
        try client.sendCurl(method, url, body)
    else
        try client.sendStd(method, url, uri, body);

    const parsed = try parseBody(client.arena, response.body);
    if (response.status >= 300) {
        return client.fail(.{
            .status = response.status,
            .message = try errorText(client.arena, response.status, parsed),
            .retry_after = response.retry_after,
            .body = parsed,
        });
    }
    return parsed;
}

fn invalidUrl(client: *Client, url: []const u8) Error {
    const message = std.fmt.allocPrint(client.arena, "Invalid URL: {s}", .{url}) catch return error.OutOfMemory;
    return client.fail(.{ .message = message });
}

fn sendCurl(client: *Client, method: std.http.Method, url: []const u8, body: ?[]const u8) Error!Response {
    const arena = client.arena;
    var headers: std.ArrayList([:0]const u8) = .empty;
    try headers.append(arena, "Accept: application/json");
    if (body != null or method.requestHasBody()) try headers.append(arena, "Content-Type: application/json");
    if (client.api_key.len > 0) try headers.append(arena, try std.fmt.allocPrintSentinel(arena, "Authorization: Bearer {s}", .{client.api_key}, 0));

    const response = client.http.send(arena, .{
        .method = @tagName(method),
        .url = try arena.dupeZ(u8, url),
        .headers = headers.items,
        .user_agent = user_agent,
        .body = if (method.requestHasBody()) body orelse "" else null,
        .timeout_ms = client.timeout_ms,
        .max_response_size = max_response_size,
    }) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.InvalidUrl => client.invalidUrl(url),
        error.TimedOut => client.connectionError(true),
        error.ResponseTooLarge => client.fail(.{ .message = "The response is too large." }),
        error.Unavailable => client.fail(.{ .message = "Cannot load libcurl." }),
        error.ConnectionFailed => client.connectionError(false),
    };
    return .{ .status = response.status, .retry_after = response.retry_after, .body = response.body };
}

fn sendStd(client: *Client, method: std.http.Method, url: []const u8, uri: std.Uri, body: ?[]const u8) Error!Response {
    const authorization = try std.mem.concat(client.arena, u8, &.{ "Bearer ", client.api_key });

    var req = client.http.request(method, uri, .{
        // Not followed, so the token never goes to another host.
        .redirect_behavior = .unhandled,
        .headers = .{
            .authorization = if (client.api_key.len == 0) .omit else .{ .override = authorization },
            .user_agent = .{ .override = user_agent },
            .content_type = if (body != null or method.requestHasBody())
                .{ .override = "application/json" }
            else
                .default,
            .accept_encoding = .omit,
        },
        .extra_headers = &.{.{ .name = "Accept", .value = "application/json" }},
    }) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.UnsupportedUriScheme, error.UriMissingHost, error.UriHostTooLong => client.invalidUrl(url),
        error.ConnectionTimedOut => client.connectionError(true),
        else => client.connectionError(false),
    };
    defer req.deinit();
    setReadTimeout(req.connection.?, client.timeout_ms);

    const sent = if (method.requestHasBody()) send: {
        const payload = body orelse "";
        req.transfer_encoding = .{ .content_length = payload.len };
        var body_writer = req.sendBodyUnflushed(&.{}) catch break :send false;
        body_writer.writer.writeAll(payload) catch break :send false;
        body_writer.end() catch break :send false;
        req.connection.?.flush() catch break :send false;
        break :send true;
    } else if (req.sendBodiless()) true else |_| false;
    if (!sent) return client.connectionError(false);

    var response = req.receiveHead(&.{}) catch |err|
        return client.connectionError(err == error.ReadFailed and isTimeout(req.connection));

    const status: u16 = @intFromEnum(response.head.status);
    var retry_after: ?f64 = null;
    var headers = response.head.iterateHeaders();
    while (headers.next()) |header| {
        if (std.ascii.eqlIgnoreCase(header.name, "retry-after")) {
            retry_after = std.fmt.parseFloat(f64, std.mem.trim(u8, header.value, " ")) catch null;
        }
    }

    const reader = response.reader(&.{});
    const raw = reader.allocRemaining(client.arena, .limited(max_response_size)) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.StreamTooLong => return client.fail(.{ .message = "The response is too large." }),
        error.ReadFailed => return client.connectionError(isTimeout(req.connection)),
    };

    return .{ .status = status, .retry_after = retry_after, .body = raw };
}

/// Parses a JSON body, keeping a body that is not JSON as a string, because proxies in front of the
/// API may answer with plain text.
pub fn parseBody(arena: Allocator, raw: []const u8) Allocator.Error!json.Value {
    if (raw.len == 0) return .null;
    return json.parseFromSliceLeaky(json.Value, arena, raw, .{ .allocate = .alloc_always }) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => .{ .string = raw },
    };
}

/// "<status> <detail>", where the detail is the text body, or the "error" or "message" field of
/// a JSON object, or else the JSON body.
pub fn errorText(arena: Allocator, status: u16, body: json.Value) Allocator.Error![]const u8 {
    const detail: []const u8 = switch (body) {
        .string => |text| text,
        .null => "",
        .bool => |b| if (b) "true" else "",
        .integer => |n| if (n != 0) try std.fmt.allocPrint(arena, "{d}", .{n}) else "",
        .object => |object| detail: {
            for ([_][]const u8{ "error", "message" }) |key| {
                if (object.get(key)) |value| {
                    if (value == .string and value.string.len > 0) break :detail value.string;
                }
            }
            break :detail if (object.count() == 0) "" else try stringify(arena, body);
        },
        .array => |array| if (array.items.len == 0) "" else try stringify(arena, body),
        else => try stringify(arena, body),
    };
    if (detail.len == 0) return std.fmt.allocPrint(arena, "{d} status code (no body)", .{status});
    return std.fmt.allocPrint(arena, "{d} {s}", .{ status, detail });
}

fn stringify(arena: Allocator, value: json.Value) Allocator.Error![]const u8 {
    return json.Stringify.valueAlloc(arena, value, .{});
}

fn shouldRetry(err: ApiError) bool {
    // 409 is a state conflict in this API, so retrying it would not help.
    const status = err.status orelse return true;
    return status == 408 or status == 429 or status >= 500;
}

fn retryDelay(err: ApiError, attempt: u32) f64 {
    if (err.retry_after) |seconds| {
        if (seconds >= 0 and seconds <= max_retry_delay) return seconds;
    }
    const base = @min(0.5 * std.math.pow(f64, 2, @floatFromInt(attempt)), 8.0);
    return base * (1 - std.crypto.random.float(f64) * 0.25);
}

fn defaultSleep(seconds: f64) void {
    std.Thread.sleep(@intFromFloat(seconds * std.time.ns_per_s));
}

/// std.http.Client has no read timeout, so set one on the socket; otherwise a silent server hangs the CLI.
fn setReadTimeout(connection: *std.http.Client.Connection, ms: u32) void {
    const handle = connection.stream_reader.getStream().handle;
    if (builtin.os.tag == .windows) {
        const ws2_32 = std.os.windows.ws2_32;
        const value: u32 = ms;
        _ = ws2_32.setsockopt(handle, ws2_32.SOL.SOCKET, ws2_32.SO.RCVTIMEO, std.mem.asBytes(&value), @sizeOf(u32));
    } else {
        const posix = std.posix;
        const timeout: posix.timeval = .{
            .sec = @intCast(ms / 1000),
            .usec = @intCast((ms % 1000) * 1000),
        };
        posix.setsockopt(handle, posix.SOL.SOCKET, posix.SO.RCVTIMEO, std.mem.asBytes(&timeout)) catch {};
    }
}

fn isTimeout(connection: ?*std.http.Client.Connection) bool {
    const c = connection orelse return false;
    const err = c.getReadError() orelse return false;
    return err == error.WouldBlock or err == error.ConnectionTimedOut;
}

/// Browser ids come from the user, so encode them to keep values such as "../" from changing the path.
pub fn escapeSegment(arena: Allocator, segment: []const u8) Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (segment) |c| {
        if (std.ascii.isAlphanumeric(c) or c == '-' or c == '.' or c == '_' or c == '~') {
            try out.append(arena, c);
        } else {
            try out.print(arena, "%{X:0>2}", .{c});
        }
    }
    return out.items;
}

test escapeSegment {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectEqualStrings("a%2Fb%20c-d_e.f~", try escapeSegment(arena.allocator(), "a/b c-d_e.f~"));
}

test errorText {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const cases = [_]struct { []const u8, []const u8 }{
        .{ "{\"error\":\"nope\"}", "404 nope" },
        .{ "{\"message\":\"gone\"}", "404 gone" },
        .{ "{\"error\":\"\",\"message\":\"gone\"}", "404 gone" },
        .{ "{\"detail\":1}", "404 {\"detail\":1}" },
        .{ "{}", "404 status code (no body)" },
        .{ "", "404 status code (no body)" },
        .{ "Not Found", "404 Not Found" },
    };
    for (cases) |case| {
        try std.testing.expectEqualStrings(case[1], try errorText(arena, 404, try parseBody(arena, case[0])));
    }
}
