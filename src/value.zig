//! Runtime values.
//!
//! Weave values are dynamically typed and reference-counted. Small scalars are
//! inline; strings, lists, maps and closures live in refcounted boxes so copies
//! are cheap (O(1) retain) and ownership is explicit.
//!
//! Every session is single-threaded (one connection = one thread = one state),
//! so the refcounts are plain integers — no atomics, no locks, no GC pauses.

const std = @import("std");

/// Process-wide allocator. Initialised by `initRuntime`.
pub var alloc: std.mem.Allocator = undefined;

var gpa: std.heap.GeneralPurposeAllocator(.{ .thread_safe = true }) = .{};
var runtime_ready = false;

pub fn initRuntime() void {
    if (runtime_ready) return;
    alloc = gpa.allocator();
    runtime_ready = true;
}

/// Point the runtime at a caller-supplied allocator (tests use
/// `std.testing.allocator` to get per-test leak detection).
pub fn useAllocator(a: std.mem.Allocator) void {
    alloc = a;
    runtime_ready = true;
}

/// Returns true when no leaks were detected.
pub fn deinitRuntime() bool {
    if (!runtime_ready) return true;
    runtime_ready = false;
    return gpa.deinit() == .ok;
}

pub const Kind = enum(u8) {
    nil,
    boolean,
    int,
    float,
    str,
    list,
    map,
    func,

    pub fn name(self: Kind) []const u8 {
        return switch (self) {
            .nil => "null",
            .boolean => "bool",
            .int => "int",
            .float => "float",
            .str => "string",
            .list => "list",
            .map => "map",
            .func => "handler",
        };
    }
};

pub const StrBox = struct {
    rc: u32 = 1,
    bytes: []u8,
};

pub const ListBox = struct {
    rc: u32 = 1,
    items: std.ArrayList(Value),

    pub fn len(self: *const ListBox) usize {
        return self.items.items.len;
    }
};

pub const MapEntry = struct {
    key: []u8,
    value: Value,
};

pub const MapBox = struct {
    rc: u32 = 1,
    entries: std.ArrayList(MapEntry),

    pub fn len(self: *const MapBox) usize {
        return self.entries.items.len;
    }

    pub fn getPtr(self: *MapBox, key: []const u8) ?*Value {
        for (self.entries.items) |*e| {
            if (std.mem.eql(u8, e.key, key)) return &e.value;
        }
        return null;
    }

    pub fn get(self: *const MapBox, key: []const u8) ?Value {
        for (self.entries.items) |e| {
            if (std.mem.eql(u8, e.key, key)) return e.value;
        }
        return null;
    }

    pub fn set(self: *MapBox, key: []const u8, v: Value) !void {
        if (self.getPtr(key)) |slot| {
            slot.release();
            slot.* = v;
            return;
        }
        const k = try alloc.dupe(u8, key);
        errdefer alloc.free(k);
        try self.entries.append(.{ .key = k, .value = v });
    }

    pub fn remove(self: *MapBox, key: []const u8) bool {
        for (self.entries.items, 0..) |e, i| {
            if (std.mem.eql(u8, e.key, key)) {
                e.value.release();
                alloc.free(e.key);
                _ = self.entries.orderedRemove(i);
                return true;
            }
        }
        return false;
    }

    pub fn indexOf(self: *const MapBox, key: []const u8) ?usize {
        for (self.entries.items, 0..) |e, i| {
            if (std.mem.eql(u8, e.key, key)) return i;
        }
        return null;
    }
};

/// A callable value: a compiled function plus its by-value captures.
///
/// Captures are a *snapshot* taken when the closure is created, which is exactly
/// what an event handler inside a `for` loop needs: each rendered row keeps the
/// loop variable it was rendered with.
pub const FuncBox = struct {
    rc: u32 = 1,
    name: []const u8 = "",
    /// Index into `CodeUnit.funcs`.
    func_idx: u32 = 0,
    /// Owned: released with the box.
    captures: []const Value = &.{},
};

pub const Value = union(Kind) {
    nil,
    boolean: bool,
    int: i64,
    float: f64,
    str: *StrBox,
    list: *ListBox,
    map: *MapBox,
    func: *FuncBox,

    pub const null_value: Value = .{ .nil = {} };

    pub fn booleanOf(b: bool) Value {
        return .{ .boolean = b };
    }

    pub fn intOf(i: i64) Value {
        return .{ .int = i };
    }

    pub fn floatOf(f: f64) Value {
        return .{ .float = f };
    }

    pub fn isRefcounted(self: Value) bool {
        return switch (self) {
            .str, .list, .map, .func => true,
            else => false,
        };
    }

    pub fn retain(self: Value) Value {
        switch (self) {
            .str => |b| b.rc += 1,
            .list => |b| b.rc += 1,
            .map => |b| b.rc += 1,
            .func => |b| b.rc += 1,
            else => {},
        }
        return self;
    }

    pub fn release(self: Value) void {
        switch (self) {
            .str => |b| {
                if (b.rc == 0) return;
                b.rc -= 1;
                if (b.rc == 0) {
                    alloc.free(b.bytes);
                    alloc.destroy(b);
                }
            },
            .list => |b| {
                if (b.rc == 0) return;
                b.rc -= 1;
                if (b.rc == 0) {
                    for (b.items.items) |it| it.release();
                    b.items.deinit();
                    alloc.destroy(b);
                }
            },
            .map => |b| {
                if (b.rc == 0) return;
                b.rc -= 1;
                if (b.rc == 0) {
                    for (b.entries.items) |e| {
                        e.value.release();
                        alloc.free(e.key);
                    }
                    b.entries.deinit();
                    alloc.destroy(b);
                }
            },
            .func => |b| {
                if (b.rc == 0) return;
                b.rc -= 1;
                if (b.rc == 0) {
                    for (b.captures) |c| c.release();
                    if (b.captures.len > 0) alloc.free(@constCast(b.captures));
                    alloc.destroy(b);
                }
            },
            else => {},
        }
    }

    pub fn typeName(self: Value) []const u8 {
        return std.meta.activeTag(self).name();
    }

    pub fn truthy(self: Value) bool {
        return switch (self) {
            .nil => false,
            .boolean => |b| b,
            .int => |i| i != 0,
            .float => |f| f != 0,
            .str => |s| s.bytes.len > 0,
            .list => |l| l.items.items.len > 0,
            .map => |m| m.entries.items.len > 0,
            .func => true,
        };
    }

    pub fn deepEqual(self: Value, other: Value) bool {
        const a = std.meta.activeTag(self);
        const b = std.meta.activeTag(other);
        // int/float compare equal when numerically equal.
        if ((a == .int or a == .float) and (b == .int or b == .float)) {
            return self.toFloat() == other.toFloat();
        }
        if (a != b) return false;
        return switch (self) {
            .nil => true,
            .boolean => |x| x == other.boolean,
            .int => |x| x == other.int,
            .float => |x| x == other.float,
            .str => |x| std.mem.eql(u8, x.bytes, other.str.bytes),
            .list => |x| blk: {
                const y = other.list;
                if (x == y) break :blk true;
                if (x.items.items.len != y.items.items.len) break :blk false;
                for (x.items.items, y.items.items) |xi, yi| {
                    if (!xi.deepEqual(yi)) break :blk false;
                }
                break :blk true;
            },
            .map => |x| blk: {
                const y = other.map;
                if (x == y) break :blk true;
                if (x.entries.items.len != y.entries.items.len) break :blk false;
                for (x.entries.items) |e| {
                    const ov = y.get(e.key) orelse break :blk false;
                    if (!e.value.deepEqual(ov)) break :blk false;
                }
                break :blk true;
            },
            .func => |x| x == other.func,
        };
    }

    pub fn toFloat(self: Value) f64 {
        return switch (self) {
            .nil => 0,
            .boolean => |b| if (b) 1 else 0,
            .int => |i| @floatFromInt(i),
            .float => |f| f,
            .str => |s| std.fmt.parseFloat(f64, s.bytes) catch 0,
            else => 0,
        };
    }

    pub fn toInt(self: Value) i64 {
        return switch (self) {
            .nil => 0,
            .boolean => |b| if (b) 1 else 0,
            .int => |i| i,
            .float => |f| @intFromFloat(@trunc(f)),
            .str => |s| std.fmt.parseInt(i64, s.bytes, 10) catch 0,
            else => 0,
        };
    }

    /// Render as the user would see it (string interpolation, `text(...)`).
    pub fn display(self: Value, out: *std.ArrayList(u8)) error{OutOfMemory}!void {
        switch (self) {
            .nil => try out.appendSlice("null"),
            .boolean => |b| try out.appendSlice(if (b) "true" else "false"),
            .int => |i| try out.writer().print("{d}", .{i}),
            .float => |f| try out.writer().print("{d}", .{f}),
            .str => |s| try out.appendSlice(s.bytes),
            .list => |l| {
                try out.append('[');
                for (l.items.items, 0..) |it, i| {
                    if (i > 0) try out.appendSlice(", ");
                    try it.displayQuoted(out);
                }
                try out.append(']');
            },
            .map => |m| {
                try out.append('{');
                for (m.entries.items, 0..) |e, i| {
                    if (i > 0) try out.appendSlice(", ");
                    try out.writer().print("{s}: ", .{e.key});
                    try e.value.displayQuoted(out);
                }
                try out.append('}');
            },
            .func => |f| try out.writer().print("<handler {s}>", .{if (f.name.len > 0) f.name else "inline"}),
        }
    }

    fn displayQuoted(self: Value, out: *std.ArrayList(u8)) error{OutOfMemory}!void {
        if (self == .str) {
            try out.append('"');
            try out.appendSlice(self.str.bytes);
            try out.append('"');
        } else {
            try self.display(out);
        }
    }

    pub fn displayAlloc(self: Value) error{OutOfMemory}![]u8 {
        var list = std.ArrayList(u8).init(alloc);
        errdefer list.deinit();
        try self.display(&list);
        return try list.toOwnedSlice();
    }

    pub fn deepCopy(self: Value) error{OutOfMemory}!Value {
        return switch (self) {
            .str => |s| makeStr(s.bytes),
            .list => |l| blk: {
                const out = try makeList();
                try out.list.items.ensureTotalCapacity(l.items.items.len);
                for (l.items.items) |it| {
                    const c = try it.deepCopy();
                    try out.list.items.append(c);
                }
                break :blk out;
            },
            .map => |m| blk: {
                const out = try makeMap();
                for (m.entries.items) |e| {
                    const c = try e.value.deepCopy();
                    try out.map.set(e.key, c);
                }
                break :blk out;
            },
            .func => self.retain(),
            else => self,
        };
    }
};

// ---------------------------------------------------------------------------
// Constructors
// ---------------------------------------------------------------------------

pub fn makeStr(bytes: []const u8) !Value {
    const box = try alloc.create(StrBox);
    errdefer alloc.destroy(box);
    box.bytes = try alloc.dupe(u8, bytes);
    box.rc = 1;
    return Value{ .str = box };
}

pub fn makeList() !Value {
    const box = try alloc.create(ListBox);
    errdefer alloc.destroy(box);
    box.* = .{ .rc = 1, .items = std.ArrayList(Value).init(alloc) };
    return Value{ .list = box };
}

pub fn makeListFrom(items: []const Value) !Value {
    const v = try makeList();
    try v.list.items.appendSlice(items);
    return v;
}

pub fn makeMap() !Value {
    const box = try alloc.create(MapBox);
    errdefer alloc.destroy(box);
    box.* = .{ .rc = 1, .entries = std.ArrayList(MapEntry).init(alloc) };
    return Value{ .map = box };
}

pub fn makeFunc(name: []const u8, func_idx: u32, captures: []const Value) !Value {
    const box = try alloc.create(FuncBox);
    errdefer alloc.destroy(box);
    box.* = .{ .rc = 1, .name = name, .func_idx = func_idx, .captures = captures };
    return Value{ .func = box };
}

pub fn releaseValues(vals: []const Value) void {
    for (vals) |v| v.release();
}
