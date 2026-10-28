//! `zig build wasm` helper: copies the freshly compiled in-page engine to a
//! fixed path in the source tree.
//!
//! `@embedFile` needs a location that exists before the executable compiles and
//! that does not move with `--prefix`, so `assets/weave-core.wasm` is a checked
//! in build product. CI regenerates it and fails if the committed copy is stale.

const std = @import("std");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const a = gpa.allocator();

    var args = std.process.args();
    _ = args.skip();
    const src = args.next() orelse return usage();
    const dst = args.next() orelse return usage();

    const bytes = try std.fs.cwd().readFileAlloc(a, src, 256 * 1024 * 1024);
    defer a.free(bytes);
    try std.fs.cwd().writeFile(.{ .sub_path = dst, .data = bytes });

    std.io.getStdOut().writer().print("wrote {s} ({d} bytes)\n", .{ dst, bytes.len }) catch {};
}

fn usage() error{Usage} {
    std.io.getStdErr().writer().print("usage: copyfile <src> <dst>\n", .{}) catch {};
    return error.Usage;
}
