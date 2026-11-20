//! The `remotebrowser` command line: parses the arguments, calls the API, and prints the result.

const std = @import("std");
const build_options = @import("build_options");
const Client = @import("Client.zig");

const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
const json = std.json;

pub const prog = "remotebrowser";
pub const version = build_options.version;

const description = "Manage browsers on Remote Browser from the command line.";

const epilog =
    \\environment:
    \\  REMOTEBROWSER_API_KEY  API key (required)
    \\  REMOTEBROWSER_URL      base URL of the Remote Browser API (required)
    \\
    \\The CDP endpoint printed by "connect" needs the API key in the header
    \\"Authorization: Bearer $REMOTEBROWSER_API_KEY".
    \\
;

const main_usage = "[-h] [-v] [--json] <command> ...";

pub const Options = struct {
    /// From REMOTEBROWSER_API_KEY.
    api_key: ?[]const u8 = null,
    /// From REMOTEBROWSER_URL.
    base_url: ?[]const u8 = null,
    timeout_ms: u32 = Client.default_timeout_ms,
    max_retries: u32 = Client.default_max_retries,
    /// Seconds between the status checks of `create --wait`.
    poll_interval: f64 = 1.0,
    /// Replaces the waits between retries and status checks; tests use it to skip them.
    sleep: ?*const fn (seconds: f64) void = null,
};

/// Runs the CLI with the arguments that follow the program name, and returns the exit code:
/// 0 on success, 1 when the API call fails, and 2 for a usage error.
pub fn run(gpa: Allocator, argv: []const []const u8, options: Options, out: *Writer, err: *Writer) u8 {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    var cli: Cli = .{ .gpa = gpa, .arena = arena_state.allocator(), .options = options, .out = out, .err = err };
    defer if (cli.api) |*api| api.deinit();
    const code = cli.main(argv);
    out.flush() catch {};
    err.flush() catch {};
    return code;
}

const Failure = error{
    /// A usage error; `Cli.message` tells why and `Cli.usage_of` names the command.
    Usage,
    /// An invalid argument that is not a usage error, such as an empty browser id.
    Invalid,
    /// The command failed; `Cli.message` tells why.
    Failed,
    ApiFailed,
    OutOfMemory,
    WriteFailed,
};

const OptionKind = enum { flag, string, int };

const Option = struct {
    name: []const u8,
    dest: []const u8,
    kind: OptionKind = .string,
    metavar: []const u8 = "",
    help: []const u8,
};

const Command = struct {
    /// A subcommand includes its parent, such as "config set".
    name: []const u8,
    aliases: []const []const u8 = &.{},
    help: []const u8,
    usage: []const u8,
    options: []const Option = &.{},
    /// The name of the positional argument, if any.
    positional: ?[]const u8 = null,
    /// Whether the positional argument takes one or more values.
    many: bool = false,
    handler: *const fn (*Cli, *const Args) Failure!void,
};

const json_option: Option = .{ .name = "--json", .dest = "json", .kind = .flag, .help = "print the raw JSON response" };

const commands = [_]Command{
    .{
        .name = "create",
        .help = "launch a browser and print its id",
        .usage = "[-h] [--json] [--name NAME] [--description DESCRIPTION] [--os OS] [--browser BROWSER] " ++
            "[--screen-resolution RES] [--screen-scale PERCENT] [--proxy URL] [--wait]",
        .options = &.{
            .{ .name = "--name", .dest = "name", .metavar = "NAME", .help = "1-80 characters, random if omitted" },
            .{
                .name = "--description",
                .dest = "description",
                .metavar = "DESCRIPTION",
                .help = "up to 140 characters",
            },
            .{
                .name = "--os",
                .dest = "os",
                .metavar = "OS",
                .help = "debian-13, ubuntu-26.04, fedora-44, windows-11, ...",
            },
            .{ .name = "--browser", .dest = "browser", .metavar = "BROWSER", .help = "chromium or chrome" },
            .{
                .name = "--screen-resolution",
                .dest = "screen_resolution",
                .metavar = "RES",
                .help = "full-hd, wuxga, qhd or 4k",
            },
            .{
                .name = "--screen-scale",
                .dest = "screen_scale",
                .kind = .int,
                .metavar = "PERCENT",
                .help = "100, 125, 150, 175 or 200",
            },
            .{ .name = "--proxy", .dest = "proxy", .metavar = "URL", .help = "http://, socks4:// or socks5:// URL" },
            .{ .name = "--wait", .dest = "wait", .kind = .flag, .help = "wait until the browser is running" },
        },
        .handler = create,
    },
    .{
        .name = "list",
        .aliases = &.{"ls"},
        .help = "print the ids of the starting and running browsers",
        .usage = "[-h] [--json]",
        .handler = list,
    },
    .{
        .name = "get",
        .aliases = &.{"info"},
        .help = "show the details of a browser",
        .usage = "[-h] [--json] id",
        .positional = "id",
        .handler = get,
    },
    .{
        .name = "delete",
        .aliases = &.{"rm"},
        .help = "terminate browsers (cannot be undone)",
        .usage = "[-h] [--json] id [id ...]",
        .positional = "id",
        .many = true,
        .handler = changeStatus,
    },
    .{
        .name = "suspend",
        .help = "suspend browsers",
        .usage = "[-h] [--json] id [id ...]",
        .positional = "id",
        .many = true,
        .handler = changeStatus,
    },
    .{
        .name = "resume",
        .help = "resume browsers",
        .usage = "[-h] [--json] id [id ...]",
        .positional = "id",
        .many = true,
        .handler = changeStatus,
    },
    .{
        .name = "connect",
        .help = "print the CDP WebSocket URL of a browser",
        .usage = "[-h] [--json] id",
        .positional = "id",
        .handler = connect,
    },
    .{
        .name = "config get",
        .help = "show the configuration of a browser",
        .usage = "[-h] [--json] id",
        .positional = "id",
        .handler = configGet,
    },
    .{
        .name = "config set",
        .help = "change the configuration of a browser",
        .usage = "[-h] [--json] (--proxy URL | --no-proxy) id",
        .options = &.{
            .{
                .name = "--proxy",
                .dest = "proxy",
                .metavar = "URL",
                .help = "set the proxy (closes all open connections)",
            },
            .{ .name = "--no-proxy", .dest = "no_proxy", .kind = .flag, .help = "remove the proxy" },
        },
        .positional = "id",
        .handler = configSet,
    },
};

const config_help = "show or change the configuration of a browser";
const config_usage = "[-h] <command> ...";
const help_help = "show this help";

fn findCommand(name: []const u8) ?*const Command {
    for (&commands) |*command| {
        if (std.mem.eql(u8, command.name, name)) return command;
        for (command.aliases) |alias| {
            if (std.mem.eql(u8, alias, name)) return command;
        }
    }
    return null;
}

const Args = struct {
    command: *const Command,
    values: std.ArrayList(Value) = .empty,
    positionals: std.ArrayList([]const u8) = .empty,

    const Value = struct { dest: []const u8, value: []const u8 };

    /// The last value wins when an option is given more than once.
    fn get(args: *const Args, dest: []const u8) ?[]const u8 {
        var i = args.values.items.len;
        while (i > 0) {
            i -= 1;
            if (std.mem.eql(u8, args.values.items[i].dest, dest)) return args.values.items[i].value;
        }
        return null;
    }

    fn flag(args: *const Args, dest: []const u8) bool {
        const value = args.get(dest) orelse return false;
        return std.mem.eql(u8, value, "true");
    }
};

const Cli = struct {
    gpa: Allocator,
    arena: Allocator,
    options: Options,
    out: *Writer,
    err: *Writer,
    json_output: bool = false,
    api: ?Client = null,
    message: []const u8 = "",
    /// Which usage line to print with a usage error: "" for the program, or "config".
    usage_of: []const u8 = "",
    usage: []const u8 = main_usage,

    fn main(cli: *Cli, argv: []const []const u8) u8 {
        cli.dispatch(argv) catch |err| switch (err) {
            error.Usage => {
                const name = if (cli.usage_of.len == 0) prog else prog ++ " ";
                cli.err.print("usage: {s}{s} {s}\n{s}{s}: error: {s}\n", .{
                    name, cli.usage_of, cli.usage, name, cli.usage_of, cli.message,
                }) catch {};
                return 2;
            },
            error.Invalid => {
                cli.printError("{s}", .{cli.message});
                return 2;
            },
            error.Failed => {
                cli.printError("{s}", .{cli.message});
                return 1;
            },
            error.ApiFailed => {
                cli.printError("{s}", .{cli.api.?.errorMessage()});
                return 1;
            },
            error.OutOfMemory => {
                cli.printError("Out of memory.", .{});
                return 1;
            },
            error.WriteFailed => return 1,
        };
        return 0;
    }

    fn printError(cli: *Cli, comptime format: []const u8, args: anytype) void {
        cli.err.print(prog ++ ": " ++ format ++ "\n", args) catch {};
        cli.err.flush() catch {};
    }

    fn usageError(cli: *Cli, comptime format: []const u8, args: anytype) Failure {
        cli.message = try std.fmt.allocPrint(cli.arena, format, args);
        return error.Usage;
    }

    fn fail(cli: *Cli, comptime format: []const u8, args: anytype) Failure {
        cli.message = try std.fmt.allocPrint(cli.arena, format, args);
        return error.Failed;
    }

    fn dispatch(cli: *Cli, argv: []const []const u8) Failure!void {
        var i: usize = 0;
        while (i < argv.len) : (i += 1) {
            const arg = argv[i];
            if (isHelp(arg)) return cli.printMainHelp();
            if (std.mem.eql(u8, arg, "-v") or std.mem.eql(u8, arg, "--version")) {
                return cli.line(version);
            }
            if (std.mem.eql(u8, arg, "--json")) {
                cli.json_output = true;
            } else if (isOption(arg)) {
                return cli.usageError("unrecognized arguments: {s}", .{arg});
            } else break;
        }
        if (i == argv.len) return cli.printMainHelp();

        const name = argv[i];
        const rest = argv[i + 1 ..];
        if (std.mem.eql(u8, name, "help")) return cli.help(rest);
        if (std.mem.eql(u8, name, "config")) return cli.config(rest);
        const command = findCommand(name) orelse {
            if (std.mem.startsWith(u8, name, "config ")) return cli.usageError("invalid command '{s}'", .{name});
            return cli.usageError("invalid command '{s}' (run '{s} help')", .{ name, prog });
        };
        return cli.runCommand(command, rest);
    }

    fn help(cli: *Cli, argv: []const []const u8) Failure!void {
        if (argv.len == 0) return cli.printMainHelp();
        if (argv.len == 1) {
            if (std.mem.eql(u8, argv[0], "config")) return cli.printConfigHelp();
            if (findCommand(argv[0])) |command| return cli.printCommandHelp(command);
        }
        cli.usage_of = "help";
        cli.usage = "[<command>]";
        const joined = std.mem.join(cli.arena, " ", argv) catch return error.OutOfMemory;
        return cli.usageError("invalid command '{s}'", .{joined});
    }

    fn config(cli: *Cli, argv: []const []const u8) Failure!void {
        cli.usage_of = "config";
        cli.usage = config_usage;
        for (argv, 0..) |arg, i| {
            if (isHelp(arg)) return cli.printConfigHelp();
            if (std.mem.eql(u8, arg, "--json")) {
                cli.json_output = true;
                continue;
            }
            if (isOption(arg)) return cli.usageError("unrecognized arguments: {s}", .{arg});
            const full_name = try std.mem.concat(cli.arena, u8, &.{ "config ", arg });
            const command = findCommand(full_name) orelse
                return cli.usageError("invalid command '{s}' (choose from 'get', 'set')", .{arg});
            return cli.runCommand(command, argv[i + 1 ..]);
        }
        return cli.usageError("the following arguments are required: <command>", .{});
    }

    fn runCommand(cli: *Cli, command: *const Command, argv: []const []const u8) Failure!void {
        cli.usage_of = command.name;
        cli.usage = command.usage;
        var args: Args = .{ .command = command };
        var only_positionals = false;
        var i: usize = 0;
        while (i < argv.len) : (i += 1) {
            const arg = argv[i];
            if (only_positionals or !isOption(arg)) {
                try args.positionals.append(cli.arena, arg);
                continue;
            }
            if (std.mem.eql(u8, arg, "--")) {
                only_positionals = true;
                continue;
            }
            if (isHelp(arg)) return cli.printCommandHelp(command);
            if (std.mem.eql(u8, arg, "--json")) {
                cli.json_output = true;
                continue;
            }
            const equals = std.mem.indexOfScalar(u8, arg, '=');
            const name = arg[0 .. equals orelse arg.len];
            const option = findOption(command, name) orelse
                return cli.usageError("unrecognized arguments: {s}", .{arg});
            const value = switch (option.kind) {
                .flag => flag: {
                    if (equals != null) return cli.usageError("argument {s}: does not take a value", .{name});
                    break :flag "true";
                },
                .string, .int => value: {
                    if (equals) |at| break :value arg[at + 1 ..];
                    if (i + 1 == argv.len or isOption(argv[i + 1])) {
                        return cli.usageError("argument {s}: expected one argument", .{name});
                    }
                    i += 1;
                    break :value argv[i];
                },
            };
            if (option.kind == .int) {
                _ = std.fmt.parseInt(i64, value, 10) catch
                    return cli.usageError("argument {s}: invalid int value: '{s}'", .{ name, value });
            }
            try args.values.append(cli.arena, .{ .dest = option.dest, .value = value });
        }

        if (command.positional) |positional| {
            if (args.positionals.items.len == 0) {
                return cli.usageError("the following arguments are required: {s}", .{positional});
            }
            if (!command.many and args.positionals.items.len > 1) {
                return cli.usageError("unrecognized arguments: {s}", .{
                    try std.mem.join(cli.arena, " ", args.positionals.items[1..]),
                });
            }
        } else if (args.positionals.items.len > 0) {
            return cli.usageError("unrecognized arguments: {s}", .{
                try std.mem.join(cli.arena, " ", args.positionals.items),
            });
        }
        return command.handler(cli, &args);
    }

    fn findOption(command: *const Command, name: []const u8) ?*const Option {
        for (command.options) |*option| {
            if (std.mem.eql(u8, option.name, name)) return option;
        }
        return null;
    }

    fn printMainHelp(cli: *Cli) Failure!void {
        const w = cli.out;
        try w.print("usage: {s} {s}\n\n{s}\n\ncommands:\n", .{ prog, main_usage, description });
        for (commands) |command| {
            if (std.mem.startsWith(u8, command.name, "config ")) continue;
            var name_buffer: [64]u8 = undefined;
            var name: Writer = .fixed(&name_buffer);
            try name.writeAll(command.name);
            for (command.aliases) |alias| try name.print(" ({s})", .{alias});
            try printHelpLine(w, name.buffered(), command.help);
        }
        try printHelpLine(w, "config", config_help);
        try printHelpLine(w, "help", help_help);
        try w.writeAll("\noptions:\n");
        try printHelpLine(w, "-h, --help", "show this help message and exit");
        try printHelpLine(w, "-v, --version", "show the version and exit");
        try printHelpLine(w, json_option.name, json_option.help);
        try w.print("\n{s}", .{epilog});
        try w.flush();
    }

    fn printConfigHelp(cli: *Cli) Failure!void {
        const w = cli.out;
        try w.print("usage: {s} config {s}\n\n{s}\n\ncommands:\n", .{ prog, config_usage, config_help });
        for (commands) |command| {
            if (std.mem.startsWith(u8, command.name, "config ")) {
                try printHelpLine(w, command.name["config ".len..], command.help);
            }
        }
        try w.writeAll("\noptions:\n");
        try printHelpLine(w, "-h, --help", "show this help message and exit");
        try w.flush();
    }

    fn printCommandHelp(cli: *Cli, command: *const Command) Failure!void {
        const w = cli.out;
        try w.print("usage: {s} {s} {s}\n\n{s}\n", .{ prog, command.name, command.usage, command.help });
        if (command.aliases.len > 0) {
            try w.print("\naliases: {s}\n", .{try std.mem.join(cli.arena, ", ", command.aliases)});
        }
        if (command.positional) |positional| {
            try w.writeAll("\npositional arguments:\n");
            try printHelpLine(w, positional, if (command.many) "browser ids" else "browser id");
        }
        try w.writeAll("\noptions:\n");
        try printHelpLine(w, "-h, --help", "show this help message and exit");
        try printHelpLine(w, json_option.name, json_option.help);
        for (command.options) |option| {
            const name = if (option.metavar.len == 0)
                option.name
            else
                try std.mem.concat(cli.arena, u8, &.{ option.name, " ", option.metavar });
            try printHelpLine(w, name, option.help);
        }
        try w.flush();
    }

    fn line(cli: *Cli, text: []const u8) Failure!void {
        try cli.out.print("{s}\n", .{text});
        try cli.out.flush();
    }

    fn printJson(cli: *Cli, value: anytype) Failure!void {
        try json.Stringify.value(value, .{ .whitespace = .indent_2 }, cli.out);
        try cli.out.writeByte('\n');
        try cli.out.flush();
    }

    /// Prints "key: value" lines with the values aligned, "-" for null, and JSON for non-strings.
    fn printFields(cli: *Cli, fields: []const Field) Failure!void {
        var width: usize = 0;
        for (fields) |field| width = @max(width, field.key.len);
        for (fields) |field| {
            try cli.out.print("{s}:", .{field.key});
            try cli.out.splatByteAll(' ', width - field.key.len + 1);
            switch (field.value) {
                .null => try cli.out.writeAll("-"),
                .string => |text| try cli.out.writeAll(text),
                else => try json.Stringify.value(field.value, .{}, cli.out),
            }
            try cli.out.writeByte('\n');
        }
        try cli.out.flush();
    }

    fn client(cli: *Cli) Failure!*Client {
        if (cli.api) |*api| return api;
        const api_key = cli.options.api_key orelse "";
        if (api_key.len == 0) {
            return cli.fail("The REMOTEBROWSER_API_KEY environment variable is missing or empty.", .{});
        }
        const base_url = cli.options.base_url orelse "";
        if (base_url.len == 0) return cli.fail("The REMOTEBROWSER_URL environment variable is missing or empty.", .{});
        cli.api = .init(cli.gpa, cli.arena, .{
            .api_key = api_key,
            .base_url = base_url,
            .timeout_ms = cli.options.timeout_ms,
            .max_retries = cli.options.max_retries,
        });
        if (cli.options.sleep) |sleep_fn| cli.api.?.sleep = sleep_fn;
        return &cli.api.?;
    }

    fn sleep(cli: *Cli, seconds: f64) void {
        if (cli.options.sleep) |sleep_fn| return sleep_fn(seconds);
        std.Thread.sleep(@intFromFloat(seconds * std.time.ns_per_s));
    }

    fn browserPath(cli: *Cli, id: []const u8, suffix: []const u8) Failure![]const u8 {
        if (id.len == 0) {
            cli.message = "A browser id is required.";
            return error.Invalid;
        }
        const escaped = try Client.escapeSegment(cli.arena, id);
        return std.mem.concat(cli.arena, u8, &.{ "/api/v1/browsers/", escaped, suffix });
    }

    /// On an unexpected shape, shows the whole response so the user can see what the server sent.
    fn stringField(cli: *Cli, value: json.Value, key: []const u8) Failure![]const u8 {
        if (value == .object) {
            if (value.object.get(key)) |field| {
                if (field == .string) return field.string;
            }
        }
        return cli.fail("Unexpected response: {f}", .{json.fmt(value, .{})});
    }
};

const Field = struct { key: []const u8, value: json.Value };

fn isHelp(arg: []const u8) bool {
    return std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help");
}

fn isOption(arg: []const u8) bool {
    return arg.len > 1 and arg[0] == '-';
}

fn printHelpLine(w: *Writer, name: []const u8, text: []const u8) Writer.Error!void {
    const column = 24;
    try w.print("  {s}", .{name});
    if (name.len + 2 < column) {
        try w.splatByteAll(' ', column - name.len - 2);
    } else {
        try w.writeByte('\n');
        try w.splatByteAll(' ', column);
    }
    try w.print("{s}\n", .{text});
}

fn create(cli: *Cli, args: *const Args) Failure!void {
    const api = try cli.client();

    var body: Writer.Allocating = .init(cli.arena);
    var s: json.Stringify = .{ .writer = &body.writer };
    try s.beginObject();
    for ([_][]const u8{ "name", "description", "os", "browser", "screen_resolution", "screen_scale", "proxy" }) |dest| {
        const value = args.get(dest) orelse continue;
        try s.objectField(dest);
        if (std.mem.eql(u8, dest, "screen_scale")) {
            try s.write(std.fmt.parseInt(i64, value, 10) catch unreachable);
        } else {
            try s.write(value);
        }
    }
    try s.endObject();

    var result = try api.request(.POST, "/api/v1/browsers", body.written());
    var id = try cli.stringField(result, "browser_id");
    if (args.flag("wait")) {
        var status = try cli.stringField(result, "status");
        while (!isSettled(status)) {
            cli.sleep(cli.options.poll_interval);
            result = try api.request(.GET, try cli.browserPath(id, ""), null);
            id = try cli.stringField(result, "browser_id");
            status = try cli.stringField(result, "status");
        }
        if (!std.mem.eql(u8, status, "running")) {
            if (cli.json_output) try cli.printJson(result);
            return cli.fail("Browser {s} is {s}.", .{ id, status });
        }
    }
    if (cli.json_output) return cli.printJson(result);
    return cli.line(id);
}

/// Whether the status is final, so `create --wait` can stop polling. The API documents "starting"
/// as the status before "running", but servers may report others, such as "launched".
fn isSettled(status: []const u8) bool {
    for ([_][]const u8{ "running", "suspended", "error", "terminated" }) |settled| {
        if (std.mem.eql(u8, status, settled)) return true;
    }
    return false;
}

fn list(cli: *Cli, _: *const Args) Failure!void {
    const result = try (try cli.client()).request(.GET, "/api/v1/browsers", null);
    if (cli.json_output) return cli.printJson(result);
    if (result != .array) return cli.fail("Unexpected response: {f}", .{json.fmt(result, .{})});
    for (result.array.items) |item| {
        switch (item) {
            .string => |id| try cli.line(id),
            else => try cli.line(try json.Stringify.valueAlloc(cli.arena, item, .{})),
        }
    }
}

fn get(cli: *Cli, args: *const Args) Failure!void {
    const path = try cli.browserPath(args.positionals.items[0], "");
    const browser = try (try cli.client()).request(.GET, path, null);
    if (cli.json_output) return cli.printJson(browser);
    if (browser != .object) return cli.fail("Unexpected response: {f}", .{json.fmt(browser, .{})});

    const object = browser.object;
    var fields: std.ArrayList(Field) = .empty;
    const description_value = object.get("description") orelse .null;
    const created: json.Value = switch (object.get("creation_timestamp") orelse .null) {
        .integer => |ms| .{ .string = try isoTime(cli.arena, ms) },
        .float => |ms| .{ .string = try isoTime(cli.arena, @intFromFloat(ms)) },
        else => |value| value,
    };
    try fields.appendSlice(cli.arena, &.{
        .{ .key = "id", .value = object.get("browser_id") orelse .null },
        .{ .key = "status", .value = object.get("status") orelse .null },
        .{
            .key = "description",
            .value = if (description_value == .string and description_value.string.len == 0)
                .null
            else
                description_value,
        },
        .{ .key = "os", .value = object.get("os") orelse .null },
        .{ .key = "created", .value = created },
    });
    const shown = [_][]const u8{ "browser_id", "status", "description", "os", "creation_timestamp" };
    var it = object.iterator();
    next: while (it.next()) |entry| {
        for (shown) |key| {
            if (std.mem.eql(u8, entry.key_ptr.*, key)) continue :next;
        }
        try fields.append(cli.arena, .{ .key = entry.key_ptr.*, .value = entry.value_ptr.* });
    }
    return cli.printFields(fields.items);
}

/// Formats milliseconds since the Unix epoch as an ISO 8601 UTC time, such as 1970-01-01T00:00:00.000Z.
fn isoTime(arena: Allocator, ms: i64) Allocator.Error![]const u8 {
    if (ms < 0) return std.fmt.allocPrint(arena, "{d}", .{ms});
    const epoch_seconds: std.time.epoch.EpochSeconds = .{ .secs = @intCast(@divFloor(ms, 1000)) };
    const day = epoch_seconds.getEpochDay().calculateYearDay();
    const month_day = day.calculateMonthDay();
    const time = epoch_seconds.getDaySeconds();
    return std.fmt.allocPrint(arena, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}.{d:0>3}Z", .{
        day.year,
        month_day.month.numeric(),
        month_day.day_index + 1,
        time.getHoursIntoDay(),
        time.getMinutesIntoHour(),
        time.getSecondsIntoMinute(),
        @as(u64, @intCast(@mod(ms, 1000))),
    });
}

fn changeStatus(cli: *Cli, args: *const Args) Failure!void {
    const action = args.command.name;
    const ids = args.positionals.items;
    const method: std.http.Method = if (std.mem.eql(u8, action, "delete")) .DELETE else .POST;
    const suffix = if (std.mem.eql(u8, action, "delete")) "" else try std.mem.concat(cli.arena, u8, &.{ "/", action });

    const api = try cli.client();
    var results: std.ArrayList(json.Value) = .empty;
    var failed = false;
    for (ids) |id| {
        const result = api.request(method, try cli.browserPath(id, suffix), null) catch |err| switch (err) {
            error.ApiFailed => {
                if (ids.len == 1) return err;
                failed = true;
                cli.printError("{s}: {s}", .{ id, api.errorMessage() });
                continue;
            },
            else => return err,
        };
        try results.append(cli.arena, result);
        if (!cli.json_output) {
            const browser_id = try cli.stringField(result, "browser_id");
            const status = try cli.stringField(result, "status");
            try cli.out.print("{s} {s}\n", .{ browser_id, status });
            try cli.out.flush();
        }
    }
    if (cli.json_output) {
        if (ids.len == 1) {
            try cli.printJson(results.items[0]);
        } else {
            try cli.printJson(results.items);
        }
    }
    if (failed) return cli.fail("Could not {s} every browser.", .{action});
}

fn connect(cli: *Cli, args: *const Args) Failure!void {
    const id = args.positionals.items[0];
    const path = try cli.browserPath(id, "/cdp");
    const api = try cli.client();
    const separator = std.mem.indexOf(u8, api.base_url, "://");
    const scheme: []const u8 = if (std.mem.startsWith(u8, api.base_url, "https://")) "wss" else "ws";
    const rest = if (separator) |at| api.base_url[at + 3 ..] else api.base_url;
    const url = try std.mem.concat(cli.arena, u8, &.{ scheme, "://", rest, path });
    if (cli.json_output) return cli.printJson(.{ .browser_id = id, .url = url });
    return cli.line(url);
}

fn configGet(cli: *Cli, args: *const Args) Failure!void {
    const path = try cli.browserPath(args.positionals.items[0], "/config");
    return printConfig(cli, try (try cli.client()).request(.GET, path, null));
}

fn configSet(cli: *Cli, args: *const Args) Failure!void {
    const proxy = args.get("proxy");
    const no_proxy = args.flag("no_proxy");
    if (proxy != null and no_proxy) {
        return cli.usageError("argument --no-proxy: not allowed with argument --proxy", .{});
    }
    if (proxy == null and !no_proxy) return cli.usageError("one of the arguments --proxy --no-proxy is required", .{});

    const path = try cli.browserPath(args.positionals.items[0], "/config");
    const body = try json.Stringify.valueAlloc(cli.arena, .{ .proxy = proxy }, .{});
    return printConfig(cli, try (try cli.client()).request(.PATCH, path, body));
}

fn printConfig(cli: *Cli, config: json.Value) Failure!void {
    if (cli.json_output) return cli.printJson(config);
    if (config != .object) return cli.fail("Unexpected response: {f}", .{json.fmt(config, .{})});
    return cli.printFields(&.{
        .{ .key = "id", .value = config.object.get("browser_id") orelse .null },
        .{ .key = "proxy", .value = config.object.get("proxy") orelse .null },
    });
}

test isoTime {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectEqualStrings("1970-01-01T00:00:00.000Z", try isoTime(arena.allocator(), 0));
    try std.testing.expectEqualStrings("2026-11-24T08:30:05.042Z", try isoTime(arena.allocator(), 1795509005042));
}
