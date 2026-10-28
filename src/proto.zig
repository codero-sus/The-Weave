//! Wire protocol: vdom/ops <-> JSON, plus parsing of client messages.
//!
//! Frames (server -> client):
//!   {"t":"hello","app":"Name","v":N,"p":1}
//!   {"t":"mount","root":<node>}
//!   {"t":"patch","ops":[<op>,...]}
//!   {"t":"state","state":{...}}
//!   {"t":"error","message":"..."}
//!   {"t":"reload"}
//!   {"t":"pong"}
//!
//! Frames (client -> server):
//!   {"t":"event","id":12,"name":"click","args":[]}
//!   {"t":"input","id":12,"value":"text"}
//!   {"t":"ping"}
//!
//! Node shape: {"i":id,"t":tag,"p":props,"e":events,"b":bind,"x":text,"c":children}
//! Op shape:   {"o":"r","i":id} | {"o":"i","p":pid,"a":idx,"n":node}
//!             {"o":"m","i":id,"p":pid,"a":idx} | {"o":"u","i":id,"p":props,"x":text,"e":events}

const std = @import("std");
const jsonw = @import("jsonw.zig");
const value = @import("value.zig");
const vdom = @import("vdom.zig");
const diff = @import("diff.zig");

pub const version: u32 = 1;

pub fn writeNode(w: *jsonw.Writer, n: *const vdom.Node) !void {
    // Uniform for every node: `text(...)` elements and the raw text children
    // that `Builder.text` spawns both use tag `.text`, so nothing may be
    // inferred from the tag alone.
    try w.beginObj();
    try w.key("i");
    try w.uint(n.id);
    try w.sep();
    try w.key("t");
    try w.str(n.tag_name);

    switch (n.text) {
        .nil => {},
        else => {
            try w.sep();
            try w.key("x");
            try w.value(n.text);
        },
    }
    if (n.props.items.len > 0) {
        try w.sep();
        try w.key("p");
        try w.beginObj();
        for (n.props.items, 0..) |p, i| {
            if (i > 0) try w.sep();
            try w.key(p.name);
            try w.value(p.value);
        }
        try w.endObj();
    }
    if (n.events.items.len > 0) {
        try w.sep();
        try w.key("e");
        try w.beginArr();
        for (n.events.items, 0..) |e, i| {
            if (i > 0) try w.sep();
            try w.str(e.event);
        }
        try w.endArr();
    }
    if (n.bind.len > 0) {
        try w.sep();
        try w.key("b");
        try w.str(n.bind);
    }
    if (n.children.items.len > 0) {
        try w.sep();
        try w.key("c");
        try w.beginArr();
        for (n.children.items, 0..) |c, i| {
            if (i > 0) try w.sep();
            try writeNode(w, c);
        }
        try w.endArr();
    }
    try w.endObj();
}

pub fn writeHello(w: *jsonw.Writer, app_name: []const u8, generation: u32) !void {
    try w.beginObj();
    try w.key("t");
    try w.str("hello");
    try w.sep();
    try w.key("app");
    try w.str(app_name);
    try w.sep();
    try w.key("v");
    try w.uint(generation);
    try w.sep();
    try w.key("p");
    try w.uint(version);
    try w.endObj();
}

pub fn writeMount(w: *jsonw.Writer, root: *const vdom.Node) !void {
    try w.beginObj();
    try w.key("t");
    try w.str("mount");
    try w.sep();
    try w.key("root");
    try writeNode(w, root);
    try w.endObj();
}

pub fn writePatch(w: *jsonw.Writer, ops: []const diff.Op) !void {
    try w.beginObj();
    try w.key("t");
    try w.str("patch");
    try w.sep();
    try w.key("ops");
    try w.beginArr();
    for (ops, 0..) |op, oi| {
        if (oi > 0) try w.sep();
        try w.beginObj();
        switch (op) {
            .remove => |id| {
                try w.key("o");
                try w.str("r");
                try w.sep();
                try w.key("i");
                try w.uint(id);
            },
            .insert => |ins| {
                try w.key("o");
                try w.str("i");
                try w.sep();
                try w.key("p");
                try w.uint(ins.parent);
                try w.sep();
                try w.key("a");
                try w.uint(ins.index);
                try w.sep();
                try w.key("n");
                try writeNode(w, ins.node);
            },
            .move => |mv| {
                try w.key("o");
                try w.str("m");
                try w.sep();
                try w.key("i");
                try w.uint(mv.id);
                try w.sep();
                try w.key("p");
                try w.uint(mv.parent);
                try w.sep();
                try w.key("a");
                try w.uint(mv.index);
            },
            .update => |u| {
                try w.key("o");
                try w.str("u");
                try w.sep();
                try w.key("i");
                try w.uint(u.id);
                if (u.text) |t| {
                    try w.sep();
                    try w.key("x");
                    try w.value(t);
                }
                if (u.props.len > 0) {
                    try w.sep();
                    try w.key("p");
                    try w.beginObj();
                    for (u.props, 0..) |p, i| {
                        if (i > 0) try w.sep();
                        try w.key(p.name);
                        if (p.removed) {
                            try w.nullLit();
                        } else {
                            try w.value(p.val);
                        }
                    }
                    try w.endObj();
                }
                if (u.events) |evs| {
                    try w.sep();
                    try w.key("e");
                    try w.beginArr();
                    for (evs, 0..) |e, i| {
                        if (i > 0) try w.sep();
                        try w.str(e);
                    }
                    try w.endArr();
                }
            },
        }
        try w.endObj();
    }
    try w.endArr();
    try w.endObj();
}

pub fn writeError(w: *jsonw.Writer, message: []const u8) !void {
    try w.beginObj();
    try w.key("t");
    try w.str("error");
    try w.sep();
    try w.key("message");
    try w.str(message);
    try w.endObj();
}

pub fn writeReload(w: *jsonw.Writer) !void {
    try w.beginObj();
    try w.key("t");
    try w.str("reload");
    try w.endObj();
}

pub fn writePong(w: *jsonw.Writer) !void {
    try w.beginObj();
    try w.key("t");
    try w.str("pong");
    try w.endObj();
}

/// Devtools view of every signal: {"t":"state","state":{name: value, ...}}
pub fn writeState(w: *jsonw.Writer, snapshot: value.Value) !void {
    try w.beginObj();
    try w.key("t");
    try w.str("state");
    try w.sep();
    try w.key("state");
    try w.value(snapshot);
    try w.endObj();
}

// ---------------------------------------------------------------------------
// client -> server
// ---------------------------------------------------------------------------

pub const ClientMsg = union(enum) {
    event: struct { id: u32, name: []const u8, args: value.Value },
    input: struct { id: u32, value: value.Value },
    ping,
    unknown,

    pub fn release(self: ClientMsg) void {
        switch (self) {
            .event => |e| e.args.release(),
            .input => |i| i.value.release(),
            else => {},
        }
    }
};

/// Event names a client may send, interned so a parsed message can hand back a
/// static slice instead of memory owned by the transient JSON parse.
pub const known_events = [_][]const u8{
    "click", "dblclick", "change", "input", "enter",
    "submit", "key", "focus", "blur", "scroll",
};

pub fn internEventName(s: []const u8) ?[]const u8 {
    for (known_events) |k| {
        if (std.mem.eql(u8, k, s)) return k;
    }
    return null;
}

pub fn jsonToValue(jv: std.json.Value) value.Value {
    return switch (jv) {
        .null => value.Value{ .nil = {} },
        .bool => |b| value.Value.booleanOf(b),
        .integer => |i| value.Value.intOf(i),
        .float => |f| value.Value.floatOf(f),
        .number_string, .string => |s| value.makeStr(s) catch value.Value{ .nil = {} },
        .array => |arr| blk: {
            var items = std.ArrayList(value.Value).init(value.alloc);
            defer items.deinit();
            for (arr.items) |item| {
                items.append(jsonToValue(item)) catch break :blk value.Value{ .nil = {} };
            }
            break :blk value.makeListFrom(items.items) catch value.Value{ .nil = {} };
        },
        .object => |obj| blk: {
            const m = value.makeMap() catch break :blk value.Value{ .nil = {} };
            var it = obj.iterator();
            while (it.next()) |e| {
                const v = jsonToValue(e.value_ptr.*);
                m.map.set(e.key_ptr.*, v) catch {
                    v.release();
                    m.release();
                    break :blk value.Value{ .nil = {} };
                };
            }
            break :blk m;
        },
    };
}

fn fieldInt(obj: std.json.ObjectMap, name: []const u8) u32 {
    const iv = obj.get(name) orelse return 0;
    return switch (iv) {
        .integer => |i| if (i > 0 and i <= 0xFFFFFFFF) @intCast(i) else 0,
        .float => |f| if (f > 0 and f <= 0xFFFFFFFF) @as(u32, @intFromFloat(f)) else 0,
        else => 0,
    };
}

pub fn parseClientMsg(alloc: std.mem.Allocator, bytes: []const u8) ClientMsg {
    const parsed = std.json.parseFromSlice(std.json.Value, alloc, bytes, .{}) catch
        return .unknown;
    defer parsed.deinit();
    if (parsed.value != .object) return .unknown;
    const obj = parsed.value.object;

    const t_val = obj.get("t") orelse return .unknown;
    if (t_val != .string) return .unknown;
    const t = t_val.string;

    if (std.mem.eql(u8, t, "ping")) return .ping;
    if (std.mem.eql(u8, t, "event")) {
        const name_val = obj.get("name") orelse return .unknown;
        if (name_val != .string) return .unknown;
        const name = internEventName(name_val.string) orelse return .unknown;
        const args = if (obj.get("args")) |av| jsonToValue(av) else value.Value{ .nil = {} };
        return .{ .event = .{ .id = fieldInt(obj, "id"), .name = name, .args = args } };
    }
    if (std.mem.eql(u8, t, "input")) {
        const v = if (obj.get("value")) |vv| jsonToValue(vv) else value.Value{ .nil = {} };
        return .{ .input = .{ .id = fieldInt(obj, "id"), .value = v } };
    }
    return .unknown;
}
