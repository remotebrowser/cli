const std = @import("std");
const build_options = @import("build_options");
const cli = @import("cli.zig");
const FakeServer = @import("FakeServer.zig");

const testing = std.testing;
const gpa = testing.allocator;

const base = "/api/v1/browsers";

const Result = struct {
    code: u8,
    out: []const u8,
    err: []const u8,
};

var sleeps: std.ArrayList(f64) = .empty;
var opened: ?[]const u8 = null;

fn recordSleep(seconds: f64) void {
    sleeps.append(gpa, seconds) catch @panic("OOM");
}

fn recordOpen(_: std.mem.Allocator, url: []const u8) void {
    if (opened) |old| gpa.free(old);
    opened = gpa.dupe(u8, url) catch @panic("OOM");
}

const future = 4102444800; // 2100-01-01

/// Runs the CLI against a fake server, with no retries and no waits. The credentials file goes into a
/// temporary directory.
const Fixture = struct {
    server: *FakeServer,
    arena: std.heap.ArenaAllocator,
    tmp: std.testing.TmpDir,
    config_dir: []const u8,

    /// Logged in to the fake server with the token "tok".
    fn init() !Fixture {
        var f: Fixture = try .initLoggedOut();
        errdefer f.deinit();
        try f.writeCredentials(f.server.url, future);
        return f;
    }

    fn initLoggedOut() !Fixture {
        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();
        var f: Fixture = .{ .server = try FakeServer.start(gpa), .arena = .init(gpa), .tmp = tmp, .config_dir = "" };
        errdefer {
            f.server.deinit();
            f.arena.deinit();
        }
        const dir = try tmp.dir.realpathAlloc(f.arena.allocator(), ".");
        f.config_dir = try std.fs.path.join(f.arena.allocator(), &.{ dir, "rb" });
        return f;
    }

    fn deinit(self: *Fixture) void {
        self.server.deinit();
        self.arena.deinit();
        self.tmp.cleanup();
        sleeps.clearAndFree(gpa);
        if (opened) |old| gpa.free(old);
        opened = null;
    }

    fn run(self: *Fixture, argv: []const []const u8) !Result {
        return invoke(self.arena.allocator(), argv, .{
            .config_dir = self.config_dir,
            .device_name = "laptop",
            .open_url = recordOpen,
            .max_retries = 0,
            .poll_interval = 0,
            .sleep = recordSleep,
        });
    }

    fn calls(self: *Fixture) ![]const []const u8 {
        return self.server.calls(self.arena.allocator());
    }

    /// Saves one login with the token "tok", and makes it the current one.
    fn writeCredentials(self: *Fixture, url: []const u8, expires_at: i64) !void {
        try self.writeStore(try std.fmt.allocPrint(
            self.arena.allocator(),
            "{{\"current\":\"{s}\",\"servers\":{{\"{s}\":{{\"token\":\"tok\",\"expires_at\":{d}}}}}}}",
            .{ url, url, expires_at },
        ));
    }

    fn writeStore(self: *Fixture, text: []const u8) !void {
        try self.tmp.dir.makePath("rb");
        try self.tmp.dir.writeFile(.{ .sub_path = "rb/credentials.json", .data = text });
    }

    fn readStore(self: *Fixture) !std.json.Value {
        const raw = try self.tmp.dir.readFileAlloc(self.arena.allocator(), "rb/credentials.json", 4096);
        return std.json.parseFromSliceLeaky(std.json.Value, self.arena.allocator(), raw, .{});
    }

    fn fmt(self: *Fixture, comptime format: []const u8, args: anytype) ![]const u8 {
        return std.fmt.allocPrint(self.arena.allocator(), format, args);
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
        try testing.expect(std.mem.indexOf(u8, result.out, "REMOTEBROWSER_CONFIG_DIR") != null);
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

    try f.writeCredentials("https://rb.example", future);
    const secure = try f.run(&.{ "connect", "B1", "--json" });
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
        &.{ "list", "http://a", "http://b" },
        &.{ "create", "--bogus" },
        &.{ "create", "--name" },
        &.{ "create", "--screen-scale", "abc" },
        &.{ "create", "--wait=yes" },
        &.{"config"},
        &.{ "config", "del", "B1" },
        &.{ "config", "set", "B1" },
        &.{ "config", "set", "B1", "--proxy", "http://p:1", "--no-proxy" },
        &.{ "help", "frobnicate" },
        &.{ "status", "extra" },
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

test "commands need a login" {
    var f: Fixture = try .initLoggedOut();
    defer f.deinit();
    const result = try f.run(&.{"list"});
    try testing.expectEqual(1, result.code);
    try testing.expectEqualStrings("remotebrowser: Not logged in. Run 'remotebrowser login URL'.\n", result.err);
    try testing.expectEqual(0, f.server.requestCount());
}

const device_response =
    \\{"device_code":"DC","user_code":"BDFG-HJKL","verification_uri":"https://rb.example/activate",
    \\"verification_uri_complete":"https://rb.example/activate?code=BDFG-HJKL","expires_in":900,"interval":5}
;
/// Queues the responses of a login that the user approves at once, with the given token.
fn queueLogin(server: *FakeServer, token: []const u8, arena: std.mem.Allocator) !void {
    server.respond(.{ .body = device_response });
    const body = try std.fmt.allocPrint(arena, "{{\"access_token\":\"{s}\",\"expires_in\":3600}}", .{token});
    server.respond(.{ .body = body });
}

test "login polls until approved and saves the token" {
    var l: Fixture = try .initLoggedOut();
    defer l.deinit();
    const server = l.server;
    server.respond(.{ .body = device_response });
    server.respond(.{ .status = 400, .body = "{\"error\":\"authorization_pending\"}" });
    server.respond(.{ .status = 400, .body = "{\"error\":\"slow_down\"}" });
    server.respond(.{ .body = "{\"access_token\":\"tok\",\"token_type\":\"Bearer\",\"expires_in\":2592000}" });
    const result = try l.run(&.{ "login", try l.fmt("{s}/", .{server.url}), "--days", "30" });
    try testing.expectEqual(0, result.code);

    try expectCalls(&.{
        "POST /api/v1/auth/device",
        "POST /api/v1/auth/token",
        "POST /api/v1/auth/token",
        "POST /api/v1/auth/token",
    }, try l.calls());
    try testing.expectEqualStrings(
        "{\"client_id\":\"remotebrowser-cli\",\"device_name\":\"laptop\",\"days\":30}",
        server.getRequest(0).body,
    );
    try testing.expectEqualStrings(
        "{\"grant_type\":\"urn:ietf:params:oauth:grant-type:device_code\",\"device_code\":\"DC\"}",
        server.getRequest(1).body,
    );
    try testing.expectEqual(null, server.getRequest(0).header("Authorization"));
    try testing.expectEqualSlices(f64, &.{ 5, 5, 10 }, sleeps.items);
    try testing.expectEqualStrings("https://rb.example/activate?code=BDFG-HJKL", opened.?);
    try testing.expect(std.mem.indexOf(u8, result.err, "BDFG-HJKL") != null);
    try testing.expect(std.mem.startsWith(u8, result.out, "Logged in to "));

    // The trailing slash is dropped, so the URL matches later commands.
    const saved = try l.readStore();
    try testing.expectEqualStrings(server.url, saved.object.get("current").?.string);
    const login = saved.object.get("servers").?.object.get(server.url).?;
    try testing.expectEqualStrings("tok", login.object.get("token").?.string);
    const expires_at = login.object.get("expires_at").?.integer;
    try testing.expect(@abs(expires_at - std.time.timestamp() - 2592000) < 60);
    if (@import("builtin").os.tag != .windows) {
        const stat = try l.tmp.dir.statFile("rb/credentials.json");
        try testing.expectEqual(0o600, stat.mode & 0o777);
    }
}

test "login stops when denied" {
    var l: Fixture = try .initLoggedOut();
    defer l.deinit();
    l.server.respond(.{ .body = device_response });
    l.server.respond(.{ .status = 400, .body = "{\"error\":\"access_denied\"}" });
    const result = try l.run(&.{ "login", "--no-browser", l.server.url });
    try testing.expectEqual(1, result.code);
    try testing.expect(std.mem.endsWith(u8, result.err, "remotebrowser: The login was denied.\n"));
    try testing.expectEqual(null, opened);
    try testing.expectError(error.FileNotFound, l.readStore());
}

test "login gives up when the code expires" {
    var l: Fixture = try .initLoggedOut();
    defer l.deinit();
    l.server.respond(.{ .body = "{\"device_code\":\"DC\",\"user_code\":\"C\",\"verification_uri\":\"u\"," ++
        "\"expires_in\":10,\"interval\":5}" });
    l.server.respond(.{ .status = 400, .body = "{\"error\":\"authorization_pending\"}" });
    l.server.respond(.{ .status = 400, .body = "{\"error\":\"authorization_pending\"}" });
    const result = try l.run(&.{ "login", l.server.url });
    try testing.expectEqual(1, result.code);
    try testing.expect(std.mem.endsWith(u8, result.err, "The code expired before the login was approved.\n"));
    try testing.expectEqual(3, l.server.requestCount());
}

test "login explains a server without login support" {
    var l: Fixture = try .initLoggedOut();
    defer l.deinit();
    l.server.respond(.{ .status = 404, .body = "{\"error\":\"Not found.\"}" });
    const result = try l.run(&.{ "login", l.server.url });
    try testing.expectEqual(1, result.code);
    try testing.expect(std.mem.endsWith(u8, result.err, "does not support logging in with a web browser.\n"));
}

test "login needs an http URL" {
    var l: Fixture = try .initLoggedOut();
    defer l.deinit();
    const no_url = try l.run(&.{"login"});
    try testing.expectEqual(2, no_url.code);
    try testing.expect(std.mem.endsWith(u8, no_url.err, "error: the following arguments are required: url\n"));
    const bad_url = try l.run(&.{ "login", "rb.example" });
    try testing.expectEqual(2, bad_url.code);
    try testing.expect(std.mem.endsWith(u8, bad_url.err, "argument url: must start with http:// or https://\n"));
    const bad_days = try l.run(&.{ "login", "--days", "0", "http://h" });
    try testing.expectEqual(2, bad_days.code);
    try testing.expectEqual(0, l.server.requestCount());
}

test "commands use the stored login" {
    var l: Fixture = try .initLoggedOut();
    defer l.deinit();
    try l.writeCredentials(l.server.url, future);
    l.server.respond(.{ .body = "[\"B1\"]" });
    const result = try l.run(&.{"list"});
    try testing.expectEqual(0, result.code);
    try testing.expectEqualStrings("B1\n", result.out);
    try testing.expectEqualStrings("", result.err);
    try testing.expectEqualStrings("Bearer tok", l.server.getRequest(0).header("Authorization").?);

    try testing.expectEqualStrings("tok\n", (try l.run(&.{"token"})).out);
    const status = try l.run(&.{"status"});
    try testing.expectEqual(0, status.code);
    try testing.expectEqualStrings(
        try l.fmt("* {s}  login, expires 2100-01-01T00:00:00.000Z\n", .{l.server.url}),
        status.out,
    );
}

test "logins to several servers" {
    var l: Fixture = try .initLoggedOut();
    defer l.deinit();
    const a = l.server;
    const b = try FakeServer.start(gpa);
    defer b.deinit();
    const arena = l.arena.allocator();

    try queueLogin(a, "tok-a", arena);
    try testing.expectEqual(0, (try l.run(&.{ "login", a.url })).code);
    try queueLogin(b, "tok-b", arena);
    try testing.expectEqual(0, (try l.run(&.{ "--url", b.url, "login" })).code);

    // The last login is the current one; the argument or --url picks another.
    _ = try l.run(&.{"list"});
    _ = try l.run(&.{ "list", a.url });
    _ = try l.run(&.{ try l.fmt("--url={s}/", .{a.url}), "list" });
    try testing.expectEqualStrings("Bearer tok-b", b.getRequest(2).header("Authorization").?);
    try testing.expectEqualStrings("Bearer tok-a", a.getRequest(2).header("Authorization").?);
    try testing.expectEqualStrings("Bearer tok-a", a.getRequest(3).header("Authorization").?);

    const status = try l.run(&.{"status"});
    try testing.expect(std.mem.indexOf(u8, status.out, try l.fmt("  {s}  login", .{a.url})) != null);
    try testing.expect(std.mem.indexOf(u8, status.out, try l.fmt("* {s}  login", .{b.url})) != null);

    const switched = try l.run(&.{ "switch", a.url });
    try testing.expectEqualStrings(try l.fmt("Now using {s}.\n", .{a.url}), switched.out);
    _ = try l.run(&.{"list"});
    try testing.expectEqualStrings("Bearer tok-a", a.getRequest(4).header("Authorization").?);

    // Logging out of the current server moves to the one that is left.
    const logout = try l.run(&.{"logout"});
    try testing.expectEqualStrings(try l.fmt("Logged out of {s}.\nNow using {s}.\n", .{ a.url, b.url }), logout.out);
    try testing.expectEqualStrings("POST /api/v1/auth/revoke", (try a.calls(arena))[5]);
    const saved = try l.readStore();
    try testing.expectEqualStrings(b.url, saved.object.get("current").?.string);
    try testing.expectEqual(1, saved.object.get("servers").?.object.count());

    // The argument names the server to log out of.
    const by_url = try l.run(&.{ "logout", try l.fmt("{s}/", .{b.url}) });
    try testing.expectEqualStrings(try l.fmt("Logged out of {s}.\n", .{b.url}), by_url.out);
    try testing.expectError(error.FileNotFound, l.readStore());
}

test "switch needs a login to that server" {
    var l: Fixture = try .initLoggedOut();
    defer l.deinit();
    const result = try l.run(&.{ "switch", "https://other.example" });
    try testing.expectEqual(1, result.code);
    try testing.expect(std.mem.indexOf(u8, result.err, "Not logged in to https://other.example.") != null);
}

test "without a current server, commands ask to choose one" {
    var l: Fixture = try .initLoggedOut();
    defer l.deinit();
    try l.writeStore("{\"servers\":{\"https://a.example\":{\"token\":\"x\"},\"https://b.example\":{\"token\":\"y\"}}}");
    const result = try l.run(&.{"list"});
    try testing.expectEqual(1, result.code);
    try testing.expect(std.mem.indexOf(u8, result.err, "No server is chosen.") != null);
    const status = try l.run(&.{"status"});
    try testing.expectEqual(1, status.code);
    try testing.expectEqualStrings(
        "  https://a.example  login, does not expire\n  https://b.example  login, does not expire\n",
        status.out,
    );
}

test "secrets are sent only to their own server" {
    var l: Fixture = try .initLoggedOut();
    defer l.deinit();
    try l.writeCredentials("https://other.example", future);
    const login_elsewhere = try l.run(&.{ "list", "--url", l.server.url });
    try testing.expectEqual(1, login_elsewhere.code);
    try testing.expect(std.mem.indexOf(u8, login_elsewhere.err, "Not logged in to ") != null);
    try testing.expectEqual(0, l.server.requestCount());
}

test "an expired login is not used" {
    var l: Fixture = try .initLoggedOut();
    defer l.deinit();
    try l.writeCredentials(l.server.url, 1);
    const result = try l.run(&.{"list"});
    try testing.expectEqual(1, result.code);
    try testing.expect(std.mem.indexOf(u8, result.err, "expired on 1970-01-01T00:00:01.000Z") != null);
    try testing.expectEqual(0, l.server.requestCount());
    try testing.expectEqual(1, (try l.run(&.{"token"})).code);
    const status = try l.run(&.{"status"});
    try testing.expectEqual(1, status.code);
    try testing.expect(std.mem.indexOf(u8, status.out, "login, expired 1970-01-01T00:00:01.000Z") != null);
}

test "a login that expires soon gives a warning" {
    var l: Fixture = try .initLoggedOut();
    defer l.deinit();
    try l.writeCredentials(l.server.url, std.time.timestamp() + std.time.s_per_day);
    l.server.respond(.{ .body = "[]" });
    const result = try l.run(&.{"list"});
    try testing.expectEqual(0, result.code);
    try testing.expect(std.mem.startsWith(u8, result.err, "remotebrowser: warning: Your login expires on "));
}

test "a rejected login suggests logging in again" {
    var l: Fixture = try .initLoggedOut();
    defer l.deinit();
    try l.writeCredentials(l.server.url, future);
    l.server.respond(.{ .status = 401, .body = "{\"error\":\"Your login has expired.\"}" });
    const result = try l.run(&.{"list"});
    try testing.expectEqual(1, result.code);
    try testing.expectEqualStrings(
        "remotebrowser: 401 Your login has expired.\nremotebrowser: Run 'remotebrowser login' to log in again.\n",
        result.err,
    );
}

test "logout revokes the token and deletes the file" {
    var l: Fixture = try .initLoggedOut();
    defer l.deinit();
    try l.writeCredentials(l.server.url, future);
    l.server.respond(.{ .status = 204, .body = "" });
    const result = try l.run(&.{"logout"});
    try testing.expectEqual(0, result.code);
    try expectCalls(&.{"POST /api/v1/auth/revoke"}, try l.calls());
    try testing.expectEqualStrings("Bearer tok", l.server.getRequest(0).header("Authorization").?);
    try testing.expectError(error.FileNotFound, l.readStore());

    const again = try l.run(&.{"logout"});
    try testing.expectEqual(1, again.code);
    try testing.expectEqualStrings("remotebrowser: Not logged in.\n", again.err);
}

test "logout deletes the login even when the server fails" {
    var l: Fixture = try .initLoggedOut();
    defer l.deinit();
    try l.writeCredentials(l.server.url, future);
    l.server.respond(.{ .status = 500, .body = "{\"error\":\"oops\"}" });
    const result = try l.run(&.{"logout"});
    try testing.expectEqual(0, result.code);
    try testing.expect(std.mem.indexOf(u8, result.err, "500 oops") != null);
    try testing.expectError(error.FileNotFound, l.readStore());
}

test "login commands are top-level" {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const help = try invoke(arena.allocator(), &.{"help"}, .{});
    try testing.expectEqual(0, help.code);
    try testing.expect(std.mem.indexOf(u8, help.out, "  login ") != null);
    try testing.expect(std.mem.indexOf(u8, help.out, "  auth ") == null);
    const login_help = try invoke(arena.allocator(), &.{ "login", "-h" }, .{});
    try testing.expect(std.mem.startsWith(u8, login_help.out, "usage: remotebrowser login "));
    try testing.expect(std.mem.indexOf(u8, login_help.out, "[url]") != null);

    const bad = try invoke(arena.allocator(), &.{ "auth", "status" }, .{});
    try testing.expectEqual(2, bad.code);
    try testing.expect(std.mem.endsWith(u8, bad.err, "error: invalid command 'auth' (run 'remotebrowser help')\n"));
    try testing.expectEqual(2, (try invoke(arena.allocator(), &.{ "list", "--url" }, .{})).code);
    try testing.expectEqual(2, (try invoke(arena.allocator(), &.{"switch"}, .{})).code);
}

test "the executable reads the login from REMOTEBROWSER_CONFIG_DIR" {
    var l: Fixture = try .initLoggedOut();
    defer l.deinit();
    try l.writeCredentials(l.server.url, future);
    l.server.respond(.{ .body = "[\"B1\"]" });
    var env: std.process.EnvMap = .init(gpa);
    defer env.deinit();
    try env.put("REMOTEBROWSER_CONFIG_DIR", l.config_dir);
    const result = try std.process.Child.run(.{
        .allocator = l.arena.allocator(),
        .argv = &.{ build_options.exe_path, "list" },
        .env_map = &env,
    });
    try testing.expectEqual(std.process.Child.Term{ .Exited = 0 }, result.term);
    try testing.expectEqualStrings("B1\n", result.stdout);
    try testing.expectEqualStrings("Bearer tok", l.server.getRequest(0).header("Authorization").?);

    const usage = try std.process.Child.run(.{
        .allocator = l.arena.allocator(),
        .argv = &.{ build_options.exe_path, "get" },
        .env_map = &env,
    });
    try testing.expectEqual(std.process.Child.Term{ .Exited = 2 }, usage.term);
}
