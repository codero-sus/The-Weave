//! `zig build itest` — end-to-end test of the real thing.
//!
//! Boots the actual HTTP+WebSocket server on an ephemeral port, then drives it
//! over a real socket with a real WebSocket client (the same framing code the
//! server uses, in client mode). Covers static assets, the handshake, mount,
//! input binding, event dispatch, patch shape, ping/pong and hot reload.
//!
//! Exits non-zero on the first failure so CI can gate on it.

const std = @import("std");
const value = @import("value.zig");
const module = @import("module.zig");
const server = @import("server.zig");
const ws = @import("ws.zig");

const app_source =
    \\app ItestApp:
    \\    state:
    \\        items = ["alpha", "beta"]
    \\        draft = ""
    \\        hits = 0
    \\
    \\    computed:
    \\        total = "{items.len()} items"
    \\
    \\    view:
    \\        stack(padding: 8, gap: 8):
    \\            text(total)
    \\            text("hits: {hits}")
    \\            input(bind: draft, placeholder: "type here", on_enter: {
    \\                items.append(draft)
    \\                draft = ""
    \\                hits += 1
    \\            })
    \\            for item in items:
    \\                card(shadow: sm):
    \\                    text(item)
    \\                    button("del", click: items.remove(item))
;

const reloaded_source =
    \\app ItestApp:
    \\    state:
    \\        items = ["reloaded"]
    \\        draft = ""
    \\        hits = 0
    \\
    \\    view:
    \\        stack:
    \\            text("version two")
;

const tmp_path = "itest-app.weave";

// Resolved per call: a comptime `getStdOut()` does not survive a Windows target.
fn out() std.fs.File.Writer {
    return std.io.getStdOut().writer();
}

fn err() std.fs.File.Writer {
    return std.io.getStdErr().writer();
}

fn step(msg: []const u8) void {
    out().print("  ok   {s}\n", .{msg}) catch {};
}

fn fail(comptime fmt: []const u8, args: anytype) error{TestFailed} {
    err().print("  FAIL " ++ fmt ++ "\n", args) catch {};
    return error.TestFailed;
}

fn expect(cond: bool, comptime fmt: []const u8, args: anytype) !void {
    if (!cond) return fail(fmt, args);
}

fn expectStr(haystack: []const u8, needle: []const u8, what: []const u8) !void {
    if (std.mem.indexOf(u8, haystack, needle) == null) {
        return fail("{s}: expected to find `{s}` in:\n{s}", .{ what, needle, haystack });
    }
}

// ---------------------------------------------------------------- JSON ------

fn get(v: std.json.Value, key: []const u8) ?std.json.Value {
    if (v != .object) return null;
    return v.object.get(key);
}

fn str(v: ?std.json.Value) []const u8 {
    const x = v orelse return "";
    return if (x == .string) x.string else "";
}

fn int(v: ?std.json.Value) i64 {
    const x = v orelse return 0;
    return switch (x) {
        .integer => |i| i,
        .float => |f| @intFromFloat(f),
        else => 0,
    };
}

/// Depth-first search for the first node whose "t" equals `tag`.
fn findNode(root: std.json.Value, tag: []const u8) ?std.json.Value {
    if (std.mem.eql(u8, str(get(root, "t")), tag)) return root;
    const kids = get(root, "c") orelse return null;
    if (kids != .array) return null;
    for (kids.array.items) |k| {
        if (findNode(k, tag)) |hit| return hit;
    }
    return null;
}

fn findAll(root: std.json.Value, tag: []const u8, ids: *std.ArrayList(i64)) void {
    if (std.mem.eql(u8, str(get(root, "t")), tag)) ids.append(int(get(root, "i"))) catch {};
    const kids = get(root, "c") orelse return;
    if (kids != .array) return;
    for (kids.array.items) |k| findAll(k, tag, ids);
}

fn countOps(frame: std.json.Value, code: []const u8) usize {
    const ops = get(frame, "ops") orelse return 0;
    if (ops != .array) return 0;
    var n: usize = 0;
    for (ops.array.items) |op| {
        if (std.mem.eql(u8, str(get(op, "o")), code)) n += 1;
    }
    return n;
}

// --------------------------------------------------------------- client -----

const Client = struct {
    conn: ws.Conn,
    arena: *std.heap.ArenaAllocator,
    last: []const u8 = "",

    fn connect(a: std.mem.Allocator, port: u16) !Client {
        const stream = try std.net.tcpConnectToHost(a, "127.0.0.1", port);
        errdefer stream.close();
        var c = ws.Conn.init(a, stream, false);
        c.setReadTimeoutMs(100);
        var host: [48]u8 = undefined;
        const h = try std.fmt.bufPrint(&host, "127.0.0.1:{d}", .{port});
        try c.requestUpgrade(h, "/ws");

        const arena_box = try a.create(std.heap.ArenaAllocator);
        arena_box.* = std.heap.ArenaAllocator.init(a);
        return .{ .conn = c, .arena = arena_box };
    }

    fn deinit(self: *Client) void {
        const a = self.arena.child_allocator;
        self.arena.deinit();
        a.destroy(self.arena);
        self.conn.close();
        self.conn.deinit();
    }

    fn next(self: *Client, timeout_ms: i64) !std.json.Value {
        const deadline = std.time.milliTimestamp() + timeout_ms;
        while (true) {
            if (try self.conn.readMessage()) |bytes| {
                self.last = bytes;
                const parsed = try std.json.parseFromSlice(std.json.Value, self.arena.allocator(), bytes, .{});
                return parsed.value;
            }
            if (std.time.milliTimestamp() > deadline) return error.Timeout;
        }
    }

    /// Read frames until one has `"t": kind`.
    fn expectFrame(self: *Client, kind: []const u8, timeout_ms: i64) !std.json.Value {
        const deadline = std.time.milliTimestamp() + timeout_ms;
        while (true) {
            const f = try self.next(@max(deadline - std.time.milliTimestamp(), 1));
            if (std.mem.eql(u8, str(get(f, "t")), kind)) return f;
            if (std.time.milliTimestamp() > deadline) {
                return fail("timed out waiting for a `{s}` frame (last: {s})", .{ kind, self.last });
            }
        }
    }

    fn send(self: *Client, comptime fmt: []const u8, args: anytype) !void {
        const a = self.arena.child_allocator;
        const s = try std.fmt.allocPrint(a, fmt, args);
        defer a.free(s);
        try self.conn.writeText(s);
    }
};

// ----------------------------------------------------------------- http -----

const HttpResponse = struct { status: u16, body: []u8 };

fn httpGet(a: std.mem.Allocator, port: u16, path: []const u8) !HttpResponse {
    const stream = try std.net.tcpConnectToHost(a, "127.0.0.1", port);
    defer stream.close();
    var c = ws.Conn.init(a, stream, false);
    defer c.deinit();
    c.setReadTimeoutMs(5000);

    var req: [512]u8 = undefined;
    const n = try std.fmt.bufPrint(&req, "GET {s} HTTP/1.1\r\nHost: 127.0.0.1:{d}\r\nConnection: close\r\n\r\n", .{ path, port });
    try stream.writeAll(n);

    var line: [8192]u8 = undefined;
    const status_line = try c.readLine(&line);
    var status: u16 = 0;
    var it = std.mem.tokenizeScalar(u8, status_line, ' ');
    _ = it.next();
    if (it.next()) |code| status = std.fmt.parseInt(u16, code, 10) catch 0;

    var content_length: usize = 0;
    while (true) {
        const h = try c.readLine(&line);
        if (h.len == 0) break;
        if (std.ascii.startsWithIgnoreCase(h, "content-length:")) {
            content_length = std.fmt.parseInt(usize, std.mem.trim(u8, h["content-length:".len..], " "), 10) catch 0;
        }
    }
    const body = try a.alloc(u8, content_length);
    errdefer a.free(body);
    if (content_length > 0) try c.readExact(body);
    return .{ .status = status, .body = body };
}

// ----------------------------------------------------------------- main -----

fn runServer(s: *server.Server) void {
    s.run() catch {};
}

pub fn main() !u8 {
    value.initRuntime();
    run(value.alloc) catch |e| {
        err().print("\nitest: {s}\n", .{@errorName(e)}) catch {};
        _ = value.deinitRuntime();
        return 1;
    };
    if (!value.deinitRuntime()) {
        err().print("itest: memory leaked\n", .{}) catch {};
        return 1;
    }
    return 0;
}

fn run(a: std.mem.Allocator) !void {
    out().print("weave itest: booting a real server\n", .{}) catch {};

    try std.fs.cwd().writeFile(.{ .sub_path = tmp_path, .data = app_source });
    defer std.fs.cwd().deleteFile(tmp_path) catch {};

    const m = try module.load(a, tmp_path, false);
    var srv = try server.Server.init(a, tmp_path, m, .{
        .host = "127.0.0.1",
        .port = 0,
        .reload = true,
        .poll_ms = 20,
        .quiet = true,
        .color = false,
    });
    defer srv.deinit();

    const thread = try std.Thread.spawn(.{}, runServer, .{&srv});
    defer {
        srv.requestStop();
        // Wake accept() out of its blocking call.
        if (std.net.tcpConnectToHost(a, "127.0.0.1", srv.bound_port.load(.monotonic))) |s| s.close() else |_| {}
        thread.join();
    }

    var port: u16 = 0;
    var waited: usize = 0;
    while (waited < 300) : (waited += 1) {
        if (srv.listening.load(.monotonic)) {
            port = srv.bound_port.load(.monotonic);
            break;
        }
        std.time.sleep(10 * std.time.ns_per_ms);
    }
    if (port == 0) return fail("server never started listening", .{});
    out().print("  ..   listening on 127.0.0.1:{d}\n", .{port}) catch {};

    // --- static assets ----------------------------------------------------
    {
        const r = try httpGet(a, port, "/");
        defer a.free(r.body);
        try expect(r.status == 200, "GET / returned {d}", .{r.status});
        try expectStr(r.body, "<div id=\"app\"", "index.html");
        try expectStr(r.body, "/client.js", "index.html script tag");
        step("GET / serves the client shell");
    }
    {
        const r = try httpGet(a, port, "/client.js");
        defer a.free(r.body);
        try expect(r.status == 200, "GET /client.js returned {d}", .{r.status});
        try expectStr(r.body, "new WebSocket(", "client.js");
        step("GET /client.js serves the runtime");
    }
    {
        const r = try httpGet(a, port, "/client.css");
        defer a.free(r.body);
        try expect(r.status == 200, "GET /client.css returned {d}", .{r.status});
        try expectStr(r.body, ".weave-card", "client.css");
        step("GET /client.css serves the stylesheet");
    }
    {
        const r = try httpGet(a, port, "/health");
        defer a.free(r.body);
        try expect(r.status == 200, "GET /health returned {d}", .{r.status});
        try expectStr(r.body, "\"ok\":true", "health");
        try expectStr(r.body, "\"app\":\"ItestApp\"", "health app name");
        step("GET /health reports the running app");
    }
    {
        const r = try httpGet(a, port, "/does-not-exist");
        defer a.free(r.body);
        try expect(r.status == 404, "unknown path returned {d}", .{r.status});
        step("unknown paths 404");
    }

    // --- websocket session -------------------------------------------------
    var client = try Client.connect(a, port);
    defer client.deinit();
    step("websocket handshake accepted");

    const hello = try client.expectFrame("hello", 5000);
    try expect(std.mem.eql(u8, str(get(hello, "app")), "ItestApp"), "hello named {s}", .{str(get(hello, "app"))});
    step("hello frame carries the app name");

    const mount = try client.expectFrame("mount", 5000);
    const root = get(mount, "root") orelse return fail("mount has no root", .{});
    try expect(std.mem.eql(u8, str(get(root, "t")), "stack"), "root tag is {s}", .{str(get(root, "t"))});

    const input_node = findNode(root, "input") orelse return fail("no input node in the mount", .{});
    const input_id = int(get(input_node, "i"));
    try expect(std.mem.eql(u8, str(get(input_node, "b")), "draft"), "input is bound to {s}", .{str(get(input_node, "b"))});
    try expectStr(client.last, "\"e\":[\"enter\"]", "input events");
    try expectStr(client.last, "2 items", "computed interpolation");

    var card_ids = std.ArrayList(i64).init(a);
    defer card_ids.deinit();
    findAll(root, "card", &card_ids);
    try expect(card_ids.items.len == 2, "expected 2 cards, got {d}", .{card_ids.items.len});
    step("mount tree: stack root, bound input, 2 loop cards");

    // --- two-way binding ---------------------------------------------------
    try client.send("{{\"t\":\"input\",\"id\":{d},\"value\":\"gamma\"}}", .{input_id});
    {
        const patch = try client.expectFrame("patch", 5000);
        try expectStr(client.last, "\"value\":\"gamma\"", "bound value patch");
        try expect(countOps(patch, "i") == 0, "typing re-inserted nodes", .{});
        step("input event patches just the bound value");
    }

    // --- handler with a block body ----------------------------------------
    try client.send("{{\"t\":\"event\",\"id\":{d},\"name\":\"enter\"}}", .{input_id});
    {
        const patch = try client.expectFrame("patch", 5000);
        try expect(countOps(patch, "i") >= 1, "enter did not insert a card:\n{s}", .{client.last});
        try expectStr(client.last, "gamma", "inserted card content");
        try expectStr(client.last, "3 items", "recomputed summary");
        try expectStr(client.last, "\"value\":\"\"", "cleared draft");
        step("enter handler appends, recomputes and clears");
    }

    // --- a second, independent session ------------------------------------
    {
        var c2 = try Client.connect(a, port);
        defer c2.deinit();
        _ = try c2.expectFrame("hello", 5000);
        const m2 = try c2.expectFrame("mount", 5000);
        const r2 = get(m2, "root") orelse return fail("second session mount has no root", .{});
        var buttons = std.ArrayList(i64).init(a);
        defer buttons.deinit();
        findAll(r2, "button", &buttons);
        // The other session appended an item; this one must not see it.
        try expect(buttons.items.len == 2, "expected 2 buttons in a fresh session, got {d}", .{buttons.items.len});
        // A brand new session starts from the source state, not this client's.
        try expectStr(c2.last, "2 items", "fresh session state");
        step("a second connection gets its own independent session");
    }

    // --- inline expression handler (`click: items.remove(item)`) -----------
    // The click lives on the button inside a card, so address the button. Ids
    // are stable across patches, so the id captured at mount still works.
    var del_ids = std.ArrayList(i64).init(a);
    defer del_ids.deinit();
    findAll(root, "button", &del_ids);
    try expect(del_ids.items.len == 2, "expected 2 del buttons, got {d}", .{del_ids.items.len});
    try client.send("{{\"t\":\"event\",\"id\":{d},\"name\":\"click\"}}", .{del_ids.items[0]});
    {
        const patch = try client.expectFrame("patch", 5000);
        try expect(countOps(patch, "r") >= 1, "click did not remove a card:\n{s}", .{client.last});
        try expectStr(client.last, "2 items", "recomputed after removal");
        step("inline handler closure removes the loop item");
    }

    // --- ping/pong ---------------------------------------------------------
    try client.send("{{\"t\":\"ping\"}}", .{});
    _ = try client.expectFrame("pong", 5000);
    step("ping answered with pong");

    // --- hot reload --------------------------------------------------------
    try std.fs.cwd().writeFile(.{ .sub_path = tmp_path, .data = reloaded_source });
    {
        const reload = try client.expectFrame("reload", 5000);
        _ = reload;
        step("editing the file pushes a reload frame");
    }
    {
        var c3 = try Client.connect(a, port);
        defer c3.deinit();
        _ = try c3.expectFrame("hello", 5000);
        const m3 = try c3.expectFrame("mount", 5000);
        try expectStr(c3.last, "version two", "reloaded mount");
        _ = m3;
        step("reconnecting after a reload serves the new build");
    }

    out().print("\nitest: all checks passed\n", .{}) catch {};
}
