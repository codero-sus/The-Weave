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
const package = @import("package.zig");
const server = @import("server.zig");
const session = @import("session.zig");
const vdom = @import("vdom.zig");

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
    \\    weave                       run the one .weave file in this directory
    \\
    \\COMMANDS
    \\    run        Serve the app over HTTP+WebSocket with hot reload (default)
    \\    serve      Alias for run
    \\    check      Parse, type-check and compile; exit non-zero on errors
    \\    build      Compile to a standalone artifact: .wvbc, .html or an executable
    \\    dump       Print the bytecode disassembly of a source or .wvbc file
    \\    ast        Print the normalised parse tree
    \\    new        Write a starter app to a new file
    \\    version    Print the version and exit
    \\    help       Show this message
    \\
    \\BUILD FORMATS
    \\    --format wvbc   pre-compiled bytecode, run by any weave (the default)
    \\    --format html   one self-contained page — engine, app and styles inline;
    \\                    no server and no build step, just open it in a browser
    \\    --format exe    this engine with your app compiled into it; the result
    \\                    runs on its own, with nothing else installed
    \\    --html, --exe   shorthand for --format html / --format exe, and they take
    \\                    the output path directly:  --html dist/todo.html
    \\
    \\OPTIONS
    \\    --host ADDR    Address to bind            (default 127.0.0.1)
    \\    --port N       Port to bind               (default 8080, 0 = any free port)
    \\    --open         Open the app in a browser once the server is up
    \\    --no-open      Do not; a terminal opens the browser by default
    \\    --no-reload    Disable hot reload
    \\    --poll MS      Socket poll interval / timer resolution (default 50)
    \\    --quiet        Suppress server log lines
    \\    --no-color     Disable ANSI colour in diagnostics
    \\    --selftest     Boot the app once, report what rendered, and exit
    \\    -o, --out FILE Output path for `build`    (default: input name + format)
    \\    -h, --help     Show this message
    \\
    \\EXAMPLES
    \\    weave examples/todo.weave
    \\    weave run examples/counter.weave --port 3000
    \\    weave build examples/todo.weave                      ->  todo.wvbc
    \\    weave build examples/todo.weave --html dist/todo.html
    \\    weave build examples/todo.weave --exe dist/todoapp   ->  ./dist/todoapp
    \\    weave check examples/*.weave
    \\    weave dump dist/todo.wvbc
    \\
    \\An executable from `build --exe` runs its own app: `./todoapp` serves it and
    \\`./todoapp --selftest` checks it. It is still a full weave, so
    \\`./todoapp build other.weave --html other.html` works too.
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
    /// `build` output form; null means "infer from -o, else .wvbc".
    format: ?package.Format = null,
    /// True when the user asked for --open explicitly, so auto-open stays out of
    /// the way of scripted runs.
    open_explicit: bool = false,
    /// Packaged binaries: load the embedded app, render once, report and exit.
    selftest: bool = false,
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
            } else if (eql(name, "--format")) {
                const v = inline_val orelse try next(argv, &i, name);
                a.format = package.Format.parse(v) orelse {
                    stderr().print("weave: --format expects wvbc, html or exe, got '{s}'\n", .{v}) catch {};
                    return error.BadUsage;
                };
            } else if (eql(name, "--html")) {
                a.format = .html;
                // `--html out.html` reads as one thought, so let it be one.
                if (inline_val) |v| {
                    a.out = v;
                } else if (peekValue(argv, i)) |v| {
                    a.out = v;
                    i += 1;
                }
            } else if (eql(name, "--exe")) {
                a.format = .exe;
                if (inline_val) |v| {
                    a.out = v;
                } else if (peekValue(argv, i)) |v| {
                    a.out = v;
                    i += 1;
                }
            } else if (eql(name, "--selftest")) {
                a.selftest = true;
            } else if (eql(name, "--open")) {
                a.opts.open_browser = true;
                a.open_explicit = true;
            } else if (eql(name, "--no-open")) {
                a.opts.open_browser = false;
                a.open_explicit = true;
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

/// Does the argument after a value-less flag look like an output path?
/// Another flag, or a Weave source file, does not.
fn peekValue(argv: []const []const u8, i: usize) ?[]const u8 {
    if (i + 1 >= argv.len) return null;
    const v = argv[i + 1];
    if (v.len == 0 or v[0] == '-') return null;
    if (std.mem.endsWith(u8, v, ".weave")) return null;
    if (std.mem.endsWith(u8, v, ".wvbc")) return null;
    return v;
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
    // A path found by looking in this directory is ours; argv paths are not.
    var discovered: ?[]const u8 = null;
    defer if (discovered) |d| alloc.free(d);

    if (a.want_help) {
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
        // A packaged binary *is* the app: run what was compiled into it.
        if ((eql(a.cmd, "run") or eql(a.cmd, "serve")) and package.isPackaged()) {
            return runEmbedded(alloc, &a);
        }
        // Otherwise be as forgiving as an interpreter: one .weave in this
        // directory means "run it".
        if (eql(a.cmd, "run") or eql(a.cmd, "serve")) {
            if (discoverApp(alloc) catch null) |path| {
                discovered = path;
                try a.files.append(path);
            } else if (argv.len == 0) {
                // Nothing to run and nothing asked: show the way in.
                try stdout().print(help_text, .{version});
                return 0;
            } else {
                stderr().print("weave: no input file, and this directory has no single .weave app to run. Try `weave help`.\n", .{}) catch {};
                return 2;
            }
        } else {
            stderr().print("weave: no input file. Try `weave help`.\n", .{}) catch {};
            return 2;
        }
    }

    // Opening a browser is what a person wants; a script does not. Ask only when
    // stdout is a terminal and the user did not say either way.
    if ((eql(a.cmd, "run") or eql(a.cmd, "serve")) and !a.open_explicit and !a.selftest) {
        a.opts.open_browser = std.io.getStdOut().isTty();
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
    if (a.selftest) {
        defer m.deinit();
        return bootCheck(m, path);
    }
    var srv = server.Server.init(alloc, path, m, a.opts) catch |e| {
        m.deinit();
        stderr().print("weave: cannot start server ({s})\n", .{@errorName(e)}) catch {};
        return 1;
    };
    defer srv.deinit();
    srv.run() catch |e| {
        stderr().print("weave: server stopped ({s})\n", .{@errorName(e)}) catch {};
        return 1;
    };
    return 0;
}

/// Boot an app with no server attached: initialise its signals, render once and
/// report what came out. This is how CI proves that a pre-compiled `.wvbc` — or
/// the app embedded in a packaged executable — still runs, and it is the fastest
/// way for a person to check one too.
fn bootCheck(m: *module.Module, label: []const u8) !u8 {
    var sink_ctx: u8 = 0;
    const s = session.Session.create(m.parent, m.unit, label, discardSink, @ptrCast(&sink_ctx)) catch {
        stderr().print("weave: out of memory\n", .{}) catch {};
        return 1;
    };
    defer s.destroy();
    s.start() catch |e| {
        stderr().print("weave: {s} failed to start ({s})\n", .{ label, @errorName(e) }) catch {};
        return 1;
    };
    if (s.root == null) {
        stderr().print("weave: {s} rendered nothing\n", .{label}) catch {};
        return 1;
    }
    stdout().print("weave: {s} ok — app {s}, {d} signals, {d} functions, {d} nodes rendered\n", .{
        label,
        m.unit.app_name,
        m.unit.signals.len,
        m.unit.funcs.len,
        s.stats.nodes,
    }) catch {};
    return 0;
}

/// Run the app that was compiled into this executable (`weave build --exe`).
/// Nothing on disk is read, and nothing on disk is watched.
fn runEmbedded(alloc: std.mem.Allocator, a: *Args) !u8 {
    const bytes = package.embeddedApp(alloc) orelse {
        stderr().print("weave: this binary has no embedded app\n", .{}) catch {};
        return 1;
    };
    defer alloc.free(bytes);

    const m = module.fromBytecode(alloc, package.embedded_label, bytes) catch |e| {
        reportLoadError(package.embedded_label, e);
        return 1;
    };

    if (a.selftest) {
        defer m.deinit();
        return bootCheck(m, package.embedded_label);
    }

    var opts = a.opts;
    opts.reload = false; // there is no source file to watch
    var srv = server.Server.init(alloc, m.path, m, opts) catch |e| {
        m.deinit();
        stderr().print("weave: cannot start server ({s})\n", .{@errorName(e)}) catch {};
        return 1;
    };
    defer srv.deinit();
    srv.run() catch |e| {
        stderr().print("weave: server stopped ({s})\n", .{@errorName(e)}) catch {};
        return 1;
    };
    return 0;
}

/// One `.weave` file in the working directory: the app the user means. Several,
/// or none, and we ask instead of guessing.
fn discoverApp(alloc: std.mem.Allocator) !?[]const u8 {
    var dir = std.fs.cwd().openDir(".", .{ .iterate = true }) catch return null;
    defer dir.close();

    var found: ?[]const u8 = null;
    var count: usize = 0;
    var it = dir.iterate();
    while (try it.next()) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".weave")) continue;
        count += 1;
        if (count == 1) found = try alloc.dupe(u8, entry.name);
    }
    if (count != 1) {
        if (found) |f| alloc.free(f);
        if (count > 1) {
            stderr().print("weave: this directory has {d} .weave files; name the one you want\n", .{count}) catch {};
        }
        return null;
    }
    return found;
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

/// `weave build`: source in, one of three artifacts out.
///
///   --format wvbc (default)  pre-compiled bytecode, run by any `weave`
///   --format html            one self-contained page: engine, app, styles
///   --format exe             this engine with the app compiled into it
fn cmdBuild(alloc: std.mem.Allocator, a: *Args) !u8 {
    if (a.files.items.len != 1) {
        stderr().print("usage: weave build <file.weave|file.wvbc> [-o out] [--format wvbc|html|exe]\n", .{}) catch {};
        return 2;
    }
    const path = a.files.items[0];
    const fmt = a.format orelse inferFormat(a.out) orelse .wvbc;

    if (fmt == .wvbc and module.isBytecode(path)) {
        stderr().print("weave: {s} is already bytecode\n", .{path}) catch {};
        return 2;
    }

    const m = module.load(alloc, path, a.opts.color) catch |e| {
        reportLoadError(path, e);
        return 1;
    };
    defer m.deinit();

    var out_buf = std.ArrayList(u8).init(alloc);
    defer out_buf.deinit();
    const out_path: []const u8 = a.out orelse try defaultOutPath(fmt, path, &out_buf);

    switch (fmt) {
        .wvbc => {
            module.writeBytecode(alloc, m.unit, out_path) catch |e| {
                stderr().print("weave: cannot write {s} ({s})\n", .{ out_path, @errorName(e) }) catch {};
                return 1;
            };
            stdout().print("weave: wrote {s} ({d} bytes, {d} functions, {d} consts)\n", .{
                out_path,
                fileSize(out_path) orelse 0,
                m.unit.funcs.len,
                m.unit.consts.len,
            }) catch {};
            stdout().print("       run it with: weave run {s}\n", .{out_path}) catch {};
        },
        .html => {
            const r = package.writeHtml(alloc, m.unit, m.source_text, out_path) catch |e| {
                stderr().print("weave: cannot write {s} ({s})\n", .{ out_path, @errorName(e) }) catch {};
                return 1;
            };
            stdout().print("weave: wrote {s} ({d} KB) — app {s}\n", .{ r.path, r.bytes / 1024, m.unit.app_name }) catch {};
            stdout().print("       engine {d} KB + bytecode {d} KB inline; open the file in a browser\n", .{
                r.engine_bytes / 1024,
                r.app_bytes / 1024,
            }) catch {};
        },
        .exe => {
            const r = package.writeExe(alloc, m.unit, out_path) catch |e| {
                stderr().print("weave: cannot write {s} ({s})\n", .{ out_path, @errorName(e) }) catch {};
                return 1;
            };
            stdout().print("weave: wrote {s} ({d} KB) — app {s}\n", .{ r.path, r.bytes / 1024, m.unit.app_name }) catch {};
            stdout().print("       engine {d} KB + app {d} KB; run it with: {s}\n", .{
                r.engine_bytes / 1024,
                r.app_bytes / 1024,
                r.path,
            }) catch {};
            if (builtin.os.tag == .macos and !r.resigned) {
                stdout().print("       note: macOS wants it signed: codesign --force --sign - {s}\n", .{r.path}) catch {};
            }
        },
    }
    return 0;
}

/// `-o app.html` says what you want as clearly as `--html` does.
fn inferFormat(out: ?[]const u8) ?package.Format {
    const o = out orelse return null;
    if (endsWithIgnoreCase(o, ".html") or endsWithIgnoreCase(o, ".htm")) return .html;
    if (endsWithIgnoreCase(o, ".wvbc")) return .wvbc;
    if (endsWithIgnoreCase(o, ".exe")) return .exe;
    return null;
}

fn endsWithIgnoreCase(s: []const u8, suffix: []const u8) bool {
    return s.len >= suffix.len and std.ascii.eqlIgnoreCase(s[s.len - suffix.len ..], suffix);
}

/// `<stem>` + the format's extension, beside the input file's name.
fn defaultOutPath(fmt: package.Format, path: []const u8, buf: *std.ArrayList(u8)) ![]const u8 {
    var stem = std.fs.path.basename(path);
    for ([_][]const u8{ ".weave", ".wvbc" }) |ext| {
        if (std.mem.endsWith(u8, stem, ext)) stem = stem[0 .. stem.len - ext.len];
    }
    if (stem.len == 0) stem = "app";
    try buf.writer().print("{s}{s}", .{ stem, fmt.extension() });
    return buf.items;
}

fn fileSize(path: []const u8) ?usize {
    const st = std.fs.cwd().statFile(path) catch return null;
    return st.size;
}

fn discardSink(ctx: *anyopaque, bytes: []const u8) session.SendError!void {
    _ = ctx;
    _ = bytes;
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
    // The file may be called anything (`my-app`, `2048`, `hello.world`), but an
    // app name has to be an identifier, so derive one from the stem.
    const app_name = try appNameFromStem(alloc, stem);
    defer alloc.free(app_name);
    const body = try std.fmt.allocPrint(alloc, scaffold, .{app_name});
    defer alloc.free(body);
    std.fs.cwd().writeFile(.{ .sub_path = path, .data = body }) catch |e| {
        stderr().print("weave: cannot write {s} ({s})\n", .{ path, @errorName(e) }) catch {};
        return 1;
    };
    stdout().print("weave: created {s}\n       run it with: weave {s}\n", .{ path, path }) catch {};
    return 0;
}

/// `my-app` -> `MyApp`, `2048` -> `App2048`, `hello.world.weave` -> `HelloWorld`.
/// Separator and punctuation runs start a new capitalised word; anything that is
/// not alphanumeric is dropped, so the result is always a valid identifier.
fn appNameFromStem(alloc: std.mem.Allocator, stem: []const u8) ![]u8 {
    var out = std.ArrayList(u8).init(alloc);
    errdefer out.deinit();

    var capitalise_next = true;
    for (stem) |c| {
        if (!std.ascii.isAlphanumeric(c)) {
            capitalise_next = true;
            continue;
        }
        if (capitalise_next) {
            try out.append(std.ascii.toUpper(c));
            capitalise_next = false;
        } else {
            try out.append(c);
        }
    }
    if (out.items.len == 0) {
        try out.appendSlice("App");
    } else if (std.ascii.isDigit(out.items[0])) {
        try out.insertSlice(0, "App");
    }
    return out.toOwnedSlice();
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
