//! Weave bytecode: instruction set, code units, and the `.wvbc` container.
//!
//! The compiler lowers AST -> bytecode once; the VM executes it. A code unit can
//! be serialised to a compact binary (`.wvbc`) so `weave build` produces an
//! artifact that runs without the original source — that is what CI ships.

const std = @import("std");
const value = @import("value.zig");

pub const magic = [_]u8{ 'W', 'V', 'B', 'C' };
pub const format_version: u32 = 1;

pub const Op = enum(u8) {
    nop = 0,
    pop,
    dup,
    dup2, // [a, b] -> [a, b, a, b]

    const_, // a: constant index
    nil,
    true_,
    false_,
    int_small, // a: immediate i32

    local, // a: slot
    set_local, // a: slot
    sig, // a: signal index (tracked read)
    set_sig, // a: signal index (write + notify)
    is_nil, // push bool(TOS == nil)

    // iteration helpers: `count` pops obj -> len; `iter_key`/`iter_at` pop
    // (obj, index) -> the key / value at that position. Over lists, strings and
    // maps alike, which is what makes `for i, x in xs:` uniform.
    count,
    iter_key,
    iter_at,

    list, // a: count
    map, // a: entry count
    index,
    set_index,
    slice,
    member, // a: name constant
    set_member, // a: name constant

    add,
    sub,
    mul,
    div,
    mod_,
    floor_div,
    pow,
    neg,
    not_,
    eq,
    ne,
    lt,
    le,
    gt,
    ge,
    in_,
    not_in,
    concat, // a: part count -> joined string

    jmp, // a: relative offset
    jmp_false_pop, // a: offset, pops
    jmp_true_pop, // a: offset, pops

    call, // a: argc (callee below args)
    call_method, // a: name const, b: argc (receiver below args)
    call_builtin, // a: builtin id, b: argc
    ret,
    ret_nil,

    closure, // a: function index -> callable value capturing listed slots
    schedule_after, // pops (callable, delay_ms) -> arm a timer on the session

    // --- UI builder intrinsics -------------------------------------------
    ui_begin, // a: tag name constant
    ui_prop, // a: name constant; pops value
    ui_event, // a: event name constant; pops callable
    ui_text, // pops value -> text child
    ui_key, // pops value -> key for the next closed node
    ui_key_if_unset, // pops value -> key only when none is pending
    ui_bind, // a: signal name constant
    ui_end, // closes node, pushes handle
    ui_child, // pops handle -> child of current node
};

pub const Instr = struct {
    op: Op,
    a: i32 = 0,
    b: i32 = 0,
    line: u32 = 0,
};

pub const Const = union(enum) {
    nil,
    boolean: bool,
    int: i64,
    float: f64,
    str: []const u8,
};

pub const FuncKind = enum(u8) {
    /// Computes the initial value of one signal; returns it.
    init = 0,
    /// Builds the app view; returns the root node handle.
    render = 1,
    /// A component body; params are props; returns a node handle.
    component = 2,
    /// A declared handler or an inline event closure.
    handler = 3,
    /// An `effects:` entry.
    effect = 4,
};

pub const Func = struct {
    name: []const u8 = "",
    kind: FuncKind = .handler,
    num_params: u32 = 0,
    num_locals: u32 = 0,
    /// Captured by value when a closure is created: `capture_srcs[i]` is a slot
    /// in the *creating* frame, `capture_dests[i]` is the slot in this frame.
    capture_srcs: []const u32 = &.{},
    capture_dests: []const u32 = &.{},
    param_names: []const []const u8 = &.{},
    param_defaults: []const bool = &.{},
    code: []const Instr = &.{},
};

pub const SigKind = enum(u8) {
    state = 0,
    computed = 1,
    theme = 2,
    style = 3,
};

pub const Signal = struct {
    name: []const u8,
    kind: SigKind = .state,
    /// Function index computing the initial value.
    init_fn: u32 = 0,
};

pub const Handler = struct {
    name: []const u8,
    func_idx: u32,
};

pub const Component = struct {
    name: []const u8,
    func_idx: u32,
};

pub const Effect = struct {
    func_idx: u32,
    on_mount: bool = false,
    /// Name shown in traces.
    label: []const u8 = "",
};

pub const CodeUnit = struct {
    app_name: []const u8 = "App",
    consts: []const Const = &.{},
    funcs: []const Func = &.{},
    signals: []const Signal = &.{},
    handlers: []const Handler = &.{},
    components: []const Component = &.{},
    effects: []const Effect = &.{},
    render_fn: u32 = 0,

    pub fn constStr(self: *const CodeUnit, idx: usize) []const u8 {
        const c = self.consts[idx];
        return switch (c) {
            .str => |s| s,
            else => "",
        };
    }

    pub fn findSignal(self: *const CodeUnit, name: []const u8) ?u32 {
        for (self.signals, 0..) |s, i| {
            if (std.mem.eql(u8, s.name, name)) return @intCast(i);
        }
        return null;
    }

    pub fn findHandler(self: *const CodeUnit, name: []const u8) ?u32 {
        for (self.handlers, 0..) |h, i| {
            if (std.mem.eql(u8, h.name, name)) return @intCast(i);
        }
        return null;
    }

    pub fn findComponent(self: *const CodeUnit, name: []const u8) ?u32 {
        for (self.components, 0..) |c, i| {
            if (std.mem.eql(u8, c.name, name)) return @intCast(i);
        }
        return null;
    }
};

// ---------------------------------------------------------------------------
// Serialisation (.wvbc)
// ---------------------------------------------------------------------------

pub const EncodeError = error{OutOfMemory};

pub const Encoder = struct {
    out: std.ArrayList(u8),
    strings: std.ArrayList([]const u8),
    index: std.StringHashMap(u32),

    pub fn init(a: std.mem.Allocator) Encoder {
        return .{
            .out = std.ArrayList(u8).init(a),
            .strings = std.ArrayList([]const u8).init(a),
            .index = std.StringHashMap(u32).init(a),
        };
    }

    pub fn deinit(self: *Encoder) void {
        self.out.deinit();
        self.strings.deinit();
        self.index.deinit();
    }

    fn strId(self: *Encoder, s: []const u8) !u32 {
        if (self.index.get(s)) |id| return id;
        const id: u32 = @intCast(self.strings.items.len);
        try self.strings.append(s);
        try self.index.put(s, id);
        return id;
    }

    fn u8v(self: *Encoder, v: u8) !void {
        try self.out.append(v);
    }
    fn u32v(self: *Encoder, v: u32) !void {
        try self.out.appendSlice(&std.mem.toBytes(v));
    }
    fn i32v(self: *Encoder, v: i32) !void {
        try self.out.appendSlice(&std.mem.toBytes(v));
    }
    fn i64v(self: *Encoder, v: i64) !void {
        try self.out.appendSlice(&std.mem.toBytes(v));
    }
    fn f64v(self: *Encoder, v: f64) !void {
        try self.out.appendSlice(&std.mem.toBytes(@as(u64, @bitCast(v))));
    }
    fn strv(self: *Encoder, s: []const u8) !void {
        try self.u32v(try self.strId(s));
    }

    pub fn encodeUnit(self: *Encoder, u: *const CodeUnit) ![]u8 {
        // Pass 1: everything except the string table (ids are assigned as we go).
        var body = std.ArrayList(u8).init(self.out.allocator);
        defer body.deinit();
        const saved = self.out;
        self.out = body;

        try self.strv(u.app_name);
        try self.u32v(u.render_fn);

        try self.u32v(@intCast(u.consts.len));
        for (u.consts) |c| switch (c) {
            .nil => try self.u8v(0),
            .boolean => |b| {
                try self.u8v(1);
                try self.u8v(if (b) 1 else 0);
            },
            .int => |i| {
                try self.u8v(2);
                try self.i64v(i);
            },
            .float => |f| {
                try self.u8v(3);
                try self.f64v(f);
            },
            .str => |s| {
                try self.u8v(4);
                try self.strv(s);
            },
        };

        try self.u32v(@intCast(u.funcs.len));
        for (u.funcs) |f| {
            try self.strv(f.name);
            try self.u8v(@intFromEnum(f.kind));
            try self.u32v(f.num_params);
            try self.u32v(f.num_locals);
            try self.u32v(@intCast(f.capture_srcs.len));
            for (f.capture_srcs) |c| try self.u32v(c);
            for (f.capture_dests) |c| try self.u32v(c);
            try self.u32v(@intCast(f.param_names.len));
            for (f.param_names) |p| try self.strv(p);
            for (f.param_defaults) |d| try self.u8v(if (d) 1 else 0);
            try self.u32v(@intCast(f.code.len));
            for (f.code) |ins| {
                try self.u8v(@intFromEnum(ins.op));
                try self.i32v(ins.a);
                try self.i32v(ins.b);
                try self.u32v(ins.line);
            }
        }

        try self.u32v(@intCast(u.signals.len));
        for (u.signals) |s| {
            try self.strv(s.name);
            try self.u8v(@intFromEnum(s.kind));
            try self.u32v(s.init_fn);
        }

        try self.u32v(@intCast(u.handlers.len));
        for (u.handlers) |h| {
            try self.strv(h.name);
            try self.u32v(h.func_idx);
        }

        try self.u32v(@intCast(u.components.len));
        for (u.components) |c| {
            try self.strv(c.name);
            try self.u32v(c.func_idx);
        }

        try self.u32v(@intCast(u.effects.len));
        for (u.effects) |e| {
            try self.u32v(e.func_idx);
            try self.u8v(if (e.on_mount) 1 else 0);
            try self.strv(e.label);
        }

        // `self.out` may have reallocated while appending, so copy the live
        // ArrayList back before restoring — otherwise `body.deinit()` frees a
        // stale pointer and the real buffer leaks.
        body = self.out;
        self.out = saved;

        // Pass 2: header + string table + body.
        try self.out.appendSlice(&magic);
        try self.u32v(format_version);
        try self.u32v(@intCast(self.strings.items.len));
        for (self.strings.items) |s| {
            try self.u32v(@intCast(s.len));
            try self.out.appendSlice(s);
        }
        try self.u32v(@intCast(body.items.len));
        try self.out.appendSlice(body.items);
        return try self.out.toOwnedSlice();
    }
};

pub const DecodeError = error{ OutOfMemory, BadBytecode };

pub const Loaded = struct {
    arena: *std.heap.ArenaAllocator,
    parent: std.mem.Allocator,
    unit: *CodeUnit,

    pub fn deinit(self: *Loaded) void {
        const a = self.arena;
        a.deinit();
        self.parent.destroy(a);
    }
};

pub const Decoder = struct {
    a: std.mem.Allocator,
    buf: []const u8,
    pos: usize = 0,
    strings: [][]const u8 = &.{},

    fn need(self: *Decoder, n: usize) DecodeError!void {
        if (self.pos + n > self.buf.len) return error.BadBytecode;
    }

    fn u8v(self: *Decoder) DecodeError!u8 {
        try self.need(1);
        const v = self.buf[self.pos];
        self.pos += 1;
        return v;
    }

    fn u32v(self: *Decoder) DecodeError!u32 {
        try self.need(4);
        const v = std.mem.bytesToValue(u32, self.buf[self.pos..][0..4]);
        self.pos += 4;
        return v;
    }

    fn i32v(self: *Decoder) DecodeError!i32 {
        try self.need(4);
        const v = std.mem.bytesToValue(i32, self.buf[self.pos..][0..4]);
        self.pos += 4;
        return v;
    }

    fn i64v(self: *Decoder) DecodeError!i64 {
        try self.need(8);
        const v = std.mem.bytesToValue(i64, self.buf[self.pos..][0..8]);
        self.pos += 8;
        return v;
    }

    fn f64v(self: *Decoder) DecodeError!f64 {
        try self.need(8);
        const bits = std.mem.bytesToValue(u64, self.buf[self.pos..][0..8]);
        self.pos += 8;
        return @bitCast(bits);
    }

    fn strv(self: *Decoder) DecodeError![]const u8 {
        const id = try self.u32v();
        if (id >= self.strings.len) return error.BadBytecode;
        return self.strings[id];
    }

    fn enumOf(self: *const Decoder, comptime T: type, v: u8) DecodeError!T {
        _ = self;
        return std.meta.intToEnum(T, v) catch error.BadBytecode;
    }
};

/// Decode a `.wvbc` blob into an owned code unit.
pub fn decode(parent: std.mem.Allocator, bytes: []const u8) DecodeError!Loaded {
    const arena_box = try parent.create(std.heap.ArenaAllocator);
    errdefer parent.destroy(arena_box);
    arena_box.* = std.heap.ArenaAllocator.init(parent);
    const a = arena_box.allocator();
    errdefer {
        arena_box.deinit();
        parent.destroy(arena_box);
    }

    if (bytes.len < 12 or !std.mem.eql(u8, bytes[0..4], &magic)) return error.BadBytecode;
    var d = Decoder{ .a = a, .buf = bytes, .pos = 4 };

    const version = try d.u32v();
    if (version != format_version) return error.BadBytecode;

    const n_strings = try d.u32v();
    d.strings = try a.alloc([]const u8, n_strings);
    for (d.strings) |*s| {
        const len = try d.u32v();
        try d.need(len);
        s.* = try a.dupe(u8, bytes[d.pos .. d.pos + len]);
        d.pos += len;
    }

    const body_len = try d.u32v();
    try d.need(body_len);

    const unit = try a.create(CodeUnit);
    unit.* = .{};
    unit.app_name = try d.strv();
    unit.render_fn = try d.u32v();

    const n_consts = try d.u32v();
    const consts = try a.alloc(Const, n_consts);
    for (consts, 0..) |*c, i| {
        const tag = try d.u8v();
        c.* = switch (tag) {
            0 => Const{ .nil = {} },
            1 => .{ .boolean = (try d.u8v()) != 0 },
            2 => .{ .int = try d.i64v() },
            3 => .{ .float = try d.f64v() },
            4 => .{ .str = try d.strv() },
            else => return error.BadBytecode,
        };
        _ = i;
    }
    unit.consts = consts;

    const n_funcs = try d.u32v();
    const funcs = try a.alloc(Func, n_funcs);
    for (funcs) |*f| {
        f.name = try d.strv();
        f.kind = try d.enumOf(FuncKind, try d.u8v());
        f.num_params = try d.u32v();
        f.num_locals = try d.u32v();
        const n_cap = try d.u32v();
        const srcs = try a.alloc(u32, n_cap);
        for (srcs) |*cp| cp.* = try d.u32v();
        f.capture_srcs = srcs;
        const dests = try a.alloc(u32, n_cap);
        for (dests) |*cp| cp.* = try d.u32v();
        f.capture_dests = dests;
        const n_pn = try d.u32v();
        const pns = try a.alloc([]const u8, n_pn);
        for (pns) |*pn| pn.* = try d.strv();
        f.param_names = pns;
        const pdefs = try a.alloc(bool, n_pn);
        for (pdefs) |*pd| pd.* = (try d.u8v()) != 0;
        f.param_defaults = pdefs;
        const n_code = try d.u32v();
        const code = try a.alloc(Instr, n_code);
        for (code) |*ins| {
            ins.op = try d.enumOf(Op, try d.u8v());
            ins.a = try d.i32v();
            ins.b = try d.i32v();
            ins.line = try d.u32v();
        }
        f.code = code;
    }
    unit.funcs = funcs;

    const n_sigs = try d.u32v();
    const sigs = try a.alloc(Signal, n_sigs);
    for (sigs) |*s| {
        s.name = try d.strv();
        s.kind = try d.enumOf(SigKind, try d.u8v());
        s.init_fn = try d.u32v();
    }
    unit.signals = sigs;

    const n_handlers = try d.u32v();
    const handlers = try a.alloc(Handler, n_handlers);
    for (handlers) |*h| {
        h.name = try d.strv();
        h.func_idx = try d.u32v();
    }
    unit.handlers = handlers;

    const n_comps = try d.u32v();
    const comps = try a.alloc(Component, n_comps);
    for (comps) |*c| {
        c.name = try d.strv();
        c.func_idx = try d.u32v();
    }
    unit.components = comps;

    const n_effects = try d.u32v();
    const effects = try a.alloc(Effect, n_effects);
    for (effects) |*e| {
        e.func_idx = try d.u32v();
        e.on_mount = (try d.u8v()) != 0;
        e.label = try d.strv();
    }
    unit.effects = effects;

    return Loaded{ .arena = arena_box, .parent = parent, .unit = unit };
}

pub fn encode(parent: std.mem.Allocator, u: *const CodeUnit) ![]u8 {
    var enc = Encoder.init(parent);
    defer enc.deinit();
    return try enc.encodeUnit(u);
}

/// Human-readable disassembly (used by `weave dump`).
pub fn disassemble(a: std.mem.Allocator, u: *const CodeUnit) ![]u8 {
    var out = std.ArrayList(u8).init(a);
    errdefer out.deinit();
    const w = out.writer();
    try w.print("; weave bytecode v{d}  app={s}\n", .{ format_version, u.app_name });
    try w.print("; {d} consts, {d} funcs, {d} signals\n\n", .{ u.consts.len, u.funcs.len, u.signals.len });

    try w.print("signals:\n", .{});
    for (u.signals, 0..) |s, i| {
        try w.print("  {d:>3} {s:<9} {s}  (init fn {d})\n", .{ i, @tagName(s.kind), s.name, s.init_fn });
    }
    try w.print("\nconstants:\n", .{});
    for (u.consts, 0..) |c, i| {
        try w.print("  {d:>3} ", .{i});
        switch (c) {
            .nil => try w.print("null\n", .{}),
            .boolean => |b| try w.print("{s}\n", .{if (b) "true" else "false"}),
            .int => |n| try w.print("{d}\n", .{n}),
            .float => |f| try w.print("{d}\n", .{f}),
            .str => |s| try w.print("\"{s}\"\n", .{s}),
        }
    }
    try w.print("\n", .{});

    for (u.funcs, 0..) |f, fi| {
        try w.print("fn {d} {s} <{s}> params={d} locals={d} captures={d}\n", .{ fi, f.name, @tagName(f.kind), f.num_params, f.num_locals, f.capture_srcs.len });
        if (f.capture_srcs.len > 0) {
            try w.print("     captures (src->dest):", .{});
            for (f.capture_srcs, f.capture_dests) |s2, d2| try w.print(" {d}->{d}", .{ s2, d2 });
            try w.print("\n", .{});
        }
        for (f.code, 0..) |ins, ii| {
            try w.print("  {d:>4}  {s:<16}", .{ ii, @tagName(ins.op) });
            const needs_a = switch (ins.op) {
                .nop, .pop, .dup, .dup2, .schedule_after, .ui_key_if_unset, .nil, .true_, .false_, .is_nil, .count, .iter_key, .iter_at, .index, .set_index, .slice, .add, .sub, .mul, .div, .mod_, .floor_div, .pow, .neg, .not_, .eq, .ne, .lt, .le, .gt, .ge, .in_, .not_in, .ret, .ret_nil, .ui_text, .ui_key, .ui_end, .ui_child, .set_member => false,
                else => true,
            };
            if (needs_a) {
                switch (ins.op) {
                    .const_, .member, .set_member, .ui_begin, .ui_prop, .ui_event, .ui_bind => {
                        const idx: usize = @intCast(ins.a);
                        if (idx < u.consts.len) {
                            try w.print(" {d} ; ", .{ins.a});
                            switch (u.consts[idx]) {
                                .str => |s| try w.print("\"{s}\"", .{s}),
                                .int => |n| try w.print("{d}", .{n}),
                                .float => |fl| try w.print("{d}", .{fl}),
                                .boolean => |b| try w.print("{s}", .{if (b) "true" else "false"}),
                                .nil => try w.print("null", .{}),
                            }
                        } else {
                            try w.print(" {d}", .{ins.a});
                        }
                    },
                    else => try w.print(" {d}", .{ins.a}),
                }
                if (ins.b != 0) try w.print(", {d}", .{ins.b});
            }
            try w.print("   (line {d})\n", .{ins.line});
        }
        try w.print("\n", .{});
    }
    return try out.toOwnedSlice();
}

/// Size in bytes of a compiled unit's instruction stream (for `weave build` stats).
pub fn codeSize(u: *const CodeUnit) usize {
    var n: usize = 0;
    for (u.funcs) |f| n += f.code.len;
    return n;
}

pub fn emptyValue() value.Value {
    return value.Value{ .nil = {} };
}
