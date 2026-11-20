//! For tests: an HTTP server that answers with queued responses and records the requests.

const std = @import("std");
const Allocator = std.mem.Allocator;

const FakeServer = @This();

gpa: Allocator,
server: std.net.Server,
thread: std.Thread,
/// "http://127.0.0.1:<port>"
url: []const u8,
mutex: std.Thread.Mutex = .{},
requests: std.ArrayList(Request) = .empty,
responses: std.ArrayList(Response) = .empty,
stopping: std.atomic.Value(bool) = .init(false),

pub const Request = struct {
    method: []const u8,
    path: []const u8,
    /// "Name: value" lines, as sent.
    headers: []const []const u8,
    body: []const u8,

    pub fn header(self: Request, name: []const u8) ?[]const u8 {
        for (self.headers) |line| {
            const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
            if (std.ascii.eqlIgnoreCase(line[0..colon], name)) return std.mem.trim(u8, line[colon + 1 ..], " ");
        }
        return null;
    }
};

pub const Response = struct {
    status: u16 = 200,
    body: []const u8 = "{}",
    headers: []const std.http.Header = &.{},
    delay_ms: u64 = 0,
};

/// Starts the server on a free port. The caller calls `deinit`.
pub fn start(gpa: Allocator) !*FakeServer {
    const self = try gpa.create(FakeServer);
    errdefer gpa.destroy(self);
    const address = try std.net.Address.parseIp("127.0.0.1", 0);
    self.* = .{
        .gpa = gpa,
        .server = try address.listen(.{ .reuse_address = true }),
        .thread = undefined,
        .url = undefined,
    };
    errdefer self.server.deinit();
    self.url = try std.fmt.allocPrint(gpa, "http://127.0.0.1:{d}", .{self.server.listen_address.getPort()});
    errdefer gpa.free(self.url);
    self.thread = try std.Thread.spawn(.{}, serve, .{self});
    return self;
}

pub fn deinit(self: *FakeServer) void {
    self.stopping.store(true, .release);
    // accept() blocks, so connect once to let the thread see `stopping`.
    if (std.net.tcpConnectToAddress(self.server.listen_address)) |stream| stream.close() else |_| {}
    self.thread.join();
    self.server.deinit();
    for (self.requests.items) |item| {
        self.gpa.free(item.method);
        self.gpa.free(item.path);
        for (item.headers) |line| self.gpa.free(line);
        self.gpa.free(item.headers);
        self.gpa.free(item.body);
    }
    self.requests.deinit(self.gpa);
    self.responses.deinit(self.gpa);
    self.gpa.free(self.url);
    self.gpa.destroy(self);
}

/// Queues a response. Without one, the server answers 200 with "{}".
pub fn respond(self: *FakeServer, response: Response) void {
    self.mutex.lock();
    defer self.mutex.unlock();
    self.responses.append(self.gpa, response) catch @panic("OOM");
}

/// "METHOD /path" of each request so far.
pub fn calls(self: *FakeServer, arena: Allocator) ![]const []const u8 {
    self.mutex.lock();
    defer self.mutex.unlock();
    const result = try arena.alloc([]const u8, self.requests.items.len);
    for (self.requests.items, result) |item, *call| {
        call.* = try std.fmt.allocPrint(arena, "{s} {s}", .{ item.method, item.path });
    }
    return result;
}

pub fn requestCount(self: *FakeServer) usize {
    self.mutex.lock();
    defer self.mutex.unlock();
    return self.requests.items.len;
}

pub fn getRequest(self: *FakeServer, index: usize) Request {
    self.mutex.lock();
    defer self.mutex.unlock();
    return self.requests.items[index];
}

fn serve(self: *FakeServer) void {
    while (true) {
        const connection = self.server.accept() catch return;
        defer connection.stream.close();
        if (self.stopping.load(.acquire)) return;
        self.handle(connection.stream) catch {};
    }
}

fn handle(self: *FakeServer, stream: std.net.Stream) !void {
    var read_buffer: [16 * 1024]u8 = undefined;
    var stream_reader = stream.reader(&read_buffer);
    const in = stream_reader.interface();

    const request_line = try dupeLine(self.gpa, try in.takeDelimiterInclusive('\n'));
    defer self.gpa.free(request_line);
    var parts = std.mem.splitScalar(u8, request_line, ' ');
    const method = try self.gpa.dupe(u8, parts.next() orelse return error.BadRequest);
    errdefer self.gpa.free(method);
    const path = try self.gpa.dupe(u8, parts.next() orelse return error.BadRequest);
    errdefer self.gpa.free(path);

    var headers: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (headers.items) |line| self.gpa.free(line);
        headers.deinit(self.gpa);
    }
    var content_length: usize = 0;
    while (true) {
        const line = try dupeLine(self.gpa, try in.takeDelimiterInclusive('\n'));
        if (line.len == 0) {
            self.gpa.free(line);
            break;
        }
        try headers.append(self.gpa, line);
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        if (std.ascii.eqlIgnoreCase(line[0..colon], "content-length")) {
            content_length = try std.fmt.parseInt(usize, std.mem.trim(u8, line[colon + 1 ..], " "), 10);
        }
    }
    const body = try self.gpa.dupe(u8, try in.take(content_length));
    errdefer self.gpa.free(body);
    const header_lines = try headers.toOwnedSlice(self.gpa);

    const response = response: {
        self.mutex.lock();
        defer self.mutex.unlock();
        try self.requests.append(self.gpa, .{ .method = method, .path = path, .headers = header_lines, .body = body });
        break :response if (self.responses.items.len > 0) self.responses.orderedRemove(0) else Response{};
    };

    if (response.delay_ms > 0) std.Thread.sleep(response.delay_ms * std.time.ns_per_ms);
    var write_buffer: [4096]u8 = undefined;
    var stream_writer = stream.writer(&write_buffer);
    const out = &stream_writer.interface;
    try out.print("HTTP/1.1 {d} {s}\r\n", .{
        response.status,
        (std.meta.intToEnum(std.http.Status, response.status) catch std.http.Status.teapot).phrase() orelse "Unknown",
    });
    for (response.headers) |header| try out.print("{s}: {s}\r\n", .{ header.name, header.value });
    try out.print(
        "Content-Type: application/json\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n",
        .{response.body.len},
    );
    try out.writeAll(response.body);
    try out.flush();
}

fn dupeLine(gpa: Allocator, line: []const u8) ![]const u8 {
    return gpa.dupe(u8, std.mem.trimRight(u8, line, "\r\n"));
}
