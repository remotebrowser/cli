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
    const config_dir = configDir(gpa) catch return outOfMemory();
    defer if (config_dir) |value| gpa.free(value);
    var host_buffer: [256]u8 = undefined;
    const device_name = hostName(&host_buffer);

    var out_buffer: [4096]u8 = undefined;
    var err_buffer: [1024]u8 = undefined;
    var out = std.fs.File.stdout().writer(&out_buffer);
    var err = std.fs.File.stderr().writer(&err_buffer);
    const args: []const []const u8 = argv[1..];
    return cli.run(gpa, args, .{
        .api_key = api_key,
        .base_url = base_url,
        .config_dir = config_dir,
        .device_name = device_name,
    }, &out.interface, &err.interface);
}

fn getEnv(gpa: std.mem.Allocator, name: []const u8) error{OutOfMemory}!?[]u8 {
    return std.process.getEnvVarOwned(gpa, name) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.EnvironmentVariableNotFound, error.InvalidWtf8 => null,
    };
}

/// REMOTEBROWSER_CONFIG_DIR, or the usual place for settings on each OS.
fn configDir(gpa: std.mem.Allocator) error{OutOfMemory}!?[]u8 {
    if (try getEnv(gpa, "REMOTEBROWSER_CONFIG_DIR")) |dir| {
        if (dir.len > 0) return dir;
        gpa.free(dir);
    }
    const builtin = @import("builtin");
    const base_name, const parts: []const []const u8 = switch (builtin.os.tag) {
        .windows => .{ "APPDATA", &.{"remotebrowser"} },
        .macos => .{ "HOME", &.{ "Library", "Application Support", "remotebrowser" } },
        else => xdg: {
            if (try getEnv(gpa, "XDG_CONFIG_HOME")) |xdg| {
                defer gpa.free(xdg);
                // The XDG spec says to ignore a relative path.
                if (std.fs.path.isAbsolute(xdg)) return try std.fs.path.join(gpa, &.{ xdg, "remotebrowser" });
            }
            break :xdg .{ "HOME", &.{ ".config", "remotebrowser" } };
        },
    };
    const base = try getEnv(gpa, base_name) orelse return null;
    defer gpa.free(base);
    if (base.len == 0) return null;
    var all: [4][]const u8 = undefined;
    all[0] = base;
    @memcpy(all[1 .. parts.len + 1], parts);
    return try std.fs.path.join(gpa, all[0 .. parts.len + 1]);
}

fn hostName(buffer: *[256]u8) ?[]const u8 {
    if (@import("builtin").os.tag == .windows) return null;
    return std.posix.gethostname(buffer[0..std.posix.HOST_NAME_MAX]) catch null;
}

fn outOfMemory() u8 {
    std.fs.File.stderr().writeAll(cli.prog ++ ": Out of memory.\n") catch {};
    return 1;
}
