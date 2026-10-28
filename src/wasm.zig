//! The headless engine API — one app, a queue of JSON frames in and out.
//!
//! The same file is compiled twice:
//!
//!   * to `weave-core.wasm` (wasm32-freestanding), embedded into the output of
//!     `weave build --html` so a single `.html` file runs a full Weave app with
//!     no server anywhere;
//!   * natively, by the unit tests, so the browser code path is exercised on
//!     every `zig build test` without a browser in sight.
//!
//! Contract for the embedding page:
//!
//!   1. `weave_alloc(n)` -> write `n` bytes at the returned pointer
//!   2. `weave_load(ptr, n, kind)` with kind 0 = source text, 1 = `.wvbc`
//!   3. `weave_start()`, then drain frames with `weave_next_frame()`
//!   4. on a user event, `weave_alloc` + write the client message JSON +
//!      `weave_dispatch(ptr, n)`, then drain frames again
//!   5. on an animation frame, `weave_tick(Date.now())` and drain again
//!
//! A returned `i64` packs a pointer and a length as `(ptr << 32) | len`; `0`
//! means "nothing". Buffers stay valid until the next call that allocates, so
//! the page copies them out immediately.

const std = @import("std");
const builtin = @import("builtin");

const value = @import("value.zig");
const diag = @import("diag.zig");
const parser = @import("parser.zig");
const compiler = @import("compiler.zig");
const bytecode = @import("bytecode.zig");
const session = @import("session.zig");
const proto = @import("proto.zig");
const host = @import("host.zig");

pub const LoadKind = enum(u32) {
    source = 0,
    bytecode = 1,
};

pub const Error = error{ Diagnostics, BadBytecode, OutOfMemory, Runtime };

/// One running app. Everything it owns comes from a single arena, so tearing it
/// down is one `deinit`.
pub const Engine = struct {
    parent: std.mem.Allocator,
    arena: *std.heap.ArenaAllocator,
    alloc: std.mem.Allocator,

    unit: *bytecode.CodeUnit,
    /// Null until the session exists, so a failed `create` can still be torn
    /// down. An engine that never started still owns a session, and with it
    /// every value the VM built for the unit's constants.
    sess: ?*session.Session,

    /// Kept alive for the whole run: identifier slices in the code unit point
    /// into the source text.
    source_text: []const u8,
    path: []const u8,

    /// Frames waiting to be handed to the page, oldest first.
    frames: std.ArrayList([]const u8),
    diagnostics: []const u8 = "",
    started: bool = false,

    /// Compile `bytes` (source or bytecode) and build a session for it. The caller
    /// must have initialised the value runtime (`value.initRuntime`) first.
    ///
    /// `diagnostics_out` receives human-readable text allocated from `parent`
    /// (not from the engine arena, which is gone by the time a caller reads a
    /// failure). The caller owns it: free it when `len > 0`.
    pub fn create(
        parent: std.mem.Allocator,
        path: []const u8,
        bytes: []const u8,
        kind: LoadKind,
        diagnostics_out: *[]const u8,
    ) Error!*Engine {
        var arena_box = try parent.create(std.heap.ArenaAllocator);
        arena_box.* = std.heap.ArenaAllocator.init(parent);
        const a = arena_box.allocator();

        // `Engine.destroy` frees the arena it lives in, so from the moment the
        // Engine exists it is the arena's only owner — an `errdefer` on the
        // arena as well would tear it down twice. Before that point the two
        // steps below are the whole cleanup.
        const e = a.create(Engine) catch {
            arena_box.deinit();
            parent.destroy(arena_box);
            return error.OutOfMemory;
        };
        e.* = .{
            .parent = parent,
            .arena = arena_box,
            .alloc = a,
            .unit = undefined,
            .sess = null,
            .source_text = "",
            .path = a.dupe(u8, path) catch {
                arena_box.deinit();
                parent.destroy(arena_box);
                return error.OutOfMemory;
            },
            .frames = std.ArrayList([]const u8).init(a),
        };
        errdefer e.destroy();

        diagnostics_out.* = "";

        switch (kind) {
            .bytecode => {
                // The decoder builds its own arena; nesting it inside ours means
                // one deinit frees the whole unit.
                const loaded = bytecode.decode(a, bytes) catch |err| switch (err) {
                    error.BadBytecode => {
                        diagnostics_out.* = try parent.dupe(u8, "not a .wvbc file: bad magic, unsupported version or truncated body");
                        return error.BadBytecode;
                    },
                    error.OutOfMemory => return error.OutOfMemory,
                };
                e.unit = loaded.unit;
            },
            .source => {
                e.source_text = try a.dupe(u8, bytes);
                var src = diag.Source.init(a, e.path, e.source_text) catch return error.OutOfMemory;
                // The arena owns the line index now; `src` must not free it twice.
                src.owns_lines = false;
                var rep = diag.Reporter.init(a, &src);

                const parsed = (parser.parse(a, &src, &rep) catch return error.OutOfMemory) orelse {
                    diagnostics_out.* = try renderDiags(parent, &rep);
                    return error.Diagnostics;
                };
                const unit = (compiler.compile(parsed.arena.allocator(), &parsed.program, &rep) catch
                    return error.OutOfMemory) orelse {
                    diagnostics_out.* = try renderDiags(parent, &rep);
                    return error.Diagnostics;
                };
                if (rep.hasErrors()) {
                    diagnostics_out.* = try renderDiags(parent, &rep);
                    return error.Diagnostics;
                }
                // Warnings are worth showing even when the app compiles.
                if (rep.items.items.len > 0) diagnostics_out.* = try renderDiags(parent, &rep);
                e.unit = unit;
            },
        }

        e.sess = session.Session.create(a, e.unit, e.path, frameSink, @ptrCast(e)) catch
            return error.OutOfMemory;
        return e;
    }

    /// Run signal initialisers and emit `hello` + `mount`.
    pub fn start(self: *Engine) Error!void {
        if (self.started) return;
        self.started = true;
        const s = self.sess orelse return error.Runtime;
        s.start() catch |e| return self.fail(e);
    }

    /// Feed one client message (`event`, `input` or `ping`) to the session.
    pub fn dispatch(self: *Engine, msg: []const u8) Error!void {
        if (!self.started) try self.start();
        const s = self.sess orelse return error.Runtime;
        const cm = proto.parseClientMsg(self.alloc, msg);
        switch (cm) {
            // dispatch* take ownership of the payload value.
            .event => |ev| s.dispatchEvent(ev.id, ev.name, ev.args) catch |e| return self.fail(e),
            .input => |in| s.dispatchInput(in.id, in.value, "input") catch |e| return self.fail(e),
            .ping => s.sendPong() catch |e| return self.fail(e),
            .unknown => {},
        }
    }

    /// Advance the clock and run any `after <ms>:` timers that are due.
    pub fn tick(self: *Engine, now_ms: i64) Error!void {
        if (!self.started) return;
        const s = self.sess orelse return error.Runtime;
        host.setNowMs(now_ms);
        s.tick(now_ms) catch |e| return self.fail(e);
    }

    pub fn nextFrame(self: *Engine) ?[]const u8 {
        if (self.frames.items.len == 0) return null;
        return self.frames.orderedRemove(0);
    }

    pub fn appName(self: *const Engine) []const u8 {
        return self.unit.app_name;
    }

    pub fn destroy(self: *Engine) void {
        const parent = self.parent;
        const arena = self.arena;
        if (self.sess) |s| s.destroy();
        for (self.frames.items) |f| _ = f;
        arena.deinit();
        parent.destroy(arena);
    }

    fn fail(self: *Engine, e: anyerror) Error {
        if (e == error.OutOfMemory) return error.OutOfMemory;
        const name = @errorName(e);
        self.diagnostics = std.fmt.allocPrint(self.alloc, "runtime error: {s}", .{name}) catch
            "runtime error";
        return error.Runtime;
    }

    fn frameSink(ctx: *anyopaque, bytes: []const u8) session.SendError!void {
        const self: *Engine = @ptrCast(@alignCast(ctx));
        const copy = self.alloc.dupe(u8, bytes) catch return error.OutOfMemory;
        self.frames.append(copy) catch {
            self.alloc.free(copy);
            return error.OutOfMemory;
        };
    }
};

fn renderDiags(parent: std.mem.Allocator, rep: *diag.Reporter) ![]const u8 {
    const txt = try rep.render(false);
    defer rep.alloc.free(txt);
    return try parent.dupe(u8, txt);
}

// --------------------------------------------------------------- exports ----
//
// A page hosts one app, so the exported API drives a single global engine. The
// `Engine` struct above is what the native tests use directly.

var engine: ?*Engine = null;
/// Allocated from `value.alloc`, or "" when there is nothing to say.
var last_diagnostics: []const u8 = "";

fn setDiagnostics(text: []const u8) void {
    if (last_diagnostics.len > 0) value.alloc.free(last_diagnostics);
    last_diagnostics = text;
}

/// Scratch region for buffers the page hands in. Reset on every `weave_alloc`,
/// which is why the contract is: allocate, write, call one function.
var js_arena: ?*std.heap.ArenaAllocator = null;

fn scratch() std.mem.Allocator {
    value.initRuntime();
    if (js_arena == null) {
        const box = value.alloc.create(std.heap.ArenaAllocator) catch return value.alloc;
        box.* = std.heap.ArenaAllocator.init(value.alloc);
        js_arena = box;
    }
    _ = js_arena.?.reset(.retain_capacity);
    return js_arena.?.allocator();
}

fn pack(ptr: [*]const u8, len: usize) i64 {
    const p: u64 = @intFromPtr(ptr);
    const l: u64 = @intCast(len);
    return @bitCast((p << 32) | (l & 0xFFFF_FFFF));
}

fn packSlice(s: []const u8) i64 {
    return pack(s.ptr, s.len);
}

/// Wasm entry point. The linker wants one; a library has nothing to run. A
/// native test binary already has `_start`, so this is exported for wasm only.
fn wasmEntry() callconv(.C) void {}
comptime {
    if (builtin.target.cpu.arch == .wasm32) {
        @export(wasmEntry, .{ .name = "_start", .linkage = .strong });
    }
}

/// Allocate `len` writable bytes and return the pointer. Invalidates any buffer
/// returned by a previous call.
export fn weave_alloc(len: u32) u32 {
    const a = scratch();
    const buf = a.alloc(u8, len) catch return 0;
    return @intCast(@intFromPtr(buf.ptr));
}

/// Compile and install an app. `kind`: 0 = `.weave` source, 1 = `.wvbc`.
/// Returns 0 on success, 1 on diagnostics (call `weave_diagnostics`),
/// 2 on a bad bytecode file, 3 on out-of-memory.
export fn weave_load(ptr: u32, len: u32, kind: u32) i32 {
    value.initRuntime();
    const bytes: []const u8 = @as([*]const u8, @ptrFromInt(ptr))[0..len];
    weave_reset();

    const k: LoadKind = if (kind == 1) .bytecode else .source;
    var diags: []const u8 = "";
    engine = Engine.create(value.alloc, "app.weave", bytes, k, &diags) catch |e| {
        setDiagnostics(diags);
        return switch (e) {
            error.Diagnostics => 1,
            error.BadBytecode => 2,
            error.OutOfMemory, error.Runtime => {
                if (diags.len > 0) value.alloc.free(diags);
                return 3;
            },
        };
    };
    setDiagnostics(diags); // warnings, when the app did compile
    return 0;
}

/// Initialise signals and queue the `hello` + `mount` frames.
export fn weave_start() i32 {
    const e = engine orelse return 1;
    e.start() catch return 2;
    return 0;
}

/// Feed one client message to the app; queues any resulting frames.
export fn weave_dispatch(ptr: u32, len: u32) i32 {
    const e = engine orelse return 1;
    const bytes: []const u8 = @as([*]const u8, @ptrFromInt(ptr))[0..len];
    e.dispatch(bytes) catch return 2;
    return 0;
}

/// Advance the clock to `now_ms` and run due timers.
export fn weave_tick(now_ms: f64) i32 {
    const e = engine orelse return 1;
    e.tick(@intFromFloat(now_ms)) catch return 2;
    return 0;
}

/// Pop the oldest queued frame as `(ptr << 32) | len`, or 0 when empty.
export fn weave_next_frame() i64 {
    const e = engine orelse return 0;
    const f = e.nextFrame() orelse return 0;
    return packSlice(f);
}

/// Compile diagnostics, warnings, or the last runtime error.
export fn weave_diagnostics() i64 {
    if (engine) |e| {
        if (e.diagnostics.len > 0) return packSlice(e.diagnostics);
    }
    return packSlice(last_diagnostics);
}

/// The app name from the `app Name:` declaration.
export fn weave_app_name() i64 {
    const e = engine orelse return 0;
    return packSlice(e.appName());
}

/// `log()` output from handlers and effects, drained on read.
export fn weave_take_log() i64 {
    return packSlice(host.takeLog());
}

/// Number of log bytes dropped because the buffer was full.
export fn weave_log_dropped() u32 {
    return @intCast(host.droppedLogBytes());
}

/// Tear the app down. Called by `weave_load` so a page can swap apps.
export fn weave_reset() void {
    if (engine) |e| {
        e.destroy();
        engine = null;
    }
    setDiagnostics("");
}
