const std = @import("std");
const Client = @import("Client.zig");
const FakeServer = @import("FakeServer.zig");

const testing = std.testing;
const gpa = testing.allocator;

/// Records the waits so tests can check the backoff without sleeping.
var sleeps: std.ArrayList(f64) = .empty;

fn recordSleep(seconds: f64) void {
    sleeps.append(gpa, seconds) catch @panic("OOM");
}

const Fixture = struct {
    server: *FakeServer,
    arena: std.heap.ArenaAllocator,
    client: Client,

    fn init(self: *Fixture, options: struct { max_retries: u32 = 2, timeout_ms: u32 = 5000 }) !void {
        self.server = try FakeServer.start(gpa);
        self.arena = .init(gpa);
        self.client = .init(gpa, self.arena.allocator(), .{
            .api_key = "sk-1",
            .base_url = self.server.url,
            .max_retries = options.max_retries,
            .timeout_ms = options.timeout_ms,
        });
        self.client.sleep = recordSleep;
        sleeps.clearRetainingCapacity();
    }

    fn deinit(self: *Fixture) void {
        self.client.deinit();
        self.arena.deinit();
        self.server.deinit();
        sleeps.clearAndFree(gpa);
    }
};

test "sends the bearer token and the JSON body" {
    var f: Fixture = undefined;
    try f.init(.{});
    defer f.deinit();
    f.server.respond(.{ .body = "{\"browser_id\":\"B1\",\"status\":\"starting\"}" });

    const result = try f.client.request(.POST, "/api/v1/browsers", "{\"os\":\"ubuntu-26.04\"}");
    try testing.expectEqualStrings("B1", result.object.get("browser_id").?.string);
    const request = f.server.getRequest(0);
    try testing.expectEqualStrings("POST", request.method);
    try testing.expectEqualStrings("/api/v1/browsers", request.path);
    try testing.expectEqualStrings("Bearer sk-1", request.header("Authorization").?);
    try testing.expectEqualStrings("application/json", request.header("Content-Type").?);
    try testing.expectEqualStrings("application/json", request.header("Accept").?);
    try testing.expect(std.mem.startsWith(u8, request.header("User-Agent").?, "remotebrowser-cli/"));
    try testing.expectEqualStrings("{\"os\":\"ubuntu-26.04\"}", request.body);
}

test "a POST without a body sends an empty one" {
    var f: Fixture = undefined;
    try f.init(.{});
    defer f.deinit();
    _ = try f.client.request(.POST, "/api/v1/browsers/B1/suspend", null);
    _ = try f.client.request(.GET, "/api/v1/browsers/B1", null);
    try testing.expectEqualStrings("0", f.server.getRequest(0).header("Content-Length").?);
    try testing.expectEqualStrings("", f.server.getRequest(0).body);
    try testing.expect(f.server.getRequest(1).header("Content-Type") == null);
}

test "strips the trailing slash of the base URL" {
    var f: Fixture = undefined;
    try f.init(.{});
    defer f.deinit();
    var client: Client = .init(gpa, f.arena.allocator(), .{
        .api_key = "sk",
        .base_url = try std.fmt.allocPrint(f.arena.allocator(), "{s}/", .{f.server.url}),
    });
    defer client.deinit();
    _ = try client.request(.GET, "/api/v1/browsers", null);
    try testing.expectEqualStrings("/api/v1/browsers", f.server.getRequest(0).path);
}

test "maps the status codes to error messages" {
    var f: Fixture = undefined;
    try f.init(.{ .max_retries = 0 });
    defer f.deinit();
    for ([_]u16{ 400, 401, 403, 404, 409, 422, 429, 500, 503, 418 }) |status| {
        f.server.respond(.{ .status = status, .body = "{\"error\":\"nope\"}" });
        try testing.expectError(error.ApiFailed, f.client.request(.GET, "/api/v1/browsers", null));
        try testing.expectEqual(status, f.client.last_error.?.status.?);
        const expected = try std.fmt.allocPrint(f.arena.allocator(), "{d} nope", .{status});
        try testing.expectEqualStrings(expected, f.client.errorMessage());
    }
}

test "keeps a plain text error body" {
    var f: Fixture = undefined;
    try f.init(.{});
    defer f.deinit();
    f.server.respond(.{ .status = 404, .body = "Not Found" });
    try testing.expectError(error.ApiFailed, f.client.request(.GET, "/api/v1/browsers/B1", null));
    try testing.expectEqualStrings("404 Not Found", f.client.errorMessage());
}

test "does not retry a conflict" {
    var f: Fixture = undefined;
    try f.init(.{});
    defer f.deinit();
    f.server.respond(.{
        .status = 409,
        .body = "{\"error\":\"Only a suspended browser can be resumed.\",\"status\":\"running\"}",
    });
    try testing.expectError(error.ApiFailed, f.client.request(.POST, "/api/v1/browsers/B1/resume", null));
    try testing.expectEqualStrings("409 Only a suspended browser can be resumed.", f.client.errorMessage());
    try testing.expectEqual(1, f.server.requestCount());
}

test "retries 429 using Retry-After" {
    var f: Fixture = undefined;
    try f.init(.{});
    defer f.deinit();
    f.server.respond(.{ .status = 429, .headers = &.{.{ .name = "Retry-After", .value = "3" }} });
    f.server.respond(.{ .body = "[\"B1\"]" });
    const result = try f.client.request(.GET, "/api/v1/browsers", null);
    try testing.expectEqualStrings("B1", result.array.items[0].string);
    try testing.expectEqualSlices(f64, &.{3.0}, sleeps.items);
    try testing.expectEqual(2, f.server.requestCount());
}

test "retries 5xx with backoff and gives up after max_retries" {
    var f: Fixture = undefined;
    try f.init(.{});
    defer f.deinit();
    for (0..3) |_| f.server.respond(.{ .status = 503, .body = "{\"error\":\"busy\"}" });
    try testing.expectError(error.ApiFailed, f.client.request(.GET, "/api/v1/browsers", null));
    try testing.expectEqualStrings("503 busy", f.client.errorMessage());
    try testing.expectEqual(3, f.server.requestCount());
    try testing.expectEqual(2, sleeps.items.len);
    try testing.expect(0.375 <= sleeps.items[0] and sleeps.items[0] <= 0.5);
    try testing.expect(0.75 <= sleeps.items[1] and sleeps.items[1] <= 1.0);
}

test "wraps network failures and retries them" {
    const address = try std.net.Address.parseIp("127.0.0.1", 0);
    var listener = try address.listen(.{});
    const port = listener.listen_address.getPort();
    listener.deinit();

    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const url = try std.fmt.allocPrint(arena.allocator(), "http://127.0.0.1:{d}", .{port});
    var client: Client = .init(gpa, arena.allocator(), .{ .api_key = "sk", .base_url = url });
    defer client.deinit();
    client.sleep = recordSleep;
    defer sleeps.clearAndFree(gpa);

    try testing.expectError(error.ApiFailed, client.request(.GET, "/api/v1/browsers", null));
    try testing.expectEqualStrings("Connection error.", client.errorMessage());
    try testing.expectEqual(null, client.last_error.?.status);
    try testing.expectEqual(2, sleeps.items.len);
}

test "times out" {
    var f: Fixture = undefined;
    try f.init(.{ .max_retries = 0, .timeout_ms = 100 });
    defer f.deinit();
    f.server.respond(.{ .body = "[]", .delay_ms = 500 });
    try testing.expectError(error.ApiFailed, f.client.request(.GET, "/api/v1/browsers", null));
    try testing.expectEqualStrings("Request timed out.", f.client.errorMessage());
}

test "an empty body is null" {
    var f: Fixture = undefined;
    try f.init(.{});
    defer f.deinit();
    f.server.respond(.{ .body = "" });
    try testing.expectEqual(.null, std.meta.activeTag(try f.client.request(.GET, "/api/v1/browsers", null)));
}
