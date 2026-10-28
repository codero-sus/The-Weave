//! Tree reconciliation: old vdom -> new vdom -> a minimal op list.
//!
//! Identity rules:
//!   * a node keeps its id when it matches an old node (same tag and, when
//!     either side is keyed, the same key)
//!   * loop children are always keyed by the compiler (`key <expr>` or the item
//!     value, falling back to the positional index), so reordering a list moves
//!     DOM nodes instead of rewriting them
//!
//! Op ordering matters for the client: removals for a parent are emitted before
//! its insert/move ops, and those run in increasing target index. Applying them
//! sequentially therefore converges on the new order without any client-side
//! bookkeeping.

const std = @import("std");
const value = @import("value.zig");
const vdom = @import("vdom.zig");

pub const PropDelta = struct {
    name: []const u8,
    /// `null` value + `removed` means "drop this prop".
    val: value.Value = .{ .nil = {} },
    removed: bool = false,
};

pub const Update = struct {
    id: u32,
    /// New text for a text node.
    text: ?value.Value = null,
    props: []PropDelta = &.{},
    /// Full replacement list of event names, when the set changed.
    events: ?[][]const u8 = null,
};

pub const Op = union(enum) {
    remove: u32,
    insert: struct { parent: u32, index: u32, node: *vdom.Node },
    move: struct { id: u32, parent: u32, index: u32 },
    update: Update,
};

pub const IdGen = struct {
    next_id: u32 = 1,
    pub fn next(self: *IdGen) u32 {
        const id = self.next_id;
        self.next_id += 1;
        return id;
    }
};

pub const Patcher = struct {
    alloc: std.mem.Allocator,
    ids: *IdGen,
    ops: std.ArrayList(Op),
    /// Nodes whose ids were assigned during this pass (for cleanup on abort).
    stats: Stats = .{},

    pub const Stats = struct {
        inserted: usize = 0,
        removed: usize = 0,
        moved: usize = 0,
        updated: usize = 0,
        reused: usize = 0,
    };

    pub fn init(a: std.mem.Allocator, ids: *IdGen) Patcher {
        return .{ .alloc = a, .ids = ids, .ops = std.ArrayList(Op).init(a) };
    }

    pub fn deinit(self: *Patcher) void {
        self.clear();
        self.ops.deinit();
    }

    pub fn clear(self: *Patcher) void {
        for (self.ops.items) |op| switch (op) {
            .update => |u| {
                if (u.text) |t| t.release();
                for (u.props) |p| p.val.release();
                if (u.props.len > 0) self.alloc.free(u.props);
                if (u.events) |evs| {
                    for (evs) |e| self.alloc.free(e);
                    self.alloc.free(evs);
                }
            },
            else => {},
        };
        self.ops.clearRetainingCapacity();
        self.stats = .{};
    }

    /// Assign ids to a whole subtree that has no old counterpart.
    fn assignIds(self: *Patcher, n: *vdom.Node) void {
        if (n.id == 0) n.id = self.ids.next();
        for (n.children.items) |c| self.assignIds(c);
    }

    /// Reconcile `old` (may be null on first render) against `new`.
    pub fn reconcile(self: *Patcher, old: ?*vdom.Node, new: *vdom.Node) error{OutOfMemory}!void {
        if (old == null) {
            self.assignIds(new);
            self.stats.inserted += new.count();
            return; // the caller sends a full mount instead of ops
        }
        try self.diffNode(old.?, new);
    }

    fn diffNode(self: *Patcher, old: *vdom.Node, new: *vdom.Node) error{OutOfMemory}!void {
        new.id = old.id;
        self.stats.reused += 1;

        // --- self: text / props / events ---
        var deltas = std.ArrayList(PropDelta).init(self.alloc);
        defer deltas.deinit(); // no-op once toOwnedSlice() has run

        if (!old.text.deepEqual(new.text)) {
            try self.ops.append(.{ .update = .{ .id = new.id, .text = new.text.retain() } });
            self.stats.updated += 1;
        }

        for (new.props.items) |np| {
            const ov = old.getProp(np.name);
            if (ov == null) {
                try deltas.append(.{ .name = np.name, .val = np.value.retain() });
            } else if (!ov.?.deepEqual(np.value)) {
                try deltas.append(.{ .name = np.name, .val = np.value.retain() });
            }
        }
        for (old.props.items) |op| {
            if (new.getProp(op.name) == null) {
                try deltas.append(.{ .name = op.name, .removed = true });
            }
        }

        // bind is part of the node's identity for the client
        const bind_changed = !std.mem.eql(u8, old.bind, new.bind);

        const events_changed = !sameEventNames(old, new);

        if (deltas.items.len > 0 or events_changed or bind_changed) {
            var u = Update{
                .id = new.id,
                .props = if (deltas.items.len > 0) try deltas.toOwnedSlice() else &.{},
            };
            if (events_changed) {
                const names = try self.alloc.alloc([]const u8, new.events.items.len);
                for (new.events.items, 0..) |e, i| names[i] = e.event;
                u.events = names;
            }
            if (bind_changed) {
                const extra = try self.alloc.alloc(PropDelta, u.props.len + 1);
                @memcpy(extra[0..u.props.len], u.props);
                if (u.props.len > 0) self.alloc.free(u.props);
                extra[u.props.len] = .{
                    .name = "bind",
                    .val = if (new.bind.len > 0) try value.makeStr(new.bind) else value.Value{ .nil = {} },
                    .removed = new.bind.len == 0,
                };
                u.props = extra;
            }
            try self.ops.append(.{ .update = u });
            self.stats.updated += 1;
        }

        try self.diffChildren(old, new);
    }

    fn diffChildren(self: *Patcher, old: *vdom.Node, new: *vdom.Node) error{OutOfMemory}!void {
        // Surviving candidates in old order.
        var alive = std.ArrayList(*vdom.Node).init(self.alloc);
        defer alive.deinit();
        for (old.children.items) |c| try alive.append(c);

        var matched = std.ArrayList(bool).init(self.alloc);
        defer matched.deinit();
        for (alive.items) |_| try matched.append(false);

        // Pass 1: pair up new children with old ones.
        const Pair = struct { new_idx: usize, old_idx: ?usize };
        var pairs = std.ArrayList(Pair).init(self.alloc);
        defer pairs.deinit();

        var cursor: usize = 0;
        for (new.children.items, 0..) |nc, j| {
            var found: ?usize = null;
            if (cursor < alive.items.len and !matched.items[cursor] and sameNode(alive.items[cursor], nc)) {
                found = cursor;
            } else {
                var k = cursor;
                while (k < alive.items.len) : (k += 1) {
                    if (matched.items[k]) continue;
                    if (sameNode(alive.items[k], nc)) {
                        found = k;
                        break;
                    }
                }
            }
            if (found) |fi| {
                matched.items[fi] = true;
                if (fi == cursor) cursor += 1;
                while (cursor < alive.items.len and matched.items[cursor]) cursor += 1;
            }
            try pairs.append(.{ .new_idx = j, .old_idx = found });
        }

        // Pass 2: removals first, so later indices refer to the post-removal list.
        var cur = std.ArrayList(u32).init(self.alloc);
        defer cur.deinit();
        for (alive.items, 0..) |oc, i| {
            if (matched.items[i]) {
                try cur.append(oc.id);
                continue;
            }
            try self.ops.append(.{ .remove = oc.id });
            self.stats.removed += oc.count();
        }

        // Pass 3: walk the new order and emit only the ops that are actually
        // needed, simulating the client's list as we go.
        for (pairs.items) |p| {
            const j: u32 = @intCast(p.new_idx);
            const nc = new.children.items[p.new_idx];
            if (p.old_idx) |oi| {
                const oc = alive.items[oi];
                const at = std.mem.indexOfScalar(u32, cur.items, oc.id) orelse cur.items.len;
                if (at != j) {
                    _ = cur.orderedRemove(at);
                    try cur.insert(@intCast(j), oc.id);
                    try self.ops.append(.{ .move = .{ .id = oc.id, .parent = new.id, .index = j } });
                    self.stats.moved += 1;
                }
                try self.diffNode(oc, nc);
            } else {
                self.assignIds(nc);
                self.stats.inserted += 1;
                try cur.insert(@intCast(j), nc.id);
                try self.ops.append(.{ .insert = .{ .parent = new.id, .index = j, .node = nc } });
            }
        }
    }
};

fn sameEventNames(a: *const vdom.Node, b: *const vdom.Node) bool {
    if (a.events.items.len != b.events.items.len) return false;
    for (a.events.items) |ae| {
        var found = false;
        for (b.events.items) |be| {
            if (std.mem.eql(u8, ae.event, be.event)) {
                found = true;
                break;
            }
        }
        if (!found) return false;
    }
    return true;
}

pub fn sameNode(a: *const vdom.Node, b: *const vdom.Node) bool {
    if (a.tag != b.tag) return false;
    if (!std.mem.eql(u8, a.tag_name, b.tag_name)) return false;
    const ka = a.key;
    const kb = b.key;
    if (ka == null and kb == null) return true;
    if (ka == null or kb == null) return false;
    return ka.?.eql(kb.?);
}
