//! The handful of places the engine touches the operating system.
//!
//! A native build reads the real clock and writes to stderr. The WebAssembly
//! build (`src/wasm.zig`, embedded into `weave build --html` output) has
//! neither: the page sets the clock before each tick and drains a log buffer
//! afterwards. Everything else in the engine is target-agnostic, so the exact
//! same compiler, VM, store and diff run in a browser and on a server.

const std = @import("std");
const builtin = @import("builtin");

/// True when compiled to WebAssembly, where there is no OS to talk to.
pub const is_wasm: bool = builtin.target.cpu.arch == .wasm32;

// -- clock ------------------------------------------------------------------

var wasm_clock_ms: i64 = 0;

/// Milliseconds since the Unix epoch, or since page load in a browser.
pub fn nowMs() i64 {
    if (is_wasm) return wasm_clock_ms;
    return std.time.milliTimestamp();
}

/// Browser-only: the page calls this before every tick with `Date.now()`, which
/// is what drives `after <ms>:` timers when there is no socket poll to lean on.
pub fn setNowMs(ms: i64) void {
    wasm_clock_ms = ms;
}

// -- log --------------------------------------------------------------------

const log_cap = 16 * 1024;
var log_buf: [log_cap]u8 = undefined;
var log_len: usize = 0;
var log_dropped: usize = 0;

/// Append to the drainable buffer, and to stderr as well when there is one.
///
/// The buffer is what a browser page reads (`weave_take_log`) to mirror `log()`
/// into the devtools console. It exists on native builds too, so the engine
/// behaves identically in both and a test can assert on log output without
/// capturing stderr.
pub fn log(msg: []const u8) void {
    const room = log_cap - log_len;
    const n = @min(room, msg.len);
    if (n > 0) @memcpy(log_buf[log_len .. log_len + n], msg[0..n]);
    log_len += n;
    log_dropped += msg.len - n;
    if (!is_wasm) std.io.getStdErr().writeAll(msg) catch {};
}

pub fn logf(comptime fmt: []const u8, args: anytype) void {
    var buf: [2048]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, fmt, args) catch fmt;
    log(msg);
}

/// Drain the log buffer. Called by the page after each dispatch so `log()` in a
/// handler reaches the devtools console.
pub fn takeLog() []const u8 {
    const out = log_buf[0..log_len];
    log_len = 0;
    return out;
}

/// Bytes that did not fit in the log buffer since the last drain.
pub fn droppedLogBytes() usize {
    const n = log_dropped;
    log_dropped = 0;
    return n;
}
