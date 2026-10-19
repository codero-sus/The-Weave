//! The Weave compiler: AST -> bytecode `CodeUnit`.
//!
//! Responsibilities beyond lowering:
//!   * scope resolution — every identifier becomes a local slot, a signal index,
//!     a builtin id, a handler/component reference, or a bare keyword string
//!   * closure conversion — nested handlers capture enclosing locals *by value*
//!     (a snapshot), which is exactly what a `for` loop event handler needs
//!   * view lowering — declarative UI becomes `ui_*` builder instructions
//!   * semantic diagnostics — unknown functions, bad assignments, arity checks

const std = @import("std");
const ast = @import("ast.zig");
const bytecode = @import("bytecode.zig");
const builtins = @import("builtins.zig");
const diag = @import("diag.zig");

pub const Error = error{OutOfMemory};

pub const Output = struct {
    arena: *std.heap.ArenaAllocator,
    parent: std.mem.Allocator,
    unit: *bytecode.CodeUnit,

    pub fn deinit(self: *Output) void {
        const a = self.arena;
        a.deinit();
        self.parent.destroy(a);
    }
};

const Local = struct {
    name: []const u8,
    slot: u32,
    depth: u32,
};

const Capture = struct {
    name: []const u8,
    src: u32,
    dest: u32,
};

const Resolve = union(enum) {
    local: u32,
    sig: u32,
    builtin: builtins.Id,
    handler: u32,
    component: u32,
    /// Bare word in a value position (`align: center`) — becomes a string.
    keyword: []const u8,
};

const ParamInfo = struct {
    name: []const u8,
    has_default: bool,
};

// ---------------------------------------------------------------------------
// Function compiler
// ---------------------------------------------------------------------------

const Fn = struct {
    c: *Compiler,
    parent: ?*Fn,
    name: []const u8,
    kind: bytecode.FuncKind,
    params: std.ArrayList(ParamInfo),
    locals: std.ArrayList(Local),
    captures: std.ArrayList(Capture),
    code: std.ArrayList(bytecode.Instr),
    next_slot: u32,
    depth: u32 = 0,
    line: u32 = 1,
    breaks: std.ArrayList(usize),
    continues: std.ArrayList(usize),
    loop_depth: usize = 0,
    index: u32 = 0,

    fn init(c: *Compiler, parent: ?*Fn, name: []const u8, kind: bytecode.FuncKind) Error!Fn {
        return .{
            .c = c,
            .parent = parent,
            .name = name,
            .kind = kind,
            .params = std.ArrayList(ParamInfo).init(c.a),
            .locals = std.ArrayList(Local).init(c.a),
            .captures = std.ArrayList(Capture).init(c.a),
            .code = std.ArrayList(bytecode.Instr).init(c.a),
            .next_slot = 0,
            .breaks = std.ArrayList(usize).init(c.a),
            .continues = std.ArrayList(usize).init(c.a),
        };
    }

    fn deinit(self: *Fn) void {
        self.params.deinit();
        self.locals.deinit();
        self.captures.deinit();
        self.code.deinit();
        self.breaks.deinit();
        self.continues.deinit();
    }

    fn emit(self: *Fn, op: bytecode.Op, a: i32, b: i32) Error!usize {
        try self.code.append(.{ .op = op, .a = a, .b = b, .line = self.line });
        return self.code.items.len - 1;
    }

    fn patch(self: *Fn, at: usize, target: usize) void {
        self.code.items[at].a = @as(i32, @intCast(target)) - @as(i32, @intCast(at));
    }

    fn here(self: *const Fn) usize {
        return self.code.items.len;
    }

    fn pushScope(self: *Fn) void {
        self.depth += 1;
    }

    fn popScope(self: *Fn) void {
        while (self.locals.items.len > 0 and self.locals.items[self.locals.items.len - 1].depth == self.depth) {
            _ = self.locals.pop();
        }
        if (self.depth > 0) self.depth -= 1;
    }

    fn findLocal(self: *const Fn, name: []const u8) ?u32 {
        var i: usize = self.locals.items.len;
        while (i > 0) {
            i -= 1;
            if (std.mem.eql(u8, self.locals.items[i].name, name)) return self.locals.items[i].slot;
        }
        return null;
    }

    fn declare(self: *Fn, name: []const u8) Error!u32 {
        // Reuse a slot when the same name is declared at the same block depth.
        for (self.locals.items) |l| {
            if (l.depth == self.depth and std.mem.eql(u8, l.name, name)) return l.slot;
        }
        const slot = self.next_slot;
        self.next_slot += 1;
        try self.locals.append(.{ .name = name, .slot = slot, .depth = self.depth });
        return slot;
    }

    fn addCapture(self: *Fn, name: []const u8, src_slot: u32) Error!u32 {
        for (self.captures.items) |cap| {
            if (std.mem.eql(u8, cap.name, name)) return cap.dest;
        }
        const dest = self.next_slot;
        self.next_slot += 1;
        try self.captures.append(.{ .name = name, .src = src_slot, .dest = dest });
        try self.locals.append(.{ .name = name, .slot = dest, .depth = self.depth });
        return dest;
    }

    fn resolve(self: *Fn, name: []const u8) Resolve {
        if (self.findLocal(name)) |slot| return .{ .local = slot };
        if (self.parent) |p| {
            const r = p.resolve(name);
            if (r == .local) {
                const dest = self.addCapture(name, r.local) catch return .{ .keyword = name };
                return .{ .local = dest };
            }
            return r;
        }
        return self.c.resolveGlobal(name);
    }

    fn setLine(self: *Fn, span: diag.Span) void {
        if (span.line > 0) self.line = span.line;
    }

    /// Finish and register this function, returning its index.
    fn finish(self: *Fn) Error!u32 {
        const srcs = try self.c.a.alloc(u32, self.captures.items.len);
        const dests = try self.c.a.alloc(u32, self.captures.items.len);
        for (self.captures.items, 0..) |cap, i| {
            srcs[i] = cap.src;
            dests[i] = cap.dest;
        }
        const idx = try self.c.pushFunc(.{
            .name = self.name,
            .kind = self.kind,
            .num_params = @intCast(self.params.items.len),
            .num_locals = self.next_slot,
            .capture_srcs = srcs,
            .capture_dests = dests,
            .param_names = try self.c.paramNames(self.params.items),
            .param_defaults = try self.c.paramDefaults(self.params.items),
            .code = try self.c.a.dupe(bytecode.Instr, self.code.items),
        });
        return idx;
    }

    // -- expressions --------------------------------------------------------

    fn expr(self: *Fn, e: *const ast.Expr, opt: ExprOpt) Error!void {
        self.setLine(e.spanOf());
        switch (e.*) {
            .nil_lit => _ = try self.emit(.nil, 0, 0),
            .bool_lit => |x| _ = try self.emit(if (x.v) .true_ else .false_, 0, 0),
            .int_lit => |x| {
                if (x.v >= -2147483648 and x.v <= 2147483647) {
                    _ = try self.emit(.int_small, @intCast(x.v), 0);
                } else {
                    _ = try self.emit(.const_, @intCast(try self.c.addConst(.{ .int = x.v })), 0);
                }
            },
            .float_lit => |x| _ = try self.emit(.const_, @intCast(try self.c.addConst(.{ .float = x.v })), 0),
            .str_lit => |x| {
                if (x.parts.len == 1 and x.parts[0] == .lit) {
                    _ = try self.emit(.const_, @intCast(try self.c.addConstStr(x.parts[0].lit)), 0);
                    return;
                }
                for (x.parts) |p| switch (p) {
                    .lit => |s| _ = try self.emit(.const_, @intCast(try self.c.addConstStr(s)), 0),
                    .expr => |sub| try self.expr(sub, opt),
                };
                _ = try self.emit(.concat, @intCast(x.parts.len), 0);
            },
            .list_lit => |x| {
                for (x.items) |it| try self.expr(it, opt);
                _ = try self.emit(.list, @intCast(x.items.len), 0);
            },
            .map_lit => |x| {
                for (x.entries) |en| {
                    try self.expr(en.key, opt);
                    try self.expr(en.value, opt);
                }
                _ = try self.emit(.map, @intCast(x.entries.len), 0);
            },
            .ident => |x| try self.loadIdent(x.name, x.span, opt),
            .index => |x| {
                try self.expr(x.target, opt);
                try self.expr(x.index, opt);
                _ = try self.emit(.index, 0, 0);
            },
            .slice => |x| {
                try self.expr(x.target, opt);
                if (x.from) |f| try self.expr(f, opt) else _ = try self.emit(.nil, 0, 0);
                if (x.to) |t| try self.expr(t, opt) else _ = try self.emit(.nil, 0, 0);
                _ = try self.emit(.slice, 0, 0);
            },
            .member => |x| {
                try self.expr(x.target, opt);
                _ = try self.emit(.member, @intCast(try self.c.addConstStr(x.name)), 0);
            },
            .call => |x| try self.call(x, opt),
            .unary => |x| {
                try self.expr(x.operand, opt);
                _ = try self.emit(if (x.op == .neg) .neg else .not_, 0, 0);
            },
            .binary => |x| try self.binary(x, opt),
            .cond => |x| {
                try self.expr(x.cond, opt);
                const j = try self.emit(.jmp_false_pop, 0, 0);
                try self.expr(x.then, opt);
                const j2 = try self.emit(.jmp, 0, 0);
                self.patch(j, self.here());
                try self.expr(x.els, opt);
                self.patch(j2, self.here());
            },
        }
    }

    fn loadIdent(self: *Fn, name: []const u8, span: diag.Span, opt: ExprOpt) Error!void {
        switch (self.resolve(name)) {
            .local => |slot| _ = try self.emit(.local, @intCast(slot), 0),
            .sig => |idx| _ = try self.emit(.sig, @intCast(idx), 0),
            .handler => |h| {
                const fi = self.c.handler_func.items[h];
                _ = try self.emit(.closure, @intCast(fi), 0);
            },
            .component => |cm| {
                const fi = self.c.component_func.items[cm];
                _ = try self.emit(.closure, @intCast(fi), 0);
            },
            .builtin => |b| {
                // A builtin used as a value (e.g. passed around) — wrap it.
                self.c.rep.warnHint(span, "builtins must be called, e.g. len(tasks)", "'{s}' is a builtin function, not a value", .{@tagName(b)});
                _ = try self.emit(.nil, 0, 0);
            },
            .keyword => {
                if (opt.strict_names) {
                    self.c.rep.warnHint(span, "bare words are allowed as style keywords such as align: center", "unknown name '{s}' — treated as the string \"{s}\"", .{ name, name });
                }
                _ = try self.emit(.const_, @intCast(try self.c.addConstStr(name)), 0);
            },
        }
    }

    fn binary(self: *Fn, x: anytype, opt: ExprOpt) Error!void {
        switch (x.op) {
            .and_ => {
                try self.expr(x.lhs, opt);
                const j = try self.emit(.dup, 0, 0);
                _ = j;
                const j2 = try self.emit(.jmp_false_pop, 0, 0);
                _ = try self.emit(.pop, 0, 0);
                try self.expr(x.rhs, opt);
                self.patch(j2, self.here());
            },
            .or_ => {
                try self.expr(x.lhs, opt);
                _ = try self.emit(.dup, 0, 0);
                const j2 = try self.emit(.jmp_true_pop, 0, 0);
                _ = try self.emit(.pop, 0, 0);
                try self.expr(x.rhs, opt);
                self.patch(j2, self.here());
            },
            else => {
                try self.expr(x.lhs, opt);
                try self.expr(x.rhs, opt);
                const op: bytecode.Op = switch (x.op) {
                    .add => .add,
                    .sub => .sub,
                    .mul => .mul,
                    .div => .div,
                    .mod => .mod_,
                    .floor_div => .floor_div,
                    .pow => .pow,
                    .eq => .eq,
                    .ne => .ne,
                    .lt => .lt,
                    .le => .le,
                    .gt => .gt,
                    .ge => .ge,
                    .in_ => .in_,
                    .not_in => .not_in,
                    .and_, .or_ => unreachable,
                };
                _ = try self.emit(op, 0, 0);
            },
        }
    }

    fn call(self: *Fn, x: anytype, opt: ExprOpt) Error!void {
        const argc = x.args.len;

        switch (x.callee.*) {
            // method call: receiver.name(args)
            .member => |m| {
                try self.expr(m.target, opt);
                for (x.args) |a| {
                    if (a.name != null) {
                        self.c.rep.warn(a.span, "named arguments are not supported in method calls; ignoring '{s}'", .{a.name.?});
                    }
                    try self.expr(a.value, opt);
                }
                _ = try self.emit(.call_method, @intCast(try self.c.addConstStr(m.name)), @intCast(argc));
                return;
            },
            .ident => |id| {
                const name = id.name;
                // Declarations shadow builtins, so `handlers: clear():` wins
                // over the list builtin of the same name.
                if (self.c.handlerIndex(name)) |h| {
                    const decl = self.c.program.app.handlers[h];
                    _ = try self.emit(.closure, @intCast(self.c.handler_func.items[h]), 0);
                    try self.callArgs(x.args, decl.params, opt);
                    _ = try self.emit(.call, @intCast(decl.params.len), 0);
                    return;
                }
                if (self.c.componentIndex(name)) |ci| {
                    const decl = self.c.program.components[ci];
                    _ = try self.emit(.closure, @intCast(self.c.component_func.items[ci]), 0);
                    try self.callArgs(x.args, decl.params, opt);
                    _ = try self.emit(.call, @intCast(decl.params.len), 0);
                    return;
                }
                if (builtins.byName(name)) |bid| {
                    const info = builtins.info(bid);
                    if (argc < info.min_args or argc > info.max_args) {
                        self.c.rep.err(x.span, "'{s}()' takes {d}..{d} arguments, found {d}", .{ info.name, info.min_args, info.max_args, argc });
                    }
                    for (x.args) |a| {
                        if (a.name != null) {
                            self.c.rep.err(a.span, "'{s}()' does not take named arguments", .{info.name});
                        }
                        try self.expr(a.value, opt);
                    }
                    _ = try self.emit(.call_builtin, @intCast(@intFromEnum(bid)), @intCast(argc));
                    return;
                }
            },
            else => {},
        }

        // generic call: the callee evaluates to a callable value
        try self.expr(x.callee, opt);
        for (x.args) |a| {
            if (a.name != null) {
                self.c.rep.warn(a.span, "named argument '{s}' is passed positionally here", .{a.name.?});
            }
            try self.expr(a.value, opt);
        }
        _ = try self.emit(.call, @intCast(argc), 0);
    }

    /// Emit arguments in declared parameter order (supports named args).
    fn callArgs(self: *Fn, args: []const ast.CallArg, params: []const ast.Param, opt: ExprOpt) Error!void {
        var used = std.ArrayList(bool).init(self.c.a);
        defer used.deinit();
        for (args) |_| try used.append(false);

        var pos: usize = 0;
        for (params, 0..) |p, pi| {
            _ = pi;
            // explicit named argument?
            var found = false;
            for (args, 0..) |a, ai| {
                if (a.name != null and std.mem.eql(u8, a.name.?, p.name) and !used.items[ai]) {
                    used.items[ai] = true;
                    try self.expr(a.value, opt);
                    found = true;
                    break;
                }
            }
            if (found) continue;
            // next positional argument?
            while (pos < args.len and (args[pos].name != null or used.items[pos])) pos += 1;
            if (pos < args.len) {
                used.items[pos] = true;
                try self.expr(args[pos].value, opt);
                pos += 1;
            } else {
                if (p.default) |d| {
                    try self.expr(d, opt);
                } else {
                    _ = try self.emit(.nil, 0, 0);
                }
            }
        }
    }

    // -- statements ---------------------------------------------------------

    fn stmts(self: *Fn, list: []const ast.Stmt) Error!void {
        for (list) |s| try self.stmt(s);
    }

    fn stmt(self: *Fn, s: ast.Stmt) Error!void {
        self.setLine(s.spanOf());
        switch (s) {
            .pass => _ = try self.emit(.nop, 0, 0),
            .expr => |x| {
                try self.expr(x.e, .{});
                _ = try self.emit(.pop, 0, 0);
            },
            .assign => |x| try self.assign(x),
            .return_ => |x| {
                if (x.value) |v| {
                    try self.expr(v, .{});
                    _ = try self.emit(.ret, 0, 0);
                } else {
                    _ = try self.emit(.ret_nil, 0, 0);
                }
            },
            .break_ => |span| {
                if (self.loop_depth == 0) {
                    self.c.rep.err(span, "'break' outside of a loop", .{});
                    return;
                }
                const at = try self.emit(.jmp, 0, 0);
                try self.breaks.append(at);
            },
            .continue_ => |span| {
                if (self.loop_depth == 0) {
                    self.c.rep.err(span, "'continue' outside of a loop", .{});
                    return;
                }
                const at = try self.emit(.jmp, 0, 0);
                try self.continues.append(at);
            },
            .if_ => |x| {
                var end_jumps = std.ArrayList(usize).init(self.c.a);
                defer end_jumps.deinit();
                for (x.branches, 0..) |b, bi| {
                    if (b.cond) |c| {
                        self.setLine(c.spanOf());
                        try self.expr(c, .{});
                        const j = try self.emit(.jmp_false_pop, 0, 0);
                        try self.stmts(b.body);
                        const je = try self.emit(.jmp, 0, 0);
                        try end_jumps.append(je);
                        self.patch(j, self.here());
                    } else {
                        try self.stmts(b.body);
                    }
                    _ = bi;
                }
                for (end_jumps.items) |j| self.patch(j, self.here());
            },
            .for_ => |x| try self.forLoop(x),
            .after => |x| {
                self.setLine(x.span);
                try self.expr(x.delay_ms, .{});
                // body becomes a closure so it can capture loop locals
                var body = try Fn.init(self.c, self, "after", .handler);
                defer body.deinit();
                try body.stmts(x.body);
                _ = try body.emit(.ret_nil, 0, 0);
                const fi = try body.finish();
                _ = try self.emit(.closure, @intCast(fi), 0);
                _ = try self.emit(.schedule_after, 0, 0);
            },
        }
    }

    fn assign(self: *Fn, x: ast.Assign) Error!void {
        switch (x.target.*) {
            .ident => |id| {
                const r = self.resolve(id.name);
                switch (r) {
                    .local => |slot| {
                        if (x.op != .set) {
                            _ = try self.emit(.local, @intCast(slot), 0);
                            try self.expr(x.value, .{});
                            _ = try self.emit(augOp(x.op), 0, 0);
                        } else {
                            try self.expr(x.value, .{});
                        }
                        _ = try self.emit(.set_local, @intCast(slot), 0);
                    },
                    .sig => |idx| {
                        if (x.op != .set) {
                            _ = try self.emit(.sig, @intCast(idx), 0);
                            try self.expr(x.value, .{});
                            _ = try self.emit(augOp(x.op), 0, 0);
                        } else {
                            try self.expr(x.value, .{});
                        }
                        _ = try self.emit(.set_sig, @intCast(idx), 0);
                    },
                    .builtin => |b| {
                        self.c.rep.err(x.span, "cannot assign to builtin '{s}'", .{@tagName(b)});
                    },
                    .keyword => {
                        // Assignment to a fresh name creates a function-local.
                        const slot = try self.declare(id.name);
                        if (x.op != .set) {
                            self.c.rep.err(x.span, "'{s}' is not defined yet, so '{s}=' cannot be used", .{ id.name, opName(x.op) });
                        }
                        try self.expr(x.value, .{});
                        _ = try self.emit(.set_local, @intCast(slot), 0);
                    },
                    .handler, .component => {
                        self.c.rep.err(x.span, "cannot assign to '{s}'", .{id.name});
                    },
                }
            },
            .index => |ix| {
                // plain:    [obj, idx, value]            -> set_index
                // augmented:[obj, idx, obj, idx] -> index -> [obj, idx, old]
                //           [obj, idx, old, value] -> op  -> [obj, idx, new]
                try self.expr(ix.target, .{});
                try self.expr(ix.index, .{});
                if (x.op != .set) {
                    _ = try self.emit(.dup2, 0, 0);
                    _ = try self.emit(.index, 0, 0);
                    try self.expr(x.value, .{});
                    _ = try self.emit(augOp(x.op), 0, 0);
                } else {
                    try self.expr(x.value, .{});
                }
                _ = try self.emit(.set_index, 0, 0);
            },
            .member => |m| {
                try self.expr(m.target, .{});
                if (x.op != .set) {
                    _ = try self.emit(.dup, 0, 0);
                    _ = try self.emit(.member, @intCast(try self.c.addConstStr(m.name)), 0);
                    try self.expr(x.value, .{});
                    _ = try self.emit(augOp(x.op), 0, 0);
                } else {
                    try self.expr(x.value, .{});
                }
                _ = try self.emit(.set_member, @intCast(try self.c.addConstStr(m.name)), 0);
            },
            else => self.c.rep.err(x.target.spanOf(), "invalid assignment target", .{}),
        }
    }

    fn forLoop(self: *Fn, x: ast.ForStmt) Error!void {
        self.setLine(x.span);
        try self.expr(x.iter, .{});
        const obj_slot = try self.tempSlot("$iter");
        _ = try self.emit(.set_local, @intCast(obj_slot), 0);
        const i_slot = try self.tempSlot("$i");
        _ = try self.emit(.int_small, 0, 0);
        _ = try self.emit(.set_local, @intCast(i_slot), 0);

        self.pushScope();
        const idx_slot = if (x.index_name) |n| try self.declare(n) else 0;
        const item_slot = try self.declare(x.item_name);

        const jmp_cond = try self.emit(.jmp, 0, 0);
        const body_at = self.here();

        if (x.index_name != null) {
            _ = try self.emit(.local, @intCast(obj_slot), 0);
            _ = try self.emit(.local, @intCast(i_slot), 0);
            _ = try self.emit(.iter_key, 0, 0);
            _ = try self.emit(.set_local, @intCast(idx_slot), 0);
        }
        _ = try self.emit(.local, @intCast(obj_slot), 0);
        _ = try self.emit(.local, @intCast(i_slot), 0);
        _ = try self.emit(.iter_at, 0, 0);
        _ = try self.emit(.set_local, @intCast(item_slot), 0);

        self.loop_depth += 1;
        const break_base = self.breaks.items.len;
        const cont_base = self.continues.items.len;

        try self.stmts(x.body);

        self.loop_depth -= 1;
        const cont_at = self.here();
        for (self.continues.items[cont_base..]) |at| self.patch(at, cont_at);
        self.continues.shrinkRetainingCapacity(cont_base);

        _ = try self.emit(.local, @intCast(i_slot), 0);
        _ = try self.emit(.int_small, 1, 0);
        _ = try self.emit(.add, 0, 0);
        _ = try self.emit(.set_local, @intCast(i_slot), 0);

        const cond_at = self.here();
        self.patch(jmp_cond, cond_at);
        _ = try self.emit(.local, @intCast(i_slot), 0);
        _ = try self.emit(.local, @intCast(obj_slot), 0);
        _ = try self.emit(.count, 0, 0);
        _ = try self.emit(.lt, 0, 0);
        const jback = try self.emit(.jmp_true_pop, 0, 0);
        self.patch(jback, body_at);

        const end_at = self.here();
        for (self.breaks.items[break_base..]) |at| self.patch(at, end_at);
        self.breaks.shrinkRetainingCapacity(break_base);

        self.popScope();
    }

    fn tempSlot(self: *Fn, name: []const u8) Error!u32 {
        if (self.findLocal(name)) |s| return s;
        const slot = self.next_slot;
        self.next_slot += 1;
        // depth 0 so it survives nested scopes
        try self.locals.append(.{ .name = name, .slot = slot, .depth = 0 });
        return slot;
    }

    // -- view ---------------------------------------------------------------

    fn viewNodes(self: *Fn, nodes: []const ast.ViewNode) Error!void {
        for (nodes) |n| try self.viewNode(n);
    }

    fn viewNode(self: *Fn, n: ast.ViewNode) Error!void {
        self.setLine(n.spanOf());
        switch (n) {
            .element => |el| try self.element(el),
            .loop => |lp| try self.viewLoop(lp),
            .cond => |cd| try self.viewCond(cd),
        }
    }

    fn element(self: *Fn, el: ast.Element) Error!void {
        self.setLine(el.span);

        // `if:` / `show:` guards the whole element.
        var guard_jump: ?usize = null;
        for (el.args) |a| {
            if (a.name) |nm| {
                if ((std.mem.eql(u8, nm, "if") or std.mem.eql(u8, nm, "show")) and a.value != null) {
                    try self.expr(a.value.?, .{});
                    guard_jump = try self.emit(.jmp_false_pop, 0, 0);
                }
            }
        }

        // Component call?
        if (self.c.componentIndex(el.tag)) |ci| {
            const decl = self.c.program.components[ci];
            const fi = self.c.component_func.items[ci];
            _ = try self.emit(.closure, @intCast(fi), 0);
            try self.componentArgs(el.args, decl.params);
            _ = try self.emit(.call, @intCast(decl.params.len), 0);
            // A component attaches its own root to the current node.
            _ = try self.emit(.pop, 0, 0);
            if (guard_jump) |g| self.patch(g, self.here());
            return;
        }

        if (self.c.findComponentDecl(el.tag) == null and !isKnownTag(el.tag)) {
            self.c.rep.warnHint(el.span, "unknown elements render as a generic container", "unknown element '{s}'", .{el.tag});
        }

        _ = try self.emit(.ui_begin, @intCast(try self.c.addConstStr(el.tag)), 0);

        for (el.args) |a| {
            if (a.name) |nm| {
                if ((std.mem.eql(u8, nm, "if") or std.mem.eql(u8, nm, "show"))) continue;
                if (std.mem.eql(u8, nm, "bind")) {
                    const v = a.value orelse {
                        self.c.rep.err(a.span, "'bind:' needs a state name", .{});
                        continue;
                    };
                    if (v.* != .ident) {
                        self.c.rep.err(v.spanOf(), "'bind:' needs a plain state name", .{});
                        continue;
                    }
                    const sig_name = v.ident.name;
                    const sig_idx = self.c.sigIndex(sig_name) orelse {
                        self.c.rep.err(v.spanOf(), "cannot bind to '{s}': it is not declared in state:", .{sig_name});
                        continue;
                    };
                    _ = try self.emit(.ui_bind, @intCast(try self.c.addConstStr(sig_name)), 0);
                    _ = try self.emit(.sig, @intCast(sig_idx), 0);
                    _ = try self.emit(.ui_prop, @intCast(try self.c.addConstStr("value")), 0);
                    continue;
                }
                if (std.mem.eql(u8, nm, "key")) {
                    if (a.value) |v| {
                        try self.expr(v, .{});
                        _ = try self.emit(.ui_key, 0, 0);
                    }
                    continue;
                }
                if (eventName(nm)) |ev| {
                    try self.eventArg(a, ev);
                    continue;
                }
                if (a.block) |blk| {
                    self.c.rep.err(a.span, "'{s}:' takes a value, not a block", .{nm});
                    _ = blk;
                    continue;
                }
                const v = a.value orelse continue;
                // View arguments are non-strict: `align: center` and
                // `shadow: sm` are style keywords, not typos.
                try self.expr(v, .{});
                _ = try self.emit(.ui_prop, @intCast(try self.c.addConstStr(nm)), 0);
            } else {
                // positional argument
                const v = a.value orelse continue;
                if (positionalProp(el.tag)) |prop_name| {
                    try self.expr(v, .{});
                    _ = try self.emit(.ui_prop, @intCast(try self.c.addConstStr(prop_name)), 0);
                } else {
                    try self.expr(v, .{});
                    _ = try self.emit(.ui_text, 0, 0);
                }
            }
        }

        for (el.children) |ch| try self.viewNode(ch);

        _ = try self.emit(.ui_end, 0, 0);
        _ = try self.emit(.ui_child, 0, 0);
        if (guard_jump) |g| self.patch(g, self.here());
    }

    fn componentArgs(self: *Fn, args: []const ast.Arg, params: []const ast.Param) Error!void {
        var pos: usize = 0;
        for (params) |p| {
            var found = false;
            for (args) |a| {
                if (a.name != null and std.mem.eql(u8, a.name.?, p.name)) {
                    try self.argValue(a, p.name);
                    found = true;
                    break;
                }
            }
            if (found) continue;
            while (pos < args.len and args[pos].name != null) pos += 1;
            if (pos < args.len) {
                try self.argValue(args[pos], p.name);
                pos += 1;
            } else if (p.default) |d| {
                try self.expr(d, .{});
            } else {
                _ = try self.emit(.nil, 0, 0);
            }
        }
        for (args) |a| {
            if (a.name) |nm| {
                var known = false;
                for (params) |p| if (std.mem.eql(u8, p.name, nm)) {
                    known = true;
                };
                if (!known) self.c.rep.warn(a.span, "component does not declare a prop '{s}'", .{nm});
            }
        }
    }

    fn argValue(self: *Fn, a: ast.Arg, prop_name: []const u8) Error!void {
        if (a.block) |blk| {
            // An inline handler block passed as a prop (component callback).
            var f = try Fn.init(self.c, self, prop_name, .handler);
            defer f.deinit();
            try f.stmts(blk);
            _ = try f.emit(.ret_nil, 0, 0);
            const fi = try f.finish();
            _ = try self.emit(.closure, @intCast(fi), 0);
            return;
        }
        const v = a.value orelse {
            _ = try self.emit(.nil, 0, 0);
            return;
        };
        // `on_done: remove_task` — a bare handler name becomes a callable.
        if (eventName(prop_name) != null and v.* == .ident) {
            if (self.c.handlerIndex(v.ident.name)) |h| {
                _ = try self.emit(.closure, @intCast(self.c.handler_func.items[h]), 0);
                return;
            }
        }
        if (eventName(prop_name) != null) {
            // Wrap an arbitrary expression as a zero-arg handler closure.
            var f = try Fn.init(self.c, self, prop_name, .handler);
            defer f.deinit();
            try f.expr(v, .{});
            _ = try f.emit(.pop, 0, 0);
            _ = try f.emit(.ret_nil, 0, 0);
            const fi = try f.finish();
            _ = try self.emit(.closure, @intCast(fi), 0);
            return;
        }
        try self.expr(v, .{});
    }

    fn eventArg(self: *Fn, a: ast.Arg, ev: []const u8) Error!void {
        if (a.block) |blk| {
            var f = try Fn.init(self.c, self, ev, .handler);
            defer f.deinit();
            try f.stmts(blk);
            _ = try f.emit(.ret_nil, 0, 0);
            const fi = try f.finish();
            _ = try self.emit(.closure, @intCast(fi), 0);
            _ = try self.emit(.ui_event, @intCast(try self.c.addConstStr(ev)), 0);
            return;
        }
        const v = a.value orelse return;
        if (v.* == .ident) {
            if (self.c.handlerIndex(v.ident.name)) |h| {
                _ = try self.emit(.closure, @intCast(self.c.handler_func.items[h]), 0);
                _ = try self.emit(.ui_event, @intCast(try self.c.addConstStr(ev)), 0);
                return;
            }
        }
        var f = try Fn.init(self.c, self, ev, .handler);
        defer f.deinit();
        try f.expr(v, .{});
        _ = try f.emit(.pop, 0, 0);
        _ = try f.emit(.ret_nil, 0, 0);
        const fi = try f.finish();
        _ = try self.emit(.closure, @intCast(fi), 0);
        _ = try self.emit(.ui_event, @intCast(try self.c.addConstStr(ev)), 0);
    }

    fn viewLoop(self: *Fn, lp: ast.ViewLoop) Error!void {
        self.setLine(lp.span);
        try self.expr(lp.iter, .{ .strict_names = false });
        const obj_slot = try self.tempSlot("$iter");
        _ = try self.emit(.set_local, @intCast(obj_slot), 0);
        const i_slot = try self.tempSlot("$i");
        _ = try self.emit(.int_small, 0, 0);
        _ = try self.emit(.set_local, @intCast(i_slot), 0);

        self.pushScope();
        const idx_slot = if (lp.index_name) |n| try self.declare(n) else 0;
        const item_slot = try self.declare(lp.item_name);

        const jmp_cond = try self.emit(.jmp, 0, 0);
        const body_at = self.here();

        if (lp.index_name != null) {
            _ = try self.emit(.local, @intCast(obj_slot), 0);
            _ = try self.emit(.local, @intCast(i_slot), 0);
            _ = try self.emit(.iter_key, 0, 0);
            _ = try self.emit(.set_local, @intCast(idx_slot), 0);
        }
        _ = try self.emit(.local, @intCast(obj_slot), 0);
        _ = try self.emit(.local, @intCast(i_slot), 0);
        _ = try self.emit(.iter_at, 0, 0);
        _ = try self.emit(.set_local, @intCast(item_slot), 0);

        // Key: explicit `key <expr>`, else the item value, else the index.
        if (lp.key) |k| {
            try self.expr(k, .{ .strict_names = false });
            _ = try self.emit(.ui_key, 0, 0);
        } else {
            // Scalar items key by value (stable across reorders); everything
            // else falls back to the positional index.
            _ = try self.emit(.local, @intCast(item_slot), 0);
            _ = try self.emit(.ui_key, 0, 0);
            _ = try self.emit(.local, @intCast(i_slot), 0);
            _ = try self.emit(.ui_key_if_unset, 0, 0);
        }

        try self.viewNodes(lp.children);

        _ = try self.emit(.local, @intCast(i_slot), 0);
        _ = try self.emit(.int_small, 1, 0);
        _ = try self.emit(.add, 0, 0);
        _ = try self.emit(.set_local, @intCast(i_slot), 0);

        const cond_at = self.here();
        self.patch(jmp_cond, cond_at);
        _ = try self.emit(.local, @intCast(i_slot), 0);
        _ = try self.emit(.local, @intCast(obj_slot), 0);
        _ = try self.emit(.count, 0, 0);
        _ = try self.emit(.lt, 0, 0);
        const jback = try self.emit(.jmp_true_pop, 0, 0);
        self.patch(jback, body_at);

        self.popScope();
    }

    fn viewCond(self: *Fn, cd: ast.ViewCond) Error!void {
        var end_jumps = std.ArrayList(usize).init(self.c.a);
        defer end_jumps.deinit();
        for (cd.branches) |b| {
            if (b.cond) |c| {
                self.setLine(c.spanOf());
                try self.expr(c, .{ .strict_names = false });
                const j = try self.emit(.jmp_false_pop, 0, 0);
                try self.viewNodes(b.children);
                const je = try self.emit(.jmp, 0, 0);
                try end_jumps.append(je);
                self.patch(j, self.here());
            } else {
                try self.viewNodes(b.children);
            }
        }
        for (end_jumps.items) |j| self.patch(j, self.here());
    }
};

pub const ExprOpt = struct {
    /// Warn about unknown names (off for view/prop positions where bare
    /// keywords like `align: center` are legal).
    strict_names: bool = false,
};

fn augOp(o: ast.AssignOp) bytecode.Op {
    return switch (o) {
        .set => unreachable,
        .add => .add,
        .sub => .sub,
        .mul => .mul,
        .div => .div,
    };
}

fn opName(o: ast.AssignOp) []const u8 {
    return switch (o) {
        .set => "=",
        .add => "+=",
        .sub => "-=",
        .mul => "*=",
        .div => "/=",
    };
}

/// Map a source prop name to a wire event name.
pub fn eventName(prop: []const u8) ?[]const u8 {
    const pairs = [_]struct { p: []const u8, e: []const u8 }{
        .{ .p = "click", .e = "click" },
        .{ .p = "on_click", .e = "click" },
        .{ .p = "onclick", .e = "click" },
        .{ .p = "double_click", .e = "dblclick" },
        .{ .p = "on_double_click", .e = "dblclick" },
        .{ .p = "enter", .e = "enter" },
        .{ .p = "on_enter", .e = "enter" },
        .{ .p = "submit", .e = "enter" },
        .{ .p = "on_submit", .e = "enter" },
        .{ .p = "change", .e = "change" },
        .{ .p = "on_change", .e = "change" },
        .{ .p = "input", .e = "input" },
        .{ .p = "on_input", .e = "input" },
        .{ .p = "key", .e = "key" },
        .{ .p = "on_key", .e = "key" },
        .{ .p = "keydown", .e = "key" },
        .{ .p = "focus", .e = "focus" },
        .{ .p = "on_focus", .e = "focus" },
        .{ .p = "blur", .e = "blur" },
        .{ .p = "on_blur", .e = "blur" },
    };
    for (pairs) |p| if (std.mem.eql(u8, prop, p.p)) return p.e;
    return null;
}

/// First positional argument becomes a prop instead of a text child for these.
pub fn positionalProp(tag: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, tag, "input") or std.mem.eql(u8, tag, "textfield")) return "placeholder";
    if (std.mem.eql(u8, tag, "textarea")) return "placeholder";
    if (std.mem.eql(u8, tag, "image") or std.mem.eql(u8, tag, "img")) return "src";
    if (std.mem.eql(u8, tag, "spacer")) return "size";
    return null;
}

fn isKnownTag(tag: []const u8) bool {
    const known = [_][]const u8{
        "stack", "column", "row", "box", "div", "card", "grid", "text", "p", "span",
        "heading", "h1", "h2", "button", "btn", "input", "textfield", "textarea",
        "checkbox", "toggle", "image", "img", "link", "a", "divider", "hr",
        "badge", "spacer", "code", "pre", "scroll",
    };
    for (known) |k| if (std.mem.eql(u8, tag, k)) return true;
    return false;
}

// ---------------------------------------------------------------------------
// Compiler
// ---------------------------------------------------------------------------

pub const Compiler = struct {
    a: std.mem.Allocator,
    rep: *diag.Reporter,
    program: *const ast.Program,

    consts: std.ArrayList(bytecode.Const),
    str_ids: std.StringHashMap(u32),
    int_ids: std.AutoHashMap(i64, u32),
    float_ids: std.AutoHashMap(u64, u32),

    funcs: std.ArrayList(bytecode.Func),
    signals: std.ArrayList(bytecode.Signal),
    handlers: std.ArrayList(bytecode.Handler),
    handler_func: std.ArrayList(u32),
    components: std.ArrayList(bytecode.Component),
    component_func: std.ArrayList(u32),
    effects: std.ArrayList(bytecode.Effect),

    state_names: std.StringHashMap(u32),
    render_fn: u32 = 0,

    pub fn init(a: std.mem.Allocator, program: *const ast.Program, rep: *diag.Reporter) Compiler {
        return .{
            .a = a,
            .rep = rep,
            .program = program,
            .consts = std.ArrayList(bytecode.Const).init(a),
            .str_ids = std.StringHashMap(u32).init(a),
            .int_ids = std.AutoHashMap(i64, u32).init(a),
            .float_ids = std.AutoHashMap(u64, u32).init(a),
            .funcs = std.ArrayList(bytecode.Func).init(a),
            .signals = std.ArrayList(bytecode.Signal).init(a),
            .handlers = std.ArrayList(bytecode.Handler).init(a),
            .handler_func = std.ArrayList(u32).init(a),
            .components = std.ArrayList(bytecode.Component).init(a),
            .component_func = std.ArrayList(u32).init(a),
            .effects = std.ArrayList(bytecode.Effect).init(a),
            .state_names = std.StringHashMap(u32).init(a),
        };
    }

    pub fn deinit(self: *Compiler) void {
        self.consts.deinit();
        self.str_ids.deinit();
        self.int_ids.deinit();
        self.float_ids.deinit();
        self.funcs.deinit();
        self.signals.deinit();
        self.handlers.deinit();
        self.handler_func.deinit();
        self.components.deinit();
        self.component_func.deinit();
        self.effects.deinit();
        self.state_names.deinit();
    }

    fn paramNames(self: *Compiler, params: []const ParamInfo) Error![]const []const u8 {
        const out = try self.a.alloc([]const u8, params.len);
        for (params, 0..) |p, i| out[i] = p.name;
        return out;
    }

    fn paramDefaults(self: *Compiler, params: []const ParamInfo) Error![]const bool {
        const out = try self.a.alloc(bool, params.len);
        for (params, 0..) |p, i| out[i] = p.has_default;
        return out;
    }

    fn pushFunc(self: *Compiler, f: bytecode.Func) Error!u32 {
        const idx: u32 = @intCast(self.funcs.items.len);
        try self.funcs.append(f);
        return idx;
    }

    // -- constant pool ------------------------------------------------------

    fn addConst(self: *Compiler, c: bytecode.Const) Error!u32 {
        switch (c) {
            .str => |s| return self.addConstStr(s),
            .int => |i| {
                if (self.int_ids.get(i)) |id| return id;
                const id: u32 = @intCast(self.consts.items.len);
                try self.consts.append(c);
                try self.int_ids.put(i, id);
                return id;
            },
            .float => |f| {
                const bits: u64 = @bitCast(f);
                if (self.float_ids.get(bits)) |id| return id;
                const id: u32 = @intCast(self.consts.items.len);
                try self.consts.append(c);
                try self.float_ids.put(bits, id);
                return id;
            },
            else => {
                for (self.consts.items, 0..) |ex, i| {
                    if (std.meta.eql(ex, c)) return @intCast(i);
                }
                const id: u32 = @intCast(self.consts.items.len);
                try self.consts.append(c);
                return id;
            },
        }
    }

    fn addConstStr(self: *Compiler, s: []const u8) Error!u32 {
        if (self.str_ids.get(s)) |id| return id;
        const owned = try self.a.dupe(u8, s);
        const id: u32 = @intCast(self.consts.items.len);
        try self.consts.append(.{ .str = owned });
        try self.str_ids.put(owned, id);
        return id;
    }

    // -- name tables --------------------------------------------------------

    fn sigIndex(self: *const Compiler, name: []const u8) ?u32 {
        return self.state_names.get(name);
    }

    fn handlerIndex(self: *const Compiler, name: []const u8) ?u32 {
        for (self.handlers.items, 0..) |h, i| {
            if (std.mem.eql(u8, h.name, name)) return @intCast(i);
        }
        return null;
    }

    fn componentIndex(self: *const Compiler, name: []const u8) ?u32 {
        for (self.components.items, 0..) |c, i| {
            if (std.mem.eql(u8, c.name, name)) return @intCast(i);
        }
        return null;
    }

    fn findComponentDecl(self: *const Compiler, name: []const u8) ?*const ast.Component {
        return self.program.findComponent(name);
    }

    /// Name resolution order. Anything the programmer declared beats a builtin,
    /// so a handler called `clear` or `sort` is not shadowed by the stdlib.
    fn resolveGlobal(self: *const Compiler, name: []const u8) Resolve {
        if (self.sigIndex(name)) |i| return .{ .sig = i };
        if (self.handlerIndex(name)) |h| return .{ .handler = h };
        if (self.componentIndex(name)) |c| return .{ .component = c };
        if (builtins.byName(name)) |b| return .{ .builtin = b };
        return .{ .keyword = name };
    }

    fn declareSignal(self: *Compiler, name: []const u8, kind: bytecode.SigKind, span: diag.Span) Error!?u32 {
        if (self.state_names.contains(name)) {
            self.rep.err(span, "'{s}' is already declared", .{name});
            return null;
        }
        const idx: u32 = @intCast(self.signals.items.len);
        try self.signals.append(.{ .name = name, .kind = kind, .init_fn = 0 });
        try self.state_names.put(name, idx);
        return idx;
    }

    // -- driver -------------------------------------------------------------

    pub fn run(self: *Compiler) Error!*bytecode.CodeUnit {
        const app = &self.program.app;

        // 1. declare signal slots (indices must be stable before compiling bodies)
        for (app.state) |f| _ = try self.declareSignal(f.name, .state, f.span);
        for (app.computed) |f| _ = try self.declareSignal(f.name, .computed, f.span);
        if (app.theme.len > 0) _ = try self.declareSignal("theme", .theme, app.span);
        if (app.styles.len > 0) _ = try self.declareSignal("styles", .style, app.span);

        for (app.handlers) |h| {
            if (self.handlerIndex(h.name) != null) {
                self.rep.err(h.span, "handler '{s}' is declared twice", .{h.name});
                continue;
            }
            if (self.sigIndex(h.name) != null) {
                self.rep.err(h.span, "handler '{s}' clashes with a state name", .{h.name});
            }
            try self.handlers.append(.{ .name = h.name, .func_idx = 0 });
            try self.handler_func.append(0);
        }
        for (self.program.components) |c| {
            if (self.componentIndex(c.name) != null) {
                self.rep.err(c.span, "component '{s}' is declared twice", .{c.name});
                continue;
            }
            try self.components.append(.{ .name = c.name, .func_idx = 0 });
            try self.component_func.append(0);
        }

        // 2. signal initialisers
        for (app.state) |f| {
            const idx = self.sigIndex(f.name).?;
            const fi = try self.compileValueFn(f.name, f.value, .init);
            self.signals.items[idx].init_fn = fi;
        }
        for (app.computed) |f| {
            const idx = self.sigIndex(f.name).?;
            const fi = try self.compileValueFn(f.name, f.value, .init);
            self.signals.items[idx].init_fn = fi;
        }
        if (app.theme.len > 0) {
            const idx = self.sigIndex("theme").?;
            self.signals.items[idx].init_fn = try self.compileMapFn("theme", app.theme);
        }
        if (app.styles.len > 0) {
            const idx = self.sigIndex("styles").?;
            self.signals.items[idx].init_fn = try self.compileMapFn("styles", app.styles);
        }

        // 3. handlers
        for (app.handlers, 0..) |h, i| {
            const fi = try self.compileHandler(h);
            self.handler_func.items[i] = fi;
            self.handlers.items[i].func_idx = fi;
        }

        // 4. components
        for (self.program.components, 0..) |c, i| {
            const fi = try self.compileComponent(c);
            self.component_func.items[i] = fi;
            self.components.items[i].func_idx = fi;
        }

        if (self.rep.hasErrors()) return self.finishUnit();

        // 5. effects
        for (app.effects) |e| {
            var f = try Fn.init(self, null, "effect", .effect);
            defer f.deinit();
            switch (e.trigger) {
                .on_mount => {},
                .watch => |w| {
                    // Evaluate the watched expression so its signals are tracked.
                    try f.expr(w, .{ .strict_names = true });
                    _ = try f.emit(.pop, 0, 0);
                },
            }
            try f.stmts(e.body);
            _ = try f.emit(.ret_nil, 0, 0);
            const fi = try f.finish();
            try self.effects.append(.{
                .func_idx = fi,
                .on_mount = e.trigger == .on_mount,
                .label = if (e.trigger == .on_mount) "on_mount" else "on",
            });
        }

        // 6. the view
        self.render_fn = try self.compileRender(app);

        return try self.finishUnit();
    }

    fn finishUnit(self: *Compiler) Error!*bytecode.CodeUnit {
        const unit = try self.a.create(bytecode.CodeUnit);
        unit.* = .{
            .app_name = self.program.app.name,
            .consts = try self.a.dupe(bytecode.Const, self.consts.items),
            .funcs = try self.a.dupe(bytecode.Func, self.funcs.items),
            .signals = try self.a.dupe(bytecode.Signal, self.signals.items),
            .handlers = try self.a.dupe(bytecode.Handler, self.handlers.items),
            .components = try self.a.dupe(bytecode.Component, self.components.items),
            .effects = try self.a.dupe(bytecode.Effect, self.effects.items),
            .render_fn = self.render_fn,
        };
        return unit;
    }

    fn compileValueFn(self: *Compiler, name: []const u8, e: *const ast.Expr, kind: bytecode.FuncKind) Error!u32 {
        var f = try Fn.init(self, null, name, kind);
        defer f.deinit();
        f.setLine(e.spanOf());
        try f.expr(e, .{ .strict_names = kind == .init });
        _ = try f.emit(.ret, 0, 0);
        return try f.finish();
    }

    fn compileMapFn(self: *Compiler, name: []const u8, fields: []const ast.Field) Error!u32 {
        var f = try Fn.init(self, null, name, .init);
        defer f.deinit();
        for (fields) |fl| {
            _ = try f.emit(.const_, @intCast(try self.addConstStr(fl.name)), 0);
            try f.expr(fl.value, .{ .strict_names = true });
        }
        _ = try f.emit(.map, @intCast(fields.len), 0);
        _ = try f.emit(.ret, 0, 0);
        return try f.finish();
    }

    fn compileHandler(self: *Compiler, h: ast.Handler) Error!u32 {
        var f = try Fn.init(self, null, h.name, .handler);
        defer f.deinit();
        f.setLine(h.span);
        for (h.params) |p| {
            const slot = try f.declare(p.name);
            try f.params.append(.{ .name = p.name, .has_default = p.default != null });
            if (p.default) |d| {
                // prologue: fill in the default when the caller passed null
                _ = try f.emit(.local, @intCast(slot), 0);
                _ = try f.emit(.is_nil, 0, 0);
                const j = try f.emit(.jmp_false_pop, 0, 0);
                try f.expr(d, .{});
                _ = try f.emit(.set_local, @intCast(slot), 0);
                f.patch(j, f.here());
            }
        }
        try f.stmts(h.body);
        _ = try f.emit(.ret_nil, 0, 0);
        return try f.finish();
    }

    fn compileComponent(self: *Compiler, c: ast.Component) Error!u32 {
        var f = try Fn.init(self, null, c.name, .component);
        defer f.deinit();
        f.setLine(c.span);
        for (c.params) |p| {
            const slot = try f.declare(p.name);
            try f.params.append(.{ .name = p.name, .has_default = p.default != null });
            if (p.default) |d| {
                _ = try f.emit(.local, @intCast(slot), 0);
                _ = try f.emit(.is_nil, 0, 0);
                const j = try f.emit(.jmp_false_pop, 0, 0);
                try f.expr(d, .{});
                _ = try f.emit(.set_local, @intCast(slot), 0);
                f.patch(j, f.here());
            }
        }
        try self.emitView(&f, c.view);
        _ = try f.emit(.ret_nil, 0, 0);
        return try f.finish();
    }

    fn compileRender(self: *Compiler, app: *const ast.App) Error!u32 {
        var f = try Fn.init(self, null, app.name, .render);
        defer f.deinit();
        f.setLine(app.span);
        try self.emitView(&f, app.view);
        _ = try f.emit(.ret_nil, 0, 0);
        return try f.finish();
    }

    /// Emit a view body, wrapping it in an implicit container when it has more
    /// than one top-level node (a tree needs exactly one root). Every path ends
    /// with `ui_end` + `ui_child`: at the top of a render that records the root,
    /// inside a parent element it attaches the subtree.
    fn emitView(self: *Compiler, f: *Fn, nodes: []const ast.ViewNode) Error!void {
        if (nodes.len == 0) {
            _ = try f.emit(.ui_begin, @intCast(try self.addConstStr("box")), 0);
            _ = try f.emit(.ui_end, 0, 0);
            _ = try f.emit(.ui_child, 0, 0);
            return;
        }
        if (nodes.len > 1) {
            _ = try f.emit(.ui_begin, @intCast(try self.addConstStr("stack")), 0);
            _ = try f.emit(.const_, @intCast(try self.addConstStr("weave-root")), 0);
            _ = try f.emit(.ui_prop, @intCast(try self.addConstStr("class")), 0);
            try f.viewNodes(nodes);
            _ = try f.emit(.ui_end, 0, 0);
            _ = try f.emit(.ui_child, 0, 0);
            return;
        }
        try f.viewNode(nodes[0]);
    }
};

/// Compile a parsed program. Returns null when semantic errors were reported.
pub fn compile(arena: std.mem.Allocator, program: *const ast.Program, rep: *diag.Reporter) Error!?*bytecode.CodeUnit {
    var c = Compiler.init(arena, program, rep);
    defer c.deinit();
    const unit = try c.run();
    if (rep.hasErrors()) return null;
    return unit;
}
