//! The virtual UI tree and its builder.
//!
//! The compiler emits `ui_*` instructions; the VM drives a `Builder` that
//! assembles a tree of heap `Node`s. Ownership rules:
//!
//!   * every `Value` inside a node (props, text, handler closures, keys) is
//!     retained exactly once by that node and released when the node dies
//!   * `owned` marks a node that a parent (or the session tree) is responsible
//!     for, so an aborted render can clean up only the orphans
//!   * destruction is two-phase (release values, then free structs) so a
//!     recursive walk can never touch freed memory

const std = @import("std");
const value = @import("value.zig");

pub const Tag = enum {
    stack,
    row,
    box,
    card,
    grid,
    text,
    heading,
    button,
    input,
    textarea,
    checkbox,
    image,
    link,
    divider,
    badge,
    spacer,
    code,
    scroll,
    custom,

    pub fn of(name: []const u8) Tag {
        const table = [_]struct { n: []const u8, t: Tag }{
            .{ .n = "stack", .t = .stack },
            .{ .n = "column", .t = .stack },
            .{ .n = "row", .t = .row },
            .{ .n = "box", .t = .box },
            .{ .n = "div", .t = .box },
            .{ .n = "card", .t = .card },
            .{ .n = "grid", .t = .grid },
            .{ .n = "text", .t = .text },
            .{ .n = "p", .t = .text },
            .{ .n = "span", .t = .text },
            .{ .n = "heading", .t = .heading },
            .{ .n = "h1", .t = .heading },
            .{ .n = "h2", .t = .heading },
            .{ .n = "button", .t = .button },
            .{ .n = "btn", .t = .button },
            .{ .n = "input", .t = .input },
            .{ .n = "textfield", .t = .input },
            .{ .n = "textarea", .t = .textarea },
            .{ .n = "checkbox", .t = .checkbox },
            .{ .n = "toggle", .t = .checkbox },
            .{ .n = "image", .t = .image },
            .{ .n = "img", .t = .image },
            .{ .n = "link", .t = .link },
            .{ .n = "a", .t = .link },
            .{ .n = "divider", .t = .divider },
            .{ .n = "hr", .t = .divider },
            .{ .n = "badge", .t = .badge },
            .{ .n = "spacer", .t = .spacer },
            .{ .n = "code", .t = .code },
            .{ .n = "pre", .t = .code },
            .{ .n = "scroll", .t = .scroll },
        };
        for (table) |e| {
            if (std.mem.eql(u8, name, e.n)) return e.t;
        }
        return .custom;
    }

    /// Whether a positional argument becomes a text child.
    pub fn takesText(self: Tag) bool {
        return switch (self) {
            .text, .heading, .button, .link, .badge, .code => true,
            else => false,
        };
    }
};

pub const Key = union(enum) {
    str: []const u8,
    num: i64,

    pub fn release(self: Key) void {
        switch (self) {
            .str => |s| value.alloc.free(@constCast(s)),
            .num => {},
        }
    }

    pub fn eql(a: Key, b: Key) bool {
        return switch (a) {
            .str => |s| switch (b) {
                .str => |o| std.mem.eql(u8, s, o),
                else => false,
            },
            .num => |n| switch (b) {
                .num => |o| n == o,
                else => false,
            },
        };
    }

    /// Derive a stable key from a loop item value.
    pub fn fromValue(v: value.Value) !Key {
        return switch (v) {
            .int => |i| Key{ .num = i },
            .float => |f| Key{ .num = @intFromFloat(f) },
            .boolean => |b| Key{ .num = if (b) 1 else 0 },
            .str => |s| Key{ .str = try value.alloc.dupe(u8, s.bytes) },
            else => Key{ .num = 0 }, // lists/maps fall back to index keys
        };
    }

    pub fn isUsable(v: value.Value) bool {
        return switch (v) {
            .int, .float, .boolean, .str => true,
            else => false,
        };
    }
};

pub const Prop = struct {
    name: []const u8,
    value: value.Value,
};

pub const EventHandler = struct {
    /// Wire name: "click", "enter", "change", "input", ...
    event: []const u8,
    callable: value.Value,
};

pub const Node = struct {
    id: u32 = 0,
    tag: Tag = .box,
    /// Source tag name, sent to the client (also used for `.custom`).
    tag_name: []const u8 = "box",
    text: value.Value = .{ .nil = {} },
    props: std.ArrayList(Prop),
    events: std.ArrayList(EventHandler),
    children: std.ArrayList(*Node),
    /// Signal name for two-way `bind:` ("" when absent).
    bind: []const u8 = "",
    key: ?Key = null,
    /// True once a parent node or the session tree owns this node.
    owned: bool = false,
    /// True once its values have been released.
    dead: bool = false,
    /// Index into `Builder.nodes`, so `ui_end` is O(1).
    handle: i64 = -1,

    pub fn init(a: std.mem.Allocator) !*Node {
        const n = try a.create(Node);
        n.* = .{
            .props = std.ArrayList(Prop).init(a),
            .events = std.ArrayList(EventHandler).init(a),
            .children = std.ArrayList(*Node).init(a),
        };
        return n;
    }

    pub fn isText(self: *const Node) bool {
        return self.tag == .text and self.children.items.len == 0 and self.props.items.len == 0;
    }

    pub fn getProp(self: *const Node, name: []const u8) ?value.Value {
        for (self.props.items) |p| {
            if (std.mem.eql(u8, p.name, name)) return p.value;
        }
        return null;
    }

    pub fn setProp(self: *Node, name: []const u8, v: value.Value) !void {
        for (self.props.items) |*p| {
            if (std.mem.eql(u8, p.name, name)) {
                p.value.release();
                p.value = v;
                return;
            }
        }
        try self.props.append(.{ .name = name, .value = v });
    }

    pub fn findEvent(self: *const Node, event: []const u8) ?value.Value {
        for (self.events.items) |e| {
            if (std.mem.eql(u8, e.event, event)) return e.callable;
        }
        return null;
    }

    /// Phase 1: release every value below this node, keeping structure intact.
    pub fn releaseDeep(self: *Node) void {
        if (self.dead) return;
        self.dead = true;
        for (self.children.items) |c| c.releaseDeep();
        for (self.props.items) |p| p.value.release();
        for (self.events.items) |e| e.callable.release();
        self.text.release();
        if (self.key) |k| k.release();
    }

    /// Phase 2a: free only this node's own storage (children must be freed by
    /// whoever holds the flat list, so we never touch a node twice).
    pub fn freeShallow(self: *Node, a: std.mem.Allocator) void {
        self.children.deinit();
        self.props.deinit();
        self.events.deinit();
        a.destroy(self);
    }

    /// Phase 2b: free this node and everything below it. Only valid when no
    /// other structure also enumerates the descendants.
    pub fn freeDeep(self: *Node, a: std.mem.Allocator) void {
        for (self.children.items) |c| c.freeDeep(a);
        self.freeShallow(a);
    }

    /// Release a whole subtree from a single root pointer.
    pub fn destroy(self: *Node, a: std.mem.Allocator) void {
        self.releaseDeep();
        self.freeDeep(a);
    }

    pub fn count(self: *const Node) usize {
        var n: usize = 1;
        for (self.children.items) |c| n += c.count();
        return n;
    }
};

/// Assembles the tree during a render pass.
pub const Builder = struct {
    alloc: std.mem.Allocator,
    /// Every node created this pass, so an aborted render can be cleaned up.
    nodes: std.ArrayList(*Node),
    stack: std.ArrayList(*Node),
    pending_key: ?Key = null,
    root: ?*Node = null,

    pub fn init(a: std.mem.Allocator) Builder {
        return .{
            .alloc = a,
            .nodes = std.ArrayList(*Node).init(a),
            .stack = std.ArrayList(*Node).init(a),
        };
    }

    pub fn deinit(self: *Builder) void {
        self.abort();
        self.nodes.deinit();
        self.stack.deinit();
    }

    /// Discard every node created since the last reset (used after a failed
    /// render, or when the builder itself goes away). Two-phase and flat:
    /// values are released through the tree, then every struct in `nodes` is
    /// freed exactly once.
    pub fn abort(self: *Builder) void {
        if (self.root) |r| {
            if (!r.dead) r.releaseDeep();
        }
        for (self.nodes.items) |n| {
            if (!n.owned and !n.dead) n.releaseDeep();
        }
        for (self.nodes.items) |n| {
            if (n.dead) n.freeShallow(self.alloc);
        }
        if (self.pending_key) |k| {
            k.release();
            self.pending_key = null;
        }
        self.stack.clearRetainingCapacity();
        self.nodes.clearRetainingCapacity();
        self.root = null;
    }

    /// Start a new render pass without touching the nodes already handed to the tree.
    pub fn reset(self: *Builder) void {
        self.nodes.clearRetainingCapacity();
        self.stack.clearRetainingCapacity();
        if (self.pending_key) |k| {
            k.release();
            self.pending_key = null;
        }
        self.root = null;
    }

    fn current(self: *Builder) ?*Node {
        if (self.stack.items.len == 0) return null;
        return self.stack.items[self.stack.items.len - 1];
    }

    pub fn begin(self: *Builder, tag_name: []const u8) !void {
        const n = try Node.init(self.alloc);
        n.tag = Tag.of(tag_name);
        n.tag_name = tag_name;
        n.handle = @intCast(self.nodes.items.len);
        // A pending key belongs to the first node *opened* after `ui_key`, i.e.
        // the outermost element of a loop iteration — not the first one closed,
        // which would be some descendant.
        if (self.pending_key) |k| {
            n.key = k;
            self.pending_key = null;
        }
        try self.nodes.append(n);
        try self.stack.append(n);
    }

    /// `v` ownership transfers to the node.
    pub fn prop(self: *Builder, name: []const u8, v: value.Value) !void {
        const n = self.current() orelse return v.release();
        try n.setProp(name, v);
    }

    /// `callable` ownership transfers to the node.
    pub fn event(self: *Builder, name: []const u8, callable: value.Value) !void {
        const n = self.current() orelse return callable.release();
        for (n.events.items) |*e| {
            if (std.mem.eql(u8, e.event, name)) {
                e.callable.release();
                e.callable = callable;
                return;
            }
        }
        try n.events.append(.{ .event = name, .callable = callable });
    }

    /// `v` ownership transfers to the node.
    pub fn text(self: *Builder, v: value.Value) !void {
        const n = self.current() orelse return v.release();
        const t = try Node.init(self.alloc);
        t.tag = .text;
        t.tag_name = "text";
        t.text = v;
        t.owned = true;
        t.handle = @intCast(self.nodes.items.len);
        try self.nodes.append(t);
        try n.children.append(t);
    }

    /// `v` ownership transfers to the builder (consumed by the next `end`).
    pub fn key(self: *Builder, v: value.Value) void {
        if (self.pending_key) |k| k.release();
        if (!Key.isUsable(v)) {
            v.release();
            self.pending_key = null;
            return;
        }
        const k = Key.fromValue(v) catch {
            v.release();
            self.pending_key = null;
            return;
        };
        v.release();
        self.pending_key = k;
    }

    pub fn bind(self: *Builder, signal_name: []const u8) !void {
        const n = self.current() orelse return;
        n.bind = signal_name;
    }

    /// Close the current node and return its handle (index into `nodes`).
    pub fn end(self: *Builder) !i64 {
        if (self.stack.items.len == 0) return -1;
        const n = self.stack.pop();
        return n.handle;
    }

    /// Attach a previously closed node to the current node. `handle` ownership
    /// transfers to the parent.
    pub fn child(self: *Builder, handle: i64) !void {
        if (handle < 0 or handle >= self.nodes.items.len) return;
        const n = self.nodes.items[@intCast(handle)];
        if (n.owned or n.dead) return;
        const parent = self.current();
        if (parent == null) {
            n.owned = true;
            self.root = n;
            return;
        }
        n.owned = true;
        try parent.?.children.append(n);
    }

    pub fn nodeAt(self: *const Builder, handle: i64) ?*Node {
        if (handle < 0 or handle >= self.nodes.items.len) return null;
        return self.nodes.items[@intCast(handle)];
    }
};
