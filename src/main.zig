//! `weave` entry point.
//!
//! The runtime owns one process-wide general purpose allocator (see value.zig);
//! every thread shares it, while all *values* stay confined to the session that
//! created them.

const std = @import("std");
const value = @import("value.zig");
const cli = @import("cli.zig");

pub fn main() u8 {
    value.initRuntime();

    const args = std.process.argsAlloc(value.alloc) catch {
        std.io.getStdErr().writer().print("weave: out of memory reading arguments\n", .{}) catch {};
        return 2;
    };

    // Freed before the allocator is torn down — a `defer` here would run after
    // `deinitRuntime` and free into a dead GPA.
    const code = cli.run(value.alloc, args[1..]) catch |e| {
        std.process.argsFree(value.alloc, args);
        switch (e) {
            error.BadUsage => return 2,
            error.OutOfMemory => {
                std.io.getStdErr().writer().print("weave: out of memory\n", .{}) catch {};
                return 2;
            },
            else => {
                std.io.getStdErr().writer().print("weave: {s}\n", .{@errorName(e)}) catch {};
                return 1;
            },
        }
    };
    std.process.argsFree(value.alloc, args);

    if (!value.deinitRuntime()) {
        std.io.getStdErr().writer().print("weave: note: some memory was still allocated at exit\n", .{}) catch {};
    }
    return code;
}
