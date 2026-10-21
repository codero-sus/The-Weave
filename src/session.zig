//! One running instance of a Weave app.
//!
//! A Session owns the reactive store, the VM, the current vdom tree and the
//! timer queue. It is deliberately *not* thread-safe: every session belongs to
//! exactly one connection thread, which also means value refcounts stay
//! non-atomic.
//!
//! Lifecycle:
//!   create -> start()  (init signals, register effects, first flush -> mount)
//!          -> dispatchEvent/dispatchInput/tick  (each ends in settle())
//!          -> destroy()

const std = @import("std");
const value = @import("value.zig");
const bytecode = @import("bytecode.zig");
const reactive = @import("reactive.zig");
const vdom = @import("vdom.zig");
const diff = @import("diff.zig");
const proto = @import("proto.zig");
const jsonw = @import("jsonw.zig");
const vm = @import("vm.zig");
const host = @import("host.zig");

pub const SendError = error{ Closed, OutOfMemory };
pub const Sink = *const fn (ctx: *anyopaque, bytes: []const u8) SendError!void;

pub const Error = error{OutOfMemory} || SendError;

pub const Timer = struct {
    due_ms: i64,
    callable: value.Value,
};

/// Which Weave construct a store effect implements. Indexed by store effect id.
const EffectKind = union(enum) {
    computed: u32,
    user: u32,
    render,
};

pub const Stats = struct {
    renders: u64 = 0,
    patches: u64 = 0,
    events: u64 = 0,
    timers_fired: u64 = 0,
    nodes: usize = 0,
    ops_last: usize = 0,
};

pub const Session = struct {
    alloc: std.mem.Allocator,
    unit: *const bytecode.CodeUnit,
    source_path: []const u8,

    store: reactive.Store,
    builder: vdom.Builder,
    ids: diff.IdGen = .{},
    patcher: diff.Patcher,
    vmx: vm.Vm,
    host: vm.Host,

    root: ?*vdom.Node = null,
    timers: std.ArrayList(Timer),
    effect_kinds: std.ArrayList(EffectKind),
    on_mount_ids: std.ArrayList(u32),
    render_effect: u32 = 0,

    now_ms: i64 = 0,
    started: bool = false,
    broken: bool = false,
    verbose: bool = false,

    send: Sink,
    send_ctx: *anyopaque,

    stats: Stats = .{},

    pub fn create(
        a: std.mem.Allocator,
        unit: *const bytecode.CodeUnit,
        source_path: []const u8,
        sink: Sink,
        sink_ctx: *anyopaque,
    ) !*Session {
        const s = try a.create(Session);
        errdefer a.destroy(s);

        // NOTE: `a.create` returns *undefined* memory, and struct field defaults
        // only apply to initialiser literals — so every field is set explicitly.
        s.alloc = a;
        s.unit = unit;
        s.source_path = source_path;
        s.store = reactive.Store.init(a);
        s.builder = vdom.Builder.init(a);
        s.ids = .{ .next_id = 1 };
        s.patcher = diff.Patcher.init(a, &s.ids);
        s.vmx = try vm.Vm.init(a, unit, &s.store);
        s.host = .{ .ctx = s, .schedule_after = hostScheduleAfter, .log = hostLog };
        s.vmx.host = &s.host;
        s.vmx.builder = &s.builder;
        s.root = null;
        s.timers = std.ArrayList(Timer).init(a);
        s.effect_kinds = std.ArrayList(EffectKind).init(a);
        s.on_mount_ids = std.ArrayList(u32).init(a);
        s.render_effect = 0;
        s.now_ms = 0;
        s.started = false;
        s.broken = false;
        s.verbose = false;
        s.send = sink;
        s.send_ctx = sink_ctx;
        s.stats = .{};
        return s;
    }

    pub fn destroy(self: *Session) void {
        const a = self.alloc;
        for (self.timers.items) |t| t.callable.release();
        self.timers.deinit();
        self.effect_kinds.deinit();
        self.on_mount_ids.deinit();
        self.patcher.deinit();
        if (self.root) |r| r.destroy(a);
        self.builder.deinit();
        self.vmx.deinit();
        self.store.deinit();
        a.destroy(self);
    }

    // -- startup ------------------------------------------------------------

    /// Initialise signals, register effects and produce the first mount frame.
    pub fn start(self: *Session) !void {
        self.now_ms = host.nowMs();

        for (self.unit.signals) |sig| {
            _ = try self.store.addSignal(sig.name, sig.kind);
        }

        // Signal initialisers run in declaration order; a `computed` that reads
        // a later signal simply sees nil for now and is corrected by the first
        // flush below.
        for (self.unit.signals, 0..) |sig, i| {
            const idx: u32 = @intCast(i);
            const rv = self.vmx.callFunc(sig.init_fn, &.{}, null) catch |e| {
                try self.reportVmError();
                return e;
            };
            self.store.write(idx, rv);
        }

        for (self.unit.signals, 0..) |sig, i| {
            if (sig.kind != .computed) continue;
            const id = try self.store.addEffect(sig.name, reactive.Priority.computed, effectTrampoline, self);
            try self.effect_kinds.append(.{ .computed = @intCast(i) });
            self.store.markDirty(id);
        }

        for (self.unit.effects, 0..) |e, i| {
            const label = if (e.label.len > 0) e.label else "effect";
            const id = try self.store.addEffect(label, reactive.Priority.effect, effectTrampoline, self);
            try self.effect_kinds.append(.{ .user = @intCast(i) });
            if (e.on_mount) {
                self.store.effects.items[id].enabled = false;
                try self.on_mount_ids.append(id);
            } else {
                self.store.markDirty(id);
            }
        }

        self.render_effect = try self.store.addEffect("render", reactive.Priority.render, effectTrampoline, self);
        try self.effect_kinds.append(.render);
        self.store.markDirty(self.render_effect);

        try self.sendHello();

        // One flush settles computed -> effects -> render, and the render
        // effect emits the mount frame because there is no tree yet.
        try self.settle();

        self.started = true;

        for (self.on_mount_ids.items) |id| {
            const fn_idx = switch (self.effect_kinds.items[id]) {
                .user => |ue_idx| self.unit.effects[ue_idx].func_idx,
                else => continue,
            };
            const rv = self.vmx.callFunc(fn_idx, &.{}, null) catch {
                try self.reportVmError();
                continue;
            };
            rv.release();
        }
        self.settle() catch {};
    }

    // -- effects ------------------------------------------------------------

    fn effectTrampoline(ctx: *anyopaque, effect_id: u32) anyerror!void {
        const self: *Session = @ptrCast(@alignCast(ctx));
        return self.runEffect(effect_id);
    }

    fn runEffect(self: *Session, effect_id: u32) anyerror!void {
        if (effect_id >= self.effect_kinds.items.len) return;
        switch (self.effect_kinds.items[effect_id]) {
            .render => try self.render(),
            .computed => |sig_idx| {
                const rv = self.vmx.callFunc(self.unit.signals[sig_idx].init_fn, &.{}, null) catch |e| {
                    try self.reportVmError();
                    return e;
                };
                self.store.write(sig_idx, rv);
            },
            .user => |ue_idx| {
                const ue = self.unit.effects[ue_idx];
                const rv = self.vmx.callFunc(ue.func_idx, &.{}, null) catch |e| {
                    try self.reportVmError();
                    return e;
                };
                rv.release();
            },
        }
    }

    /// Run the reactive graph until it settles, then let the render effect's
    /// patch reach the client.
    pub fn settle(self: *Session) Error!void {
        if (self.broken) return;
        self.store.flush() catch |e| switch (e) {
            // A failing effect must not wedge the session: it was already
            // reported to the client, so only propagate the fatal cases.
            error.OutOfMemory => return error.OutOfMemory,
            error.Closed => return error.Closed,
            else => return,
        };
    }

    // -- rendering ----------------------------------------------------------

    pub fn render(self: *Session) anyerror!void {
        self.builder.reset();
        const rv = self.vmx.callFunc(self.unit.render_fn, &.{}, null) catch |e| {
            self.builder.abort();
            try self.reportVmError();
            return e;
        };
        rv.release();

        const new_root = self.builder.root orelse {
            self.builder.abort();
            return;
        };
        // Ownership of every node moves from the builder to the session.
        self.builder.reset();
        self.stats.renders += 1;

        var committed = false;
        defer if (!committed) new_root.destroy(self.alloc);

        if (self.root) |old| {
            self.patcher.clear();
            try self.patcher.reconcile(old, new_root);
            const ops = self.patcher.ops.items;
            self.stats.ops_last = ops.len;
            if (ops.len > 0) {
                try self.sendPatch(ops);
                self.stats.patches += 1;
            }
            old.destroy(self.alloc);
        } else {
            try self.patcher.reconcile(null, new_root);
            try self.sendMount(new_root);
        }

        self.root = new_root;
        self.stats.nodes = new_root.count();
        committed = true;
    }

    pub fn findNode(self: *const Session, id: u32) ?*vdom.Node {
        const r = self.root orelse return null;
        return findNodeIn(r, id);
    }

    fn findNodeIn(n: *vdom.Node, id: u32) ?*vdom.Node {
        if (n.id == id) return n;
        for (n.children.items) |c| {
            if (findNodeIn(c, id)) |hit| return hit;
        }
        return null;
    }

    // -- input from the client ---------------------------------------------

    pub fn dispatchEvent(self: *Session, node_id: u32, name: []const u8, args: value.Value) !void {
        defer args.release();
        if (self.broken) return;
        self.stats.events += 1;
        const node = self.findNode(node_id) orelse return;
        const callable = node.findEvent(name) orelse return;
        const fb: ?*value.FuncBox = switch (callable) {
            .func => |f| f,
            else => null,
        };
        if (fb == null) return;
        const argv: []const value.Value = switch (args) {
            .list => |l| l.items.items,
            else => &.{},
        };
        const rv = self.vmx.callFunc(fb.?.func_idx, argv, fb) catch |e| {
            try self.reportVmError();
            if (e == error.OutOfMemory) return e;
            return;
        };
        rv.release();
        try self.settle();
    }

    /// Two-way binding: write the value into the bound signal, then run the
    /// node's own input/change handler if it has one.
    pub fn dispatchInput(self: *Session, node_id: u32, v: value.Value, event_name: []const u8) !void {
        if (self.broken) {
            v.release();
            return;
        }
        const node = self.findNode(node_id) orelse {
            v.release();
            return;
        };
        if (node.bind.len > 0) {
            if (self.store.indexOf(node.bind)) |idx| {
                self.store.write(idx, v.retain());
            }
        }
        self.stats.events += 1;

        const handler = node.findEvent(event_name) orelse node.findEvent("change");
        if (handler) |callable| {
            const fb: ?*value.FuncBox = switch (callable) {
                .func => |f| f,
                else => null,
            };
            if (fb) |box| {
                const argv = [_]value.Value{v.retain()};
                const rv = self.vmx.callFunc(box.func_idx, &argv, box) catch |e| {
                    v.release();
                    try self.reportVmError();
                    if (e == error.OutOfMemory) return e;
                    return;
                };
                rv.release();
            }
        }
        v.release();
        try self.settle();
    }

    // -- timers -------------------------------------------------------------

    pub fn tick(self: *Session, now_ms: i64) !void {
        self.now_ms = now_ms;
        if (self.broken or self.timers.items.len == 0) return;

        // Snapshot the due set first: a timer body may arm new timers, and those
        // must wait for a later tick. Without this, `after 0:` inside a timer
        // body would keep the loop growing forever.
        var due = std.ArrayList(Timer).init(self.alloc);
        defer due.deinit();
        var i: usize = 0;
        while (i < self.timers.items.len) {
            if (self.timers.items[i].due_ms <= now_ms) {
                try due.append(self.timers.orderedRemove(i));
            } else {
                i += 1;
            }
        }

        for (due.items) |t| {
            self.stats.timers_fired += 1;
            switch (t.callable) {
                .func => |fb| {
                    const rv = self.vmx.callFunc(fb.func_idx, &.{}, fb) catch {
                        t.callable.release();
                        self.reportVmError() catch {};
                        continue;
                    };
                    rv.release();
                },
                else => {},
            }
            t.callable.release();
        }
        if (due.items.len > 0) try self.settle();
    }

    pub fn nextDueMs(self: *const Session) ?i64 {
        var best: ?i64 = null;
        for (self.timers.items) |t| {
            if (best == null or t.due_ms < best.?) best = t.due_ms;
        }
        return best;
    }

    fn hostScheduleAfter(ctx: *anyopaque, delay_ms: i64, callable: value.Value) void {
        const self: *Session = @ptrCast(@alignCast(ctx));
        const due = self.now_ms + @max(delay_ms, 0);
        self.timers.append(.{ .due_ms = due, .callable = callable }) catch callable.release();
    }

    fn hostLog(ctx: *anyopaque, msg: []const u8) void {
        const self: *Session = @ptrCast(@alignCast(ctx));
        host.logf("[{s}] {s}\n", .{ self.unit.app_name, msg });
    }

    // -- output -------------------------------------------------------------

    fn sendFrame(self: *Session, args: FrameArgs) Error!void {
        var w = jsonw.Writer.init(self.alloc);
        defer w.deinit();
        try writeFrame(&w, args);
        const bytes = try w.toOwnedSlice();
        defer self.alloc.free(bytes);
        try self.send(self.send_ctx, bytes);
    }

    const FrameArgs = union(enum) {
        hello: struct { app: []const u8, gen: u32 },
        mount: *const vdom.Node,
        patch: []const diff.Op,
        err: []const u8,
        reload: void,
        pong: void,
        state: value.Value,
    };

    fn writeFrame(w: *jsonw.Writer, args: FrameArgs) !void {
        switch (args) {
            .hello => |h| try proto.writeHello(w, h.app, h.gen),
            .mount => |r| try proto.writeMount(w, r),
            .patch => |ops| try proto.writePatch(w, ops),
            .err => |m| try proto.writeError(w, m),
            .reload => try proto.writeReload(w),
            .pong => try proto.writePong(w),
            .state => |s| try proto.writeState(w, s),
        }
    }

    fn sendHello(self: *Session) !void {
        try self.sendFrame(.{ .hello = .{ .app = self.unit.app_name, .gen = 1 } });
    }

    fn sendMount(self: *Session, root: *const vdom.Node) !void {
        try self.sendFrame(.{ .mount = root });
    }

    fn sendPatch(self: *Session, ops: []const diff.Op) !void {
        try self.sendFrame(.{ .patch = ops });
    }

    pub fn sendReload(self: *Session) !void {
        try self.sendFrame(.reload);
    }

    pub fn sendPong(self: *Session) !void {
        try self.sendFrame(.pong);
    }

    pub fn sendState(self: *Session) !void {
        const snap = try self.store.dumpState();
        defer snap.release();
        try self.sendFrame(.{ .state = snap });
    }

    /// Report a VM failure to the client and the server log.
    pub fn reportVmError(self: *Session) !void {
        const msg = self.vmx.errorMessage();
        if (msg.len == 0) return;
        var buf = std.ArrayList(u8).init(self.alloc);
        defer buf.deinit();
        buf.appendSlice(msg) catch {};
        if (self.vmx.renderTrace(self.alloc, self.source_path)) |trace| {
            defer self.alloc.free(trace);
            buf.append('\n') catch {};
            buf.appendSlice(trace) catch {};
        } else |_| {}
        host.logf("weave: runtime error in {s}\n{s}\n", .{ self.unit.app_name, buf.items });
        self.vmx.resetError();
        self.sendFrame(.{ .err = buf.items }) catch {};
    }
};
