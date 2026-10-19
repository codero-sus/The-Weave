//! The Weave virtual machine.
//!
//! A compact stack machine over refcounted values. Three rules keep it correct:
//!
//!   * **Ownership.** The value stack holds owned references. Producers transfer
//!     ownership on push; consumers release on pop. Every error path releases.
//!   * **No live stack slices across calls.** A nested call can grow the stack's
//!     backing array, so arguments are copied out and the frame is popped
//!     *before* dispatch. Getting this wrong is a use-after-free, not a bug that
//!     shows up in tests.
//!   * **Mutation is visible.** `tasks.append(x)` mutates a box in place, so the
//!     signal graph cannot see it. After every mutating operation the VM asks
//!     the store which signals contain that box (`markMutated`).

const std = @import("std");
const value = @import("value.zig");
const bytecode = @import("bytecode.zig");
const builtins = @import("builtins.zig");
const reactive = @import("reactive.zig");
const vdom = @import("vdom.zig");

pub const Error = error{ WeaveRuntime, OutOfMemory };

pub const max_call_depth: u32 = 200;

pub const TraceFrame = struct {
    func: []const u8,
    line: u32,
};

/// Hooks the host (a session) provides.
pub const Host = struct {
    ctx: *anyopaque,
    schedule_after: *const fn (ctx: *anyopaque, delay_ms: i64, callable: value.Value) void,
    log: *const fn (ctx: *anyopaque, msg: []const u8) void,
};

pub const Vm = struct {
    alloc: std.mem.Allocator,
    unit: *const bytecode.CodeUnit,
    store: *reactive.Store,
    builder: ?*vdom.Builder = null,
    host: ?*const Host = null,

    /// Constants materialised once per session, so `const_` is just a retain.
    consts: []value.Value = &.{},
    stack: std.ArrayList(value.Value),
    trace: std.ArrayList(TraceFrame),
    depth: u32 = 0,
    rng: u64 = 0x9E3779B97F4A7C15,

    err_buf: [2048]u8 = undefined,
    err_len: usize = 0,
    failed: bool = false,

    pub fn init(a: std.mem.Allocator, unit: *const bytecode.CodeUnit, store: *reactive.Store) !Vm {
        var vm = Vm{
            .alloc = a,
            .unit = unit,
            .store = store,
            .stack = std.ArrayList(value.Value).init(a),
            .trace = std.ArrayList(TraceFrame).init(a),
        };
        vm.consts = try a.alloc(value.Value, unit.consts.len);
        for (unit.consts, 0..) |c, i| {
            vm.consts[i] = switch (c) {
                .nil => value.Value{ .nil = {} },
                .boolean => |b| .{ .boolean = b },
                .int => |n| .{ .int = n },
                .float => |f| .{ .float = f },
                .str => |s| try value.makeStr(s),
            };
        }
        return vm;
    }

    pub fn deinit(self: *Vm) void {
        for (self.consts) |c| c.release();
        if (self.consts.len > 0) self.alloc.free(self.consts);
        for (self.stack.items) |v| v.release();
        self.stack.deinit();
        self.trace.deinit();
    }

    // -- stack primitives ---------------------------------------------------

    fn push(self: *Vm, v: value.Value) Error!void {
        try self.stack.append(v);
    }

    fn pop(self: *Vm) Error!value.Value {
        if (self.stack.items.len == 0) return self.fail("internal error: value stack underflow", .{});
        return self.stack.pop();
    }

    fn peek(self: *Vm, off: usize) Error!value.Value {
        if (self.stack.items.len <= off) return self.fail("internal error: value stack underflow", .{});
        return self.stack.items[self.stack.items.len - 1 - off];
    }

    pub fn fail(self: *Vm, comptime fmt: []const u8, args: anytype) Error {
        if (!self.failed) {
            if (std.fmt.bufPrint(&self.err_buf, fmt, args)) |msg| {
                self.err_len = msg.len;
            } else |_| {
                self.err_len = 0;
            }
            self.failed = true;
        }
        return error.WeaveRuntime;
    }

    pub fn errorMessage(self: *const Vm) []const u8 {
        return self.err_buf[0..self.err_len];
    }

    pub fn resetError(self: *Vm) void {
        self.failed = false;
        self.err_len = 0;
        self.trace.clearRetainingCapacity();
    }

    /// A readable stack trace for the last failure.
    pub fn renderTrace(self: *const Vm, a: std.mem.Allocator, path: []const u8) ![]u8 {
        var out = std.ArrayList(u8).init(a);
        errdefer out.deinit();
        var i: usize = self.trace.items.len;
        while (i > 0) {
            i -= 1;
            const t = self.trace.items[i];
            try out.writer().print("    at {s} ({s}:{d})\n", .{ t.func, path, t.line });
        }
        return try out.toOwnedSlice();
    }

    // -- calls --------------------------------------------------------------

    pub fn callFunc(self: *Vm, fn_idx: u32, args: []const value.Value, closure: ?*value.FuncBox) Error!value.Value {
        if (fn_idx >= self.unit.funcs.len) return self.fail("internal error: bad function index {d}", .{fn_idx});
        if (self.depth >= max_call_depth) return self.fail("call stack too deep (infinite recursion?)", .{});
        const f = &self.unit.funcs[fn_idx];

        const n_locals = @max(f.num_locals, 1);
        const locals = try self.alloc.alloc(value.Value, n_locals);
        defer {
            for (locals) |l| l.release();
            self.alloc.free(locals);
        }
        for (locals) |*l| l.* = value.Value{ .nil = {} };

        if (closure) |cl| {
            for (f.capture_dests, 0..) |dest, i| {
                if (i < cl.captures.len and dest < n_locals) {
                    locals[dest] = cl.captures[i].retain();
                }
            }
        }
        const np = @min(args.len, @as(usize, f.num_params));
        for (args[0..np], 0..) |arg, i| {
            if (i < n_locals) locals[i] = arg.retain();
        }

        self.depth += 1;
        defer self.depth -= 1;
        return self.runFrame(f, locals);
    }

    fn runFrame(self: *Vm, f: *const bytecode.Func, locals: []value.Value) Error!value.Value {
        try self.trace.append(.{ .func = f.name, .line = 0 });
        const trace_idx = self.trace.items.len - 1;
        defer self.trace.shrinkRetainingCapacity(trace_idx);

        const code = f.code;
        var pc: usize = 0;
        while (pc < code.len) {
            const ins = code[pc];
            self.trace.items[trace_idx].line = ins.line;
            pc += 1;
            if (try self.step(locals, ins, &pc)) |rv| return rv;
        }
        return value.Value{ .nil = {} };
    }

    fn jump(pc: usize, off: i32) usize {
        const cur: i64 = @intCast(pc - 1);
        const target = cur + off;
        if (target < 0) return 0;
        return @intCast(target);
    }

    /// Execute one instruction. Returns the frame's return value, if any.
    fn step(self: *Vm, locals: []value.Value, ins: bytecode.Instr, pc: *usize) Error!?value.Value {
        switch (ins.op) {
            .nop => {},
            .pop => (try self.pop()).release(),
            .dup => {
                const v = try self.peek(0);
                try self.push(v.retain());
            },
            .dup2 => {
                const b = try self.peek(0);
                const a = try self.peek(1);
                try self.push(a.retain());
                try self.push(b.retain());
            },
            .const_ => {
                const i: usize = @intCast(ins.a);
                if (i >= self.consts.len) return self.fail("internal error: bad constant {d}", .{ins.a});
                try self.push(self.consts[i].retain());
            },
            .nil => try self.push(.{ .nil = {} }),
            .true_ => try self.push(.{ .boolean = true }),
            .false_ => try self.push(.{ .boolean = false }),
            .int_small => try self.push(.{ .int = ins.a }),
            .local => {
                const s: usize = @intCast(ins.a);
                if (s >= locals.len) return self.fail("internal error: bad local slot {d}", .{ins.a});
                try self.push(locals[s].retain());
            },
            .set_local => {
                const v = try self.pop();
                const s: usize = @intCast(ins.a);
                if (s >= locals.len) {
                    v.release();
                    return self.fail("internal error: bad local slot {d}", .{ins.a});
                }
                locals[s].release();
                locals[s] = v;
            },
            .sig => {
                const i: u32 = @intCast(ins.a);
                if (i >= self.store.signals.items.len) return self.fail("internal error: bad signal {d}", .{ins.a});
                const v = self.store.read(i);
                try self.push(v.retain());
            },
            .set_sig => {
                const v = try self.pop();
                const i: u32 = @intCast(ins.a);
                if (i >= self.store.signals.items.len) {
                    v.release();
                    return self.fail("internal error: bad signal {d}", .{ins.a});
                }
                self.store.write(i, v);
            },
            .is_nil => {
                const v = try self.pop();
                const was_nil = (v == .nil);
                v.release();
                try self.push(.{ .boolean = was_nil });
            },
            .list => {
                const n: usize = @intCast(ins.a);
                if (self.stack.items.len < n) return self.fail("internal error: stack underflow building a list", .{});
                const l = try value.makeList();
                errdefer l.release();
                try l.list.items.ensureTotalCapacity(n);
                const base = self.stack.items.len - n;
                for (self.stack.items[base..]) |it| try l.list.items.append(it);
                self.stack.shrinkRetainingCapacity(base);
                try self.push(l);
            },
            .map => {
                const n: usize = @intCast(ins.a);
                if (self.stack.items.len < n * 2) return self.fail("internal error: stack underflow building a map", .{});
                const m = try value.makeMap();
                errdefer m.release();
                const base = self.stack.items.len - n * 2;
                var i: usize = 0;
                while (i < n) : (i += 1) {
                    const k = self.stack.items[base + i * 2];
                    const v = self.stack.items[base + i * 2 + 1];
                    const key = try displayString(k);
                    defer self.alloc.free(key);
                    if (m.map.set(key, v)) |_| {
                        k.release();
                    } else |_| {
                        k.release();
                        v.release();
                        self.stack.shrinkRetainingCapacity(base);
                        return error.OutOfMemory;
                    }
                }
                self.stack.shrinkRetainingCapacity(base);
                try self.push(m);
            },
            .index => {
                const idx = try self.pop();
                defer idx.release();
                const obj = try self.pop();
                defer obj.release();
                try self.push(try self.indexValue(obj, idx));
            },
            .set_index => {
                const v = try self.pop();
                const idx = try self.pop();
                defer idx.release();
                const obj = try self.pop();
                defer obj.release();
                try self.setIndexValue(obj, idx, v);
                self.store.markMutated(obj);
            },
            .slice => {
                const to = try self.pop();
                const from = try self.pop();
                const obj = try self.pop();
                defer obj.release();
                try self.push(try self.sliceValue(obj, from, to));
            },
            .member => {
                const obj = try self.pop();
                defer obj.release();
                try self.push(try self.memberValue(obj, self.unit.constStr(@intCast(ins.a))));
            },
            .set_member => {
                const v = try self.pop();
                const obj = try self.pop();
                defer obj.release();
                try self.setMemberValue(obj, self.unit.constStr(@intCast(ins.a)), v);
                self.store.markMutated(obj);
            },
            .add, .sub, .mul, .div, .mod_, .floor_div, .pow => {
                const b = try self.pop();
                defer b.release();
                const a = try self.pop();
                defer a.release();
                try self.push(try self.arith(ins.op, a, b));
            },
            .neg => {
                const a = try self.pop();
                defer a.release();
                switch (a) {
                    .int => |i| try self.push(.{ .int = -%i }),
                    .float => |fl| try self.push(.{ .float = -fl }),
                    else => return self.fail("cannot negate a {s}", .{a.typeName()}),
                }
            },
            .not_ => {
                const a = try self.pop();
                const t = a.truthy();
                a.release();
                try self.push(.{ .boolean = !t });
            },
            .eq, .ne => {
                const b = try self.pop();
                defer b.release();
                const a = try self.pop();
                defer a.release();
                const e = a.deepEqual(b);
                try self.push(.{ .boolean = if (ins.op == .eq) e else !e });
            },
            .lt, .le, .gt, .ge => {
                const b = try self.pop();
                defer b.release();
                const a = try self.pop();
                defer a.release();
                const c = compareValues(a, b) orelse return self.fail("cannot compare a {s} with a {s}", .{ a.typeName(), b.typeName() });
                const r = switch (ins.op) {
                    .lt => c < 0,
                    .le => c <= 0,
                    .gt => c > 0,
                    .ge => c >= 0,
                    else => false,
                };
                try self.push(.{ .boolean = r });
            },
            .in_, .not_in => {
                const b = try self.pop();
                defer b.release();
                const a = try self.pop();
                defer a.release();
                const found = try containsValue(b, a);
                try self.push(.{ .boolean = if (ins.op == .in_) found else !found });
            },
            .concat => {
                const n: usize = @intCast(ins.a);
                if (self.stack.items.len < n) return self.fail("internal error: stack underflow in concat", .{});
                var out = std.ArrayList(u8).init(self.alloc);
                defer out.deinit();
                const base = self.stack.items.len - n;
                for (self.stack.items[base..]) |part| {
                    const s = try displayString(part);
                    defer self.alloc.free(s);
                    try out.appendSlice(s);
                    part.release();
                }
                self.stack.shrinkRetainingCapacity(base);
                try self.push(try value.makeStr(out.items));
            },
            .jmp => pc.* = jump(pc.*, ins.a),
            .jmp_false_pop => {
                const v = try self.pop();
                const t = v.truthy();
                v.release();
                if (!t) pc.* = jump(pc.*, ins.a);
            },
            .jmp_true_pop => {
                const v = try self.pop();
                const t = v.truthy();
                v.release();
                if (t) pc.* = jump(pc.*, ins.a);
            },
            .call => {
                const argc: usize = @intCast(ins.a);
                if (self.stack.items.len < argc + 1) return self.fail("internal error: stack underflow in call", .{});
                const base = self.stack.items.len - argc - 1;
                const argv = try self.alloc.alloc(value.Value, argc);
                defer self.alloc.free(argv);
                // Ownership of callee+args moves out of the stack: do NOT retain.
                const callee = self.stack.items[base];
                @memcpy(argv, self.stack.items[base + 1 ..]);
                // Pop the frame *before* dispatch: the call may grow the stack.
                self.stack.shrinkRetainingCapacity(base);
                const result = self.invoke(callee, argv) catch |e| {
                    for (argv) |a| a.release();
                    callee.release();
                    return e;
                };
                for (argv) |a| a.release();
                callee.release();
                try self.push(result);
            },
            .call_method => {
                const argc: usize = @intCast(ins.b);
                if (self.stack.items.len < argc + 1) return self.fail("internal error: stack underflow in method call", .{});
                const base = self.stack.items.len - argc - 1;
                const argv = try self.alloc.alloc(value.Value, argc);
                defer self.alloc.free(argv);
                const recv = self.stack.items[base]; // ownership transfer, no retain
                @memcpy(argv, self.stack.items[base + 1 ..]);
                self.stack.shrinkRetainingCapacity(base);
                const name = self.unit.constStr(@intCast(ins.a));
                const result = self.callMethod(recv, name, argv) catch |e| {
                    for (argv) |a| a.release();
                    recv.release();
                    return e;
                };
                for (argv) |a| a.release();
                // Notify while `recv` is definitely still alive.
                if (isMutatingMethod(name)) self.store.markMutated(recv);
                recv.release();
                try self.push(result);
            },
            .call_builtin => {
                const argc: usize = @intCast(ins.b);
                if (self.stack.items.len < argc) return self.fail("internal error: stack underflow in builtin call", .{});
                const base = self.stack.items.len - argc;
                const argv = try self.alloc.alloc(value.Value, argc);
                defer self.alloc.free(argv);
                @memcpy(argv, self.stack.items[base..]);
                self.stack.shrinkRetainingCapacity(base);
                const id: builtins.Id = @enumFromInt(ins.a);
                const result = self.callBuiltin(id, argv) catch |e| {
                    for (argv) |a| a.release();
                    return e;
                };
                for (argv) |a| a.release();
                try self.push(result);
            },
            .ret => return try self.pop(),
            .ret_nil => return value.Value{ .nil = {} },
            .closure => {
                const fi: u32 = @intCast(ins.a);
                if (fi >= self.unit.funcs.len) return self.fail("internal error: bad closure index", .{});
                const target = &self.unit.funcs[fi];
                const captures = try self.alloc.alloc(value.Value, target.capture_srcs.len);
                errdefer self.alloc.free(captures);
                for (target.capture_srcs, 0..) |src, i| {
                    captures[i] = if (src < locals.len) locals[src].retain() else value.Value{ .nil = {} };
                }
                const box = try self.alloc.create(value.FuncBox);
                errdefer self.alloc.destroy(box);
                box.* = .{ .rc = 1, .name = target.name, .func_idx = fi, .captures = captures };
                try self.push(.{ .func = box });
            },
            .schedule_after => {
                const callable = try self.pop();
                const delay = try self.pop();
                defer delay.release();
                if (self.host) |h| {
                    h.schedule_after(h.ctx, delay.toInt(), callable);
                } else {
                    callable.release();
                }
            },
            .count => {
                const obj = try self.pop();
                defer obj.release();
                try self.push(.{ .int = countOf(obj) });
            },
            .iter_key => {
                const i = try self.pop();
                defer i.release();
                const obj = try self.pop();
                defer obj.release();
                try self.push(try self.iterKey(obj, i.toInt()));
            },
            .iter_at => {
                const i = try self.pop();
                defer i.release();
                const obj = try self.pop();
                defer obj.release();
                try self.push(try self.iterAt(obj, i.toInt()));
            },

            // ---- UI builder intrinsics ----
            .ui_begin => {
                const b = self.builder orelse return self.fail("a ui instruction ran outside of a render", .{});
                try b.begin(self.unit.constStr(@intCast(ins.a)));
            },
            .ui_prop => {
                const b = self.builder orelse return self.fail("a ui instruction ran outside of a render", .{});
                const v = try self.pop();
                try b.prop(self.unit.constStr(@intCast(ins.a)), v);
            },
            .ui_event => {
                const b = self.builder orelse return self.fail("a ui instruction ran outside of a render", .{});
                const v = try self.pop();
                try b.event(self.unit.constStr(@intCast(ins.a)), v);
            },
            .ui_text => {
                const b = self.builder orelse return self.fail("a ui instruction ran outside of a render", .{});
                const v = try self.pop();
                defer v.release();
                const s = try displayString(v);
                defer self.alloc.free(s);
                try b.text(try value.makeStr(s));
            },
            .ui_key => {
                const b = self.builder orelse return self.fail("a ui instruction ran outside of a render", .{});
                const v = try self.pop();
                b.key(v);
            },
            .ui_key_if_unset => {
                const b = self.builder orelse return self.fail("a ui instruction ran outside of a render", .{});
                const v = try self.pop();
                if (b.pending_key == null) b.key(v) else v.release();
            },
            .ui_bind => {
                const b = self.builder orelse return self.fail("a ui instruction ran outside of a render", .{});
                try b.bind(self.unit.constStr(@intCast(ins.a)));
            },
            .ui_end => {
                const b = self.builder orelse return self.fail("a ui instruction ran outside of a render", .{});
                try self.push(.{ .int = try b.end() });
            },
            .ui_child => {
                const b = self.builder orelse return self.fail("a ui instruction ran outside of a render", .{});
                const h = try self.pop();
                defer h.release();
                try b.child(h.toInt());
            },
        }
        return null;
    }

    // -- value operations ---------------------------------------------------

    /// Public entry point for dispatching an event handler value.
    pub fn invokePublic(self: *Vm, callee: value.Value, args: []const value.Value) Error!value.Value {
        return self.invoke(callee, args);
    }

    fn invoke(self: *Vm, callee: value.Value, args: []const value.Value) Error!value.Value {
        switch (callee) {
            .func => |box| {
                if (box.func_idx >= self.unit.funcs.len) return self.fail("'{s}' is not callable", .{box.name});
                return self.callFunc(box.func_idx, args, box);
            },
            else => return self.fail("a {s} is not callable", .{callee.typeName()}),
        }
    }

    fn indexValue(self: *Vm, obj: value.Value, idx: value.Value) Error!value.Value {
        switch (obj) {
            .list => |l| {
                var i = idx.toInt();
                const n: i64 = @intCast(l.items.items.len);
                if (i < 0) i += n;
                if (i < 0 or i >= n) return self.fail("index {d} is out of range for a list of {d} item(s)", .{ idx.toInt(), n });
                return l.items.items[@intCast(i)].retain();
            },
            .str => |s| {
                var i = idx.toInt();
                const n: i64 = @intCast(s.bytes.len);
                if (i < 0) i += n;
                if (i < 0 or i >= n) return self.fail("index {d} is out of range for a string of length {d}", .{ idx.toInt(), n });
                const at: usize = @intCast(i);
                return try value.makeStr(s.bytes[at .. at + 1]);
            },
            .map => |m| {
                const key = try displayString(idx);
                defer self.alloc.free(key);
                if (m.get(key)) |v| return v.retain();
                return value.Value{ .nil = {} };
            },
            else => return self.fail("cannot index into a {s}", .{obj.typeName()}),
        }
    }

    fn setIndexValue(self: *Vm, obj: value.Value, idx: value.Value, v: value.Value) Error!void {
        switch (obj) {
            .list => |l| {
                var i = idx.toInt();
                const n: i64 = @intCast(l.items.items.len);
                if (i < 0) i += n;
                if (i < 0 or i >= n) {
                    v.release();
                    return self.fail("index {d} is out of range for a list of {d} item(s)", .{ idx.toInt(), n });
                }
                l.items.items[@intCast(i)].release();
                l.items.items[@intCast(i)] = v;
            },
            .map => |m| {
                const key = try displayString(idx);
                defer self.alloc.free(key);
                if (m.set(key, v)) |_| {} else |_| {
                    v.release();
                    return error.OutOfMemory;
                }
            },
            else => {
                v.release();
                return self.fail("cannot assign into a {s}", .{obj.typeName()});
            },
        }
    }

    fn sliceValue(self: *Vm, obj: value.Value, from: value.Value, to: value.Value) Error!value.Value {
        const n = countOf(obj);
        var lo: i64 = if (from == .nil) 0 else from.toInt();
        var hi: i64 = if (to == .nil) n else to.toInt();
        if (lo < 0) lo += n;
        if (hi < 0) hi += n;
        lo = @max(0, @min(lo, n));
        hi = @max(0, @min(hi, n));
        if (hi < lo) hi = lo;
        switch (obj) {
            .list => |l| {
                const out = try value.makeList();
                errdefer out.release();
                for (l.items.items[@intCast(lo)..@intCast(hi)]) |it| {
                    try out.list.items.append(it.retain());
                }
                return out;
            },
            .str => |s| return try value.makeStr(s.bytes[@intCast(lo)..@intCast(hi)]),
            else => return self.fail("cannot slice a {s}", .{obj.typeName()}),
        }
    }

    fn memberValue(self: *Vm, obj: value.Value, name: []const u8) Error!value.Value {
        switch (obj) {
            .map => |m| {
                if (m.get(name)) |v| return v.retain();
                return value.Value{ .nil = {} };
            },
            .list => |l| {
                if (eqStr(name, "len") or eqStr(name, "length") or eqStr(name, "size")) return .{ .int = @intCast(l.items.items.len) };
                if (eqStr(name, "first")) return if (l.items.items.len > 0) l.items.items[0].retain() else value.Value{ .nil = {} };
                if (eqStr(name, "last")) return if (l.items.items.len > 0) l.items.items[l.items.items.len - 1].retain() else value.Value{ .nil = {} };
            },
            .str => |s| {
                if (eqStr(name, "len") or eqStr(name, "length")) return .{ .int = @intCast(s.bytes.len) };
            },
            else => {},
        }
        return self.fail("a {s} has no field '{s}'", .{ obj.typeName(), name });
    }

    fn setMemberValue(self: *Vm, obj: value.Value, name: []const u8, v: value.Value) Error!void {
        switch (obj) {
            .map => |m| {
                if (m.set(name, v)) |_| {} else |_| {
                    v.release();
                    return error.OutOfMemory;
                }
            },
            else => {
                v.release();
                return self.fail("cannot set field '{s}' on a {s}", .{ name, obj.typeName() });
            },
        }
    }

    fn iterKey(self: *Vm, obj: value.Value, i: i64) Error!value.Value {
        _ = self;
        if (obj == .map) {
            const m = obj.map;
            if (i >= 0 and i < m.entries.items.len) return try value.makeStr(m.entries.items[@intCast(i)].key);
            return value.Value{ .nil = {} };
        }
        return .{ .int = i };
    }

    fn iterAt(self: *Vm, obj: value.Value, i: i64) Error!value.Value {
        switch (obj) {
            .list => |l| {
                if (i >= 0 and i < l.items.items.len) return l.items.items[@intCast(i)].retain();
                return value.Value{ .nil = {} };
            },
            .str => |s| {
                if (i >= 0 and i < s.bytes.len) {
                    const at: usize = @intCast(i);
                    return try value.makeStr(s.bytes[at .. at + 1]);
                }
                return try value.makeStr("");
            },
            .map => |m| {
                if (i >= 0 and i < m.entries.items.len) return m.entries.items[@intCast(i)].value.retain();
                return value.Value{ .nil = {} };
            },
            .nil => return value.Value{ .nil = {} },
            else => return self.fail("cannot iterate over a {s}", .{obj.typeName()}),
        }
    }

    fn arith(self: *Vm, op: bytecode.Op, a: value.Value, b: value.Value) Error!value.Value {
        // `+` is overloaded: string concatenation and list extension read far
        // better in a UI language than a separate operator would.
        if (op == .add) {
            if (a == .str or b == .str) {
                const sa = try displayString(a);
                defer self.alloc.free(sa);
                const sb = try displayString(b);
                defer self.alloc.free(sb);
                var buf = std.ArrayList(u8).init(self.alloc);
                defer buf.deinit();
                try buf.appendSlice(sa);
                try buf.appendSlice(sb);
                return try value.makeStr(buf.items);
            }
            if (a == .list and b == .list) {
                const out = try value.makeList();
                errdefer out.release();
                for (a.list.items.items) |it| try out.list.items.append(it.retain());
                for (b.list.items.items) |it| try out.list.items.append(it.retain());
                return out;
            }
        }
        if (a == .int and b == .int) {
            const x = a.int;
            const y = b.int;
            return switch (op) {
                .add => .{ .int = x + y },
                .sub => .{ .int = x - y },
                .mul => .{ .int = x * y },
                .div => if (y == 0) self.fail("division by zero", .{}) else floatVal(@as(f64, @floatFromInt(x)) / @as(f64, @floatFromInt(y))),
                .mod_ => if (y == 0) self.fail("modulo by zero", .{}) else .{ .int = @mod(x, y) },
                .floor_div => if (y == 0) self.fail("division by zero", .{}) else .{ .int = @divFloor(x, y) },
                .pow => floatVal(std.math.pow(f64, @floatFromInt(x), @floatFromInt(y))),
                else => .{ .nil = {} },
            };
        }
        if (a == .nil or b == .nil or a == .list or a == .map or b == .list or b == .map) {
            return self.fail("cannot apply '{s}' to a {s} and a {s}", .{ @tagName(op), a.typeName(), b.typeName() });
        }
        const x = a.toFloat();
        const y = b.toFloat();
        return switch (op) {
            .add => floatVal(x + y),
            .sub => floatVal(x - y),
            .mul => floatVal(x * y),
            .div => if (y == 0) self.fail("division by zero", .{}) else floatVal(x / y),
            .mod_ => if (y == 0) self.fail("modulo by zero", .{}) else floatVal(@mod(x, y)),
            .floor_div => if (y == 0) self.fail("division by zero", .{}) else floatVal(@floor(x / y)),
            .pow => floatVal(std.math.pow(f64, x, y)),
            else => .{ .nil = {} },
        };
    }

    // -- methods ------------------------------------------------------------

    pub fn callMethod(self: *Vm, recv: value.Value, name: []const u8, args: []const value.Value) Error!value.Value {
        switch (recv) {
            .list => |l| return self.listMethod(l, name, args),
            .str => |s| return self.strMethod(s, name, args),
            .map => |m| return self.mapMethod(m, name, args),
            .int, .float => return self.numMethod(recv, name),
            else => return self.fail("a {s} has no method '{s}()'", .{ recv.typeName(), name }),
        }
    }

    fn argAt(self: *Vm, args: []const value.Value, i: usize, method: []const u8) Error!value.Value {
        if (i >= args.len) return self.fail("'{s}()' is missing argument {d}", .{ method, i + 1 });
        return args[i];
    }

    fn listMethod(self: *Vm, l: *value.ListBox, name: []const u8, args: []const value.Value) Error!value.Value {
        if (eqStr(name, "append") or eqStr(name, "push") or eqStr(name, "add")) {
            const v = (try self.argAt(args, 0, name)).retain();
            if (l.items.append(v)) |_| {} else |_| {
                v.release();
                return error.OutOfMemory;
            }
            return value.Value{ .nil = {} };
        }
        if (eqStr(name, "insert")) {
            const idx = (try self.argAt(args, 0, name)).toInt();
            const v = (try self.argAt(args, 1, name)).retain();
            const at: usize = @intCast(@max(0, @min(idx, @as(i64, @intCast(l.items.items.len)))));
            if (l.items.insert(at, v)) |_| {} else |_| {
                v.release();
                return error.OutOfMemory;
            }
            return value.Value{ .nil = {} };
        }
        if (eqStr(name, "extend")) {
            const other = try self.argAt(args, 0, name);
            if (other != .list) return self.fail("extend() expects a list, found a {s}", .{other.typeName()});
            for (other.list.items.items) |it| try l.items.append(it.retain());
            return value.Value{ .nil = {} };
        }
        if (eqStr(name, "remove")) {
            const target = try self.argAt(args, 0, name);
            for (l.items.items, 0..) |it, i| {
                if (it.deepEqual(target)) {
                    it.release();
                    _ = l.items.orderedRemove(i);
                    return .{ .boolean = true };
                }
            }
            return .{ .boolean = false };
        }
        if (eqStr(name, "pop")) {
            if (l.items.items.len == 0) return value.Value{ .nil = {} };
            if (args.len > 0) {
                var i = args[0].toInt();
                const n: i64 = @intCast(l.items.items.len);
                if (i < 0) i += n;
                if (i < 0 or i >= n) return self.fail("pop({d}) is out of range for a list of {d}", .{ args[0].toInt(), n });
                return l.items.orderedRemove(@intCast(i));
            }
            return l.items.pop();
        }
        if (eqStr(name, "clear")) {
            for (l.items.items) |it| it.release();
            l.items.clearRetainingCapacity();
            return value.Value{ .nil = {} };
        }
        if (eqStr(name, "len") or eqStr(name, "length") or eqStr(name, "size") or eqStr(name, "count")) {
            return .{ .int = @intCast(l.items.items.len) };
        }
        if (eqStr(name, "index") or eqStr(name, "index_of")) {
            const target = try self.argAt(args, 0, name);
            for (l.items.items, 0..) |it, i| {
                if (it.deepEqual(target)) return .{ .int = @intCast(i) };
            }
            return .{ .int = -1 };
        }
        if (eqStr(name, "contains") or eqStr(name, "has")) {
            const target = try self.argAt(args, 0, name);
            for (l.items.items) |it| if (it.deepEqual(target)) return .{ .boolean = true };
            return .{ .boolean = false };
        }
        if (eqStr(name, "reverse")) {
            std.mem.reverse(value.Value, l.items.items);
            return value.Value{ .nil = {} };
        }
        if (eqStr(name, "sort")) {
            std.mem.sort(value.Value, l.items.items, {}, valueLessThan);
            return value.Value{ .nil = {} };
        }
        if (eqStr(name, "join")) {
            var sep_buf = std.ArrayList(u8).init(self.alloc);
            defer sep_buf.deinit();
            if (args.len > 0) {
                const s = try displayString(args[0]);
                defer self.alloc.free(s);
                try sep_buf.appendSlice(s);
            }
            var buf = std.ArrayList(u8).init(self.alloc);
            defer buf.deinit();
            for (l.items.items, 0..) |it, i| {
                if (i > 0) try buf.appendSlice(sep_buf.items);
                const part = try displayString(it);
                defer self.alloc.free(part);
                try buf.appendSlice(part);
            }
            return try value.makeStr(buf.items);
        }
        if (eqStr(name, "first")) return if (l.items.items.len > 0) l.items.items[0].retain() else value.Value{ .nil = {} };
        if (eqStr(name, "last")) return if (l.items.items.len > 0) l.items.items[l.items.items.len - 1].retain() else value.Value{ .nil = {} };
        if (eqStr(name, "at") or eqStr(name, "get")) {
            const idx = (try self.argAt(args, 0, name)).toInt();
            var i = idx;
            const n: i64 = @intCast(l.items.items.len);
            if (i < 0) i += n;
            if (i < 0 or i >= n) {
                if (args.len > 1) return args[1].retain();
                return value.Value{ .nil = {} };
            }
            return l.items.items[@intCast(i)].retain();
        }
        if (eqStr(name, "set")) {
            const idx = (try self.argAt(args, 0, name)).toInt();
            const v = (try self.argAt(args, 1, name)).retain();
            var i = idx;
            const n: i64 = @intCast(l.items.items.len);
            if (i < 0) i += n;
            if (i < 0 or i >= n) {
                v.release();
                return self.fail("set({d}) is out of range for a list of {d}", .{ idx, n });
            }
            l.items.items[@intCast(i)].release();
            l.items.items[@intCast(i)] = v;
            return value.Value{ .nil = {} };
        }
        if (eqStr(name, "slice")) {
            const from = if (args.len > 0) args[0] else value.Value{ .nil = {} };
            const to = if (args.len > 1) args[1] else value.Value{ .nil = {} };
            return self.sliceValue(.{ .list = l }, from, to);
        }
        if (eqStr(name, "sum")) {
            var total: f64 = 0;
            var acc: i64 = 0;
            var all_int = true;
            for (l.items.items) |it| {
                if (it == .int) {
                    acc += it.int;
                } else {
                    all_int = false;
                }
                total += it.toFloat();
            }
            return if (all_int) value.Value{ .int = acc } else .{ .float = total };
        }
        if (eqStr(name, "min") or eqStr(name, "max")) {
            if (l.items.items.len == 0) return value.Value{ .nil = {} };
            var best = l.items.items[0];
            for (l.items.items[1..]) |it| {
                const c = compareValues(it, best) orelse continue;
                if ((eqStr(name, "min") and c < 0) or (eqStr(name, "max") and c > 0)) best = it;
            }
            return best.retain();
        }
        return self.fail("a list has no method '{s}()'", .{name});
    }

    fn strMethod(self: *Vm, s: *value.StrBox, name: []const u8, args: []const value.Value) Error!value.Value {
        if (eqStr(name, "len") or eqStr(name, "length") or eqStr(name, "size")) return .{ .int = @intCast(s.bytes.len) };
        if (eqStr(name, "upper") or eqStr(name, "lower")) {
            const upper = eqStr(name, "upper");
            const buf = try self.alloc.alloc(u8, s.bytes.len);
            defer self.alloc.free(buf);
            for (s.bytes, 0..) |c, i| buf[i] = if (upper) std.ascii.toUpper(c) else std.ascii.toLower(c);
            return try value.makeStr(buf);
        }
        if (eqStr(name, "strip") or eqStr(name, "trim")) return try value.makeStr(std.mem.trim(u8, s.bytes, " \t\r\n"));
        if (eqStr(name, "split")) {
            const out = try value.makeList();
            errdefer out.release();
            if (args.len == 0) {
                var it = std.mem.tokenizeAny(u8, s.bytes, " \t\r\n");
                while (it.next()) |tok| try out.list.items.append(try value.makeStr(tok));
                return out;
            }
            const sep = try displayString(args[0]);
            defer self.alloc.free(sep);
            if (sep.len == 0) {
                for (s.bytes) |c| try out.list.items.append(try value.makeStr(std.mem.sliceTo(&[_]u8{ c, 0 }, 0)));
                return out;
            }
            var it = std.mem.splitSequence(u8, s.bytes, sep);
            while (it.next()) |part| try out.list.items.append(try value.makeStr(part));
            return out;
        }
        if (eqStr(name, "replace")) {
            const from = try displayString(try self.argAt(args, 0, name));
            defer self.alloc.free(from);
            const to = try displayString(try self.argAt(args, 1, name));
            defer self.alloc.free(to);
            if (from.len == 0) return try value.makeStr(s.bytes);
            var buf = std.ArrayList(u8).init(self.alloc);
            defer buf.deinit();
            var rest: []const u8 = s.bytes;
            while (std.mem.indexOf(u8, rest, from)) |i| {
                try buf.appendSlice(rest[0..i]);
                try buf.appendSlice(to);
                rest = rest[i + from.len ..];
            }
            try buf.appendSlice(rest);
            return try value.makeStr(buf.items);
        }
        if (eqStr(name, "contains") or eqStr(name, "has")) {
            const needle = try displayString(try self.argAt(args, 0, name));
            defer self.alloc.free(needle);
            return .{ .boolean = std.mem.indexOf(u8, s.bytes, needle) != null };
        }
        if (eqStr(name, "starts_with")) {
            const p = try displayString(try self.argAt(args, 0, name));
            defer self.alloc.free(p);
            return .{ .boolean = std.mem.startsWith(u8, s.bytes, p) };
        }
        if (eqStr(name, "ends_with")) {
            const p = try displayString(try self.argAt(args, 0, name));
            defer self.alloc.free(p);
            return .{ .boolean = std.mem.endsWith(u8, s.bytes, p) };
        }
        if (eqStr(name, "index_of") or eqStr(name, "find")) {
            const needle = try displayString(try self.argAt(args, 0, name));
            defer self.alloc.free(needle);
            const i = std.mem.indexOf(u8, s.bytes, needle) orelse return value.Value{ .int = -1 };
            return .{ .int = @intCast(i) };
        }
        if (eqStr(name, "repeat")) {
            const n = (try self.argAt(args, 0, name)).toInt();
            var buf = std.ArrayList(u8).init(self.alloc);
            defer buf.deinit();
            var i: i64 = 0;
            while (i < @min(n, 100_000)) : (i += 1) try buf.appendSlice(s.bytes);
            return try value.makeStr(buf.items);
        }
        if (eqStr(name, "slice") or eqStr(name, "substr")) {
            const from = if (args.len > 0) args[0] else value.Value{ .nil = {} };
            const to = if (args.len > 1) args[1] else value.Value{ .nil = {} };
            return self.sliceValue(.{ .str = s }, from, to);
        }
        if (eqStr(name, "int")) return .{ .int = std.fmt.parseInt(i64, std.mem.trim(u8, s.bytes, " "), 10) catch 0 };
        if (eqStr(name, "float")) return .{ .float = std.fmt.parseFloat(f64, std.mem.trim(u8, s.bytes, " ")) catch 0 };
        if (eqStr(name, "str")) {
            const v = value.Value{ .str = s };
            return v.retain();
        }
        // `"-".join(xs)` — the receiver is the separator (Python style).
        // `xs.join("-")` is handled by the list branch; both spellings work.
        if (eqStr(name, "join")) {
            const arg = try self.argAt(args, 0, name);
            switch (arg) {
                .list => |lb| {
                    var buf = std.ArrayList(u8).init(self.alloc);
                    defer buf.deinit();
                    for (lb.items.items, 0..) |it, i| {
                        if (i > 0) try buf.appendSlice(s.bytes);
                        const part = try displayString(it);
                        defer self.alloc.free(part);
                        try buf.appendSlice(part);
                    }
                    return try value.makeStr(buf.items);
                },
                else => return self.fail("'{s}'.join() needs a list, got a {s}", .{ s.bytes, arg.typeName() }),
            }
        }
        return self.fail("a string has no method '{s}()'", .{name});
    }

    fn mapMethod(self: *Vm, m: *value.MapBox, name: []const u8, args: []const value.Value) Error!value.Value {
        if (eqStr(name, "get") or eqStr(name, "at")) {
            const key = try displayString(try self.argAt(args, 0, name));
            defer self.alloc.free(key);
            if (m.get(key)) |v| return v.retain();
            if (args.len > 1) return args[1].retain();
            return value.Value{ .nil = {} };
        }
        if (eqStr(name, "set") or eqStr(name, "put")) {
            const key = try displayString(try self.argAt(args, 0, name));
            defer self.alloc.free(key);
            const v = (try self.argAt(args, 1, name)).retain();
            if (m.set(key, v)) |_| {} else |_| {
                v.release();
                return error.OutOfMemory;
            }
            return value.Value{ .nil = {} };
        }
        if (eqStr(name, "has") or eqStr(name, "contains")) {
            const key = try displayString(try self.argAt(args, 0, name));
            defer self.alloc.free(key);
            return .{ .boolean = m.get(key) != null };
        }
        if (eqStr(name, "remove") or eqStr(name, "delete")) {
            const key = try displayString(try self.argAt(args, 0, name));
            defer self.alloc.free(key);
            return .{ .boolean = m.remove(key) };
        }
        if (eqStr(name, "keys")) {
            const out = try value.makeList();
            errdefer out.release();
            for (m.entries.items) |e| try out.list.items.append(try value.makeStr(e.key));
            return out;
        }
        if (eqStr(name, "values")) {
            const out = try value.makeList();
            errdefer out.release();
            for (m.entries.items) |e| try out.list.items.append(e.value.retain());
            return out;
        }
        if (eqStr(name, "items")) {
            const out = try value.makeList();
            errdefer out.release();
            for (m.entries.items) |e| {
                const pair = try value.makeList();
                errdefer pair.release();
                try pair.list.items.append(try value.makeStr(e.key));
                try pair.list.items.append(e.value.retain());
                try out.list.items.append(pair);
            }
            return out;
        }
        if (eqStr(name, "len") or eqStr(name, "size") or eqStr(name, "count")) return .{ .int = @intCast(m.entries.items.len) };
        if (eqStr(name, "clear")) {
            for (m.entries.items) |e| {
                e.value.release();
                self.alloc.free(e.key);
            }
            m.entries.clearRetainingCapacity();
            return value.Value{ .nil = {} };
        }
        return self.fail("a map has no method '{s}()'", .{name});
    }

    fn numMethod(self: *Vm, v: value.Value, name: []const u8) Error!value.Value {
        const f = v.toFloat();
        if (eqStr(name, "abs")) {
            if (v == .int) return .{ .int = @as(i64, @intCast(@abs(v.int))) };
            return .{ .float = @abs(f) };
        }
        if (eqStr(name, "round")) return .{ .int = @intFromFloat(@round(f)) };
        if (eqStr(name, "floor")) return .{ .int = @intFromFloat(@floor(f)) };
        if (eqStr(name, "ceil")) return .{ .int = @intFromFloat(@ceil(f)) };
        if (eqStr(name, "str")) {
            const s = try displayString(v);
            defer self.alloc.free(s);
            return try value.makeStr(s);
        }
        if (eqStr(name, "int")) return .{ .int = v.toInt() };
        if (eqStr(name, "float")) return .{ .float = f };
        return self.fail("a {s} has no method '{s}()'", .{ v.typeName(), name });
    }

    // -- builtins -----------------------------------------------------------

    pub fn callBuiltin(self: *Vm, id: builtins.Id, args: []const value.Value) Error!value.Value {
        const a = if (args.len > 0) args[0] else value.Value{ .nil = {} };
        switch (id) {
            .len, .count => return .{ .int = countOf(a) },
            .str => {
                const s = try displayString(a);
                defer self.alloc.free(s);
                return try value.makeStr(s);
            },
            .int => return .{ .int = a.toInt() },
            .float => return .{ .float = a.toFloat() },
            .bool_ => return .{ .boolean = a.truthy() },
            .abs => {
                if (a == .int) return .{ .int = @as(i64, @intCast(@abs(a.int))) };
                return .{ .float = @abs(a.toFloat()) };
            },
            .min, .max => {
                var items: []const value.Value = args;
                if (args.len == 1 and a == .list) items = a.list.items.items;
                if (items.len == 0) return value.Value{ .nil = {} };
                var best = items[0];
                for (items[1..]) |it| {
                    const c = compareValues(it, best) orelse continue;
                    if ((id == .min and c < 0) or (id == .max and c > 0)) best = it;
                }
                return best.retain();
            },
            .sum => {
                var total: f64 = 0;
                var acc: i64 = 0;
                var all_int = true;
                if (a == .list) {
                    for (a.list.items.items) |it| {
                        if (it == .int) {
                            acc += it.int;
                        } else {
                    all_int = false;
                }
                        total += it.toFloat();
                    }
                } else {
                    all_int = false;
                    total = a.toFloat();
                }
                return if (all_int) value.Value{ .int = acc } else .{ .float = total };
            },
            .round => {
                const digits: i64 = if (args.len > 1) args[1].toInt() else 0;
                const factor = std.math.pow(f64, 10, @floatFromInt(digits));
                const r = @round(a.toFloat() * factor) / factor;
                if (digits <= 0) return .{ .int = @intFromFloat(r) };
                return .{ .float = r };
            },
            .floor => return .{ .int = @intFromFloat(@floor(a.toFloat())) },
            .ceil => return .{ .int = @intFromFloat(@ceil(a.toFloat())) },
            .range => {
                var start: i64 = 0;
                var end: i64 = 0;
                var stride: i64 = 1;
                if (args.len == 1) {
                    end = a.toInt();
                } else {
                    start = a.toInt();
                    end = args[1].toInt();
                    if (args.len > 2) stride = args[2].toInt();
                }
                if (stride == 0) return self.fail("range() step cannot be 0", .{});
                const out = try value.makeList();
                errdefer out.release();
                var i = start;
                var guard: i64 = 0;
                while ((stride > 0 and i < end) or (stride < 0 and i > end)) : (i += stride) {
                    try out.list.items.append(.{ .int = i });
                    guard += 1;
                    if (guard > 1_000_000) return self.fail("range() would produce more than 1,000,000 items", .{});
                }
                return out;
            },
            .sorted, .reversed => {
                const out = try value.makeList();
                errdefer out.release();
                if (a == .list) {
                    for (a.list.items.items) |it| try out.list.items.append(it.retain());
                } else if (a == .str) {
                    for (a.str.bytes) |c| try out.list.items.append(try value.makeStr(std.mem.sliceTo(&[_]u8{ c, 0 }, 0)));
                } else return self.fail("sorted() expects a list or a string", .{});
                std.mem.sort(value.Value, out.list.items.items, {}, valueLessThan);
                if (id == .reversed) std.mem.reverse(value.Value, out.list.items.items);
                return out;
            },
            .print, .log => {
                var buf = std.ArrayList(u8).init(self.alloc);
                defer buf.deinit();
                for (args, 0..) |arg, i| {
                    if (i > 0) try buf.append(' ');
                    const s = try displayString(arg);
                    defer self.alloc.free(s);
                    try buf.appendSlice(s);
                }
                if (self.host) |h| {
                    h.log(h.ctx, buf.items);
                } else {
                    std.debug.print("{s}\n", .{buf.items});
                }
                return value.Value{ .nil = {} };
            },
            .now => return .{ .int = std.time.milliTimestamp() },
            .random => {
                self.rng = nextRand(self.rng);
                const f = @as(f64, @floatFromInt(self.rng >> 11)) / 9007199254740992.0;
                return .{ .float = f };
            },
            .rand_int => {
                if (args.len < 2) return self.fail("rand_int() needs 2 arguments", .{});
                const lo = args[0].toInt();
                const hi = args[1].toInt();
                if (hi < lo) return self.fail("rand_int({d}, {d}): max is below min", .{ lo, hi });
                self.rng = nextRand(self.rng);
                const span: u64 = @intCast(hi - lo + 1);
                return .{ .int = lo + @as(i64, @intCast(self.rng % span)) };
            },
            .type_of => return try value.makeStr(a.typeName()),
            .clone => return try a.deepCopy(),
            .keys => return self.callMethod(a, "keys", &.{}),
            .values => return self.callMethod(a, "values", &.{}),
            .items => return self.callMethod(a, "items", &.{}),
            .first => return self.callMethod(a, "first", &.{}),
            .last => return self.callMethod(a, "last", &.{}),
            .contains, .has => {
                if (args.len < 2) return self.fail("contains() needs 2 arguments", .{});
                return .{ .boolean = try containsValue(args[0], args[1]) };
            },
            .join => {
                if (args.len < 1) return self.fail("join() needs a list", .{});
                return self.callMethod(args[0], "join", if (args.len > 1) args[1..2] else &.{});
            },
            .enumerate => {
                const out = try value.makeList();
                errdefer out.release();
                const n = countOf(a);
                var i: i64 = 0;
                while (i < n) : (i += 1) {
                    const pair = try value.makeList();
                    errdefer pair.release();
                    try pair.list.items.append(.{ .int = i });
                    try pair.list.items.append(try self.iterAt(a, i));
                    try out.list.items.append(pair);
                }
                return out;
            },
            .get => {
                if (args.len < 2) return self.fail("get() needs at least 2 arguments", .{});
                return self.callMethod(args[0], "get", args[1..]);
            },
            .push => {
                if (args.len < 2) return self.fail("push() needs 2 arguments", .{});
                (try self.callMethod(args[0], "append", args[1..2])).release();
                self.store.markMutated(args[0]);
                return args[0].retain();
            },
            .remove => {
                if (args.len < 2) return self.fail("remove() needs 2 arguments", .{});
                const r = try self.callMethod(args[0], "remove", args[1..2]);
                self.store.markMutated(args[0]);
                return r;
            },
            .insert => {
                if (args.len < 3) return self.fail("insert() needs 3 arguments", .{});
                (try self.callMethod(args[0], "insert", args[1..3])).release();
                self.store.markMutated(args[0]);
                return args[0].retain();
            },
            .pop => {
                const r = try self.callMethod(a, "pop", if (args.len > 1) args[1..2] else &.{});
                self.store.markMutated(a);
                return r;
            },
            .clear => {
                const r = try self.callMethod(a, "clear", &.{});
                self.store.markMutated(a);
                return r;
            },
            .set => {
                if (args.len < 3) return self.fail("set() needs 3 arguments", .{});
                (try self.callMethod(args[0], "set", args[1..3])).release();
                self.store.markMutated(args[0]);
                return args[0].retain();
            },
            .upper => return self.callMethod(a, "upper", &.{}),
            .lower => return self.callMethod(a, "lower", &.{}),
            .strip => return self.callMethod(a, "strip", &.{}),
            .split => return self.callMethod(a, "split", if (args.len > 1) args[1..2] else &.{}),
            .replace => {
                if (args.len < 3) return self.fail("replace() needs 3 arguments", .{});
                return self.callMethod(args[0], "replace", args[1..3]);
            },
            .starts_with => {
                if (args.len < 2) return self.fail("starts_with() needs 2 arguments", .{});
                return self.callMethod(args[0], "starts_with", args[1..2]);
            },
            .ends_with => {
                if (args.len < 2) return self.fail("ends_with() needs 2 arguments", .{});
                return self.callMethod(args[0], "ends_with", args[1..2]);
            },
            .index_of => {
                if (args.len < 2) return self.fail("index_of() needs 2 arguments", .{});
                return self.callMethod(args[0], "index_of", args[1..2]);
            },
            .slice => {
                const from = if (args.len > 1) args[1] else value.Value{ .nil = {} };
                const to = if (args.len > 2) args[2] else value.Value{ .nil = {} };
                return self.sliceValue(a, from, to);
            },
        }
    }
};

fn floatVal(f: f64) value.Value {
    return value.Value{ .float = f };
}

fn eqStr(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

fn nextRand(x: u64) u64 {
    var s = x;
    s ^= s << 13;
    s ^= s >> 7;
    s ^= s << 17;
    return s;
}

pub fn countOf(v: value.Value) i64 {
    return switch (v) {
        .nil => 0,
        .list => |l| @intCast(l.items.items.len),
        .map => |m| @intCast(m.entries.items.len),
        .str => |s| @intCast(s.bytes.len),
        else => 1,
    };
}

fn containsValue(haystack: value.Value, needle: value.Value) Error!bool {
    return switch (haystack) {
        .list => |l| blk: {
            for (l.items.items) |it| {
                if (it.deepEqual(needle)) break :blk true;
            }
            break :blk false;
        },
        .map => |m| blk: {
            const key = try displayString(needle);
            defer value.alloc.free(key);
            break :blk m.get(key) != null;
        },
        .str => |s| blk: {
            const key = try displayString(needle);
            defer value.alloc.free(key);
            break :blk std.mem.indexOf(u8, s.bytes, key) != null;
        },
        else => haystack.deepEqual(needle),
    };
}

pub fn compareValues(a: value.Value, b: value.Value) ?i8 {
    const numeric_a = a == .int or a == .float or a == .boolean;
    const numeric_b = b == .int or b == .float or b == .boolean;
    if (numeric_a and numeric_b) {
        const x = a.toFloat();
        const y = b.toFloat();
        if (x < y) return -1;
        if (x > y) return 1;
        return 0;
    }
    if (a == .str and b == .str) {
        return switch (std.mem.order(u8, a.str.bytes, b.str.bytes)) {
            .lt => @as(i8, -1),
            .gt => @as(i8, 1),
            .eq => @as(i8, 0),
        };
    }
    return null;
}

fn valueLessThan(_: void, a: value.Value, b: value.Value) bool {
    return (compareValues(a, b) orelse 0) < 0;
}

/// Render a value the way a user would write it.
pub fn displayString(v: value.Value) ![]u8 {
    var list = std.ArrayList(u8).init(value.alloc);
    errdefer list.deinit();
    try v.display(&list);
    return try list.toOwnedSlice();
}

fn isMutatingMethod(name: []const u8) bool {
    const names = [_][]const u8{ "append", "push", "add", "insert", "extend", "remove", "delete", "pop", "clear", "set", "put", "reverse", "sort" };
    for (names) |n| if (eqStr(name, n)) return true;
    return false;
}
