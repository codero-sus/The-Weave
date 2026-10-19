//! The `weave` command line.
//!
//!   weave run app.weave          serve it (default when a file is given)
//!   weave build app.weave        emit pre-compiled bytecode (.wvbc)
//!   weave check app.weave        parse + compile only, non-zero exit on error
//!   weave dump app.weave|.wvbc   print the bytecode disassembly
//!   weave ast app.weave          print the normalised parse tree
//!   weave new myapp              scaffold a starter app
//!   weave version | help

const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");

const value = @import("value.zig");
const diag = @import("diag.zig");
const ast = @import("ast.zig");
const astprint = @import("astprint.zig");
const parser = @import("parser.zig");
const compiler = @import("compiler.zig");
const bytecode = @import("bytecode.zig");
const module = @import("module.zig");
const server = @import("server.zig");

pub const version = build_options.version;

// `std.io.getStdOut()` cannot be evaluated at comptime when targeting Windows
// (it reaches for the PEB through inline asm), so the writers are resolved per
// call instead of as top-level constants.
fn stdout() std.fs.File.Writer {
    return std.io.getStdOut().writer();
}

fn stderr() std.fs.File.Writer {
    return std.io.getStdErr().writer();
}

pub const help_text =
    \\weave {s} — one file, full stack
    \\
    \\USAGE
    \\    weave [COMMAND] [OPTIONS] <file.weave|file.wvbc>
    \\
    \\COMMANDS
    \\    run        Serve the app over HTTP+WebSocket with hot reload (default)
    \\    serve      Alias for run
    \\    check      Parse, type-check and compile; exit non-zero on errors
    \\    build      Compile to a standalone bytecode artifact (.wvbc)
    \\    dump       Print the bytecode disassembly of a source or .wvbc file
    \\    ast        Print the normalised parse tree
    \\    new        Write a starter app to a new file
    \\    version    Print the version and exit
    \\    help       Show this message
    \\
    \\OPTIONS
    \\    --host ADDR    Address to bind            (default 127.0.0.1)
    \\    --port N       Port to bind               (default 8080, 0 = any free port)
    \\    --open         Open the app in a browser once the server is up
    \\    --no-reload    Disable hot reload
    \\    --poll MS      Socket poll interval / timer resolution (default 50)
    \\    --quiet        Suppress server log lines
    \\    --no-color     Disable ANSI colour in diagnostics
    \\    -o, --out FILE Output path for `build`    (default: input with .wvbc)
    \\    -h, --help     Show this message
    \\
    \\EXAMPLES
    \\    weave examples/todo.weave
    \\    weave run examples/counter.weave --port 3000 --open
    \\    weave build examples/todo.weave -o dist/todo.wvbc
    \\    weave check examples/*.weave
    \\    weave dump dist/todo.wvbc
    \\
;

const scaffold =
    \\app {s}:
    \\    state:
    \\        count = 0
    \\        name = "world"
    \\
    \\    computed:
    \\        greeting = "Hello, {{name}}!"
    \\        parity = "even" if count % 2 == 0 else "odd"
    \\
    \\    handlers:
    \\        bump(by):
    \\            count += by
    \\
    \\    effects:
    \\        on_mount:
    \\            log("app is live")
    \\
    \\        on count:
    \\            log("count is now {{count}}")
    \\
    \\    view:
    \\        stack(padding: 32, gap: 16, align: start):
    \\            heading(greeting, font: 28, bold: true)
    \\            text("count is {{count}} ({{parity}})")
    \\
    \\            row(gap: 8):
    \\                button("+1", click: bump(1))
    \\                button("-1", click: bump(-1))
    \\                button("reset", click: {{
    \\                    count = 0
    \\                }})
    \\
    \\            divider()
    \\
    \\            input(bind: name, placeholder: "Your name")
    \\
    \\            card(shadow: sm, padding: 16):
    \\                text("Save this file and the browser updates itself.")
    \\
;

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

fn isCommand(s: []const u8) bool {
    const cmds = [_][]const u8{ "run", "serve", "check", "build", "dump", "ast", "new", "version", "help" };
    for (cmds) |c| if (eql(s, c)) return true;
    return false;
}

pub const Args = struct {
    cmd: []const u8 = "run",
    files: std.ArrayList([]const u8),
    out: ?[]const u8 = null,
    opts: server.Options = .{},
    want_help: bool = false,
};

pub fn parseArgs(alloc: std.mem.Allocator, argv: []const []const u8) !Args {
    var a = Args{
        .files = std.ArrayList([]const u8).init(alloc),
        .opts = .{ .color = std.io.getStdErr().supportsAnsiEscapeCodes() },
    };
    var explicit_cmd = false;

    var i: usize = 0;
    while (i < argv.len) : (i += 1) {
        const arg = argv[i];
        if (arg.len >= 2 and arg[0] == '-' and arg[1] == '-') {
            var name = arg;
            var inline_val: ?[]const u8 = null;
            if (std.mem.indexOfScalar(u8, arg, '=')) |eq| {
                name = arg[0..eq];
                inline_val = arg[eq + 1 ..];
            }
            if (eql(name, "--help")) {
                a.want_help = true;
            } else if (eql(name, "--host")) {
                a.opts.host = inline_val orelse try next(argv, &i, name);
            } else if (eql(name, "--port")) {
                const v = inline_val orelse try next(argv, &i, name);
                a.opts.port = std.fmt.parseInt(u16, v, 10) catch {
                    stderr().print("weave: --port expects a number, got '{s}'\n", .{v}) catch {};
                    return error.BadUsage;
                };
            } else if (eql(name, "--poll")) {
                const v = inline_val orelse try next(argv, &i, name);
                a.opts.poll_ms = std.fmt.parseInt(u32, v, 10) catch 50;
                if (a.opts.poll_ms == 0) a.opts.poll_ms = 50;
            } else if (eql(name, "--out") or eql(name, "-o")) {
                a.out = inline_val orelse try next(argv, &i, name);
            } else if (eql(name, "--open")) {
                a.opts.open_browser = true;
            } else if (eql(name, "--no-reload")) {
                a.opts.reload = false;
            } else if (eql(name, "--quiet")) {
                a.opts.quiet = true;
            } else if (eql(name, "--color")) {
                a.opts.color = true;
            } else if (eql(name, "--no-color")) {
                a.opts.color = false;
            } else if (eql(name, "--version")) {
                a.cmd = "version";
                explicit_cmd = true;
            } else {
                stderr().print("weave: unknown option '{s}'\n", .{name}) catch {};
                return error.BadUsage;
            }
        } else if (arg.len == 2 and arg[0] == '-') {
            if (eql(arg, "-h")) {
                a.want_help = true;
            } else if (eql(arg, "-o")) {
                a.out = try next(argv, &i, arg);
            } else if (eql(arg, "-v")) {
                a.cmd = "version";
                explicit_cmd = true;
            } else {
                stderr().print("weave: unknown option '{s}'\n", .{arg}) catch {};
                return error.BadUsage;
            }
        } else if (!explicit_cmd and a.files.items.len == 0 and isCommand(arg)) {
            a.cmd = arg;
            explicit_cmd = true;
        } else {
            try a.files.append(arg);
        }
    }
    return a;
}

fn next(argv: []const []const u8, i: *usize, flag: []const u8) ![]const u8 {
    if (i.* + 1 >= argv.len) {
        stderr().print("weave: {s} expects a value\n", .{flag}) catch {};
        return error.BadUsage;
    }
    i.* += 1;
    return argv[i.*];
}

pub fn run(alloc: std.mem.Allocator, argv: []const []const u8) !u8 {
    var a = try parseArgs(alloc, argv);
    defer a.files.deinit();

    if (a.want_help or (eql(a.cmd, "run") and a.files.items.len == 0 and argv.len == 0)) {
        try stdout().print(help_text, .{version});
        return 0;
    }
    if (eql(a.cmd, "help")) {
        try stdout().print(help_text, .{version});
        return 0;
    }
    if (eql(a.cmd, "version")) {
        try stdout().print("weave {s} ({s}-{s})\n", .{ version, @tagName(builtin.cpu.arch), @tagName(builtin.os.tag) });
        return 0;
    }
    if (eql(a.cmd, "new")) return cmdNew(alloc, &a);
    if (a.files.items.len == 0) {
        stderr().print("weave: no input file. Try `weave help`.\n", .{}) catch {};
        return 2;
    }
    if (eql(a.cmd, "check")) return cmdCheck(alloc, &a);
    if (eql(a.cmd, "ast")) return cmdAst(alloc, &a);
    if (eql(a.cmd, "build")) return cmdBuild(alloc, &a);
    if (eql(a.cmd, "dump")) return cmdDump(alloc, &a);
    if (eql(a.cmd, "run") or eql(a.cmd, "serve")) return cmdRun(alloc, &a);

    stderr().print("weave: unknown command '{s}'\n", .{a.cmd}) catch {};
    return 2;
}

fn cmdRun(alloc: std.mem.Allocator, a: *Args) !u8 {
    if (a.files.items.len > 1) {
        stderr().print("weave: run takes exactly one file\n", .{}) catch {};
        return 2;
    }
    const path = a.files.items[0];
    const m = module.load(alloc, path, a.opts.color) catch |e| {
        reportLoadError(path, e);
        return 1;
    };
    var srv = try server.Server.init(alloc, path, m, a.opts);
    defer srv.deinit();
    srv.run() catch |e| {
        stderr().print("weave: server stopped ({s})\n", .{@errorName(e)}) catch {};
        return 1;
    };
    return 0;
}

fn cmdCheck(alloc: std.mem.Allocator, a: *Args) !u8 {
    var failed: usize = 0;
    for (a.files.items) |path| {
        const m = module.load(alloc, path, a.opts.color) catch |e| {
            reportLoadError(path, e);
            failed += 1;
            continue;
        };
        const u = m.unit;
        stdout().print("{s}: ok — app {s}, {d} signals, {d} functions, {d} handlers, {d} effects, {d} components\n", .{
            path,
            u.app_name,
            u.signals.len,
            u.funcs.len,
            u.handlers.len,
            u.effects.len,
            u.components.len,
        }) catch {};
        m.deinit();
    }
    if (failed > 0) {
        stderr().print("weave: {d} of {d} file(s) failed\n", .{ failed, a.files.items.len }) catch {};
        return 1;
    }
    stdout().print("weave: {d} file(s) ok\n", .{a.files.items.len}) catch {};
    return 0;
}

fn cmdAst(alloc: std.mem.Allocator, a: *Args) !u8 {
    var failed: u8 = 0;
    for (a.files.items) |path| {
        const text = std.fs.cwd().readFileAlloc(alloc, path, module.max_source_bytes) catch {
            stderr().print("weave: cannot read {s}\n", .{path}) catch {};
            failed = 1;
            continue;
        };
        defer alloc.free(text);

        var src = try diag.Source.init(alloc, path, text);
        defer src.deinit();
        var rep = diag.Reporter.init(alloc, &src);
        defer rep.deinit();

        var parsed = (try parser.parse(alloc, &src, &rep)) orelse {
            failed = 1;
            continue;
        };
        defer parsed.deinit();
        if (rep.hasErrors()) {
            failed = 1;
            continue;
        }
        const out = try astprint.print(alloc, &parsed.program);
        defer alloc.free(out);
        try stdout().writeAll(out);
    }
    return failed;
}

fn cmdBuild(alloc: std.mem.Allocator, a: *Args) !u8 {
    const path = a.files.items[0];
    if (module.isBytecode(path)) {
        stderr().print("weave: {s} is already bytecode\n", .{path}) catch {};
        return 2;
    }
    const m = module.load(alloc, path, a.opts.color) catch |e| {
        reportLoadError(path, e);
        return 1;
    };
    defer m.deinit();

    var out_buf: std.ArrayList(u8) = std.ArrayList(u8).init(alloc);
    defer out_buf.deinit();
    const out_path: []const u8 = a.out orelse blk: {
        const stem = if (std.mem.endsWith(u8, path, ".weave")) path[0 .. path.len - 6] else path;
        try out_buf.writer().print("{s}.wvbc", .{stem});
        break :blk out_buf.items;
    };

    module.writeBytecode(alloc, m.unit, out_path) catch |e| {
        stderr().print("weave: cannot write {s} ({s})\n", .{ out_path, @errorName(e) }) catch {};
        return 1;
    };
    const size = std.fs.cwd().statFile(out_path) catch null;
    stdout().print("weave: wrote {s} ({d} bytes, {d} functions, {d} consts)\n", .{
        out_path,
        if (size) |s| s.size else 0,
        m.unit.funcs.len,
        m.unit.consts.len,
    }) catch {};
    return 0;
}

fn cmdDump(alloc: std.mem.Allocator, a: *Args) !u8 {
    var failed: u8 = 0;
    for (a.files.items) |path| {
        const m = module.load(alloc, path, a.opts.color) catch |e| {
            reportLoadError(path, e);
            failed = 1;
            continue;
        };
        defer m.deinit();
        const txt = try bytecode.disassemble(alloc, m.unit);
        defer alloc.free(txt);
        try stdout().writeAll(txt);
    }
    return failed;
}

fn cmdNew(alloc: std.mem.Allocator, a: *Args) !u8 {
    if (a.files.items.len != 1) {
        stderr().print("usage: weave new <name>\n", .{}) catch {};
        return 2;
    }
    const name = a.files.items[0];
    var path_buf = std.ArrayList(u8).init(alloc);
    defer path_buf.deinit();
    if (std.mem.endsWith(u8, name, ".weave")) {
        try path_buf.appendSlice(name);
    } else {
        try path_buf.writer().print("{s}.weave", .{name});
    }
    const path = path_buf.items;

    if (std.fs.cwd().access(path, .{})) {
        stderr().print("weave: {s} already exists\n", .{path}) catch {};
        return 1;
    } else |_| {}

    const stem = std.fs.path.basename(if (std.mem.endsWith(u8, name, ".weave")) name[0 .. name.len - 6] else name);
    const body = try std.fmt.allocPrint(alloc, scaffold, .{stem});
    defer alloc.free(body);
    std.fs.cwd().writeFile(.{ .sub_path = path, .data = body }) catch |e| {
        stderr().print("weave: cannot write {s} ({s})\n", .{ path, @errorName(e) }) catch {};
        return 1;
    };
    stdout().print("weave: created {s}\n       run it with: weave {s}\n", .{ path, path }) catch {};
    return 0;
}

fn reportLoadError(path: []const u8, e: anyerror) void {
    switch (e) {
        error.NotFound => stderr().print("weave: no such file: {s}\n", .{path}) catch {},
        error.Diagnostics => {}, // already printed with source context
        error.BadBytecode => stderr().print("weave: {s} is not valid weave bytecode\n", .{path}) catch {},
        error.ReadFailed => stderr().print("weave: cannot read {s}\n", .{path}) catch {},
        error.OutOfMemory => stderr().print("weave: out of memory loading {s}\n", .{path}) catch {},
        else => stderr().print("weave: cannot load {s} ({s})\n", .{ path, @errorName(e) }) catch {},
    }
}
