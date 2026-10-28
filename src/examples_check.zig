//! `zig build examples` — compile *and run* every bundled example headlessly.
//!
//! Each `examples/*.weave` file is parsed, compiled, booted into a real Session
//! with a discard sink, rendered, and then poked with a synthetic event on every
//! clickable node so handler bodies actually execute. Anything that fails to
//! compile, render, or run makes the process exit non-zero, which is what CI
//! keys off.

const std = @import("std");
const value = @import("value.zig");
const module = @import("module.zig");
const session = @import("session.zig");
const vdom = @import("vdom.zig");

const examples_dir = "examples";

var frames_written: usize = 0;
var bytes_written: usize = 0;

fn discardSink(ctx: *anyopaque, bytes: []const u8) session.SendError!void {
    _ = ctx;
    frames_written += 1;
    bytes_written += bytes.len;
    // Cheap structural check: every frame must be a JSON object.
    if (bytes.len < 2 or bytes[0] != '{') return error.Closed;
    return;
}

fn collectIds(n: *vdom.Node, out: *std.ArrayList(u32)) void {
    if (n.events.items.len > 0) out.append(n.id) catch {};
    for (n.children.items) |c| collectIds(c, out);
}

fn collectBinds(n: *vdom.Node, out: *std.ArrayList(u32)) void {
    if (n.bind.len > 0) out.append(n.id) catch {};
    for (n.children.items) |c| collectBinds(c, out);
}

fn checkOne(alloc: std.mem.Allocator, path: []const u8) !CheckReport {
    var report = CheckReport{ .path = try alloc.dupe(u8, path) };
    errdefer alloc.free(report.path);

    const m = try module.load(alloc, path, false);
    defer m.deinit();

    // The module (and its arena) dies when checkOne returns, so anything the
    // report keeps must be copied out.
    report.app_name = try alloc.dupe(u8, m.unit.app_name);
    errdefer alloc.free(@constCast(report.app_name));
    report.signals = m.unit.signals.len;
    report.funcs = m.unit.funcs.len;

    var dummy: u8 = 0;
    const s = try session.Session.create(alloc, m.unit, path, discardSink, @ptrCast(&dummy));
    defer s.destroy();
    try s.start();

    if (s.root == null) return error.NothingRendered;
    report.nodes = s.stats.nodes;
    report.mount_bytes = bytes_written;

    // Poke every interactive node once, in tree order, so handler bodies run.
    var ids = std.ArrayList(u32).init(alloc);
    defer ids.deinit();
    collectIds(s.root.?, &ids);
    report.interactive = ids.items.len;

    const names = [_][]const u8{ "click", "enter", "change" };
    for (ids.items) |id| {
        for (names) |name| {
            s.dispatchEvent(id, name, value.Value{ .nil = {} }) catch |e| return e;
        }
    }

    // Type into every bound input.
    var binds = std.ArrayList(u32).init(alloc);
    defer binds.deinit();
    collectBinds(s.root.?, &binds);
    for (binds.items) |id| {
        const v = try value.makeStr("typed by examples_check");
        s.dispatchInput(id, v, "input") catch |e| return e;
    }

    // Let timers fire.
    try s.tick(std.time.milliTimestamp() + 60_000);

    report.renders = s.stats.renders;
    report.patches = s.stats.patches;
    return report;
}

const CheckReport = struct {
    path: []const u8,
    app_name: []const u8 = "",
    signals: usize = 0,
    funcs: usize = 0,
    nodes: usize = 0,
    interactive: usize = 0,
    renders: u64 = 0,
    patches: u64 = 0,
    mount_bytes: usize = 0,
};

/// Append every `<dir>/*.weave` to `paths`. A missing directory is fatal only
/// when `required`.
fn collect(alloc: std.mem.Allocator, dir_name: []const u8, paths: *std.ArrayList([]u8), required: bool) !void {
    var dir = std.fs.cwd().openDir(dir_name, .{ .iterate = true }) catch {
        if (required) {
            try std.io.getStdErr().writer().print("weave-examples: no {s}/ directory in the working tree\n", .{dir_name});
            std.process.exit(2);
        }
        return;
    };
    defer dir.close();

    var it = dir.iterate();
    while (try it.next()) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".weave")) continue;
        const full = try std.fmt.allocPrint(alloc, "{s}/{s}", .{ dir_name, entry.name });
        try paths.append(full);
    }
}

pub fn main() !u8 {
    value.initRuntime();
    defer _ = value.deinitRuntime();
    const alloc = value.alloc;
    const out = std.io.getStdOut().writer();
    const err = std.io.getStdErr().writer();

    var paths = std.ArrayList([]u8).init(alloc);
    defer {
        for (paths.items) |p| alloc.free(p);
        paths.deinit();
    }

    // examples/ is required; tests/ holds the language fixture and is optional so
    // the binary still works from a partial checkout.
    try collect(alloc, examples_dir, &paths, true);
    try collect(alloc, "tests", &paths, false);

    std.mem.sort([]u8, paths.items, {}, struct {
        fn lt(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.lt);

    if (paths.items.len == 0) {
        try err.print("weave-examples: {s}/ contains no .weave files\n", .{examples_dir});
        return 2;
    }

    var failed: usize = 0;
    try out.print("checking {d} example(s)\n\n", .{paths.items.len});
    for (paths.items) |path| {
        frames_written = 0;
        bytes_written = 0;
        const report = checkOne(alloc, path) catch |e| {
            try err.print("  FAIL {s}: {s}\n", .{ path, @errorName(e) });
            failed += 1;
            continue;
        };
        defer alloc.free(@constCast(report.path));
        defer alloc.free(@constCast(report.app_name));
        try out.print(
            "  ok   {s}\n         app={s}  signals={d}  funcs={d}  nodes={d}  interactive={d}\n         renders={d}  patches={d}  mount={d}B  wire={d}B in {d} frames\n",
            .{
                report.path,       report.app_name, report.signals, report.funcs,
                report.nodes,      report.interactive, report.renders, report.patches,
                report.mount_bytes, bytes_written,   frames_written,
            },
        );
    }

    try out.print("\n", .{});
    if (failed > 0) {
        try err.print("weave-examples: {d} of {d} example(s) failed\n", .{ failed, paths.items.len });
        return 1;
    }
    try out.print("weave-examples: all {d} example(s) compile, render and run\n", .{paths.items.len});
    return 0;
}
