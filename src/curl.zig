//! HTTP through the system libcurl on macOS: OS updates keep its TLS patched, and leaving out Zig's
//! TLS halves the binary. Loaded with dlopen, not linked, so the build needs no macOS SDK.

const std = @import("std");
const Allocator = std.mem.Allocator;

const library_path = "/usr/lib/libcurl.4.dylib";

const Handle = opaque {};
const Slist = opaque {};
const DataCallback = *const fn ([*]const u8, usize, usize, *anyopaque) callconv(.c) usize;

const Api = struct {
    global_init: *const fn (c_long) callconv(.c) c_int,
    easy_init: *const fn () callconv(.c) ?*Handle,
    easy_reset: *const fn (*Handle) callconv(.c) void,
    easy_cleanup: *const fn (*Handle) callconv(.c) void,
    easy_setopt: *const fn (*Handle, c_int, ...) callconv(.c) c_int,
    easy_perform: *const fn (*Handle) callconv(.c) c_int,
    easy_getinfo: *const fn (*Handle, c_int, ...) callconv(.c) c_int,
    slist_append: *const fn (?*Slist, [*:0]const u8) callconv(.c) ?*Slist,
    slist_free_all: *const fn (?*Slist) callconv(.c) void,
};

// From curl/curl.h.
const opt = struct {
    const writedata = 10001;
    const url = 10002;
    const proxy = 10004;
    const postfields = 10015;
    const useragent = 10018;
    const httpheader = 10023;
    const headerdata = 10029;
    const customrequest = 10036;
    const nobody = 44;
    const post = 47;
    const postfieldsize = 60;
    const nosignal = 99;
    const timeout_ms = 155;
    const writefunction = 20011;
    const headerfunction = 20079;
    const protocols_str = 10318;
};
const info_response_code = 0x200000 + 2;
const global_all = 3;
const e = struct {
    const ok = 0;
    const unsupported_protocol = 1;
    const url_malformat = 3;
    const write_error = 23;
    const out_of_memory = 27;
    const operation_timedout = 28;
};

var api: ?Api = null;
var load_once = std.once(load);

fn load() void {
    const lib = std.c.dlopen(library_path, .{ .NOW = true }) orelse return;
    var result: Api = undefined;
    inline for (@typeInfo(Api).@"struct".fields) |field| {
        const symbol = std.c.dlsym(lib, "curl_" ++ field.name) orelse return;
        @field(result, field.name) = @ptrCast(@alignCast(symbol));
    }
    if (result.global_init(global_all) != e.ok) return;
    api = result;
}

pub const Request = struct {
    method: []const u8,
    url: [:0]const u8,
    headers: []const [:0]const u8,
    user_agent: [:0]const u8,
    body: ?[]const u8,
    timeout_ms: u32,
    max_response_size: usize,
};

pub const Response = struct {
    status: u16,
    retry_after: ?f64,
    body: []const u8,
};

pub const Error = error{
    OutOfMemory,
    Unavailable,
    InvalidUrl,
    TimedOut,
    ResponseTooLarge,
    ConnectionFailed,
};

/// One handle for all requests, so libcurl can reuse the connection.
pub const Session = struct {
    handle: ?*Handle = null,

    pub fn deinit(session: *Session) void {
        if (session.handle) |handle| api.?.easy_cleanup(handle);
        session.handle = null;
    }

    pub fn send(session: *Session, arena: Allocator, request: Request) Error!Response {
        load_once.call();
        const c = api orelse return error.Unavailable;
        const handle = session.handle orelse init: {
            session.handle = c.easy_init() orelse return error.OutOfMemory;
            break :init session.handle.?;
        };
        c.easy_reset(handle);

        var headers: ?*Slist = null;
        defer c.slist_free_all(headers);
        for (request.headers) |line| headers = c.slist_append(headers, line) orelse return error.OutOfMemory;
        // Otherwise libcurl waits for "100 Continue" before sending a large body.
        headers = c.slist_append(headers, "Expect:") orelse return error.OutOfMemory;

        var sink: Sink = .{ .arena = arena, .limit = request.max_response_size };
        const method = try arena.dupeZ(u8, request.method);

        try check(c.easy_setopt(handle, opt.url, request.url.ptr));
        try check(c.easy_setopt(handle, opt.protocols_str, @as([*:0]const u8, "http,https")));
        // Like std.http.Client: ignore proxy env vars, and don't follow redirects so the token stays
        // on this host.
        try check(c.easy_setopt(handle, opt.proxy, @as([*:0]const u8, "")));
        try check(c.easy_setopt(handle, opt.nosignal, @as(c_long, 1)));
        try check(c.easy_setopt(handle, opt.timeout_ms, @as(c_long, request.timeout_ms)));
        try check(c.easy_setopt(handle, opt.useragent, request.user_agent.ptr));
        try check(c.easy_setopt(handle, opt.httpheader, headers));
        try check(c.easy_setopt(handle, opt.writefunction, @as(DataCallback, Sink.write)));
        try check(c.easy_setopt(handle, opt.writedata, &sink));
        try check(c.easy_setopt(handle, opt.headerfunction, @as(DataCallback, Sink.header)));
        try check(c.easy_setopt(handle, opt.headerdata, &sink));
        if (request.body) |body| {
            try check(c.easy_setopt(handle, opt.post, @as(c_long, 1)));
            try check(c.easy_setopt(handle, opt.postfieldsize, @as(c_long, @intCast(body.len))));
            try check(c.easy_setopt(handle, opt.postfields, body.ptr));
        } else if (std.mem.eql(u8, request.method, "HEAD")) {
            try check(c.easy_setopt(handle, opt.nobody, @as(c_long, 1)));
        }
        if (!std.mem.eql(u8, request.method, "GET") and !std.mem.eql(u8, request.method, "POST")) {
            try check(c.easy_setopt(handle, opt.customrequest, method.ptr));
        }

        const code = c.easy_perform(handle);
        if (sink.out_of_memory) return error.OutOfMemory;
        if (sink.too_large) return error.ResponseTooLarge;
        try check(code);

        var status: c_long = 0;
        try check(c.easy_getinfo(handle, info_response_code, &status));
        return .{
            .status = std.math.cast(u16, status) orelse return error.ConnectionFailed,
            .retry_after = sink.retry_after,
            .body = sink.body.items,
        };
    }
};

fn check(code: c_int) Error!void {
    return switch (code) {
        e.ok => {},
        e.unsupported_protocol, e.url_malformat => error.InvalidUrl,
        e.out_of_memory => error.OutOfMemory,
        e.operation_timedout => error.TimedOut,
        else => error.ConnectionFailed,
    };
}

const Sink = struct {
    arena: Allocator,
    limit: usize,
    body: std.ArrayList(u8) = .empty,
    retry_after: ?f64 = null,
    too_large: bool = false,
    out_of_memory: bool = false,

    fn write(data: [*]const u8, size: usize, count: usize, context: *anyopaque) callconv(.c) usize {
        const sink: *Sink = @ptrCast(@alignCast(context));
        const bytes = data[0 .. size * count];
        if (sink.body.items.len + bytes.len > sink.limit) {
            sink.too_large = true;
            return 0;
        }
        sink.body.appendSlice(sink.arena, bytes) catch {
            sink.out_of_memory = true;
            return 0;
        };
        return bytes.len;
    }

    fn header(data: [*]const u8, size: usize, count: usize, context: *anyopaque) callconv(.c) usize {
        const sink: *Sink = @ptrCast(@alignCast(context));
        const line = data[0 .. size * count];
        // Another response follows, e.g. after "100 Continue".
        if (std.mem.startsWith(u8, line, "HTTP/")) sink.retry_after = null;
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse return line.len;
        if (std.ascii.eqlIgnoreCase(line[0..colon], "retry-after")) {
            sink.retry_after = std.fmt.parseFloat(f64, std.mem.trim(u8, line[colon + 1 ..], " \r\n")) catch null;
        }
        return line.len;
    }
};
