//! Packaging — the three things `weave build` can emit.
//!
//!   `.wvbc`  bytecode only; the smallest artifact, still needs `weave` to run
//!   `.html`  one self-contained page: engine (wasm) + bytecode + browser client,
//!            which runs the real VM in the browser with no server anywhere
//!   `exe`    one standalone executable: this very binary with the app appended
//!
//! The `exe` form is the "just hand someone a file" target. The payload is
//! appended after the engine's own image with a 16-byte trailer, and a packaged
//! binary finds it again at startup by reading its own executable — so the same
//! `weave` that compiled it becomes the app, with no runtime dependency.

const std = @import("std");
const builtin = @import("builtin");

const assets = @import("assets");
const bytecode = @import("bytecode.zig");
const html = @import("html.zig");

pub const Format = enum {
    wvbc,
    html,
    exe,

    pub fn parse(s: []const u8) ?Format {
        if (eq(s, "wvbc") or eq(s, "bytecode") or eq(s, "bc")) return .wvbc;
        if (eq(s, "html") or eq(s, "web") or eq(s, "page")) return .html;
        if (eq(s, "exe") or eq(s, "exec") or eq(s, "executable") or eq(s, "bin") or eq(s, "native")) return .exe;
        return null;
    }

    /// Suffix used when the caller did not pass `-o`.
    pub fn extension(self: Format) []const u8 {
        return switch (self) {
            .wvbc => ".wvbc",
            .html => ".html",
            .exe => if (builtin.os.tag == .windows) ".exe" else "",
        };
    }

    pub fn label(self: Format) []const u8 {
        return switch (self) {
            .wvbc => "bytecode",
            .html => "single-file HTML app",
            .exe => "standalone executable",
        };
    }
};

fn eq(a: []const u8, b: []const u8) bool {
    return std.ascii.eqlIgnoreCase(a, b);
}

pub const Error = error{ OutOfMemory, WriteFailed, EncodeFailed, NoSelfExe };

/// `.wvbc` bytes for a compiled unit.
pub fn encode(alloc: std.mem.Allocator, unit: *const bytecode.CodeUnit) Error![]u8 {
    var enc = bytecode.Encoder.init(alloc);
    defer enc.deinit();
    return enc.encodeUnit(unit) catch |e| switch (e) {
        error.OutOfMemory => error.OutOfMemory,
    };
}

// ------------------------------------------------------------------ .html ---

pub const HtmlResult = struct {
    path: []const u8,
    bytes: usize,
    app_bytes: usize,
    engine_bytes: usize,
};

/// Write a page that runs the app by itself: engine + bytecode + client inline.
pub fn writeHtml(
    alloc: std.mem.Allocator,
    unit: *const bytecode.CodeUnit,
    source_text: ?[]const u8,
    out_path: []const u8,
) Error!HtmlResult {
    const app = try encode(alloc, unit);
    defer alloc.free(app);

    const page = html.render(alloc, .{
        .app_name = unit.app_name,
        .source_text = source_text orelse "",
        .bytecode = app,
        .wasm = assets.core_wasm,
        .client_js = assets.client_js,
        .client_css = assets.client_css,
    }) catch return error.OutOfMemory;
    defer alloc.free(page);

    std.fs.cwd().writeFile(.{ .sub_path = out_path, .data = page }) catch return error.WriteFailed;
    return .{
        .path = out_path,
        .bytes = page.len,
        .app_bytes = app.len,
        .engine_bytes = assets.core_wasm.len,
    };
}

// ------------------------------------------------------------------- .exe ---

/// Trailer appended after the payload: magic + payload length, little endian.
pub const trailer_len: usize = 8 + 8;
pub const magic = "WVEXAPP1";

pub const ExeResult = struct {
    path: []const u8,
    bytes: usize,
    engine_bytes: usize,
    app_bytes: usize,
    /// True when the engine image had to be ad-hoc signed again (macOS).
    resigned: bool = false,
};

/// Copy this binary and append the app, producing a standalone executable.
pub fn writeExe(
    alloc: std.mem.Allocator,
    unit: *const bytecode.CodeUnit,
    out_path: []const u8,
) Error!ExeResult {
    const app = try encode(alloc, unit);
    defer alloc.free(app);

    var self_buf: [std.fs.max_path_bytes]u8 = undefined;
    const self_path = std.fs.selfExePath(&self_buf) catch return error.NoSelfExe;

    var src = std.fs.cwd().openFile(self_path, .{}) catch return error.NoSelfExe;
    defer src.close();
    const st = src.stat() catch return error.NoSelfExe;

    // Packaging a packaged binary must not nest payloads: copy the engine only.
    const engine_len: u64 = if (payloadLenAtPath(self_path)) |n| st.size - trailer_len - n else st.size;

    // The copy has to come out runnable. Windows has no permission bits at all
    // (`File.Mode` is `u0` there), so the mode is a comptime branch, not a
    // literal: `0o755` does not even type-check for a Windows target.
    const out_mode: std.fs.File.Mode = if (builtin.target.os.tag == .windows) 0 else 0o755;

    var dst = std.fs.cwd().createFile(out_path, .{ .truncate = true, .mode = out_mode }) catch
        return error.WriteFailed;
    defer dst.close();

    var rbuf: [64 * 1024]u8 = undefined;
    var copied: u64 = 0;
    while (copied < engine_len) {
        const want = @min(rbuf.len, engine_len - copied);
        const n = src.read(rbuf[0..want]) catch return error.NoSelfExe;
        if (n == 0) break;
        dst.writeAll(rbuf[0..n]) catch return error.WriteFailed;
        copied += n;
    }
    dst.writeAll(app) catch return error.WriteFailed;

    var trailer: [trailer_len]u8 = undefined;
    @memcpy(trailer[0..magic.len], magic);
    std.mem.writeInt(u64, trailer[magic.len..], app.len, .little);
    dst.writeAll(&trailer) catch return error.WriteFailed;

    var result = ExeResult{
        .path = out_path,
        .bytes = @intCast(copied + app.len + trailer_len),
        .engine_bytes = @intCast(copied),
        .app_bytes = app.len,
    };

    // Appending invalidates a Mach-O code signature; re-sign ad hoc so the file
    // runs at all on Apple Silicon. Best effort: without `codesign` the user
    // gets the same one-line hint the CLI prints.
    if (builtin.target.os.tag == .macos) result.resigned = resign(alloc, out_path);

    return result;
}

fn resign(alloc: std.mem.Allocator, path: []const u8) bool {
    var child = std.process.Child.init(&.{ "codesign", "--force", "--sign", "-", path }, alloc);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;
    const term = child.spawnAndWait() catch return false;
    return term == .Exited and term.Exited == 0;
}

/// Length of the payload appended to the file at `path`, if it has one.
pub fn payloadLenAtPath(path: []const u8) ?u64 {
    var f = std.fs.cwd().openFile(path, .{}) catch return null;
    defer f.close();
    const st = f.stat() catch return null;
    if (st.size < trailer_len) return null;
    var trailer: [trailer_len]u8 = undefined;
    f.seekTo(st.size - trailer_len) catch return null;
    const got = f.readAll(&trailer) catch return null;
    if (got != trailer_len) return null;
    if (!std.mem.eql(u8, trailer[0..magic.len], magic)) return null;
    const len = std.mem.readInt(u64, trailer[magic.len..], .little);
    if (len == 0 or len > st.size - trailer_len) return null;
    return len;
}

/// True when the running executable carries an app.
pub fn isPackaged() bool {
    var self_buf: [std.fs.max_path_bytes]u8 = undefined;
    const self_path = std.fs.selfExePath(&self_buf) catch return false;
    return payloadLenAtPath(self_path) != null;
}

/// Read the app appended to the running executable. Caller owns the bytes.
pub fn embeddedApp(alloc: std.mem.Allocator) ?[]u8 {
    var self_buf: [std.fs.max_path_bytes]u8 = undefined;
    const self_path = std.fs.selfExePath(&self_buf) catch return null;
    const len = payloadLenAtPath(self_path) orelse return null;

    var f = std.fs.cwd().openFile(self_path, .{}) catch return null;
    defer f.close();
    const st = f.stat() catch return null;
    f.seekTo(st.size - trailer_len - len) catch return null;
    const buf = alloc.alloc(u8, @intCast(len)) catch return null;
    errdefer alloc.free(buf);
    const got = f.readAll(buf) catch return null;
    if (got != len) return null;
    return buf;
}

/// Human-readable name for the packaged app, used in log lines.
pub const embedded_label = "<embedded>";
