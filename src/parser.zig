//! Weave parser: tokens -> AST.
//!
//! Layout rules handled here:
//!   * sections and blocks are delimited by INDENT/DEDENT
//!   * `{ ... }` is a map literal when it starts with `name:` / `"str":`,
//!     otherwise it is an inline handler block
//!   * string literals support `{expr}` interpolation (and `{{` / `}}` escapes),
//!     parsed by recursively tokenising the inner slice with shifted spans

const std = @import("std");
const ast = @import("ast.zig");
const diag = @import("diag.zig");
const lexer = @import("lexer.zig");

const Token = lexer.Token;
const Kind = lexer.Kind;

pub const Result = struct {
    arena: *std.heap.ArenaAllocator,
    parent: std.mem.Allocator,
    program: ast.Program,

    pub fn deinit(self: *Result) void {
        const a = self.arena;
        a.deinit();
        self.parent.destroy(a);
    }
};

pub const max_errors = 12;

/// Recursive descent needs an explicit error set — Zig cannot infer error sets
/// through mutually recursive functions. Diagnostics are reported through the
/// `Reporter`; the only thing we can actually *return* is OOM.
pub const Error = error{OutOfMemory};

pub const Parser = struct {
    a: std.mem.Allocator,
    parent: std.mem.Allocator,
    toks: []const Token,
    rep: *diag.Reporter,
    src: *const diag.Source,
    i: usize = 0,
    depth: usize = 0,

    pub fn init(parent: std.mem.Allocator, arena: std.mem.Allocator, toks: []const Token, src: *const diag.Source, rep: *diag.Reporter) Parser {
        return .{ .a = arena, .parent = parent, .toks = toks, .rep = rep, .src = src };
    }

    // -- token helpers ------------------------------------------------------

    fn cur(self: *const Parser) Token {
        return self.toks[@min(self.i, self.toks.len - 1)];
    }

    fn peek(self: *const Parser, off: usize) Token {
        return self.toks[@min(self.i + off, self.toks.len - 1)];
    }

    fn at(self: *const Parser, k: Kind) bool {
        return self.cur().kind == k;
    }

    fn atName(self: *const Parser, s: []const u8) bool {
        const t = self.cur();
        return t.kind == .name and std.mem.eql(u8, t.text, s);
    }

    fn peekName(self: *const Parser, off: usize, s: []const u8) bool {
        const t = self.peek(off);
        return t.kind == .name and std.mem.eql(u8, t.text, s);
    }

    fn advance(self: *Parser) Token {
        const t = self.cur();
        if (self.i < self.toks.len - 1) self.i += 1;
        return t;
    }

    fn skipNewlines(self: *Parser) void {
        while (self.at(.newline)) self.i += 1;
    }

    fn expect(self: *Parser, k: Kind) ?Token {
        if (self.at(k)) return self.advance();
        const t = self.cur();
        self.rep.err(t.span, "expected {s}, found {s}", .{ k.label(), describeTok(t) });
        return null;
    }

    fn expectName(self: *Parser, s: []const u8) ?Token {
        if (self.atName(s)) return self.advance();
        const t = self.cur();
        self.rep.err(t.span, "expected '{s}', found {s}", .{ s, describeTok(t) });
        return null;
    }

    fn tooManyErrors(self: *Parser) bool {
        return self.rep.errorCount() > max_errors;
    }

    /// Skip tokens until we are plausibly at the start of a new statement.
    fn synchronize(self: *Parser) void {
        var guard: usize = 0;
        while (!self.at(.eof) and guard < 400) : (guard += 1) {
            if (self.at(.newline)) {
                self.i += 1;
                return;
            }
            if (self.at(.dedent)) return;
            if (self.at(.rbrace)) {
                self.i += 1;
                return;
            }
            self.i += 1;
        }
    }

    // -- AST allocation -----------------------------------------------------

    fn mkExpr(self: *Parser, e: ast.Expr) Error!*ast.Expr {
        const p = try self.a.create(ast.Expr);
        p.* = e;
        return p;
    }

    fn mkStmts(self: *Parser, list: std.ArrayList(ast.Stmt)) Error![]const ast.Stmt {
        if (list.items.len == 0) return &.{};
        return try self.a.dupe(ast.Stmt, list.items);
    }

    fn mkNodes(self: *Parser, list: std.ArrayList(ast.ViewNode)) Error![]const ast.ViewNode {
        if (list.items.len == 0) return &.{};
        return try self.a.dupe(ast.ViewNode, list.items);
    }

    // -- program ------------------------------------------------------------

    pub fn parseProgram(self: *Parser) Error!ast.Program {
        var app: ?ast.App = null;
        var comps = std.ArrayList(ast.Component).init(self.a);
        defer comps.deinit();

        self.skipNewlines();
        while (!self.at(.eof)) {
            if (self.tooManyErrors()) break;
            if (self.atName("app")) {
                if (app != null) {
                    self.rep.err(self.cur().span, "a file may only declare one 'app'", .{});
                    self.synchronize();
                    continue;
                }
                app = try self.parseApp();
            } else if (self.atName("component")) {
                try comps.append(try self.parseComponent());
            } else if (self.at(.indent) or self.at(.dedent) or self.at(.newline)) {
                self.i += 1;
            } else {
                const t = self.cur();
                self.rep.errHint(t.span, "a .weave file contains 'app Name:' and 'component Name(...):' declarations", "expected 'app' or 'component', found {s}", .{describeTok(t)});
                self.synchronize();
            }
            self.skipNewlines();
        }

        const the_app = app orelse blk: {
            self.rep.err(self.src.spanOf(0, @min(1, self.src.text.len)), "no 'app' declaration found", .{});
            break :blk ast.App{ .name = "App" };
        };

        return .{
            .app = the_app,
            .components = try self.a.dupe(ast.Component, comps.items),
        };
    }

    fn parseApp(self: *Parser) Error!ast.App {
        const kw = self.advance(); // 'app'
        var name: []const u8 = "App";
        if (self.at(.name)) name = self.advance().text;
        _ = self.expect(.colon);
        var app = ast.App{ .name = name, .span = kw.span };

        var state = std.ArrayList(ast.Field).init(self.a);
        var computed = std.ArrayList(ast.Field).init(self.a);
        var theme = std.ArrayList(ast.Field).init(self.a);
        var styles = std.ArrayList(ast.Field).init(self.a);
        var handlers = std.ArrayList(ast.Handler).init(self.a);
        var effects = std.ArrayList(ast.Effect).init(self.a);
        var view = std.ArrayList(ast.ViewNode).init(self.a);
        defer {
            state.deinit();
            computed.deinit();
            theme.deinit();
            styles.deinit();
            handlers.deinit();
            effects.deinit();
            view.deinit();
        }

        self.skipNewlines();
        if (self.at(.indent)) {
            self.i += 1;
            var saw_section = false;
            while (!self.at(.dedent) and !self.at(.eof)) {
                if (self.tooManyErrors()) break;
                self.skipNewlines();
                if (self.at(.dedent) or self.at(.eof)) break;
                if (self.at(.name) and self.peek(1).kind == .colon and isSectionName(self.cur().text)) {
                    saw_section = true;
                    const sec = self.advance().text;
                    self.i += 1; // ':'
                    if (std.mem.eql(u8, sec, "view")) {
                        try self.parseViewNodes(&view);
                    } else {
                        try self.parseSection(sec, &state, &computed, &theme, &styles, &handlers, &effects);
                    }
                } else if (!saw_section) {
                    // A bare app body is treated as the view.
                    try self.parseViewNodes(&view);
                } else {
                    const t = self.cur();
                    self.rep.errHint(t.span, "valid sections: state, computed, theme, styles, handlers, effects, view", "unexpected {s} in app body", .{describeTok(t)});
                    self.synchronize();
                }
                self.skipNewlines();
            }
            if (self.at(.dedent)) self.i += 1;
        } else {
            self.rep.err(kw.span, "'app {s}:' must be followed by an indented block", .{name});
        }

        app.state = try self.a.dupe(ast.Field, state.items);
        app.computed = try self.a.dupe(ast.Field, computed.items);
        app.theme = try self.a.dupe(ast.Field, theme.items);
        app.styles = try self.a.dupe(ast.Field, styles.items);
        app.handlers = try self.a.dupe(ast.Handler, handlers.items);
        app.effects = try self.a.dupe(ast.Effect, effects.items);
        app.view = try self.a.dupe(ast.ViewNode, view.items);
        return app;
    }

    fn parseSection(
        self: *Parser,
        sec: []const u8,
        state: *std.ArrayList(ast.Field),
        computed: *std.ArrayList(ast.Field),
        theme: *std.ArrayList(ast.Field),
        styles: *std.ArrayList(ast.Field),
        handlers: *std.ArrayList(ast.Handler),
        effects: *std.ArrayList(ast.Effect),
    ) Error!void {
        self.skipNewlines();
        if (!self.at(.indent)) {
            self.rep.err(self.cur().span, "section '{s}:' must be followed by an indented block", .{sec});
            return;
        }
        self.i += 1;

        if (std.mem.eql(u8, sec, "state") or std.mem.eql(u8, sec, "computed") or
            std.mem.eql(u8, sec, "theme") or std.mem.eql(u8, sec, "styles"))
        {
            const target: *std.ArrayList(ast.Field) = if (std.mem.eql(u8, sec, "state"))
                state
            else if (std.mem.eql(u8, sec, "computed"))
                computed
            else if (std.mem.eql(u8, sec, "theme"))
                theme
            else
                styles;

            while (!self.at(.dedent) and !self.at(.eof)) {
                if (self.tooManyErrors()) break;
                self.skipNewlines();
                if (self.at(.dedent) or self.at(.eof)) break;
                const field = try self.parseField(sec);
                try target.append(field);
                self.skipNewlines();
            }
        } else if (std.mem.eql(u8, sec, "handlers")) {
            while (!self.at(.dedent) and !self.at(.eof)) {
                if (self.tooManyErrors()) break;
                self.skipNewlines();
                if (self.at(.dedent) or self.at(.eof)) break;
                try handlers.append(try self.parseHandler());
                self.skipNewlines();
            }
        } else if (std.mem.eql(u8, sec, "effects")) {
            while (!self.at(.dedent) and !self.at(.eof)) {
                if (self.tooManyErrors()) break;
                self.skipNewlines();
                if (self.at(.dedent) or self.at(.eof)) break;
                try effects.append(try self.parseEffect());
                self.skipNewlines();
            }
        }
        if (self.at(.dedent)) self.i += 1;
    }

    fn parseField(self: *Parser, sec: []const u8) Error!ast.Field {
        const name_tok = self.cur();
        if (name_tok.kind != .name) {
            self.rep.err(name_tok.span, "expected a name in '{s}:' block, found {s}", .{ sec, describeTok(name_tok) });
            self.synchronize();
            return .{ .name = "_", .value = try self.mkExpr(.{ .nil_lit = name_tok.span }), .span = name_tok.span };
        }
        self.i += 1;
        _ = self.expect(.assign);
        const value = try self.parseExprFull();
        self.finishLine();
        return .{ .name = name_tok.text, .value = value, .span = diag.Span.merge(name_tok.span, value.spanOf()) };
    }

    fn parseHandler(self: *Parser) Error!ast.Handler {
        var span = self.cur().span;
        if (self.atName("def") or self.atName("fn")) {
            span = self.advance().span;
        }
        const name_tok = self.cur();
        if (name_tok.kind != .name) {
            self.rep.err(name_tok.span, "expected a handler name, found {s}", .{describeTok(name_tok)});
            self.synchronize();
            return .{ .name = "_", .params = &.{}, .body = &.{}, .span = name_tok.span };
        }
        self.i += 1;
        const params = try self.parseParams();
        _ = self.expect(.colon);
        const body = try self.parseStmtBlock();
        return .{
            .name = name_tok.text,
            .params = params,
            .body = body,
            .span = diag.Span.merge(span, name_tok.span),
        };
    }

    fn parseEffect(self: *Parser) Error!ast.Effect {
        const kw = self.advance();
        var trigger: ast.EffectTrigger = undefined;
        if (std.mem.eql(u8, kw.text, "on_mount") or std.mem.eql(u8, kw.text, "mount")) {
            trigger = .on_mount;
        } else if (std.mem.eql(u8, kw.text, "on")) {
            const e = try self.parseExprFull();
            trigger = .{ .watch = e };
        } else if (std.mem.eql(u8, kw.text, "on_change")) {
            const e = try self.parseExprFull();
            trigger = .{ .watch = e };
        } else {
            self.rep.errHint(kw.span, "effects use 'on_mount:' or 'on <expr>:'", "unknown effect trigger '{s}'", .{kw.text});
            trigger = .on_mount;
        }
        _ = self.expect(.colon);
        const body = try self.parseStmtBlock();
        return .{ .trigger = trigger, .body = body, .span = kw.span };
    }

    fn parseParams(self: *Parser) Error![]const ast.Param {
        var list = std.ArrayList(ast.Param).init(self.a);
        defer list.deinit();
        if (!self.at(.lparen)) {
            return try self.a.dupe(ast.Param, list.items);
        }
        self.i += 1;
        while (!self.at(.rparen) and !self.at(.eof)) {
            if (self.at(.newline)) {
                self.i += 1;
                continue;
            }
            if (self.at(.comma)) {
                self.i += 1;
                continue;
            }
            const nm = self.cur();
            if (nm.kind != .name) {
                self.rep.err(nm.span, "expected a parameter name, found {s}", .{describeTok(nm)});
                self.synchronize();
                break;
            }
            self.i += 1;
            var def: ?*ast.Expr = null;
            if (self.at(.assign)) {
                self.i += 1;
                def = try self.parseExprFull();
            }
            try list.append(.{ .name = nm.text, .default = def, .span = nm.span });
        }
        _ = self.expect(.rparen);
        return try self.a.dupe(ast.Param, list.items);
    }

    fn parseComponent(self: *Parser) Error!ast.Component {
        const kw = self.advance(); // 'component'
        const name_tok = self.cur();
        var name: []const u8 = "Component";
        if (name_tok.kind == .name) {
            name = name_tok.text;
            self.i += 1;
        } else {
            self.rep.err(name_tok.span, "expected a component name", .{});
        }
        const params = try self.parseParams();
        _ = self.expect(.colon);

        var view = std.ArrayList(ast.ViewNode).init(self.a);
        defer view.deinit();

        self.skipNewlines();
        if (!self.at(.indent)) {
            self.rep.err(kw.span, "'component {s}:' must be followed by an indented block", .{name});
        } else if (self.peekName(1, "view") and self.peek(2).kind == .colon) {
            // `component X():` + an explicit `view:` header.
            self.i += 3;
            self.skipNewlines();
            try self.parseViewNodes(&view);
            if (self.at(.dedent)) self.i += 1; // closes the view: block
            if (self.at(.dedent)) self.i += 1; // closes the component block
        } else {
            // Bare view body: parseViewNodes consumes the INDENT itself.
            try self.parseViewNodes(&view);
            if (self.at(.dedent)) self.i += 1;
        }
        return .{
            .name = name,
            .params = params,
            .view = try self.a.dupe(ast.ViewNode, view.items),
            .span = diag.Span.merge(kw.span, name_tok.span),
        };
    }

    // -- view ---------------------------------------------------------------

    fn parseViewNodes(self: *Parser, out: *std.ArrayList(ast.ViewNode)) Error!void {
        self.skipNewlines();
        if (!self.at(.indent)) {
            const t = self.cur();
            if (t.kind == .eof or t.kind == .dedent) return;
            self.rep.err(t.span, "expected an indented block, found {s}", .{describeTok(t)});
            return;
        }
        self.i += 1;
        while (!self.at(.dedent) and !self.at(.eof)) {
            if (self.tooManyErrors()) break;
            self.skipNewlines();
            if (self.at(.dedent) or self.at(.eof)) break;
            if (self.atName("for")) {
                try out.append(.{ .loop = try self.parseViewLoop() });
            } else if (self.atName("if")) {
                try out.append(.{ .cond = try self.parseViewCond() });
            } else if (self.at(.name)) {
                try out.append(.{ .element = try self.parseElement() });
            } else if (self.at(.string)) {
                // A bare string in a view is a text node.
                const t = self.advance();
                const e = try self.parseStringTok(t);
                try out.append(.{ .element = .{
                    .tag = "text",
                    .args = try self.a.dupe(ast.Arg, &.{.{ .value = e, .span = t.span }}),
                    .children = &.{},
                    .span = t.span,
                } });
                self.finishLine();
            } else {
                const t = self.cur();
                self.rep.errHint(t.span, "view blocks contain element calls like text(\"hi\"), for loops, and if blocks", "unexpected {s} in view", .{describeTok(t)});
                self.synchronize();
            }
            self.skipNewlines();
        }
        if (self.at(.dedent)) self.i += 1;
    }

    fn parseElement(self: *Parser) Error!ast.Element {
        const name_tok = self.advance();
        var args = std.ArrayList(ast.Arg).init(self.a);
        defer args.deinit();
        var span = name_tok.span;

        if (self.at(.lparen)) {
            self.i += 1;
            while (!self.at(.rparen) and !self.at(.eof)) {
                if (self.at(.newline) or self.at(.comma)) {
                    self.i += 1;
                    continue;
                }
                try args.append(try self.parseArg());
                if (self.at(.comma)) self.i += 1;
                self.skipNewlines();
            }
            if (self.expect(.rparen)) |rp| span = diag.Span.merge(span, rp.span);
        }

        var children = std.ArrayList(ast.ViewNode).init(self.a);
        defer children.deinit();
        if (self.at(.colon)) {
            self.i += 1;
            try self.parseViewNodes(&children);
        } else {
            self.finishLine();
        }

        return .{
            .tag = name_tok.text,
            .args = try self.a.dupe(ast.Arg, args.items),
            .children = try self.a.dupe(ast.ViewNode, children.items),
            .span = span,
        };
    }

    fn parseArg(self: *Parser) Error!ast.Arg {
        // named argument?
        if (self.at(.name) and self.peek(1).kind == .colon and !isKeyword(self.cur().text)) {
            const nm = self.advance();
            self.i += 1; // ':'
            if (self.at(.lbrace)) {
                const block = try self.parseBraceBlockOrMap();
                if (block.is_block) {
                    return .{ .name = nm.text, .block = block.stmts, .span = nm.span };
                }
                return .{ .name = nm.text, .value = block.expr.?, .span = nm.span };
            }
            const v = try self.parseExprFull();
            return .{ .name = nm.text, .value = v, .span = diag.Span.merge(nm.span, v.spanOf()) };
        }
        const v = try self.parseExprFull();
        return .{ .value = v, .span = v.spanOf() };
    }

    const BraceValue = struct {
        is_block: bool = false,
        stmts: []const ast.Stmt = &.{},
        expr: ?*ast.Expr = null,
    };

    /// `{ ... }` after `name:` — either an inline handler block or a map literal.
    /// The lexer already classified the brace; we trust that classification.
    fn parseBraceBlockOrMap(self: *Parser) Error!BraceValue {
        if (!self.at(.lbrace)) return .{ .expr = try self.parseExprFull() };
        if (self.cur().block_brace) {
            self.i += 1;
            const stmts = try self.parseInlineBlock();
            return .{ .is_block = true, .stmts = stmts };
        }
        return .{ .expr = try self.parseExprFull() };
    }

    /// Statements inside `{ ... }`, separated by newlines or `;`.
    fn parseInlineBlock(self: *Parser) Error![]const ast.Stmt {
        var list = std.ArrayList(ast.Stmt).init(self.a);
        defer list.deinit();
        while (!self.at(.rbrace) and !self.at(.eof)) {
            if (self.tooManyErrors()) break;
            if (self.at(.newline) or self.at(.semicolon)) {
                self.i += 1;
                continue;
            }
            try list.append(try self.parseStmt());
            while (self.at(.newline) or self.at(.semicolon)) self.i += 1;
        }
        _ = self.expect(.rbrace);
        return try self.mkStmts(list);
    }

    fn parseViewLoop(self: *Parser) Error!ast.ViewLoop {
        const kw = self.advance(); // 'for'
        const first = self.cur();
        if (first.kind != .name) {
            self.rep.err(first.span, "expected a loop variable after 'for'", .{});
            self.synchronize();
            return .{ .index_name = null, .item_name = "_", .iter = try self.mkExpr(.{ .nil_lit = first.span }), .key = null, .children = &.{}, .span = kw.span };
        }
        self.i += 1;
        var index_name: ?[]const u8 = null;
        var item_name: []const u8 = first.text;
        if (self.at(.comma)) {
            self.i += 1;
            const second = self.cur();
            if (second.kind == .name) {
                index_name = first.text;
                item_name = second.text;
                self.i += 1;
            }
        }
        _ = self.expectName("in");
        const iter = try self.parseExprFull();
        var key: ?*ast.Expr = null;
        if (self.atName("key")) {
            self.i += 1;
            key = try self.parseExprFull();
        }
        _ = self.expect(.colon);
        var children = std.ArrayList(ast.ViewNode).init(self.a);
        defer children.deinit();
        try self.parseViewNodes(&children);
        return .{
            .index_name = index_name,
            .item_name = item_name,
            .iter = iter,
            .key = key,
            .children = try self.a.dupe(ast.ViewNode, children.items),
            .span = diag.Span.merge(kw.span, iter.spanOf()),
        };
    }

    fn parseViewCond(self: *Parser) Error!ast.ViewCond {
        const kw = self.advance(); // 'if'
        var branches = std.ArrayList(ast.ViewBranch).init(self.a);
        defer branches.deinit();

        const cond = try self.parseExprFull();
        _ = self.expect(.colon);
        var kids = std.ArrayList(ast.ViewNode).init(self.a);
        defer kids.deinit();
        try self.parseViewNodes(&kids);
        try branches.append(.{ .cond = cond, .children = try self.a.dupe(ast.ViewNode, kids.items) });
        kids.clearRetainingCapacity();

        while (true) {
            self.skipNewlines();
            if (self.atName("elif")) {
                self.i += 1;
                const c2 = try self.parseExprFull();
                _ = self.expect(.colon);
                try self.parseViewNodes(&kids);
                try branches.append(.{ .cond = c2, .children = try self.a.dupe(ast.ViewNode, kids.items) });
                kids.clearRetainingCapacity();
            } else if (self.atName("else")) {
                self.i += 1;
                _ = self.expect(.colon);
                try self.parseViewNodes(&kids);
                try branches.append(.{ .cond = null, .children = try self.a.dupe(ast.ViewNode, kids.items) });
                kids.clearRetainingCapacity();
                break;
            } else break;
        }

        return .{ .branches = try self.a.dupe(ast.ViewBranch, branches.items), .span = kw.span };
    }

    // -- statements ---------------------------------------------------------

    /// Parse the body of an `if:`/`for:`/`after:` header.
    ///
    /// At statement level the lexer emits INDENT/DEDENT and `parseStmtBlock`
    /// uses them. Inside a `{ ... }` handler block the lexer suppresses
    /// indentation (newlines are just separators), so a nested header has no
    /// INDENT to consume. In that case the body is recovered from *columns*:
    /// every following statement that starts on a later line and is indented
    /// deeper than the header belongs to the body. `header` is the span of the
    /// keyword that opened it.
    fn parseBodyBlock(self: *Parser, header: diag.Span) Error![]const ast.Stmt {
        if (!self.at(.indent)) {
            const save = self.i;
            self.skipNewlines();
            const t = self.cur();
            const deeper = t.span.line > header.line and
                t.span.col > header.col and
                t.kind != .rbrace and t.kind != .eof and
                t.kind != .indent and t.kind != .dedent and
                t.kind != .newline and t.kind != .semicolon;
            if (deeper) {
                var list = std.ArrayList(ast.Stmt).init(self.a);
                defer list.deinit();
                var last_line = t.span.line;
                while (true) {
                    if (self.tooManyErrors()) break;
                    const c = self.cur();
                    if (c.kind == .rbrace or c.kind == .eof or c.kind == .dedent) break;
                    if (c.span.col <= header.col) break;
                    try list.append(try self.parseStmt());
                    self.finishLine();
                    self.skipNewlines();
                    const n = self.cur();
                    if (n.kind == .rbrace or n.kind == .eof or n.kind == .dedent) break;
                    if (n.span.col <= header.col) break;
                    if (n.span.line <= last_line) break; // no progress: bail out
                    last_line = n.span.line;
                }
                if (list.items.len > 0) return try self.mkStmts(list);
            }
            self.i = save;
        }
        return try self.parseStmtBlock();
    }

    fn parseStmtBlock(self: *Parser) Error![]const ast.Stmt {
        self.skipNewlines();
        if (!self.at(.indent)) {
            // Allow a single-line body: `if done: count += 1`
            if (!self.at(.newline) and !self.at(.dedent) and !self.at(.eof) and !self.at(.rbrace)) {
                var one = std.ArrayList(ast.Stmt).init(self.a);
                defer one.deinit();
                try one.append(try self.parseStmt());
                self.finishLine();
                return try self.mkStmts(one);
            }
            const t = self.cur();
            self.rep.err(t.span, "expected an indented block, found {s}", .{describeTok(t)});
            return &.{};
        }
        self.i += 1;
        var list = std.ArrayList(ast.Stmt).init(self.a);
        defer list.deinit();
        while (!self.at(.dedent) and !self.at(.eof)) {
            if (self.tooManyErrors()) break;
            self.skipNewlines();
            if (self.at(.dedent) or self.at(.eof)) break;
            try list.append(try self.parseStmt());
            self.finishLine();
            self.skipNewlines();
        }
        if (self.at(.dedent)) self.i += 1;
        return try self.mkStmts(list);
    }

    fn finishLine(self: *Parser) void {
        if (self.at(.semicolon)) self.i += 1;
        if (self.at(.newline)) self.i += 1;
    }

    fn parseStmt(self: *Parser) Error!ast.Stmt {
        const t = self.cur();
        if (t.kind == .name) {
            if (std.mem.eql(u8, t.text, "if")) return try self.parseIfStmt();
            if (std.mem.eql(u8, t.text, "for")) return try self.parseForStmt();
            if (std.mem.eql(u8, t.text, "after")) return try self.parseAfterStmt();
            if (std.mem.eql(u8, t.text, "return")) {
                self.i += 1;
                var v: ?*ast.Expr = null;
                if (!self.at(.newline) and !self.at(.dedent) and !self.at(.eof) and !self.at(.rbrace)) {
                    v = try self.parseExprFull();
                }
                return .{ .return_ = .{ .value = v, .span = diag.Span.merge(t.span, if (v) |x| x.spanOf() else t.span) } };
            }
            if (std.mem.eql(u8, t.text, "break")) {
                self.i += 1;
                return .{ .break_ = t.span };
            }
            if (std.mem.eql(u8, t.text, "continue")) {
                self.i += 1;
                return .{ .continue_ = t.span };
            }
            if (std.mem.eql(u8, t.text, "pass")) {
                self.i += 1;
                return .{ .pass = t.span };
            }
        }

        // assignment / augmented assignment / expression statement
        const lhs = try self.parseExprFull();
        const op: ?ast.AssignOp = blk: {
            switch (self.cur().kind) {
                .assign => break :blk .set,
                .plus_assign => break :blk .add,
                .minus_assign => break :blk .sub,
                .star_assign => break :blk .mul,
                .slash_assign => break :blk .div,
                else => break :blk null,
            }
        };
        if (op) |o| {
            const op_tok = self.advance();
            if (o != .set and !isAssignable(lhs)) {
                self.rep.err(lhs.spanOf(), "invalid target for '{s}'", .{opName(o)});
            }
            const rhs = try self.parseExprFull();
            return .{ .assign = .{
                .target = lhs,
                .op = o,
                .value = rhs,
                .span = diag.Span.merge(lhs.spanOf(), diag.Span.merge(op_tok.span, rhs.spanOf())),
            } };
        }
        if (!isExprStmtOk(lhs)) {
            self.rep.errHint(lhs.spanOf(), "statements are assignments, calls, if/for blocks, or 'return'", "expression statement has no effect", .{});
        }
        return .{ .expr = .{ .e = lhs, .span = lhs.spanOf() } };
    }

    fn parseIfStmt(self: *Parser) Error!ast.Stmt {
        const kw = self.advance(); // 'if'
        var branches = std.ArrayList(ast.IfBranch).init(self.a);
        defer branches.deinit();
        const cond = try self.parseExprFull();
        _ = self.expect(.colon);
        const body = try self.parseBodyBlock(kw.span);
        try branches.append(.{ .cond = cond, .body = body });

        while (true) {
            self.skipNewlines();
            if (self.atName("elif")) {
                const ekw = self.advance();
                const c2 = try self.parseExprFull();
                _ = self.expect(.colon);
                const b2 = try self.parseBodyBlock(ekw.span);
                try branches.append(.{ .cond = c2, .body = b2 });
            } else if (self.atName("else")) {
                const ekw = self.advance();
                _ = self.expect(.colon);
                const b2 = try self.parseBodyBlock(ekw.span);
                try branches.append(.{ .cond = null, .body = b2 });
                break;
            } else break;
        }
        return .{ .if_ = .{
            .branches = try self.a.dupe(ast.IfBranch, branches.items),
            .span = kw.span,
        } };
    }

    fn parseForStmt(self: *Parser) Error!ast.Stmt {
        const kw = self.advance(); // 'for'
        const first = self.cur();
        if (first.kind != .name) {
            self.rep.err(first.span, "expected a loop variable after 'for'", .{});
            self.synchronize();
            return .{ .pass = kw.span };
        }
        self.i += 1;
        var index_name: ?[]const u8 = null;
        var item_name: []const u8 = first.text;
        if (self.at(.comma)) {
            self.i += 1;
            const second = self.cur();
            if (second.kind == .name) {
                index_name = first.text;
                item_name = second.text;
                self.i += 1;
            }
        }
        _ = self.expectName("in");
        const iter = try self.parseExprFull();
        _ = self.expect(.colon);
        const body = try self.parseBodyBlock(kw.span);
        return .{ .for_ = .{
            .index_name = index_name,
            .item_name = item_name,
            .iter = iter,
            .body = body,
            .span = diag.Span.merge(kw.span, iter.spanOf()),
        } };
    }

    fn parseAfterStmt(self: *Parser) Error!ast.Stmt {
        const kw = self.advance(); // 'after'
        const delay = try self.parseExprFull();
        _ = self.expect(.colon);
        const body = try self.parseBodyBlock(kw.span);
        return .{ .after = .{ .delay_ms = delay, .body = body, .span = diag.Span.merge(kw.span, delay.spanOf()) } };
    }

    // -- expressions --------------------------------------------------------

    pub fn parseExprFull(self: *Parser) Error!*ast.Expr {
        const e = try self.parseExprPrec(1);
        // ternary: `<a> if <cond> else <b>`
        if (self.atName("if")) {
            _ = self.advance();
            const cond = try self.parseExprPrec(1);
            _ = self.expectName("else");
            const els = try self.parseExprFull();
            return try self.mkExpr(.{ .cond = .{
                .cond = cond,
                .then = e,
                .els = els,
                .span = diag.Span.merge(e.spanOf(), els.spanOf()),
            } });
        }
        return e;
    }

    const BinInfo = struct { op: ast.BinOp, prec: u8, toks: u8, right: bool = false };

    fn binAt(self: *const Parser) ?BinInfo {
        const t = self.cur();
        switch (t.kind) {
            .eq => return .{ .op = .eq, .prec = 3, .toks = 1 },
            .ne => return .{ .op = .ne, .prec = 3, .toks = 1 },
            .lt => return .{ .op = .lt, .prec = 3, .toks = 1 },
            .le => return .{ .op = .le, .prec = 3, .toks = 1 },
            .gt => return .{ .op = .gt, .prec = 3, .toks = 1 },
            .ge => return .{ .op = .ge, .prec = 3, .toks = 1 },
            .plus => return .{ .op = .add, .prec = 4, .toks = 1 },
            .minus => return .{ .op = .sub, .prec = 4, .toks = 1 },
            .star => return .{ .op = .mul, .prec = 5, .toks = 1 },
            .slash => return .{ .op = .div, .prec = 5, .toks = 1 },
            .dslash => return .{ .op = .floor_div, .prec = 5, .toks = 1 },
            .percent => return .{ .op = .mod, .prec = 5, .toks = 1 },
            .dstar => return .{ .op = .pow, .prec = 6, .toks = 1, .right = true },
            .name => {
                if (std.mem.eql(u8, t.text, "or")) return .{ .op = .or_, .prec = 1, .toks = 1 };
                if (std.mem.eql(u8, t.text, "and")) return .{ .op = .and_, .prec = 2, .toks = 1 };
                if (std.mem.eql(u8, t.text, "in")) return .{ .op = .in_, .prec = 3, .toks = 1 };
                if (std.mem.eql(u8, t.text, "not") and self.peekName(1, "in")) return .{ .op = .not_in, .prec = 3, .toks = 2 };
                return null;
            },
            else => return null,
        }
    }

    fn parseExprPrec(self: *Parser, min_prec: u8) Error!*ast.Expr {
        self.depth += 1;
        defer self.depth -= 1;
        if (self.depth > 96) {
            self.rep.err(self.cur().span, "expression nesting too deep", .{});
            return try self.mkExpr(.{ .nil_lit = self.cur().span });
        }
        var lhs = try self.parseUnary();
        while (self.binAt()) |info| {
            if (info.prec < min_prec) break;
            const op_tok = self.advance();
            if (info.toks == 2) self.i += 1; // the `in` of `not in`
            const next_min: u8 = if (info.right) info.prec else info.prec + 1;
            const rhs = try self.parseExprPrec(next_min);
            lhs = try self.mkExpr(.{ .binary = .{
                .op = info.op,
                .lhs = lhs,
                .rhs = rhs,
                .span = diag.Span.merge(lhs.spanOf(), rhs.spanOf()),
            } });
            _ = op_tok;
        }
        return lhs;
    }

    fn parseUnary(self: *Parser) Error!*ast.Expr {
        const t = self.cur();
        if (t.kind == .minus) {
            self.i += 1;
            const operand = try self.parseUnary();
            return try self.mkExpr(.{ .unary = .{ .op = .neg, .operand = operand, .span = diag.Span.merge(t.span, operand.spanOf()) } });
        }
        if (t.kind == .plus) {
            self.i += 1;
            return try self.parseUnary();
        }
        if (t.kind == .name and std.mem.eql(u8, t.text, "not")) {
            self.i += 1;
            const operand = try self.parseExprPrec(3);
            return try self.mkExpr(.{ .unary = .{ .op = .not_, .operand = operand, .span = diag.Span.merge(t.span, operand.spanOf()) } });
        }
        return try self.parsePostfix();
    }

    fn parsePostfix(self: *Parser) Error!*ast.Expr {
        var e = try self.parsePrimary();
        while (true) {
            if (self.at(.dot)) {
                const dot = self.advance();
                const nm = self.cur();
                if (nm.kind != .name) {
                    self.rep.err(nm.span, "expected a field or method name after '.', found {s}", .{describeTok(nm)});
                    break;
                }
                self.i += 1;
                e = try self.mkExpr(.{ .member = .{ .target = e, .name = nm.text, .span = diag.Span.merge(e.spanOf(), nm.span) } });
                _ = dot;
            } else if (self.at(.lbracket)) {
                const lb = self.advance();
                // slice forms: a[i], a[i:j], a[:j], a[i:]
                var from: ?*ast.Expr = null;
                var to: ?*ast.Expr = null;
                var is_slice = false;
                if (!self.at(.colon)) from = try self.parseExprFull();
                if (self.at(.colon)) {
                    is_slice = true;
                    self.i += 1;
                    if (!self.at(.rbracket)) to = try self.parseExprFull();
                }
                if (self.expect(.rbracket)) |rb| {
                    const span = diag.Span.merge(e.spanOf(), rb.span);
                    if (is_slice) {
                        e = try self.mkExpr(.{ .slice = .{ .target = e, .from = from, .to = to, .span = span } });
                    } else {
                        e = try self.mkExpr(.{ .index = .{ .target = e, .index = from.?, .span = span } });
                    }
                }
                _ = lb;
            } else if (self.at(.lparen)) {
                const lp = self.advance();
                var args = std.ArrayList(ast.CallArg).init(self.a);
                defer args.deinit();
                while (!self.at(.rparen) and !self.at(.eof)) {
                    if (self.at(.newline) or self.at(.comma)) {
                        self.i += 1;
                        continue;
                    }
                    if (self.at(.name) and self.peek(1).kind == .colon and !isKeyword(self.cur().text)) {
                        const nm = self.advance();
                        self.i += 1;
                        const v = try self.parseExprFull();
                        try args.append(.{ .name = nm.text, .value = v, .span = diag.Span.merge(nm.span, v.spanOf()) });
                    } else {
                        const v = try self.parseExprFull();
                        try args.append(.{ .value = v, .span = v.spanOf() });
                    }
                    if (self.at(.comma)) self.i += 1;
                    self.skipNewlines();
                }
                if (self.expect(.rparen)) |rp| {
                    e = try self.mkExpr(.{ .call = .{
                        .callee = e,
                        .args = try self.a.dupe(ast.CallArg, args.items),
                        .span = diag.Span.merge(e.spanOf(), rp.span),
                    } });
                }
                _ = lp;
            } else break;
        }
        return e;
    }

    fn parsePrimary(self: *Parser) Error!*ast.Expr {
        const t = self.cur();
        switch (t.kind) {
            .int => {
                self.i += 1;
                return try self.mkExpr(.{ .int_lit = .{ .v = t.int_val, .span = t.span } });
            },
            .float => {
                self.i += 1;
                return try self.mkExpr(.{ .float_lit = .{ .v = t.float_val, .span = t.span } });
            },
            .string => {
                self.i += 1;
                return try self.parseStringTok(t);
            },
            .lbracket => {
                self.i += 1;
                var items = std.ArrayList(*ast.Expr).init(self.a);
                defer items.deinit();
                while (!self.at(.rbracket) and !self.at(.eof)) {
                    if (self.at(.comma) or self.at(.newline)) {
                        self.i += 1;
                        continue;
                    }
                    try items.append(try self.parseExprFull());
                    if (self.at(.comma)) self.i += 1;
                    self.skipNewlines();
                }
                const rb = self.expect(.rbracket) orelse Token{ .kind = .rbracket, .span = t.span };
                return try self.mkExpr(.{ .list_lit = .{
                    .items = try self.a.dupe(*ast.Expr, items.items),
                    .span = diag.Span.merge(t.span, rb.span),
                } });
            },
            .lbrace => {
                // map literal in expression position
                return try self.parseMapLiteral();
            },
            .lparen => {
                self.i += 1;
                self.skipNewlines();
                if (self.at(.rparen)) {
                    const rb = self.advance();
                    return try self.mkExpr(.{ .nil_lit = diag.Span.merge(t.span, rb.span) });
                }
                const inner = try self.parseExprFull();
                self.skipNewlines();
                _ = self.expect(.rparen);
                return inner;
            },
            .name => {
                if (std.mem.eql(u8, t.text, "true") or std.mem.eql(u8, t.text, "True")) {
                    self.i += 1;
                    return try self.mkExpr(.{ .bool_lit = .{ .v = true, .span = t.span } });
                }
                if (std.mem.eql(u8, t.text, "false") or std.mem.eql(u8, t.text, "False")) {
                    self.i += 1;
                    return try self.mkExpr(.{ .bool_lit = .{ .v = false, .span = t.span } });
                }
                // `nil` is the canonical spelling; `null`/`none` are accepted too.
                if (std.mem.eql(u8, t.text, "nil") or std.mem.eql(u8, t.text, "Nil") or
                    std.mem.eql(u8, t.text, "null") or std.mem.eql(u8, t.text, "none") or
                    std.mem.eql(u8, t.text, "None"))
                {
                    self.i += 1;
                    return try self.mkExpr(.{ .nil_lit = t.span });
                }
                self.i += 1;
                return try self.mkExpr(.{ .ident = .{ .name = t.text, .span = t.span } });
            },
            else => {
                self.rep.err(t.span, "expected an expression, found {s}", .{describeTok(t)});
                self.i += 1;
                return try self.mkExpr(.{ .nil_lit = t.span });
            },
        }
    }

    fn parseMapLiteral(self: *Parser) Error!*ast.Expr {
        const t = self.advance(); // '{'
        var entries = std.ArrayList(ast.MapEntryExpr).init(self.a);
        defer entries.deinit();
        while (!self.at(.rbrace) and !self.at(.eof)) {
            if (self.at(.comma) or self.at(.newline)) {
                self.i += 1;
                continue;
            }
            var key: *ast.Expr = undefined;
            const kt = self.cur();
            if (kt.kind == .name and self.peek(1).kind == .colon) {
                // bare-word key: `{primary: "#fff"}`
                self.i += 1;
                key = try self.mkExpr(.{ .str_lit = .{
                    .parts = try self.a.dupe(ast.StrPart, &.{.{ .lit = kt.text }}),
                    .span = kt.span,
                } });
            } else if (kt.kind == .string) {
                self.i += 1;
                key = try self.parseStringTok(kt);
            } else {
                key = try self.parseExprFull();
            }
            if (self.expect(.colon) == null) {
                self.synchronize();
                break;
            }
            const v = try self.parseExprFull();
            try entries.append(.{ .key = key, .value = v, .span = diag.Span.merge(key.spanOf(), v.spanOf()) });
            if (self.at(.comma)) self.i += 1;
            self.skipNewlines();
        }
        const rb = self.expect(.rbrace) orelse Token{ .kind = .rbrace, .span = t.span };
        return try self.mkExpr(.{ .map_lit = .{
            .entries = try self.a.dupe(ast.MapEntryExpr, entries.items),
            .span = diag.Span.merge(t.span, rb.span),
        } });
    }

    /// Build a string literal, splitting `{expr}` interpolations into parts.
    fn parseStringTok(self: *Parser, t: Token) Error!*ast.Expr {
        // The lexer owns `t.text` and frees it on deinit, so copy into the arena.
        const content = try self.a.dupe(u8, t.text);
        const base = t.span.start + 1; // skip the opening quote
        var parts = std.ArrayList(ast.StrPart).init(self.a);
        defer parts.deinit();

        var lit_start: usize = 0;
        var i: usize = 0;
        var plain = true;
        while (i < content.len) {
            // `\{` / `\}` are literal braces. `{{` / `}}` mean the same thing;
            // both forms are accepted because both are easy to type.
            if (content[i] == '\\' and i + 1 < content.len and
                (content[i + 1] == '{' or content[i + 1] == '}'))
            {
                if (i > lit_start) try parts.append(.{ .lit = content[lit_start..i] });
                try parts.append(.{ .lit = content[i + 1 .. i + 2] });
                i += 2;
                lit_start = i;
                plain = false;
                continue;
            }
            if (content[i] == '{') {
                if (i + 1 < content.len and content[i + 1] == '{') {
                    try parts.append(.{ .lit = "{" });
                    // merge with the preceding literal if possible
                    lit_start = i + 2;
                    i += 2;
                    plain = false;
                    continue;
                }
                const close = findMatchingBrace(content, i) orelse {
                    self.rep.err(t.span, "unterminated interpolation: missing '}}' in string", .{});
                    break;
                };
                if (i > lit_start) try parts.append(.{ .lit = content[lit_start..i] });
                const inner = content[i + 1 .. close];
                const inner_off: u32 = base + @as(u32, @intCast(i + 1));
                const e = try self.parseInterpolation(inner, inner_off, t.span);
                try parts.append(.{ .expr = e });
                i = close + 1;
                lit_start = i;
                plain = false;
                continue;
            }
            if (content[i] == '}' and i + 1 < content.len and content[i + 1] == '}') {
                if (i > lit_start) try parts.append(.{ .lit = content[lit_start..i] });
                try parts.append(.{ .lit = "}" });
                i += 2;
                lit_start = i;
                plain = false;
                continue;
            }
            i += 1;
        }
        if (lit_start < content.len) try parts.append(.{ .lit = content[lit_start..] });

        // Merge adjacent literal parts into one slice where possible.
        if (plain and parts.items.len == 1 and parts.items[0] == .lit) {
            return try self.mkExpr(.{ .str_lit = .{
                .parts = try self.a.dupe(ast.StrPart, parts.items),
                .span = t.span,
            } });
        }
        if (parts.items.len == 0) {
            try parts.append(.{ .lit = "" });
        }
        return try self.mkExpr(.{ .str_lit = .{
            .parts = try self.a.dupe(ast.StrPart, parts.items),
            .span = t.span,
        } });
    }

    fn parseInterpolation(self: *Parser, inner: []const u8, base: u32, outer_span: diag.Span) Error!*ast.Expr {
        const text = try self.a.dupe(u8, inner);
        var sub_src = try diag.Source.init(self.a, self.src.path, text);
        // Keep the arena alive but avoid double-free of the line index.
        sub_src.owns_lines = true;

        var lx = lexer.Lexer.init(self.a, &sub_src, self.rep);
        defer lx.deinit();
        const toks = try lx.run();
        if (self.rep.hasErrors() and toks.len == 1) {
            return try self.mkExpr(.{ .nil_lit = outer_span });
        }
        // Shift spans into the parent file's coordinate space.
        var shifted = std.ArrayList(Token).init(self.a);
        defer shifted.deinit();
        for (toks) |tk| {
            var nt = tk;
            nt.span.start += base;
            nt.span.end += base;
            try shifted.append(nt);
        }
        const stoks = try shifted.toOwnedSlice();
        var sub = Parser.init(self.parent, self.a, stoks, self.src, self.rep);
        const e = try sub.parseExprFull();
        sub.skipNewlines();
        if (!sub.at(.eof)) {
            self.rep.err(diag.Span{ .start = base, .end = base + @as(u32, @intCast(text.len)) }, "invalid expression inside '{{...}}'", .{});
        }
        return e;
    }
};

fn findMatchingBrace(s: []const u8, open: usize) ?usize {
    var depth: usize = 0;
    var i = open;
    while (i < s.len) : (i += 1) {
        const c = s[i];
        if (c == '"' or c == '\'') {
            const q = c;
            i += 1;
            while (i < s.len and s[i] != q) {
                if (s[i] == '\\') i += 1;
                i += 1;
            }
            continue;
        }
        if (c == '{') depth += 1;
        if (c == '}') {
            depth -= 1;
            if (depth == 0) return i;
        }
    }
    return null;
}

fn isAssignable(e: *const ast.Expr) bool {
    return switch (e.*) {
        .ident, .index, .member => true,
        else => false,
    };
}

fn isExprStmtOk(e: *const ast.Expr) bool {
    return switch (e.*) {
        .call => true,
        else => false,
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

fn isSectionName(s: []const u8) bool {
    const names = [_][]const u8{ "state", "computed", "theme", "styles", "handlers", "effects", "view" };
    for (names) |n| if (std.mem.eql(u8, s, n)) return true;
    return false;
}

fn isKeyword(s: []const u8) bool {
    const kws = [_][]const u8{ "if", "else", "elif", "for", "in", "and", "or", "not", "true", "false", "nil", "null", "none", "return", "after", "key", "while", "break", "continue", "pass", "is" };
    for (kws) |k| if (std.mem.eql(u8, s, k)) return true;
    return false;
}

fn describeTok(t: Token) []const u8 {
    return switch (t.kind) {
        .name, .string => t.text,
        .int, .float => t.text,
        .eof => "end of file",
        .newline => "end of line",
        else => t.kind.label(),
    };
}

/// Parse a whole file. `src` and `rep` are owned by the caller and stay valid
/// for diagnostic rendering. Returns null when errors were reported.
pub fn parse(parent: std.mem.Allocator, src: *diag.Source, rep: *diag.Reporter) Error!?Result {
    var arena_box = try parent.create(std.heap.ArenaAllocator);
    arena_box.* = std.heap.ArenaAllocator.init(parent);

    const result = parseWith(parent, arena_box, src, rep) catch |e| {
        arena_box.deinit();
        parent.destroy(arena_box);
        return e;
    };
    if (result == null) {
        // Nothing may reference the arena yet, so give it back. The lexer's
        // defer must run first, which is why cleanup lives out here.
        arena_box.deinit();
        parent.destroy(arena_box);
    }
    return result;
}

fn parseWith(
    parent: std.mem.Allocator,
    arena_box: *std.heap.ArenaAllocator,
    src: *diag.Source,
    rep: *diag.Reporter,
) Error!?Result {
    const arena = arena_box.allocator();

    var lx = lexer.Lexer.init(arena, src, rep);
    defer lx.deinit();
    const toks = try lx.run();
    if (rep.hasErrors()) return null;

    var p = Parser.init(parent, arena, toks, src, rep);
    const program = try p.parseProgram();
    if (rep.hasErrors()) return null;
    return Result{ .arena = arena_box, .parent = parent, .program = program };
}
