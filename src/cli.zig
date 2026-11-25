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
    \\To log in with a web browser, run "remotebrowser login URL" once per
    \\server. Commands use the server of the last login (see "switch"), or
    \\the one given with --url.
    \\
    \\environment:
    \\  REMOTEBROWSER_CONFIG_DIR  where the login is stored
    \\
    \\The CDP endpoint printed by "connect" needs the token in the header
    \\"Authorization: Bearer $(remotebrowser token)".
    \\
;

const main_usage = "[-h] [-v] [--json] [--url URL] <command> ...";

pub const Options = struct {
    /// The directory of the credentials file. Without it, the CLI cannot log in.
    config_dir: ?[]const u8 = null,
    /// Shown on the approval page of a login.
    device_name: ?[]const u8 = null,
    /// Opens a URL in the web browser; tests replace it so nothing is launched.
    open_url: *const fn (gpa: Allocator, url: []const u8) void = openUrl,
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
    /// Help for the positional argument; browser ids by default.
    positional_help: ?[]const u8 = null,
    /// Whether the positional argument takes one or more values.
    many: bool = false,
    /// Whether the positional argument may be left out.
    optional: bool = false,
    handler: *const fn (*Cli, *const Args) Failure!void,
};

const json_option: Option = .{ .name = "--json", .dest = "json", .kind = .flag, .help = "print the raw JSON response" };
const url_option: Option = .{
    .name = "--url",
    .dest = "url",
    .metavar = "URL",
    .help = "base URL of the server (default: the current login)",
};

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
        .help = "print the ids of the active browsers",
        .usage = "[-h] [--json] [url]",
        .positional = "url",
        .positional_help = "base URL of the server (default: the current login)",
        .optional = true,
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
        .name = "login",
        .help = "log in with a web browser",
        .usage = "[-h] [--days DAYS] [--no-browser] [url]",
        .positional = "url",
        .positional_help = "base URL of the server (default: the current login)",
        .optional = true,
        .options = &.{
            .{
                .name = "--days",
                .dest = "days",
                .kind = .int,
                .metavar = "DAYS",
                .help = "how long the login lasts (the server sets the maximum)",
            },
            .{ .name = "--no-browser", .dest = "no_browser", .kind = .flag, .help = "only print the URL" },
        },
        .handler = logIn,
    },
    .{
        .name = "logout",
        .help = "revoke the login to a server and delete it from this computer",
        .usage = "[-h] [url]",
        .positional = "url",
        .positional_help = "base URL of the server (default: the current login)",
        .optional = true,
        .handler = logOut,
    },
    .{
        .name = "status",
        .help = "list the logins and show which one is used",
        .usage = "[-h] [--json] [--url URL]",
        .handler = showStatus,
    },
    .{
        .name = "switch",
        .help = "choose the server that commands use by default",
        .usage = "[-h] url",
        .positional = "url",
        .positional_help = "base URL of a server you are logged in to",
        .handler = switchServer,
    },
    .{
        .name = "token",
        .help = "print the token, for the CDP Authorization header",
        .usage = "[-h] [--json] [--url URL]",
        .handler = printToken,
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

/// Commands with subcommands, such as "config get".
const Group = struct { name: []const u8, help: []const u8 };

const groups = [_]Group{
    .{ .name = "config", .help = "show or change the configuration of a browser" },
};

const group_usage = "[-h] <command> ...";
const help_help = "show this help";

fn findGroup(name: []const u8) ?*const Group {
    for (&groups) |*group| {
        if (std.mem.eql(u8, group.name, name)) return group;
    }
    return null;
}

/// The name of a subcommand without its group, or null if the command is not in the group.
fn subcommandName(group: *const Group, command: *const Command) ?[]const u8 {
    const name = command.name;
    if (name.len <= group.name.len or !std.mem.startsWith(u8, name, group.name)) return null;
    if (name[group.name.len] != ' ') return null;
    return name[group.name.len + 1 ..];
}

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
    /// From --url, which may come before or after the command.
    url_flag: ?[]const u8 = null,
    /// Whether `api` uses a saved login, to give a hint when the server rejects it.
    uses_login: bool = false,
    /// Loaded on first use; see `loadStore`.
    store: Store = .{},
    store_loaded: bool = false,
    /// Which usage line to print with a usage error: "" for the program, or a command name.
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
                const api = &cli.api.?;
                cli.printError("{s}", .{api.errorMessage()});
                const status = if (api.last_error) |e| e.status else null;
                if (status == 401 and cli.uses_login) cli.printError("Run '{s} login' to log in again.", .{prog});
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
            if (try cli.globalOption(argv, &i)) continue;
            if (isOption(arg)) return cli.usageError("unrecognized arguments: {s}", .{arg});
            break;
        }
        if (i == argv.len) return cli.printMainHelp();

        const name = argv[i];
        const rest = argv[i + 1 ..];
        if (std.mem.eql(u8, name, "help")) return cli.help(rest);
        if (findGroup(name)) |group| return cli.runGroup(group, rest);
        const command = findCommand(name) orelse {
            if (std.mem.indexOfScalar(u8, name, ' ') != null) return cli.usageError("invalid command '{s}'", .{name});
            return cli.usageError("invalid command '{s}' (run '{s} help')", .{ name, prog });
        };
        return cli.runCommand(command, rest);
    }

    fn help(cli: *Cli, argv: []const []const u8) Failure!void {
        if (argv.len == 0) return cli.printMainHelp();
        if (argv.len == 1) {
            if (findGroup(argv[0])) |group| return cli.printGroupHelp(group);
            if (findCommand(argv[0])) |command| return cli.printCommandHelp(command);
        }
        cli.usage_of = "help";
        cli.usage = "[<command>]";
        const joined = std.mem.join(cli.arena, " ", argv) catch return error.OutOfMemory;
        return cli.usageError("invalid command '{s}'", .{joined});
    }

    fn runGroup(cli: *Cli, g: *const Group, argv: []const []const u8) Failure!void {
        cli.usage_of = g.name;
        cli.usage = group_usage;
        var i: usize = 0;
        while (i < argv.len) : (i += 1) {
            const arg = argv[i];
            if (isHelp(arg)) return cli.printGroupHelp(g);
            if (try cli.globalOption(argv, &i)) continue;
            if (isOption(arg)) return cli.usageError("unrecognized arguments: {s}", .{arg});
            const full_name = try std.mem.concat(cli.arena, u8, &.{ g.name, " ", arg });
            const command = findCommand(full_name) orelse {
                var choices: std.ArrayList(u8) = .empty;
                for (&commands) |*command| {
                    const sub = subcommandName(g, command) orelse continue;
                    if (choices.items.len > 0) try choices.appendSlice(cli.arena, ", ");
                    try choices.print(cli.arena, "'{s}'", .{sub});
                }
                return cli.usageError("invalid command '{s}' (choose from {s})", .{ arg, choices.items });
            };
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
            if (try cli.globalOption(argv, &i)) continue;
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
            if (args.positionals.items.len == 0 and !command.optional) {
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

    /// Handles the options that every command takes, and returns whether `argv[i]` was one.
    fn globalOption(cli: *Cli, argv: []const []const u8, i: *usize) Failure!bool {
        const arg = argv[i.*];
        if (std.mem.eql(u8, arg, "--json")) {
            cli.json_output = true;
            return true;
        }
        if (std.mem.startsWith(u8, arg, "--url=")) {
            cli.url_flag = arg["--url=".len..];
            return true;
        }
        if (!std.mem.eql(u8, arg, "--url")) return false;
        if (i.* + 1 == argv.len or isOption(argv[i.* + 1])) {
            return cli.usageError("argument --url: expected one argument", .{});
        }
        i.* += 1;
        cli.url_flag = argv[i.*];
        return true;
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
            if (std.mem.indexOfScalar(u8, command.name, ' ') != null) continue;
            var name_buffer: [64]u8 = undefined;
            var name: Writer = .fixed(&name_buffer);
            try name.writeAll(command.name);
            for (command.aliases) |alias| try name.print(" ({s})", .{alias});
            try printHelpLine(w, name.buffered(), command.help);
        }
        for (groups) |g| try printHelpLine(w, g.name, g.help);
        try printHelpLine(w, "help", help_help);
        try w.writeAll("\noptions:\n");
        try printHelpLine(w, "-h, --help", "show this help message and exit");
        try printHelpLine(w, "-v, --version", "show the version and exit");
        try printHelpLine(w, json_option.name, json_option.help);
        try printHelpLine(w, url_option.name ++ " " ++ url_option.metavar, url_option.help);
        try w.print("\n{s}", .{epilog});
        try w.flush();
    }

    fn printGroupHelp(cli: *Cli, g: *const Group) Failure!void {
        const w = cli.out;
        try w.print("usage: {s} {s} {s}\n\n{s}\n\ncommands:\n", .{ prog, g.name, group_usage, g.help });
        for (&commands) |*command| {
            if (subcommandName(g, command)) |sub| try printHelpLine(w, sub, command.help);
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
            const text = command.positional_help orelse if (command.many) "browser ids" else "browser id";
            try printHelpLine(w, positional, text);
        }
        try w.writeAll("\noptions:\n");
        try printHelpLine(w, "-h, --help", "show this help message and exit");
        try printHelpLine(w, json_option.name, json_option.help);
        // Commands that take the server as their argument do not list --url.
        const takes_url = if (command.positional) |p| std.mem.eql(u8, p, "url") else false;
        if (!takes_url) try printHelpLine(w, url_option.name ++ " " ++ url_option.metavar, url_option.help);
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

    /// The client with the token of the login.
    fn client(cli: *Cli) Failure!*Client {
        if (cli.api) |*api| return api;
        const auth = try cli.resolveAuth();
        try cli.checkExpiry(auth);
        if (auth.expires_at) |expires_at| {
            if (expires_at - std.time.timestamp() < expiry_warning_days * std.time.s_per_day) {
                cli.printError("warning: Your login expires on {s}. Run '{s} login' to renew it.", .{
                    try isoTime(cli.arena, expires_at * std.time.ms_per_s), prog,
                });
            }
        }
        cli.uses_login = true;
        return cli.newClient(auth.base_url, auth.token);
    }

    /// Only one client exists per run, because `main` reads its error.
    fn newClient(cli: *Cli, base_url: []const u8, api_key: []const u8) *Client {
        cli.api = .init(cli.gpa, cli.arena, .{
            .api_key = api_key,
            .base_url = base_url,
            .timeout_ms = cli.options.timeout_ms,
            .max_retries = cli.options.max_retries,
        });
        if (cli.options.sleep) |sleep_fn| cli.api.?.sleep = sleep_fn;
        return &cli.api.?;
    }

    /// The server to use: --url, then the current login. Null if there is none.
    fn targetUrl(cli: *Cli) Failure!?[]const u8 {
        if (nonEmpty(cli.url_flag)) |url| return try normalizeUrl(cli.arena, url);
        return (try cli.loadStore()).current;
    }

    /// The server given as the argument of login or logout, or else the one from targetUrl.
    fn serverArgument(cli: *Cli, args: *const Args) Failure!?[]const u8 {
        if (args.positionals.items.len > 0) return try normalizeUrl(cli.arena, args.positionals.items[0]);
        return cli.targetUrl();
    }

    /// Picks the URL and the token. A token is sent only to the server that issued it.
    fn resolveAuth(cli: *Cli) Failure!Auth {
        const base_url = try cli.targetUrl() orelse {
            if ((try cli.loadStore()).servers.map.count() > 0) {
                return cli.fail("No server is chosen. Run '{s} switch URL', or use --url.", .{prog});
            }
            return cli.fail("Not logged in. Run '{s} login URL'.", .{prog});
        };
        const login = (try cli.loadStore()).servers.map.get(base_url) orelse
            return cli.fail("Not logged in to {s}. Run '{s} login {s}'.", .{ base_url, prog, base_url });
        return .{ .base_url = base_url, .token = login.token, .expires_at = login.expires_at };
    }

    fn checkExpiry(cli: *Cli, auth: Auth) Failure!void {
        const expires_at = auth.expires_at orelse return;
        if (expires_at > std.time.timestamp()) return;
        return cli.fail("Your login to {s} expired on {s}. Run '{s} login {s}'.", .{
            auth.base_url, try isoTime(cli.arena, expires_at * std.time.ms_per_s), prog, auth.base_url,
        });
    }

    fn credentialsPath(cli: *Cli) Failure![]const u8 {
        const dir = nonEmpty(cli.options.config_dir) orelse
            return cli.fail("Cannot find a directory for the login. Set REMOTEBROWSER_CONFIG_DIR.", .{});
        return std.fs.path.join(cli.arena, &.{ dir, credentials_file });
    }

    /// The saved logins; empty if there are none.
    fn loadStore(cli: *Cli) Failure!*Store {
        if (cli.store_loaded) return &cli.store;
        cli.store_loaded = true;
        if (nonEmpty(cli.options.config_dir) == null) return &cli.store;
        const path = try cli.credentialsPath();
        const raw = std.fs.cwd().readFileAlloc(cli.arena, path, 1024 * 1024) catch |err| switch (err) {
            error.FileNotFound => return &cli.store,
            error.OutOfMemory => return error.OutOfMemory,
            else => return cli.fail("Cannot read {s}: {t}", .{ path, err }),
        };
        cli.store = json.parseFromSliceLeaky(Store, cli.arena, raw, .{
            .ignore_unknown_fields = true,
            .allocate = .alloc_always,
        }) catch return cli.fail("Cannot read {s}: the file is not valid. Delete it and log in again.", .{path});
        return &cli.store;
    }

    /// Deletes the file when the last login is gone.
    fn saveStore(cli: *Cli) Failure!void {
        const path = try cli.credentialsPath();
        if (cli.store.servers.map.count() == 0) {
            std.fs.cwd().deleteFile(path) catch |err| switch (err) {
                error.FileNotFound => {},
                else => return cli.fail("Cannot delete {s}: {t}", .{ path, err }),
            };
            return;
        }
        const text = try json.Stringify.valueAlloc(cli.arena, cli.store, .{ .whitespace = .indent_2 });
        writeSecretFile(path, text) catch |err| return cli.fail("Cannot write {s}: {t}", .{ path, err });
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

const credentials_file = "credentials.json";
const expiry_warning_days = 3;

/// A login to one server.
const Login = struct {
    token: []const u8,
    /// Seconds since the Unix epoch, or null if the token does not expire.
    expires_at: ?i64 = null,
};

/// The credentials file: one login per server, keyed by the normalized base URL.
const Store = struct {
    /// The server that commands use when --url is not given.
    current: ?[]const u8 = null,
    servers: json.ArrayHashMap(Login) = .{},
};

const Auth = struct {
    base_url: []const u8,
    token: []const u8,
    expires_at: ?i64 = null,
};

fn nonEmpty(value: ?[]const u8) ?[]const u8 {
    const v = value orelse return null;
    return if (v.len == 0) null else v;
}

/// Makes URLs that differ only in case or a trailing slash use the same login.
fn normalizeUrl(arena: Allocator, url: []const u8) Allocator.Error![]const u8 {
    const result = try arena.dupe(u8, std.mem.trimRight(u8, std.mem.trim(u8, url, " "), "/"));
    const scheme_end = std.mem.indexOf(u8, result, "://") orelse return result;
    const host_end = std.mem.indexOfScalarPos(u8, result, scheme_end + 3, '/') orelse result.len;
    _ = std.ascii.lowerString(result[0..host_end], result[0..host_end]);
    return result;
}

fn isLoopback(url: []const u8) bool {
    const start = (std.mem.indexOf(u8, url, "://") orelse return false) + 3;
    const end = std.mem.indexOfScalarPos(u8, url, start, '/') orelse url.len;
    const authority = url[start..end];
    if (std.mem.startsWith(u8, authority, "[::1]")) return true;
    const host = authority[0 .. std.mem.lastIndexOfScalar(u8, authority, ':') orelse authority.len];
    return std.mem.eql(u8, host, "localhost") or std.mem.startsWith(u8, host, "127.");
}

test normalizeUrl {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const url = try normalizeUrl(a, "HTTPS://RB.Example:8443/Path/");
    try std.testing.expectEqualStrings("https://rb.example:8443/Path", url);
    try std.testing.expectEqualStrings("http://10.0.0.5", try normalizeUrl(a, "http://10.0.0.5"));
    try std.testing.expect(isLoopback("http://localhost:8080"));
    try std.testing.expect(isLoopback("http://127.0.0.1"));
    try std.testing.expect(isLoopback("http://[::1]:80/x"));
    try std.testing.expect(!isLoopback("http://10.0.0.5:8080"));
}

/// Writes the file with owner-only permissions, and replaces it atomically so a crash
/// never leaves half a token.
fn writeSecretFile(path: []const u8, data: []const u8) !void {
    var buffer: [1024]u8 = undefined;
    var file = try std.fs.cwd().atomicFile(path, .{ .mode = 0o600, .make_path = true, .write_buffer = &buffer });
    defer file.deinit();
    try file.file_writer.interface.writeAll(data);
    try file.finish();
}

fn openUrl(gpa: Allocator, url: []const u8) void {
    const argv: []const []const u8 = switch (@import("builtin").os.tag) {
        .windows => &.{ "rundll32", "url.dll,FileProtocolHandler", url },
        .macos => &.{ "open", url },
        else => &.{ "xdg-open", url },
    };
    var child: std.process.Child = .init(argv, gpa);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;
    // The URL is printed too, so a failure here does not matter.
    _ = child.spawnAndWait() catch {};
}

/// Reads an integer field, or returns null when it is missing or not a number.
fn intField(value: json.Value, key: []const u8) ?i64 {
    if (value != .object) return null;
    return switch (value.object.get(key) orelse return null) {
        .integer => |n| n,
        .float => |f| if (std.math.isFinite(f)) @intFromFloat(f) else null,
        else => null,
    };
}

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

fn list(cli: *Cli, args: *const Args) Failure!void {
    if (args.positionals.items.len > 0) cli.url_flag = args.positionals.items[0];
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

const device_grant = "urn:ietf:params:oauth:grant-type:device_code";

/// The OAuth 2.0 device flow (RFC 8628): the user approves the login in a web browser while the CLI polls.
fn logIn(cli: *Cli, args: *const Args) Failure!void {
    const days: ?i64 = if (args.get("days")) |text| std.fmt.parseInt(i64, text, 10) catch unreachable else null;
    if (days) |d| if (d <= 0) return cli.usageError("argument --days: must be at least 1", .{});
    const base_url = try cli.serverArgument(args) orelse
        return cli.usageError("the following arguments are required: url", .{});
    if (!std.mem.startsWith(u8, base_url, "http://") and !std.mem.startsWith(u8, base_url, "https://")) {
        return cli.usageError("argument url: must start with http:// or https://", .{});
    }
    const store = try cli.loadStore();
    _ = try cli.credentialsPath();
    if (std.mem.startsWith(u8, base_url, "http://") and !isLoopback(base_url)) {
        cli.printError("warning: {s} does not use HTTPS, so the token can be read on the network.", .{base_url});
    }

    const api = cli.newClient(base_url, "");
    const start = api.request(.POST, "/api/v1/auth/device", try json.Stringify.valueAlloc(cli.arena, .{
        .client_id = "remotebrowser-cli",
        .device_name = cli.options.device_name,
        .days = days,
    }, .{ .emit_null_optional_fields = false })) catch |err| {
        if (err == error.ApiFailed and api.last_error.?.status == 404) {
            return cli.fail("{s} does not support logging in with a web browser.", .{base_url});
        }
        return err;
    };
    const device_code = try cli.stringField(start, "device_code");
    const user_code = try cli.stringField(start, "user_code");
    const verification_uri = try cli.stringField(start, "verification_uri");
    const open_uri = if (start.object.get("verification_uri_complete")) |v|
        (if (v == .string) v.string else verification_uri)
    else
        verification_uri;
    var interval: i64 = @max(intField(start, "interval") orelse 5, 1);
    const expires_in = intField(start, "expires_in") orelse 900;

    try cli.err.print("To log in, open this URL in a web browser and check that it shows the code {s}:\n\n  {s}\n\n", .{
        user_code, open_uri,
    });
    try cli.err.writeAll("Waiting for the approval...\n");
    try cli.err.flush();
    if (!args.flag("no_browser")) cli.options.open_url(cli.gpa, open_uri);

    const poll_body = try json.Stringify.valueAlloc(cli.arena, .{
        .grant_type = device_grant,
        .device_code = device_code,
    }, .{});
    var waited: i64 = 0;
    const token = while (true) {
        if (waited >= expires_in) return cli.fail("The code expired before the login was approved.", .{});
        cli.sleep(@floatFromInt(interval));
        waited += interval;
        const result = api.request(.POST, "/api/v1/auth/token", poll_body) catch |err| switch (err) {
            error.ApiFailed => {
                const code = api.errorCode() orelse return err;
                if (std.mem.eql(u8, code, "authorization_pending")) continue;
                if (std.mem.eql(u8, code, "slow_down")) {
                    interval += 5;
                    continue;
                }
                if (std.mem.eql(u8, code, "access_denied")) return cli.fail("The login was denied.", .{});
                if (std.mem.eql(u8, code, "expired_token")) {
                    return cli.fail("The code expired before the login was approved.", .{});
                }
                return err;
            },
            else => return err,
        };
        break result;
    };

    const access_token = try cli.stringField(token, "access_token");
    const expires_at = if (intField(token, "expires_in")) |seconds| std.time.timestamp() + seconds else null;
    try store.servers.map.put(cli.arena, base_url, .{ .token = access_token, .expires_at = expires_at });
    store.current = base_url;
    try cli.saveStore();

    if (cli.json_output) return cli.printJson(.{ .url = base_url, .expires_at = expires_at });
    if (expires_at) |seconds| {
        const until = try isoTime(cli.arena, seconds * std.time.ms_per_s);
        try cli.out.print("Logged in to {s} until {s}.\n", .{ base_url, until });
    } else {
        try cli.out.print("Logged in to {s}.\n", .{base_url});
    }
    try cli.out.flush();
}

fn logOut(cli: *Cli, args: *const Args) Failure!void {
    const base_url = try cli.serverArgument(args) orelse return cli.fail("Not logged in.", .{});
    const store = try cli.loadStore();
    const login = store.servers.map.get(base_url) orelse return cli.fail("Not logged in to {s}.", .{base_url});
    const api = cli.newClient(base_url, login.token);
    // Delete the local copy even when the server cannot be reached, so logging out always works.
    _ = api.request(.POST, "/api/v1/auth/revoke", "{}") catch |err| switch (err) {
        error.ApiFailed => {
            const status = api.last_error.?.status;
            if (status != 401) cli.printError("warning: Could not revoke the token on the server: {s}", .{
                api.errorMessage(),
            });
        },
        else => return err,
    };
    _ = store.servers.map.orderedRemove(base_url);
    if (store.current) |current| {
        if (std.mem.eql(u8, current, base_url)) {
            // With one login left, the choice is clear; with more, let the user pick one.
            store.current = if (store.servers.map.count() == 1) store.servers.map.keys()[0] else null;
        }
    }
    try cli.saveStore();
    try cli.out.print("Logged out of {s}.\n", .{base_url});
    if (store.current) |current| try cli.out.print("Now using {s}.\n", .{current});
    try cli.out.flush();
}

fn switchServer(cli: *Cli, args: *const Args) Failure!void {
    const base_url = try normalizeUrl(cli.arena, args.positionals.items[0]);
    const store = try cli.loadStore();
    if (!store.servers.map.contains(base_url)) {
        return cli.fail("Not logged in to {s}. Run '{s} login {s}'.", .{ base_url, prog, base_url });
    }
    store.current = base_url;
    try cli.saveStore();
    try cli.out.print("Now using {s}.\n", .{base_url});
    try cli.out.flush();
}

/// Lists every login and marks the one that commands use.
fn showStatus(cli: *Cli, _: *const Args) Failure!void {
    const store = try cli.loadStore();
    const auth: ?Auth = cli.resolveAuth() catch |err| switch (err) {
        error.Failed => null,
        else => return err,
    };
    const Row = struct { url: []const u8, expires_at: ?i64, active: bool };
    var rows: std.ArrayList(Row) = .empty;
    for (store.servers.map.keys(), store.servers.map.values()) |url, login| {
        const active = if (auth) |a| std.mem.eql(u8, a.base_url, url) else false;
        try rows.append(cli.arena, .{ .url = url, .expires_at = login.expires_at, .active = active });
    }
    // `resolveAuth` has set the message.
    if (rows.items.len == 0) return error.Failed;

    if (cli.json_output) {
        try cli.printJson(rows.items);
    } else {
        var width: usize = 0;
        for (rows.items) |row| width = @max(width, row.url.len);
        const now = std.time.timestamp();
        for (rows.items) |row| {
            try cli.out.print("{s} {s}", .{ if (row.active) "*" else " ", row.url });
            try cli.out.splatByteAll(' ', width - row.url.len + 2);
            if (row.expires_at) |seconds| {
                const verb = if (seconds > now) "expires" else "expired";
                const time = try isoTime(cli.arena, seconds * std.time.ms_per_s);
                try cli.out.print("login, {s} {s}\n", .{ verb, time });
            } else {
                try cli.out.writeAll("login, does not expire\n");
            }
        }
        try cli.out.flush();
    }
    // The exit code tells scripts whether commands would work.
    return cli.checkExpiry(auth orelse return error.Failed);
}

fn printToken(cli: *Cli, _: *const Args) Failure!void {
    const auth = try cli.resolveAuth();
    try cli.checkExpiry(auth);
    if (cli.json_output) return cli.printJson(.{ .token = auth.token });
    return cli.line(auth.token);
}
