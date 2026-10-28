//! Source files, spans, and human-quality diagnostics.
//!
//! Weave aims to feel like a real language, so error messages matter as much as
//! the parser: every diagnostic carries a span and is rendered with a source
//! snippet plus a caret underline, rustc-style.

const std = @import("std");

pub const Span = struct {
    /// Byte offset (inclusive) into the source text.
    start: u32 = 0,
    /// Byte offset (exclusive) into the source text.
    end: u32 = 0,
    /// 1-based line.
    line: u32 = 1,
    /// 1-based column (in bytes).
    col: u32 = 1,

    pub const zero: Span = .{};

    pub fn merge(a: Span, b: Span) Span {
        if (a.start == 0 and a.end == 0) return b;
        if (b.start == 0 and b.end == 0) return a;
        return .{
            .start = @min(a.start, b.start),
            .end = @max(a.end, b.end),
            .line = a.line,
            .col = a.col,
        };
    }
};

pub const Source = struct {
    path: []const u8,
    text: []const u8,
    line_starts: []const u32,
    owns_lines: bool = false,
    alloc: std.mem.Allocator,

    pub fn init(alloc: std.mem.Allocator, path: []const u8, text: []const u8) !Source {
        var starts = std.ArrayList(u32).init(alloc);
        errdefer starts.deinit();
        try starts.append(0);
        for (text, 0..) |c, i| {
            if (c == '\n') try starts.append(@intCast(i + 1));
        }
        return .{
            .path = path,
            .text = text,
            .line_starts = try starts.toOwnedSlice(),
            .owns_lines = true,
            .alloc = alloc,
        };
    }

    /// Borrow a source without copying the line index (used for synthetic snippets).
    pub fn ephemeral(path: []const u8, text: []const u8) Source {
        var s = Source{ .path = path, .text = text, .line_starts = &.{0}, .alloc = undefined };
        _ = &s;
        return s;
    }

    pub fn deinit(self: *Source) void {
        if (self.owns_lines) self.alloc.free(self.line_starts);
        self.* = undefined;
    }

    pub fn lineCount(self: *const Source) usize {
        return self.line_starts.len;
    }

    /// 1-based line number -> raw line text without the trailing newline.
    pub fn lineText(self: *const Source, line: u32) []const u8 {
        if (line == 0 or line > self.line_starts.len) return "";
        const start = self.line_starts[line - 1];
        const end = if (line < self.line_starts.len) self.line_starts[line] else @as(u32, @intCast(self.text.len));
        var slice = self.text[@min(start, self.text.len)..@min(end, self.text.len)];
        if (slice.len > 0 and slice[slice.len - 1] == '\n') slice = slice[0 .. slice.len - 1];
        if (slice.len > 0 and slice[slice.len - 1] == '\r') slice = slice[0 .. slice.len - 1];
        return slice;
    }

    pub fn lineCol(self: *const Source, offset: u32) struct { line: u32, col: u32 } {
        var line: u32 = 1;
        for (self.line_starts, 0..) |ls, i| {
            if (ls <= offset) {
                line = @intCast(i + 1);
            } else break;
        }
        const ls = self.line_starts[line - 1];
        return .{ .line = line, .col = offset - ls + 1 };
    }

    pub fn spanOf(self: *const Source, start: u32, end: u32) Span {
        const lc = self.lineCol(start);
        return .{ .start = start, .end = end, .line = lc.line, .col = lc.col };
    }
};

pub const Level = enum {
    err,
    warn,
    note,

    pub fn label(self: Level) []const u8 {
        return switch (self) {
            .err => "error",
            .warn => "warning",
            .note => "note",
        };
    }

    pub fn color(self: Level) []const u8 {
        return switch (self) {
            .err => "\x1b[1;31m",
            .warn => "\x1b[1;33m",
            .note => "\x1b[1;36m",
        };
    }
};

pub const Diag = struct {
    level: Level = .err,
    code: []const u8 = "E000",
    message: []const u8,
    span: Span = .{},
    hint: ?[]const u8 = null,
};

pub const Reporter = struct {
    alloc: std.mem.Allocator,
    source: ?*const Source,
    items: std.ArrayList(Diag),

    pub fn init(alloc: std.mem.Allocator, source: ?*const Source) Reporter {
        return .{ .alloc = alloc, .source = source, .items = std.ArrayList(Diag).init(alloc) };
    }

    pub fn deinit(self: *Reporter) void {
        for (self.items.items) |d| self.alloc.free(d.message);
        self.items.deinit();
    }

    fn add(self: *Reporter, level: Level, code: []const u8, span: Span, hint: ?[]const u8, comptime fmt: []const u8, args: anytype) void {
        const msg = std.fmt.allocPrint(self.alloc, fmt, args) catch return;
        self.items.append(.{ .level = level, .code = code, .message = msg, .span = span, .hint = hint }) catch return;
    }

    pub fn err(self: *Reporter, span: Span, comptime fmt: []const u8, args: anytype) void {
        self.add(.err, "E001", span, null, fmt, args);
    }

    pub fn errHint(self: *Reporter, span: Span, hint: []const u8, comptime fmt: []const u8, args: anytype) void {
        self.add(.err, "E001", span, hint, fmt, args);
    }

    pub fn warn(self: *Reporter, span: Span, comptime fmt: []const u8, args: anytype) void {
        self.add(.warn, "W001", span, null, fmt, args);
    }

    pub fn warnHint(self: *Reporter, span: Span, hint: []const u8, comptime fmt: []const u8, args: anytype) void {
        self.add(.warn, "W001", span, hint, fmt, args);
    }

    pub fn note(self: *Reporter, span: Span, comptime fmt: []const u8, args: anytype) void {
        self.add(.note, "N001", span, null, fmt, args);
    }

    pub fn hasErrors(self: *const Reporter) bool {
        for (self.items.items) |d| if (d.level == .err) return true;
        return false;
    }

    pub fn errorCount(self: *const Reporter) usize {
        var n: usize = 0;
        for (self.items.items) |d| if (d.level == .err) {
            n += 1;
        };
        return n;
    }

    pub fn warnCount(self: *const Reporter) usize {
        var n: usize = 0;
        for (self.items.items) |d| if (d.level == .warn) {
            n += 1;
        };
        return n;
    }

    pub fn renderOne(self: *const Reporter, d: Diag, color: bool) ![]u8 {
        var out = std.ArrayList(u8).init(self.alloc);
        errdefer out.deinit();
        const w = out.writer();
        const reset = if (color) "\x1b[0m" else "";
        const bold = if (color) "\x1b[1m" else "";
        const dim = if (color) "\x1b[2m" else "";

        try w.print("{s}{s}[{s}]{s}: {s}{s}{s}\n", .{
            if (color) d.level.color() else "",
            bold,
            d.code,
            reset,
            bold,
            d.message,
            reset,
        });

        const src = self.source orelse return try out.toOwnedSlice();

        // Line/column are always derived from the byte offsets so that spans
        // created against sub-sources (string interpolation) still render right.
        const lc = src.lineCol(d.span.start);
        const line = lc.line;
        const col = lc.col;
        const line_txt = src.lineText(line);
        var gutter_buf: [16]u8 = undefined;
        const gutter = std.fmt.bufPrint(&gutter_buf, "{d}", .{line}) catch "1";

        try w.print("  {s}-->{s} {s}:{d}:{d}{s}\n", .{ dim, reset, src.path, line, col, reset });
        try w.print("  {s}{s} |{s}\n", .{ dim, spaces(gutter.len), reset });
        try w.print("  {s}{d} |{s} {s}\n", .{ dim, line, reset, line_txt });
        try w.print("  {s}{s} |{s} ", .{ dim, spaces(gutter.len), reset });

        // Caret underline across the span (clamped to the current line).
        var caret_col: usize = col;
        if (caret_col == 0) caret_col = 1;
        if (caret_col > line_txt.len + 1) caret_col = line_txt.len + 1;
        var caret_len: usize = 1;
        if (d.span.end > d.span.start) {
            const same_line = d.span.end <= lineEndOffset(src, line);
            if (same_line) caret_len = d.span.end - d.span.start;
        }
        if (caret_len == 0) caret_len = 1;
        if (caret_col + caret_len > line_txt.len + 1) {
            caret_len = (line_txt.len + 1) -| (caret_col - 1);
            if (caret_len == 0) caret_len = 1;
        }
        if (caret_len > 200) caret_len = 200;

        try w.writeByteNTimes(' ', caret_col - 1);
        if (color) try w.print("{s}{s}", .{ d.level.color(), bold });
        try w.writeByteNTimes('^', caret_len);
        try w.print("{s}\n", .{reset});

        if (d.hint) |h| {
            try w.print("  {s}{s} ={s} {s}hint{s}: {s}\n", .{ dim, spaces(gutter.len), reset, bold, reset, h });
        }
        return try out.toOwnedSlice();
    }

    pub fn render(self: *const Reporter, color: bool) ![]u8 {
        var out = std.ArrayList(u8).init(self.alloc);
        errdefer out.deinit();
        for (self.items.items) |d| {
            const one = try self.renderOne(d, color);
            defer self.alloc.free(one);
            try out.appendSlice(one);
            try out.append('\n');
        }
        return try out.toOwnedSlice();
    }
};

fn lineEndOffset(src: *const Source, line: u32) u32 {
    if (line < src.line_starts.len) return src.line_starts[line];
    return @intCast(src.text.len);
}

fn spaces(n: usize) []const u8 {
    const buf = "                                                                ";
    return buf[0..@min(n, buf.len)];
}
