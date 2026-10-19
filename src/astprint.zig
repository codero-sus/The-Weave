//! AST pretty-printer: `weave ast file.weave`.
//!
//! Output is normalised Weave source rather than a raw node dump — it reads like
//! the input with every implicit decision made explicit (handler blocks, loop
//! keys, interpolated string parts), which makes it useful both for learning the
//! grammar and for debugging the parser.

const std = @import("std");
const ast = @import("ast.zig");

const W = std.ArrayList(u8).Writer;

pub fn print(a: std.mem.Allocator, p: *const ast.Program) error{OutOfMemory}![]u8 {
    var out = std.ArrayList(u8).init(a);
    errdefer out.deinit();
    const w = out.writer();

    for (p.components) |*c| {
        try w.print("component {s}(", .{c.name});
        for (c.params, 0..) |par, i| {
            if (i > 0) try w.writeAll(", ");
            try w.writeAll(par.name);
            if (par.default) |d| {
                const ds = try expr(a, d);
                defer a.free(ds);
                try w.print(" = {s}", .{ds});
            }
        }
        try w.writeAll("):\n");
        try viewNodes(a, w, c.view, 1);
        try w.writeAll("\n");
    }

    const app = &p.app;
    try w.print("app {s}:\n", .{app.name});

    try fields(a, w, "state", app.state);
    try fields(a, w, "computed", app.computed);
    try fields(a, w, "theme", app.theme);
    try fields(a, w, "styles", app.styles);

    if (app.handlers.len > 0) {
        try ind(w, 1);
        try w.writeAll("handlers:\n");
        for (app.handlers) |*h| {
            try ind(w, 2);
            try w.print("{s}(", .{h.name});
            for (h.params, 0..) |par, i| {
                if (i > 0) try w.writeAll(", ");
                try w.writeAll(par.name);
                if (par.default) |d| {
                    const ds = try expr(a, d);
                    defer a.free(ds);
                    try w.print(" = {s}", .{ds});
                }
            }
            try w.writeAll("):\n");
            try stmts(a, w, h.body, 3);
        }
    }

    if (app.effects.len > 0) {
        try ind(w, 1);
        try w.writeAll("effects:\n");
        for (app.effects) |*e| {
            try ind(w, 2);
            switch (e.trigger) {
                .on_mount => try w.writeAll("on_mount:\n"),
                .watch => |x| {
                    const xs = try expr(a, x);
                    defer a.free(xs);
                    try w.print("on {s}:\n", .{xs});
                },
            }
            try stmts(a, w, e.body, 3);
        }
    }

    if (app.view.len > 0) {
        try ind(w, 1);
        try w.writeAll("view:\n");
        try viewNodes(a, w, app.view, 2);
    }
    return out.toOwnedSlice();
}

fn ind(w: W, level: usize) !void {
    var i: usize = 0;
    while (i < level) : (i += 1) try w.writeAll("    ");
}

fn fields(a: std.mem.Allocator, w: W, name: []const u8, list: []const ast.Field) error{OutOfMemory}!void {
    if (list.len == 0) return;
    try ind(w, 1);
    try w.print("{s}:\n", .{name});
    for (list) |*f| {
        const vs = try expr(a, f.value);
        defer a.free(vs);
        try ind(w, 2);
        try w.print("{s} = {s}\n", .{ f.name, vs });
    }
}

fn viewNodes(a: std.mem.Allocator, w: W, nodes: []const ast.ViewNode, level: usize) error{OutOfMemory}!void {
    for (nodes) |*n| try viewNode(a, w, n, level);
}

fn viewNode(a: std.mem.Allocator, w: W, n: *const ast.ViewNode, level: usize) error{OutOfMemory}!void {
    switch (n.*) {
        .element => |el| try element(a, w, el, level),
        .loop => |lp| {
            const is = try expr(a, lp.iter);
            defer a.free(is);
            try ind(w, level);
            if (lp.index_name) |ix| {
                try w.print("for {s}, {s} in {s}:\n", .{ ix, lp.item_name, is });
            } else {
                try w.print("for {s} in {s}:\n", .{ lp.item_name, is });
            }
            if (lp.key) |k| {
                const ks = try expr(a, k);
                defer a.free(ks);
                try ind(w, level + 1);
                try w.print("key {s}\n", .{ks});
            }
            try viewNodes(a, w, lp.children, level + 1);
        },
        .cond => |cd| {
            for (cd.branches, 0..) |*br, i| {
                try ind(w, level);
                if (br.cond) |c| {
                    const cs = try expr(a, c);
                    defer a.free(cs);
                    try w.print("{s} {s}:\n", .{ if (i == 0) "if" else "elif", cs });
                } else {
                    try w.writeAll("else:\n");
                }
                try viewNodes(a, w, br.children, level + 1);
            }
        },
    }
}

fn element(a: std.mem.Allocator, w: W, el: ast.Element, level: usize) error{OutOfMemory}!void {
    try ind(w, level);
    try w.writeAll(el.tag);
    if (el.args.len > 0) {
        try w.writeAll("(");
        for (el.args, 0..) |*arg, i| {
            if (i > 0) try w.writeAll(", ");
            if (arg.name) |nm| try w.print("{s}: ", .{nm});
            if (arg.block) |body| {
                try w.print("<block {d} stmt{s}>", .{ body.len, if (body.len == 1) "" else "s" });
            } else if (arg.value) |v| {
                const vs = try expr(a, v);
                defer a.free(vs);
                try w.writeAll(vs);
            } else {
                try w.writeAll("<empty>");
            }
        }
        try w.writeAll(")");
    }
    if (el.children.len > 0) {
        try w.writeAll(":\n");
        try viewNodes(a, w, el.children, level + 1);
    } else {
        try w.writeAll("\n");
    }
    // Handler blocks are printed after the element so their scope is obvious.
    for (el.args) |*arg| {
        const body = arg.block orelse continue;
        try ind(w, level + 1);
        try w.print("handler {s}:\n", .{arg.name orelse "?"});
        try stmts(a, w, body, level + 2);
    }
}

fn stmts(a: std.mem.Allocator, w: W, list: []const ast.Stmt, level: usize) error{OutOfMemory}!void {
    if (list.len == 0) {
        try ind(w, level);
        try w.writeAll("pass\n");
        return;
    }
    for (list) |*s| try stmt(a, w, s, level);
}

fn stmt(a: std.mem.Allocator, w: W, s: *const ast.Stmt, level: usize) error{OutOfMemory}!void {
    try ind(w, level);
    switch (s.*) {
        .assign => |x| {
            const t = try expr(a, x.target);
            defer a.free(t);
            const v = try expr(a, x.value);
            defer a.free(v);
            const op: []const u8 = switch (x.op) {
                .set => "=",
                .add => "+=",
                .sub => "-=",
                .mul => "*=",
                .div => "/=",
            };
            try w.print("{s} {s} {s}\n", .{ t, op, v });
        },
        .expr => |x| {
            const v = try expr(a, x.e);
            defer a.free(v);
            try w.print("{s}\n", .{v});
        },
        .if_ => |x| {
            for (x.branches, 0..) |*br, i| {
                if (i > 0) try ind(w, level);
                if (br.cond) |c| {
                    const cs = try expr(a, c);
                    defer a.free(cs);
                    try w.print("{s}{s} {s}:\n", .{ "", if (i == 0) "if" else "elif", cs });
                } else {
                    try w.writeAll("else:\n");
                }
                try stmts(a, w, br.body, level + 1);
            }
        },
        .for_ => |x| {
            const is = try expr(a, x.iter);
            defer a.free(is);
            if (x.index_name) |ix| {
                try w.print("for {s}, {s} in {s}:\n", .{ ix, x.item_name, is });
            } else {
                try w.print("for {s} in {s}:\n", .{ x.item_name, is });
            }
            try stmts(a, w, x.body, level + 1);
        },
        .after => |x| {
            const ds = try expr(a, x.delay_ms);
            defer a.free(ds);
            try w.print("after {s}:\n", .{ds});
            try stmts(a, w, x.body, level + 1);
        },
        .return_ => |x| {
            if (x.value) |v| {
                const vs = try expr(a, v);
                defer a.free(vs);
                try w.print("return {s}\n", .{vs});
            } else try w.writeAll("return\n");
        },
        .break_ => try w.writeAll("break\n"),
        .continue_ => try w.writeAll("continue\n"),
        .pass => try w.writeAll("pass\n"),
    }
}

pub fn expr(a: std.mem.Allocator, e: *const ast.Expr) error{OutOfMemory}![]u8 {
    var out = std.ArrayList(u8).init(a);
    errdefer out.deinit();
    try exprInto(a, out.writer(), e);
    return out.toOwnedSlice();
}

fn exprInto(a: std.mem.Allocator, w: W, e: *const ast.Expr) error{OutOfMemory}!void {
    switch (e.*) {
        .nil_lit => try w.writeAll("nil"),
        .bool_lit => |x| try w.writeAll(if (x.v) "true" else "false"),
        .int_lit => |x| try w.print("{d}", .{x.v}),
        .float_lit => |x| try w.print("{d}", .{x.v}),
        .str_lit => |x| {
            try w.writeByte('"');
            for (x.parts) |part| {
                switch (part) {
                    .lit => |s| {
                        for (s) |c| {
                            if (c == '"' or c == '\\') try w.writeByte('\\');
                            try w.writeByte(c);
                        }
                    },
                    .expr => |inner| {
                        try w.writeByte('{');
                        try exprInto(a, w, inner);
                        try w.writeByte('}');
                    },
                }
            }
            try w.writeByte('"');
        },
        .list_lit => |x| {
            try w.writeByte('[');
            for (x.items, 0..) |it, i| {
                if (i > 0) try w.writeAll(", ");
                try exprInto(a, w, it);
            }
            try w.writeByte(']');
        },
        .map_lit => |x| {
            try w.writeByte('{');
            for (x.entries, 0..) |en, i| {
                if (i > 0) try w.writeAll(", ");
                try exprInto(a, w, en.key);
                try w.writeAll(": ");
                try exprInto(a, w, en.value);
            }
            try w.writeByte('}');
        },
        .ident => |x| try w.writeAll(x.name),
        .index => |x| {
            try exprInto(a, w, x.target);
            try w.writeByte('[');
            try exprInto(a, w, x.index);
            try w.writeByte(']');
        },
        .slice => |x| {
            try exprInto(a, w, x.target);
            try w.writeByte('[');
            if (x.from) |f| try exprInto(a, w, f);
            try w.writeByte(':');
            if (x.to) |t| try exprInto(a, w, t);
            try w.writeByte(']');
        },
        .member => |x| {
            try exprInto(a, w, x.target);
            try w.writeByte('.');
            try w.writeAll(x.name);
        },
        .call => |x| {
            try exprInto(a, w, x.callee);
            try w.writeByte('(');
            for (x.args, 0..) |arg, i| {
                if (i > 0) try w.writeAll(", ");
                if (arg.name) |nm| try w.print("{s}=", .{nm});
                try exprInto(a, w, arg.value);
            }
            try w.writeByte(')');
        },
        .unary => |x| {
            try w.writeAll(if (x.op == .neg) "-" else "not ");
            try w.writeByte('(');
            try exprInto(a, w, x.operand);
            try w.writeByte(')');
        },
        .binary => |x| {
            try w.writeByte('(');
            try exprInto(a, w, x.lhs);
            try w.print(" {s} ", .{x.op.symbol()});
            try exprInto(a, w, x.rhs);
            try w.writeByte(')');
        },
        .cond => |x| {
            try w.writeByte('(');
            try exprInto(a, w, x.then);
            try w.writeAll(" if ");
            try exprInto(a, w, x.cond);
            try w.writeAll(" else ");
            try exprInto(a, w, x.els);
            try w.writeByte(')');
        },
    }
}
