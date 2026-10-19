//! Loading Weave apps: `.weave` source goes through the compiler, `.wvbc`
//! straight through the bytecode decoder. Both end up as an arena-owned
//! `CodeUnit` wrapped in a `Module` that also tracks the file's mtime so the
//! dev server can hot-reload.

const std = @import("std");
const diag = @import("diag.zig");
const parser = @import("parser.zig");
const compiler = @import("compiler.zig");
const bytecode = @import("bytecode.zig");

pub const LoadError = error{ OutOfMemory, NotFound, ReadFailed, BadBytecode, Diagnostics };

pub const max_source_bytes: usize = 8 << 20;
pub const max_bytecode_bytes: usize = 64 << 20;

pub const Module = struct {
    parent: std.mem.Allocator,
    arena: *std.heap.ArenaAllocator,
    unit: *const bytecode.CodeUnit,
    path: []const u8,
    mtime_ns: i128 = 0,
    /// True when this came from a `.wvbc` file (no source diagnostics possible).
    precompiled: bool = false,
    /// Identifier slices in the AST/unit point straight into the source text, so
    /// a compiled module owns its source for as long as the unit lives.
    source_text: ?[]u8 = null,

    pub fn deinit(self: *Module) void {
        const a = self.arena;
        const parent = self.parent;
        if (self.source_text) |t| parent.free(t);
        parent.free(@constCast(self.path));
        a.deinit();
        parent.destroy(a);
        parent.destroy(self);
    }
};

pub fn isBytecode(path: []const u8) bool {
    return std.mem.eql(u8, std.fs.path.extension(path), ".wvbc");
}

pub fn mtimeOf(path: []const u8) ?i128 {
    const st = std.fs.cwd().statFile(path) catch return null;
    return st.mtime;
}

fn printDiagnostics(rep: *const diag.Reporter, color: bool) void {
    const txt = rep.render(color) catch return;
    defer rep.alloc.free(txt);
    std.io.getStdErr().writer().writeAll(txt) catch {};
}

/// Compile `path` (source or bytecode) into a module the server/VM can run.
/// Diagnostics are printed to stderr as they happen; `color` should follow the
/// terminal, not the file.
pub fn load(parent: std.mem.Allocator, path: []const u8, color: bool) LoadError!*Module {
    const mtime = mtimeOf(path) orelse 0;
    const owned_path = parent.dupe(u8, path) catch return error.OutOfMemory;
    errdefer parent.free(owned_path);

    if (isBytecode(path)) {
        const bytes = std.fs.cwd().readFileAlloc(parent, path, max_bytecode_bytes) catch |e| {
            return switch (e) {
                error.FileNotFound => error.NotFound,
                error.OutOfMemory => error.OutOfMemory,
                else => error.ReadFailed,
            };
        };
        defer parent.free(bytes);
        const loaded = bytecode.decode(parent, bytes) catch return error.BadBytecode;
        const m = try parent.create(Module);
        m.* = .{
            .parent = parent,
            .arena = loaded.arena,
            .unit = loaded.unit,
            .path = owned_path,
            .mtime_ns = mtime,
            .precompiled = true,
        };
        return m;
    }

    const text = std.fs.cwd().readFileAlloc(parent, path, max_source_bytes) catch |e| {
        return switch (e) {
            error.FileNotFound => error.NotFound,
            error.OutOfMemory => error.OutOfMemory,
            else => error.ReadFailed,
        };
    };
    // Ownership moves into the Module below; free it here only on failure.
    var text_owned = true;
    defer if (text_owned) parent.free(text);

    var src = diag.Source.init(parent, path, text) catch return error.OutOfMemory;
    defer src.deinit();
    var rep = diag.Reporter.init(parent, &src);
    defer rep.deinit();

    var parsed = (parser.parse(parent, &src, &rep) catch return error.OutOfMemory) orelse {
        printDiagnostics(&rep, color);
        return error.Diagnostics;
    };
    errdefer parsed.deinit();

    const unit = (compiler.compile(parsed.arena.allocator(), &parsed.program, &rep) catch
        return error.OutOfMemory) orelse {
        printDiagnostics(&rep, color);
        return error.Diagnostics;
    };
    if (rep.hasErrors()) {
        printDiagnostics(&rep, color);
        return error.Diagnostics;
    }
    if (rep.items.items.len > 0) printDiagnostics(&rep, color); // warnings and notes

    const m = try parent.create(Module);
    m.* = .{
        .parent = parent,
        .arena = parsed.arena,
        .unit = unit,
        .path = owned_path,
        .mtime_ns = mtime,
        .source_text = text,
    };
    text_owned = false;
    return m;
}

/// `weave build`: serialise a compiled unit to `.wvbc`.
pub fn writeBytecode(parent: std.mem.Allocator, unit: *const bytecode.CodeUnit, out_path: []const u8) !void {
    var enc = bytecode.Encoder.init(parent);
    defer enc.deinit();
    const bytes = try enc.encodeUnit(unit);
    defer parent.free(bytes);
    std.fs.cwd().writeFile(.{ .sub_path = out_path, .data = bytes }) catch return error.WriteFailed;
}

pub const CompileResult = struct {
    parent: std.mem.Allocator,
    arena: *std.heap.ArenaAllocator,
    unit: *const bytecode.CodeUnit,

    pub fn deinit(self: *CompileResult) void {
        const a = self.arena;
        a.deinit();
        self.parent.destroy(a);
    }
};

/// Compile a source *string* (used by tests and `weave run -`).
pub fn compileText(parent: std.mem.Allocator, path: []const u8, text: []const u8, color: bool) LoadError!*CompileResult {
    var src = diag.Source.init(parent, path, text) catch return error.OutOfMemory;
    defer src.deinit();
    var rep = diag.Reporter.init(parent, &src);
    defer rep.deinit();

    var parsed = (parser.parse(parent, &src, &rep) catch return error.OutOfMemory) orelse {
        printDiagnostics(&rep, color);
        return error.Diagnostics;
    };
    errdefer parsed.deinit();

    const unit = (compiler.compile(parsed.arena.allocator(), &parsed.program, &rep) catch
        return error.OutOfMemory) orelse {
        printDiagnostics(&rep, color);
        return error.Diagnostics;
    };
    if (rep.hasErrors()) {
        printDiagnostics(&rep, color);
        return error.Diagnostics;
    }
    if (rep.items.items.len > 0) printDiagnostics(&rep, color);

    const r = try parent.create(CompileResult);
    r.* = .{ .parent = parent, .arena = parsed.arena, .unit = unit };
    return r;
}
