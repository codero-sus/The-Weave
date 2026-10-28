//! Minimal, allocation-light JSON writer for the wire protocol.
//!
//! Hand-rolled rather than using `std.json.stringify` because we serialise the
//! same shapes millions of times per session and want exact control over key
//! order, number formatting and escaping.

const std = @import("std");
const val = @import("value.zig");

pub const Writer = struct {
    list: std.ArrayList(u8),

    pub fn init(a: std.mem.Allocator) Writer {
        return .{ .list = std.ArrayList(u8).init(a) };
    }

    pub fn deinit(self: *Writer) void {
        self.list.deinit();
    }

    pub fn toOwnedSlice(self: *Writer) ![]u8 {
        return self.list.toOwnedSlice();
    }

    pub fn raw(self: *Writer, s: []const u8) !void {
        try self.list.appendSlice(s);
    }

    pub fn beginObj(self: *Writer) !void {
        try self.list.append('{');
    }
    pub fn endObj(self: *Writer) !void {
        try self.list.append('}');
    }
    pub fn beginArr(self: *Writer) !void {
        try self.list.append('[');
    }
    pub fn endArr(self: *Writer) !void {
        try self.list.append(']');
    }

    pub fn key(self: *Writer, k: []const u8) !void {
        try self.str(k);
        try self.list.append(':');
    }

    pub fn sep(self: *Writer) !void {
        try self.list.append(',');
    }

    pub fn nullLit(self: *Writer) !void {
        try self.list.appendSlice("null");
    }

    pub fn boolLit(self: *Writer, b: bool) !void {
        try self.list.appendSlice(if (b) "true" else "false");
    }

    pub fn int(self: *Writer, i: i64) !void {
        try self.list.writer().print("{d}", .{i});
    }

    pub fn uint(self: *Writer, i: u64) !void {
        try self.list.writer().print("{d}", .{i});
    }

    pub fn float(self: *Writer, f: f64) !void {
        if (std.math.isNan(f) or std.math.isInf(f)) {
            try self.list.appendSlice("null");
            return;
        }
        // Emit integers without a trailing ".0" so the client sees clean numbers.
        if (f == @trunc(f) and @abs(f) < 1e15) {
            try self.list.writer().print("{d}", .{@as(i64, @intFromFloat(f))});
        } else {
            try self.list.writer().print("{d}", .{f});
        }
    }

    pub fn str(self: *Writer, s: []const u8) !void {
        try self.list.append('"');
        for (s) |c| {
            switch (c) {
                '"' => try self.list.appendSlice("\\\""),
                '\\' => try self.list.appendSlice("\\\\"),
                '\n' => try self.list.appendSlice("\\n"),
                '\r' => try self.list.appendSlice("\\r"),
                '\t' => try self.list.appendSlice("\\t"),
                0x08 => try self.list.appendSlice("\\b"),
                0x0c => try self.list.appendSlice("\\f"),
                else => {
                    if (c < 0x20) {
                        try self.list.writer().print("\\u{x:0>4}", .{c});
                    } else {
                        try self.list.append(c);
                    }
                },
            }
        }
        try self.list.append('"');
    }

    /// Serialise a runtime value.
    pub fn value(self: *Writer, v: val.Value) !void {
        switch (v) {
            .nil => try self.nullLit(),
            .boolean => |b| try self.boolLit(b),
            .int => |i| try self.int(i),
            .float => |f| try self.float(f),
            .str => |s| try self.str(s.bytes),
            .list => |l| {
                try self.beginArr();
                for (l.items.items, 0..) |it, i| {
                    if (i > 0) try self.sep();
                    try self.value(it);
                }
                try self.endArr();
            },
            .map => |m| {
                try self.beginObj();
                for (m.entries.items, 0..) |e, i| {
                    if (i > 0) try self.sep();
                    try self.key(e.key);
                    try self.value(e.value);
                }
                try self.endObj();
            },
            .func => try self.nullLit(),
        }
    }
};

/// Convenience: serialise a value to an owned JSON string.
pub fn stringify(a: std.mem.Allocator, v: val.Value) ![]u8 {
    var w = Writer.init(a);
    defer w.deinit();
    try w.value(v);
    return try w.toOwnedSlice();
}
