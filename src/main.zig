const std = @import("std");
const cli = @import("cli.zig");

pub fn main() u8 {
    var debug_allocator: std.heap.DebugAllocator(.{}) = .init;
    defer _ = debug_allocator.deinit();
    const gpa = if (@import("builtin").mode == .Debug) debug_allocator.allocator() else std.heap.smp_allocator;

    const argv = std.process.argsAlloc(gpa) catch return outOfMemory();
    defer std.process.argsFree(gpa, argv);
    const api_key = getEnv(gpa, "REMOTEBROWSER_API_KEY") catch return outOfMemory();
    defer if (api_key) |value| gpa.free(value);
    const base_url = getEnv(gpa, "REMOTEBROWSER_URL") catch return outOfMemory();
    defer if (base_url) |value| gpa.free(value);

    var out_buffer: [4096]u8 = undefined;
    var err_buffer: [1024]u8 = undefined;
    var out = std.fs.File.stdout().writer(&out_buffer);
    var err = std.fs.File.stderr().writer(&err_buffer);
    const args: []const []const u8 = argv[1..];
    return cli.run(gpa, args, .{ .api_key = api_key, .base_url = base_url }, &out.interface, &err.interface);
}

fn getEnv(gpa: std.mem.Allocator, name: []const u8) error{OutOfMemory}!?[]u8 {
    return std.process.getEnvVarOwned(gpa, name) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.EnvironmentVariableNotFound, error.InvalidWtf8 => null,
    };
}

fn outOfMemory() u8 {
    std.fs.File.stderr().writeAll(cli.prog ++ ": Out of memory.\n") catch {};
    return 1;
}
