//! Weave lexer.
//!
//! Weave is indentation-sensitive, so the lexer turns layout into explicit
//! INDENT/DEDENT tokens (the classic Python approach). Two extra rules make the
//! declarative UI syntax work:
//!
//!   * Inside `(`, `[` or a *map* `{`, newlines are insignificant, so an element
//!     call can span lines.
//!   * Inside a *handler* `{`, newlines separate statements but do not create
//!     indentation levels — `on_enter: { ... }` stays inline.
//!
//! Whether `{` opens a map literal or a handler block is decided by a two-token
//! lookahead (`name:` / `"str":` => map, anything else => block).

const std = @import("std");
const diag = @import("diag.zig");

pub const Kind = enum {
    eof,
    newline,
    indent,
    dedent,
    name,
    int,
    float,
    string,
    lparen,
    rparen,
    lbracket,
    rbracket,
    lbrace,
    rbrace,
    colon,
    comma,
    dot,
    semicolon,
    assign,
    plus_assign,
    minus_assign,
    star_assign,
    slash_assign,
    plus,
    minus,
    star,
    slash,
    dslash,
    percent,
    dstar,
    eq,
    ne,
    lt,
    le,
    gt,
    ge,

    pub fn label(self: Kind) []const u8 {
        return switch (self) {
            .eof => "end of file",
            .newline => "end of line",
            .indent => "indent",
            .dedent => "dedent",
            .name => "identifier",
            .int => "integer",
            .float => "number",
            .string => "string",
            .lparen => "'('",
            .rparen => "')'",
            .lbracket => "'['",
            .rbracket => "']'",
            .lbrace => "'{'",
            .rbrace => "'}'",
            .colon => "':'",
            .comma => "','",
            .dot => "'.'",
            .semicolon => "';'",
            .assign => "'='",
            .plus_assign => "'+='",
            .minus_assign => "'-='",
            .star_assign => "'*='",
            .slash_assign => "'/='",
            .plus => "'+'",
            .minus => "'-'",
            .star => "'*'",
            .slash => "'/'",
            .dslash => "'//'",
            .percent => "'%'",
            .dstar => "'**'",
            .eq => "'=='",
            .ne => "'!='",
            .lt => "'<'",
            .le => "'<='",
            .gt => "'>'",
            .ge => "'>='",
        };
    }
};

pub const Token = struct {
    kind: Kind,
    /// Raw source slice for names/operators; decoded content for strings.
    text: []const u8 = "",
    span: diag.Span = .{},
    int_val: i64 = 0,
    float_val: f64 = 0,
    /// True when `{` was classified as a handler block rather than a map literal.
    block_brace: bool = false,

    pub fn is(self: *const Token, k: Kind) bool {
        return self.kind == k;
    }

    pub fn isName(self: *const Token, s: []const u8) bool {
        return self.kind == .name and std.mem.eql(u8, self.text, s);
    }
};

pub const Error = error{
    LexError,
    OutOfMemory,
};

pub const Lexer = struct {
    src: *const diag.Source,
    rep: *diag.Reporter,
    tokens: std.ArrayList(Token),
    indent_stack: std.ArrayList(u32),
    /// Decoded string literal bodies. Freed by `deinit`; the parser copies any
    /// content it keeps into its own arena.
    owned: std.ArrayList([]u8),
    pos: usize = 0,
    line: u32 = 1,
    brackets: std.ArrayList(Bracket),
    bracket_depth: u32 = 0,
    block_depth: u32 = 0,
    at_line_start: bool = true,
    pending_newline: bool = false,
    failed: bool = false,

    pub fn init(a: std.mem.Allocator, src: *const diag.Source, rep: *diag.Reporter) Lexer {
        var l = Lexer{
            .src = src,
            .rep = rep,
            .tokens = std.ArrayList(Token).init(a),
            .indent_stack = std.ArrayList(u32).init(a),
            .brackets = std.ArrayList(Bracket).init(a),
            .owned = std.ArrayList([]u8).init(a),
        };
        l.indent_stack.append(0) catch {};
        return l;
    }

    pub fn deinit(self: *Lexer) void {
        for (self.owned.items) |b| self.tokens.allocator.free(b);
        self.owned.deinit();
        self.tokens.deinit();
        self.indent_stack.deinit();
        self.brackets.deinit();
    }

    fn text(self: *const Lexer) []const u8 {
        return self.src.text;
    }

    fn eof(self: *const Lexer) bool {
        return self.pos >= self.src.text.len;
    }

    fn peekAt(self: *const Lexer, off: usize) u8 {
        const i = self.pos + off;
        return if (i < self.src.text.len) self.src.text[i] else 0;
    }

    fn errAt(self: *Lexer, offset: usize, comptime fmt: []const u8, args: anytype) void {
        const span = self.src.spanOf(@intCast(offset), @intCast(@min(offset + 1, self.src.text.len)));
        self.rep.err(span, fmt, args);
        self.failed = true;
    }

    fn push(self: *Lexer, kind: Kind, start: usize, end: usize) !void {
        try self.tokens.append(.{
            .kind = kind,
            .text = self.src.text[@min(start, self.src.text.len)..@min(end, self.src.text.len)],
            .span = self.src.spanOf(@intCast(start), @intCast(end)),
        });
        if (kind != .newline and kind != .indent and kind != .dedent) self.pending_newline = true;
    }

    fn pushTok(self: *Lexer, t: Token) !void {
        try self.tokens.append(t);
        if (t.kind != .newline and t.kind != .indent and t.kind != .dedent) self.pending_newline = true;
    }

    /// Tokenise the whole source. Returns the token slice (owned by the lexer).
    pub fn run(self: *Lexer) ![]const Token {
        while (!self.eof()) {
            if (self.at_line_start) {
                try self.handleLineStart();
                self.at_line_start = false;
                if (self.failed) break;
                continue;
            }
            const c = self.text()[self.pos];
            switch (c) {
                '\n' => {
                    self.pos += 1;
                    self.line += 1;
                    self.at_line_start = true;
                },
                '\r' => self.pos += 1,
                ' ', '\t' => self.pos += 1,
                '#' => {
                    while (!self.eof() and self.text()[self.pos] != '\n') self.pos += 1;
                },
                '"', '\'' => try self.lexString(),
                else => {
                    if (isDigit(c)) {
                        try self.lexNumber();
                    } else if (isNameStart(c)) {
                        try self.lexName();
                    } else {
                        try self.lexOp();
                    }
                },
            }
            if (self.failed) break;
        }

        // Close any open block braces implicitly at EOF.
        if (self.block_depth > 0) {
            self.rep.err(self.src.spanOf(@intCast(self.pos), @intCast(self.pos)), "unclosed handler block: missing '}}'", .{});
            self.failed = true;
        }
        if (self.bracket_depth > 0) {
            self.rep.err(self.src.spanOf(@intCast(self.pos), @intCast(self.pos)), "unclosed bracket: missing ')', ']' or '}}'", .{});
            self.failed = true;
        }
        if (self.pending_newline) {
            try self.push(.newline, self.pos, self.pos);
            self.pending_newline = false;
        }
        while (self.indent_stack.items.len > 1) {
            _ = self.indent_stack.pop();
            try self.push(.dedent, self.pos, self.pos);
        }
        try self.push(.eof, self.pos, self.pos);
        return self.tokens.items;
    }

    fn handleLineStart(self: *Lexer) !void {
        var indent: u32 = 0;
        var p = self.pos;
        const t = self.text();
        while (p < t.len) {
            if (t[p] == ' ') {
                indent += 1;
                p += 1;
            } else if (t[p] == '\t') {
                indent = (indent + 4) / 4 * 4;
                p += 1;
            } else break;
        }
        // Skip blank and comment-only lines entirely.
        if (p < t.len and (t[p] == '\n' or t[p] == '#')) {
            self.pos = p;
            return;
        }
        if (p >= t.len) {
            self.pos = p;
            return;
        }
        self.pos = p;

        if (self.bracket_depth > 0) return; // continuation line
        if (self.block_depth > 0) {
            if (self.pending_newline) {
                try self.push(.newline, p, p);
                self.pending_newline = false;
            }
            return;
        }

        if (self.pending_newline) {
            try self.push(.newline, p, p);
            self.pending_newline = false;
        }

        const top = self.indent_stack.items[self.indent_stack.items.len - 1];
        if (indent > top) {
            try self.indent_stack.append(indent);
            try self.push(.indent, p, p);
        } else if (indent < top) {
            while (self.indent_stack.items.len > 1 and
                self.indent_stack.items[self.indent_stack.items.len - 1] > indent)
            {
                _ = self.indent_stack.pop();
                try self.push(.dedent, p, p);
            }
            const now_top = self.indent_stack.items[self.indent_stack.items.len - 1];
            if (now_top != indent) {
                self.errAt(p, "unindent does not match any outer indentation level (found {d}, expected {d})", .{ indent, now_top });
            }
        }
    }

    fn lexName(self: *Lexer) !void {
        const start = self.pos;
        while (!self.eof() and isNameChar(self.text()[self.pos])) self.pos += 1;
        try self.push(.name, start, self.pos);
    }

    fn lexNumber(self: *Lexer) !void {
        const start = self.pos;
        const t = self.text();
        var is_float = false;
        if (self.peekAt(0) == '0' and (self.peekAt(1) == 'x' or self.peekAt(1) == 'X')) {
            self.pos += 2;
            while (!self.eof() and (isHex(t[self.pos]) or t[self.pos] == '_')) self.pos += 1;
            const raw = t[start + 2 .. self.pos];
            const v = std.fmt.parseInt(i64, raw, 16) catch {
                self.errAt(start, "invalid hex literal", .{});
                return;
            };
            var tok = Token{ .kind = .int, .text = t[start..self.pos], .span = self.src.spanOf(@intCast(start), @intCast(self.pos)), .int_val = v };
            _ = &tok;
            try self.pushTok(tok);
            return;
        }
        while (!self.eof()) {
            const c = t[self.pos];
            if (isDigit(c) or c == '_') {
                self.pos += 1;
            } else if (c == '.') {
                if (is_float) break;
                // `1.method()` should not swallow the dot.
                if (!isDigit(self.peekAt(1))) break;
                is_float = true;
                self.pos += 1;
            } else if (c == 'e' or c == 'E') {
                if (self.peekAt(1) == '+' or self.peekAt(1) == '-') {
                    is_float = true;
                    self.pos += 2;
                } else if (isDigit(self.peekAt(1))) {
                    is_float = true;
                    self.pos += 1;
                } else break;
            } else break;
        }
        const raw = t[start..self.pos];
        const span = self.src.spanOf(@intCast(start), @intCast(self.pos));
        if (is_float) {
            const v = std.fmt.parseFloat(f64, raw) catch {
                self.errAt(start, "invalid number literal '{s}'", .{raw});
                return;
            };
            try self.pushTok(.{ .kind = .float, .text = raw, .span = span, .float_val = v });
        } else {
            var buf: [64]u8 = undefined;
            var n: usize = 0;
            for (raw) |c| {
                if (c == '_') continue;
                if (n >= buf.len) break;
                buf[n] = c;
                n += 1;
            }
            const v = std.fmt.parseInt(i64, buf[0..n], 10) catch {
                self.errAt(start, "integer literal '{s}' is too large", .{raw});
                return;
            };
            try self.pushTok(.{ .kind = .int, .text = raw, .span = span, .int_val = v });
        }
    }

    fn lexString(self: *Lexer) !void {
        const quote = self.text()[self.pos];
        const start = self.pos;
        self.pos += 1;
        var content = std.ArrayList(u8).init(self.tokens.allocator);
        defer content.deinit();
        var closed = false;
        while (!self.eof()) {
            const c = self.text()[self.pos];
            if (c == '\\' and self.pos + 1 < self.src.text.len) {
                const n = self.text()[self.pos + 1];
                const decoded: ?u8 = switch (n) {
                    'n' => '\n',
                    't' => '\t',
                    'r' => '\r',
                    '\\' => '\\',
                    '"' => '"',
                    '\'' => '\'',
                    '0' => 0,
                    else => null,
                };
                if (decoded) |d| {
                    try content.append(d);
                    self.pos += 2;
                    continue;
                } else {
                    // Unknown escape: keep it verbatim. `\{` and `\}` land here
                    // on purpose — the parser needs the backslash to tell an
                    // escaped brace from the start of an interpolation.
                    try content.appendSlice(self.text()[self.pos .. self.pos + 2]);
                    self.pos += 2;
                    continue;
                }
            }
            if (c == quote) {
                self.pos += 1;
                closed = true;
                break;
            }
            if (c == '\n') break;
            try content.append(c);
            self.pos += 1;
        }
        if (!closed) {
            self.errAt(start, "unterminated string literal", .{});
            return;
        }
        // Store the decoded content in the token arena so it outlives the lexer.
        const owned = try self.tokens.allocator.dupe(u8, content.items);
        try self.owned.append(owned);
        const span = self.src.spanOf(@intCast(start), @intCast(self.pos));
        try self.pushTok(.{ .kind = .string, .text = owned, .span = span });
    }

    /// Decide whether the `{` at `self.pos` starts a handler block or a map literal.
    fn braceIsBlock(self: *const Lexer) bool {
        const t = self.text();
        var p = self.pos + 1;
        // skip whitespace / newlines / comments
        const skip = struct {
            fn f(txt: []const u8, i: *usize) void {
                while (i.* < txt.len) {
                    const c = txt[i.*];
                    if (c == ' ' or c == '\t' or c == '\n' or c == '\r') {
                        i.* += 1;
                    } else if (c == '#') {
                        while (i.* < txt.len and txt[i.*] != '\n') i.* += 1;
                    } else break;
                }
            }
        }.f;
        skip(t, &p);
        if (p >= t.len) return false;
        if (t[p] == '}') return false; // empty map
        // first token must be a name or string, followed by ':'
        var first_end = p;
        if (t[p] == '"' or t[p] == '\'') {
            const q = t[p];
            first_end = p + 1;
            while (first_end < t.len and t[first_end] != q) {
                if (t[first_end] == '\\') first_end += 1;
                first_end += 1;
            }
            first_end += 1;
        } else if (isNameStart(t[p])) {
            while (first_end < t.len and isNameChar(t[first_end])) first_end += 1;
        } else return true;
        skip(t, &first_end);
        if (first_end < t.len and t[first_end] == ':') {
            // `x: y` — a map entry, unless it looks like a typed statement.
            return false;
        }
        return true;
    }

    fn lexOp(self: *Lexer) !void {
        const start = self.pos;
        const t = self.text();
        const c = t[self.pos];
        const n = self.peekAt(1);
        const span2 = self.src.spanOf(@intCast(start), @intCast(start + 2));
        const span1 = self.src.spanOf(@intCast(start), @intCast(start + 1));

        const two: ?Kind = blk: {
            break :blk switch (c) {
                '*' => if (n == '*') Kind.dstar else null,
                '/' => if (n == '/') Kind.dslash else null,
                '=' => if (n == '=') Kind.eq else null,
                '!' => if (n == '=') Kind.ne else null,
                '<' => if (n == '=') Kind.le else null,
                '>' => if (n == '=') Kind.ge else null,
                '+' => if (n == '=') Kind.plus_assign else null,
                '-' => if (n == '=') Kind.minus_assign else null,
                else => null,
            };
        };
        if (two) |k| {
            self.pos += 2;
            try self.push(k, start, self.pos);
            _ = span2;
            return;
        }
        // `*=` and `/=` are checked after the two-char forms above.
        if (c == '*' and n == '=') {
            self.pos += 2;
            try self.push(.star_assign, start, self.pos);
            return;
        }
        if (c == '/' and n == '=') {
            self.pos += 2;
            try self.push(.slash_assign, start, self.pos);
            return;
        }

        const one: ?Kind = switch (c) {
            '+' => Kind.plus,
            '-' => Kind.minus,
            '*' => Kind.star,
            '/' => Kind.slash,
            '%' => Kind.percent,
            '=' => Kind.assign,
            '<' => Kind.lt,
            '>' => Kind.gt,
            '(' => Kind.lparen,
            ')' => Kind.rparen,
            '[' => Kind.lbracket,
            ']' => Kind.rbracket,
            ':' => Kind.colon,
            ',' => Kind.comma,
            '.' => Kind.dot,
            ';' => Kind.semicolon,
            '{' => Kind.lbrace,
            '}' => Kind.rbrace,
            else => null,
        };
        if (one) |k| {
            switch (k) {
                .lparen => try self.openBracket(.paren),
                .lbracket => try self.openBracket(.square),
                .lbrace => {
                    if (self.braceIsBlock()) {
                        try self.openBracket(.block_brace);
                        self.pos += 1;
                        try self.pushTok(.{ .kind = .lbrace, .text = "{", .span = span1, .block_brace = true });
                        return;
                    }
                    try self.openBracket(.map_brace);
                },
                .rparen, .rbracket, .rbrace => {
                    const want: Bracket = switch (k) {
                        .rparen => .paren,
                        .rbracket => .square,
                        else => .map_brace,
                    };
                    if (!self.closeBracket(want, start)) return;
                    if (k == .rbrace and self.brackets.items.len > 0 and
                        self.brackets.items[self.brackets.items.len - 1] == .block_brace)
                    {
                        _ = self.brackets.pop();
                        self.block_depth -= 1;
                    }
                },
                else => {},
            }
            self.pos += 1;
            try self.push(k, start, self.pos);
            return;
        }
        self.errAt(start, "unexpected character '{c}'", .{c});
        self.pos += 1;
    }

    fn openBracket(self: *Lexer, b: Bracket) !void {
        try self.brackets.append(b);
        switch (b) {
            .block_brace => self.block_depth += 1,
            else => self.bracket_depth += 1,
        }
    }

    /// Pop the innermost bracket if it matches `want` (or a `}` closing a block).
    fn closeBracket(self: *Lexer, want: Bracket, offset: usize) bool {
        if (self.brackets.items.len == 0) {
            self.errAt(offset, "unmatched closing bracket", .{});
            return false;
        }
        const top = self.brackets.items[self.brackets.items.len - 1];
        if (top == want) {
            _ = self.brackets.pop();
            switch (top) {
                .block_brace => self.block_depth -= 1,
                else => self.bracket_depth -= 1,
            }
            return true;
        }
        if (want == .map_brace and top == .block_brace) return true; // handled by caller
        self.errAt(offset, "mismatched closing bracket: expected '{s}'", .{closingFor(top)});
        return false;
    }
};

fn closingFor(b: Bracket) []const u8 {
    return switch (b) {
        .paren => "')'",
        .square => "']'",
        .map_brace, .block_brace => "'}'",
    };
}

pub const Bracket = enum { paren, square, map_brace, block_brace };

pub fn isDigit(c: u8) bool {
    return c >= '0' and c <= '9';
}
pub fn isHex(c: u8) bool {
    return isDigit(c) or (c >= 'a' and c <= 'f') or (c >= 'A' and c <= 'F');
}
pub fn isNameStart(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or c == '_';
}
pub fn isNameChar(c: u8) bool {
    return isNameStart(c) or isDigit(c);
}

/// Tokenise a source, returning tokens owned by the returned lexer.
pub fn tokenize(a: std.mem.Allocator, src: *const diag.Source, rep: *diag.Reporter) !Lexer {
    var lx = Lexer.init(a, src, rep);
    errdefer lx.deinit();
    _ = try lx.run();
    return lx;
}
