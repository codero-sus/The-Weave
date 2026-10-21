//! Weave abstract syntax tree.
//!
//! Weave is indentation-based (like Python) with declarative UI blocks (like
//! HTML/JSX). The AST has three shapes:
//!
//!   * declarations — `app`, `component`
//!   * sections     — `state`, `computed`, `theme`, `styles`, `handlers`, `effects`, `view`
//!   * view nodes   — element calls, `for`, `if`
//!
//! All nodes are arena-allocated and live for the lifetime of the compiled
//! module; the interpreter never mutates the AST.

const std = @import("std");
const diag = @import("diag.zig");

pub const Span = diag.Span;

// ---------------------------------------------------------------------------
// Expressions
// ---------------------------------------------------------------------------

pub const BinOp = enum {
    add,
    sub,
    mul,
    div,
    mod,
    floor_div,
    pow,
    eq,
    ne,
    lt,
    le,
    gt,
    ge,
    and_,
    or_,
    in_,
    not_in,

    pub fn symbol(self: BinOp) []const u8 {
        return switch (self) {
            .add => "+",
            .sub => "-",
            .mul => "*",
            .div => "/",
            .mod => "%",
            .floor_div => "//",
            .pow => "**",
            .eq => "==",
            .ne => "!=",
            .lt => "<",
            .le => "<=",
            .gt => ">",
            .ge => ">=",
            .and_ => "and",
            .or_ => "or",
            .in_ => "in",
            .not_in => "not in",
        };
    }
};

pub const UnOp = enum { neg, not_ };

pub const AssignOp = enum { set, add, sub, mul, div };

/// A piece of a string literal: either raw text or an interpolated `{expr}`.
pub const StrPart = union(enum) {
    lit: []const u8,
    expr: *Expr,
};

pub const MapEntryExpr = struct {
    key: *Expr,
    value: *Expr,
    span: Span,
};

pub const CallArg = struct {
    /// `null` for positional arguments.
    name: ?[]const u8 = null,
    value: *Expr,
    span: Span = .{},
};

pub const Expr = union(enum) {
    nil_lit: Span,
    bool_lit: struct { v: bool, span: Span },
    int_lit: struct { v: i64, span: Span },
    float_lit: struct { v: f64, span: Span },
    str_lit: struct { parts: []const StrPart, span: Span },
    list_lit: struct { items: []const *Expr, span: Span },
    map_lit: struct { entries: []const MapEntryExpr, span: Span },
    ident: struct { name: []const u8, span: Span },
    index: struct { target: *Expr, index: *Expr, span: Span },
    slice: struct { target: *Expr, from: ?*Expr, to: ?*Expr, span: Span },
    member: struct { target: *Expr, name: []const u8, span: Span },
    call: struct { callee: *Expr, args: []const CallArg, span: Span },
    unary: struct { op: UnOp, operand: *Expr, span: Span },
    binary: struct { op: BinOp, lhs: *Expr, rhs: *Expr, span: Span },
    /// `a if cond else b`
    cond: struct { cond: *Expr, then: *Expr, els: *Expr, span: Span },

    pub fn spanOf(self: *const Expr) Span {
        return switch (self.*) {
            .nil_lit => |s| s,
            .bool_lit => |x| x.span,
            .int_lit => |x| x.span,
            .float_lit => |x| x.span,
            .str_lit => |x| x.span,
            .list_lit => |x| x.span,
            .map_lit => |x| x.span,
            .ident => |x| x.span,
            .index => |x| x.span,
            .slice => |x| x.span,
            .member => |x| x.span,
            .call => |x| x.span,
            .unary => |x| x.span,
            .binary => |x| x.span,
            .cond => |x| x.span,
        };
    }

    /// Cheap structural name for diagnostics ("tasks", "tasks.remove", ...).
    pub fn describe(self: *const Expr, buf: []u8) []const u8 {
        return switch (self.*) {
            .ident => |x| x.name,
            .member => |x| blk: {
                const base = x.target.describe(buf[0 .. buf.len / 2]);
                break :blk std.fmt.bufPrint(buf, "{s}.{s}", .{ base, x.name }) catch x.name;
            },
            .call => |x| blk: {
                const base = x.callee.describe(buf[0 .. buf.len / 2]);
                break :blk std.fmt.bufPrint(buf, "{s}(...)", .{base}) catch "call";
            },
            .str_lit => "string",
            .int_lit => "int",
            .float_lit => "float",
            .bool_lit => "bool",
            .nil_lit => "null",
            .list_lit => "list",
            .map_lit => "map",
            .index => "index",
            .slice => "slice",
            .unary => "unary",
            .binary => "binary",
            .cond => "conditional",
        };
    }
};

// ---------------------------------------------------------------------------
// Statements
// ---------------------------------------------------------------------------

pub const Assign = struct {
    target: *Expr,
    op: AssignOp,
    value: *Expr,
    span: Span,
};

pub const IfStmt = struct {
    branches: []const IfBranch,
    span: Span,
};

pub const IfBranch = struct {
    /// `null` for the trailing `else:` branch.
    cond: ?*Expr,
    body: []const Stmt,
};

pub const ForStmt = struct {
    /// Optional index/key binding for `for i, x in xs:`.
    index_name: ?[]const u8,
    item_name: []const u8,
    iter: *Expr,
    body: []const Stmt,
    span: Span,
};

pub const AfterStmt = struct {
    delay_ms: *Expr,
    body: []const Stmt,
    span: Span,
};

pub const Stmt = union(enum) {
    assign: Assign,
    /// A bare expression statement (usually a call).
    expr: struct { e: *Expr, span: Span },
    if_: IfStmt,
    for_: ForStmt,
    after: AfterStmt,
    return_: struct { value: ?*Expr, span: Span },
    break_: Span,
    continue_: Span,
    pass: Span,

    pub fn spanOf(self: *const Stmt) Span {
        return switch (self.*) {
            .assign => |x| x.span,
            .expr => |x| x.span,
            .if_ => |x| x.span,
            .for_ => |x| x.span,
            .after => |x| x.span,
            .return_ => |x| x.span,
            .break_ => |x| x,
            .continue_ => |x| x,
            .pass => |x| x,
        };
    }
};

// ---------------------------------------------------------------------------
// View
// ---------------------------------------------------------------------------

pub const Arg = struct {
    /// `null` for positional arguments.
    name: ?[]const u8 = null,
    /// Inline expression value (`click: tasks.remove(task)`).
    value: ?*Expr = null,
    /// Handler block value (`on_enter: { ... }`).
    block: ?[]const Stmt = null,
    span: Span = .{},
};

pub const Element = struct {
    /// Tag name (`stack`, `text`, ...) or a component name (`TaskCard`).
    tag: []const u8,
    args: []const Arg,
    children: []const ViewNode,
    span: Span,
};

pub const ViewLoop = struct {
    index_name: ?[]const u8,
    item_name: []const u8,
    iter: *Expr,
    /// Optional explicit `key <expr>`.
    key: ?*Expr,
    children: []const ViewNode,
    span: Span,
};

pub const ViewBranch = struct {
    /// `null` for `else:`.
    cond: ?*Expr,
    children: []const ViewNode,
};

pub const ViewCond = struct {
    branches: []const ViewBranch,
    span: Span,
};

pub const ViewNode = union(enum) {
    element: Element,
    loop: ViewLoop,
    cond: ViewCond,

    pub fn spanOf(self: *const ViewNode) Span {
        return switch (self.*) {
            .element => |x| x.span,
            .loop => |x| x.span,
            .cond => |x| x.span,
        };
    }
};

// ---------------------------------------------------------------------------
// Declarations
// ---------------------------------------------------------------------------

pub const Field = struct {
    name: []const u8,
    value: *Expr,
    span: Span,
};

pub const Param = struct {
    name: []const u8,
    default: ?*Expr = null,
    span: Span = .{},
};

pub const Handler = struct {
    name: []const u8,
    params: []const Param,
    body: []const Stmt,
    span: Span,
};

pub const EffectTrigger = union(enum) {
    /// Runs once when a session mounts.
    on_mount,
    /// Runs whenever any signal read by `watch` changes.
    watch: *Expr,
};

pub const Effect = struct {
    trigger: EffectTrigger,
    body: []const Stmt,
    span: Span,
};

pub const Component = struct {
    name: []const u8,
    params: []const Param,
    view: []const ViewNode,
    span: Span,
};

pub const App = struct {
    name: []const u8,
    state: []const Field = &.{},
    computed: []const Field = &.{},
    theme: []const Field = &.{},
    styles: []const Field = &.{},
    handlers: []const Handler = &.{},
    effects: []const Effect = &.{},
    view: []const ViewNode = &.{},
    span: Span = .{},
};

pub const Program = struct {
    app: App,
    components: []const Component = &.{},

    pub fn findComponent(self: *const Program, name: []const u8) ?*const Component {
        for (self.components) |*c| {
            if (std.mem.eql(u8, c.name, name)) return c;
        }
        return null;
    }
};

/// Walk every expression in the program (used by the checker and for
/// dependency discovery).
pub fn visitExprs(e: *const Expr, cb: *const fn (*const Expr, anytype) void, ctx: anytype) void {
    cb(e, ctx);
    switch (e.*) {
        .str_lit => |x| for (x.parts) |p| switch (p) {
            .expr => |sub| visitExprs(sub, cb, ctx),
            .lit => {},
        },
        .list_lit => |x| for (x.items) |sub| visitExprs(sub, cb, ctx),
        .map_lit => |x| for (x.entries) |en| {
            visitExprs(en.key, cb, ctx);
            visitExprs(en.value, cb, ctx);
        },
        .index => |x| {
            visitExprs(x.target, cb, ctx);
            visitExprs(x.index, cb, ctx);
        },
        .slice => |x| {
            visitExprs(x.target, cb, ctx);
            if (x.from) |f| visitExprs(f, cb, ctx);
            if (x.to) |t| visitExprs(t, cb, ctx);
        },
        .member => |x| visitExprs(x.target, cb, ctx),
        .call => |x| {
            visitExprs(x.callee, cb, ctx);
            for (x.args) |a| visitExprs(a.value, cb, ctx);
        },
        .unary => |x| visitExprs(x.operand, cb, ctx),
        .binary => |x| {
            visitExprs(x.lhs, cb, ctx);
            visitExprs(x.rhs, cb, ctx);
        },
        .cond => |x| {
            visitExprs(x.cond, cb, ctx);
            visitExprs(x.then, cb, ctx);
            visitExprs(x.els, cb, ctx);
        },
        else => {},
    }
}

pub fn visitStmts(stmts: []const Stmt, cb: *const fn (*const Expr, anytype) void, ctx: anytype) void {
    for (stmts) |s| switch (s) {
        .assign => |x| {
            visitExprs(x.target, cb, ctx);
            visitExprs(x.value, cb, ctx);
        },
        .expr => |x| visitExprs(x.e, cb, ctx),
        .if_ => |x| for (x.branches) |b| {
            if (b.cond) |c| visitExprs(c, cb, ctx);
            visitStmts(b.body, cb, ctx);
        },
        .for_ => |x| {
            visitExprs(x.iter, cb, ctx);
            visitStmts(x.body, cb, ctx);
        },
        .after => |x| {
            visitExprs(x.delay_ms, cb, ctx);
            visitStmts(x.body, cb, ctx);
        },
        .return_ => |x| {
            if (x.value) |v| visitExprs(v, cb, ctx);
        },
        else => {},
    };
}
