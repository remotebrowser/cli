const std = @import("std");
const build_options = @import("build_options");
const cli = @import("cli.zig");
const FakeServer = @import("FakeServer.zig");

const testing = std.testing;
const gpa = testing.allocator;

const base = "/api/v1/browsers";

fn noSleep(_: f64) void {}

const Result = struct {
    code: u8,
    out: []const u8,
    err: []const u8,
};

/// Runs the CLI against a fake server, with no retries and no waits.
const Fixture = struct {
    server: *FakeServer,
    arena: std.heap.ArenaAllocator,

    fn init() !Fixture {
        return .{ .server = try FakeServer.start(gpa), .arena = .init(gpa) };
    }

    fn deinit(self: *Fixture) void {
        self.server.deinit();
        self.arena.deinit();
    }

    fn run(self: *Fixture, argv: []const []const u8) !Result {
        return invoke(self.arena.allocator(), argv, .{
            .api_key = "sk",
            .base_url = self.server.url,
            .max_retries = 0,
            .poll_interval = 0,
            .sleep = noSleep,
        });
    }

    fn calls(self: *Fixture) ![]const []const u8 {
        return self.server.calls(self.arena.allocator());
    }
};

fn invoke(arena: std.mem.Allocator, argv: []const []const u8, options: cli.Options) !Result {
    var out: std.Io.Writer.Allocating = .init(arena);
    var err: std.Io.Writer.Allocating = .init(arena);
    const code = cli.run(gpa, argv, options, &out.writer, &err.writer);
    return .{ .code = code, .out = out.written(), .err = err.written() };
}

fn expectCalls(expected: []const []const u8, actual: []const []const u8) !void {
    try testing.expectEqual(expected.len, actual.len);
    for (expected, actual) |e, a| try testing.expectEqualStrings(e, a);
}

test "help needs no credentials" {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    for ([_][]const []const u8{ &.{}, &.{"help"}, &.{"--help"}, &.{"-h"} }) |argv| {
        const result = try invoke(arena.allocator(), argv, .{});
        try testing.expectEqual(0, result.code);
        try testing.expect(std.mem.startsWith(u8, result.out, "usage: remotebrowser"));
        try testing.expect(std.mem.indexOf(u8, result.out, "REMOTEBROWSER_API_KEY") != null);
    }
}

test "command help" {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const cases = [_]struct { []const []const u8, []const u8 }{
        .{ &.{ "create", "--help" }, "usage: remotebrowser create " },
        .{ &.{ "help", "create" }, "usage: remotebrowser create " },
        .{ &.{ "ls", "-h" }, "usage: remotebrowser list " },
        .{ &.{ "config", "--help" }, "usage: remotebrowser config " },
        .{ &.{ "config", "set", "-h" }, "usage: remotebrowser config set " },
    };
    for (cases) |case| {
        const result = try invoke(arena.allocator(), case[0], .{});
        try testing.expectEqual(0, result.code);
        try testing.expect(std.mem.startsWith(u8, result.out, case[1]));
    }
}

test "version" {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    for ([_][]const u8{ "--version", "-v" }) |arg| {
        const result = try invoke(arena.allocator(), &.{arg}, .{});
        try testing.expectEqual(0, result.code);
        try testing.expectEqualStrings(build_options.version ++ "\n", result.out);
    }
}

test "create sends the options and prints the id" {
    var f: Fixture = try .init();
    defer f.deinit();
    f.server.respond(.{ .body = "{\"browser_id\":\"B1\",\"status\":\"starting\"}" });
    const result = try f.run(&.{ "create", "--os", "ubuntu-26.04", "--screen-scale", "150", "--proxy=http://p:1" });
    try testing.expectEqual(0, result.code);
    try testing.expectEqualStrings("B1\n", result.out);
    try testing.expectEqualStrings(
        "{\"os\":\"ubuntu-26.04\",\"screen_scale\":150,\"proxy\":\"http://p:1\"}",
        f.server.getRequest(0).body,
    );
}

test "create without options sends an empty object" {
    var f: Fixture = try .init();
    defer f.deinit();
    f.server.respond(.{ .body = "{\"browser_id\":\"B1\",\"status\":\"starting\"}" });
    _ = try f.run(&.{"create"});
    try testing.expectEqualStrings("{}", f.server.getRequest(0).body);
}

test "create --wait polls until running" {
    var f: Fixture = try .init();
    defer f.deinit();
    f.server.respond(.{ .body = "{\"browser_id\":\"B1\",\"status\":\"launched\"}" });
    f.server.respond(.{ .body = "{\"browser_id\":\"B1\",\"status\":\"starting\"}" });
    f.server.respond(.{ .body = "{\"browser_id\":\"B1\",\"status\":\"running\",\"os\":\"debian-13\"}" });
    const result = try f.run(&.{ "create", "--wait" });
    try testing.expectEqual(0, result.code);
    try expectCalls(&.{ "POST " ++ base, "GET " ++ base ++ "/B1", "GET " ++ base ++ "/B1" }, try f.calls());
    try testing.expectEqualStrings("B1\n", result.out);
}

test "create --wait fails when the browser does not run" {
    var f: Fixture = try .init();
    defer f.deinit();
    f.server.respond(.{ .body = "{\"browser_id\":\"B1\",\"status\":\"starting\"}" });
    f.server.respond(.{ .body = "{\"browser_id\":\"B1\",\"status\":\"error\"}" });
    const result = try f.run(&.{ "create", "--wait", "--json" });
    try testing.expectEqual(1, result.code);
    try testing.expectEqualStrings("remotebrowser: Browser B1 is error.\n", result.err);
    try testing.expect(std.mem.indexOf(u8, result.out, "\"status\": \"error\"") != null);
}

test "list prints one id per line, or JSON" {
    var f: Fixture = try .init();
    defer f.deinit();
    f.server.respond(.{ .body = "[\"B1\",\"B2\"]" });
    f.server.respond(.{ .body = "[\"B1\"]" });
    f.server.respond(.{ .body = "[\"B1\"]" });
    f.server.respond(.{ .body = "[]" });
    try testing.expectEqualStrings("B1\nB2\n", (try f.run(&.{"list"})).out);
    try testing.expectEqualStrings("[\n  \"B1\"\n]\n", (try f.run(&.{ "ls", "--json" })).out);
    try testing.expectEqualStrings("[\n  \"B1\"\n]\n", (try f.run(&.{ "--json", "list" })).out);
    try testing.expectEqualStrings("", (try f.run(&.{"list"})).out);
}

test "get shows the browser details" {
    var f: Fixture = try .init();
    defer f.deinit();
    f.server.respond(.{
        .body = "{\"browser_id\":\"B1\",\"status\":\"running\",\"description\":\"\",\"os\":\"fedora-44\"," ++
            "\"creation_timestamp\":0,\"extra\":{\"a\":1},\"gpu\":true}",
    });
    f.server.respond(.{ .body = "{\"browser_id\":\"B2\",\"status\":\"running\",\"creation_timestamp\":null}" });
    try testing.expectEqualStrings(
        \\id:          B1
        \\status:      running
        \\description: -
        \\os:          fedora-44
        \\created:     1970-01-01T00:00:00.000Z
        \\extra:       {"a":1}
        \\gpu:         true
        \\
    , (try f.run(&.{ "info", "B1" })).out);
    try testing.expectEqualStrings(
        \\id:          B2
        \\status:      running
        \\description: -
        \\os:          -
        \\created:     -
        \\
    , (try f.run(&.{ "get", "B2" })).out);
    try expectCalls(&.{ "GET " ++ base ++ "/B1", "GET " ++ base ++ "/B2" }, try f.calls());
}

test "escapes browser ids" {
    var f: Fixture = try .init();
    defer f.deinit();
    _ = try f.run(&.{ "get", "a/b c" });
    try expectCalls(&.{"GET " ++ base ++ "/a%2Fb%20c"}, try f.calls());
}

test "rejects an empty browser id" {
    var f: Fixture = try .init();
    defer f.deinit();
    const result = try f.run(&.{ "get", "" });
    try testing.expectEqual(2, result.code);
    try testing.expectEqualStrings("remotebrowser: A browser id is required.\n", result.err);
    try testing.expectEqual(0, f.server.requestCount());
}

test "delete, suspend and resume accept several ids" {
    var f: Fixture = try .init();
    defer f.deinit();
    f.server.respond(.{ .body = "{\"browser_id\":\"B1\",\"status\":\"terminated\"}" });
    f.server.respond(.{ .body = "{\"browser_id\":\"B2\",\"status\":\"terminated\"}" });
    f.server.respond(.{ .body = "{\"browser_id\":\"B3\",\"status\":\"suspended\"}" });
    f.server.respond(.{ .body = "{\"browser_id\":\"B3\",\"status\":\"running\"}" });
    const delete = try f.run(&.{ "delete", "B1", "B2" });
    const @"suspend" = try f.run(&.{ "suspend", "B3" });
    const @"resume" = try f.run(&.{ "resume", "B3" });
    try expectCalls(&.{
        "DELETE " ++ base ++ "/B1",
        "DELETE " ++ base ++ "/B2",
        "POST " ++ base ++ "/B3/suspend",
        "POST " ++ base ++ "/B3/resume",
    }, try f.calls());
    try testing.expectEqualStrings("B1 terminated\nB2 terminated\n", delete.out);
    try testing.expectEqualStrings("B3 suspended\n", @"suspend".out);
    try testing.expectEqualStrings("B3 running\n", @"resume".out);
}

test "several ids with --json print an array" {
    var f: Fixture = try .init();
    defer f.deinit();
    f.server.respond(.{ .body = "{\"browser_id\":\"B1\",\"status\":\"running\"}" });
    f.server.respond(.{ .body = "{\"browser_id\":\"B2\",\"status\":\"running\"}" });
    f.server.respond(.{ .body = "{\"browser_id\":\"B3\",\"status\":\"running\"}" });
    try testing.expectEqualStrings(
        \\[
        \\  {
        \\    "browser_id": "B1",
        \\    "status": "running"
        \\  },
        \\  {
        \\    "browser_id": "B2",
        \\    "status": "running"
        \\  }
        \\]
        \\
    , (try f.run(&.{ "resume", "B1", "B2", "--json" })).out);
    try testing.expectEqualStrings(
        \\{
        \\  "browser_id": "B3",
        \\  "status": "running"
        \\}
        \\
    , (try f.run(&.{ "resume", "--json", "B3" })).out);
}

test "delete keeps going when one browser fails" {
    var f: Fixture = try .init();
    defer f.deinit();
    f.server.respond(.{ .status = 404, .body = "{\"error\":\"Browser not found.\"}" });
    f.server.respond(.{ .body = "{\"browser_id\":\"B2\",\"status\":\"terminated\"}" });
    const result = try f.run(&.{ "rm", "B1", "B2" });
    try testing.expectEqual(1, result.code);
    try testing.expectEqualStrings("B2 terminated\n", result.out);
    try testing.expectEqualStrings(
        "remotebrowser: B1: 404 Browser not found.\nremotebrowser: Could not delete every browser.\n",
        result.err,
    );
}

test "connect prints the CDP URL without a request" {
    var f: Fixture = try .init();
    defer f.deinit();
    const result = try f.run(&.{ "connect", "B1" });
    const expected = try std.fmt.allocPrint(f.arena.allocator(), "ws://{s}/api/v1/browsers/B1/cdp\n", .{
        f.server.url["http://".len..],
    });
    try testing.expectEqualStrings(expected, result.out);
    try testing.expectEqual(0, f.server.requestCount());

    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const secure = try invoke(arena.allocator(), &.{ "connect", "B1", "--json" }, .{
        .api_key = "sk",
        .base_url = "https://rb.example/",
    });
    try testing.expectEqualStrings(
        \\{
        \\  "browser_id": "B1",
        \\  "url": "wss://rb.example/api/v1/browsers/B1/cdp"
        \\}
        \\
    , secure.out);
}

test "config get and set" {
    var f: Fixture = try .init();
    defer f.deinit();
    f.server.respond(.{ .body = "{\"browser_id\":\"B1\",\"proxy\":null}" });
    f.server.respond(.{ .body = "{\"browser_id\":\"B1\",\"proxy\":\"socks5://p:1080\"}" });
    const config_get = try f.run(&.{ "config", "get", "B1" });
    const config_set = try f.run(&.{ "config", "set", "B1", "--proxy", "socks5://p:1080" });
    try expectCalls(&.{ "GET " ++ base ++ "/B1/config", "PATCH " ++ base ++ "/B1/config" }, try f.calls());
    try testing.expectEqualStrings("{\"proxy\":\"socks5://p:1080\"}", f.server.getRequest(1).body);
    try testing.expectEqualStrings("id:    B1\nproxy: -\n", config_get.out);
    try testing.expectEqualStrings("id:    B1\nproxy: socks5://p:1080\n", config_set.out);
}

test "config set --no-proxy sends null" {
    var f: Fixture = try .init();
    defer f.deinit();
    f.server.respond(.{ .body = "{\"browser_id\":\"B1\",\"proxy\":null}" });
    _ = try f.run(&.{ "config", "set", "B1", "--no-proxy" });
    try testing.expectEqualStrings("{\"proxy\":null}", f.server.getRequest(0).body);
}

test "usage errors exit with 2" {
    var f: Fixture = try .init();
    defer f.deinit();
    const cases = [_][]const []const u8{
        &.{"frobnicate"},
        &.{"--bogus"},
        &.{"get"},
        &.{ "get", "a", "b" },
        &.{ "list", "--os", "x" },
        &.{ "list", "extra" },
        &.{ "create", "--bogus" },
        &.{ "create", "--name" },
        &.{ "create", "--screen-scale", "abc" },
        &.{ "create", "--wait=yes" },
        &.{"config"},
        &.{ "config", "del", "B1" },
        &.{ "config", "set", "B1" },
        &.{ "config", "set", "B1", "--proxy", "http://p:1", "--no-proxy" },
        &.{ "help", "frobnicate" },
    };
    for (cases) |argv| {
        const result = try f.run(argv);
        testing.expectEqual(2, result.code) catch |err| {
            for (argv) |arg| std.debug.print("{s} ", .{arg});
            std.debug.print("\n", .{});
            return err;
        };
        try testing.expect(std.mem.startsWith(u8, result.err, "usage: remotebrowser"));
        try testing.expect(std.mem.indexOf(u8, result.err, "error: ") != null);
    }
    try testing.expectEqual(0, f.server.requestCount());

    const flag_value = try f.run(&.{ "create", "--wait=yes" });
    try testing.expect(std.mem.endsWith(u8, flag_value.err, "error: argument --wait: does not take a value\n"));
}

test "API errors exit with 1" {
    var f: Fixture = try .init();
    defer f.deinit();
    f.server.respond(.{ .status = 409, .body = "{\"error\":\"Only a suspended browser can be resumed.\"}" });
    const result = try f.run(&.{ "resume", "B1" });
    try testing.expectEqual(1, result.code);
    try testing.expectEqualStrings("remotebrowser: 409 Only a suspended browser can be resumed.\n", result.err);
}

test "missing credentials exit with 1" {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const no_key = try invoke(arena.allocator(), &.{"list"}, .{ .api_key = "", .base_url = "http://h" });
    try testing.expectEqual(1, no_key.code);
    try testing.expect(std.mem.indexOf(u8, no_key.err, "REMOTEBROWSER_API_KEY") != null);
    const no_url = try invoke(arena.allocator(), &.{"list"}, .{ .api_key = "sk" });
    try testing.expectEqual(1, no_url.code);
    try testing.expect(std.mem.indexOf(u8, no_url.err, "REMOTEBROWSER_URL") != null);
}

test "the executable reads the environment" {
    var f: Fixture = try .init();
    defer f.deinit();
    f.server.respond(.{ .body = "[\"B1\"]" });
    var env: std.process.EnvMap = .init(gpa);
    defer env.deinit();
    try env.put("REMOTEBROWSER_API_KEY", "sk-env");
    try env.put("REMOTEBROWSER_URL", f.server.url);
    const result = try std.process.Child.run(.{
        .allocator = f.arena.allocator(),
        .argv = &.{ build_options.exe_path, "list" },
        .env_map = &env,
    });
    try testing.expectEqual(std.process.Child.Term{ .Exited = 0 }, result.term);
    try testing.expectEqualStrings("B1\n", result.stdout);
    try testing.expectEqualStrings("", result.stderr);
    try testing.expectEqualStrings("Bearer sk-env", f.server.getRequest(0).header("Authorization").?);

    const usage = try std.process.Child.run(.{
        .allocator = f.arena.allocator(),
        .argv = &.{ build_options.exe_path, "get" },
        .env_map = &env,
    });
    try testing.expectEqual(std.process.Child.Term{ .Exited = 2 }, usage.term);
}
