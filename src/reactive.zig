//! Fine-grained reactivity: signals + automatically tracked effects.
//!
//! Reading a signal while an effect is running subscribes that effect to the
//! signal. Writing a signal marks its subscribers dirty and schedules them.
//! Priorities make the update order deterministic:
//!
//!   0 — computed signals (recompute derived values first)
//!   1 — user `effects:` blocks
//!   2 — the view render (always last, so it sees a consistent world)

const std = @import("std");
const value = @import("value.zig");
const bytecode = @import("bytecode.zig");

pub const Priority = struct {
    pub const computed: u8 = 0;
    pub const effect: u8 = 1;
    pub const render: u8 = 2;
};

pub const Signal = struct {
    name: []const u8,
    kind: bytecode.SigKind = .state,
    value: value.Value = .{ .nil = {} },
    version: u32 = 0,
    subs: std.ArrayList(u32),
};

pub const EffectFn = *const fn (ctx: *anyopaque, effect_id: u32) anyerror!void;

pub const Effect = struct {
    label: []const u8 = "",
    priority: u8 = Priority.effect,
    run: EffectFn,
    ctx: *anyopaque,
    deps: std.ArrayList(u32),
    dirty: bool = false,
    /// Effects can be disabled (e.g. while initialising state).
    enabled: bool = true,
    runs: u32 = 0,
};

fn sameBox(a: value.Value, b: value.Value) bool {
    return switch (a) {
        .str => |x| switch (b) {
            .str => |y| x == y,
            else => false,
        },
        .list => |x| switch (b) {
            .list => |y| x == y,
            else => false,
        },
        .map => |x| switch (b) {
            .map => |y| x == y,
            else => false,
        },
        .func => |x| switch (b) {
            .func => |y| x == y,
            else => false,
        },
        else => false,
    };
}

fn containsBox(haystack: value.Value, needle: value.Value, depth: usize) bool {
    if (depth > 8 or !haystack.isRefcounted()) return false;
    if (sameBox(haystack, needle)) return true;
    switch (haystack) {
        .list => |l| {
            for (l.items.items) |it| {
                if (containsBox(it, needle, depth + 1)) return true;
            }
        },
        .map => |m| {
            for (m.entries.items) |e| {
                if (containsBox(e.value, needle, depth + 1)) return true;
            }
        },
        else => {},
    }
    return false;
}

pub const Store = struct {
    alloc: std.mem.Allocator,
    signals: std.ArrayList(Signal),
    by_name: std.StringHashMap(u32),
    effects: std.ArrayList(Effect),
    tracking: ?u32 = null,
    flushing: bool = false,
    writes: u64 = 0,

    pub fn init(a: std.mem.Allocator) Store {
        return .{
            .alloc = a,
            .signals = std.ArrayList(Signal).init(a),
            .by_name = std.StringHashMap(u32).init(a),
            .effects = std.ArrayList(Effect).init(a),
        };
    }

    pub fn deinit(self: *Store) void {
        for (self.signals.items) |*s| {
            s.value.release();
            s.subs.deinit();
        }
        self.signals.deinit();
        for (self.effects.items) |*e| e.deps.deinit();
        self.effects.deinit();
        self.by_name.deinit();
    }

    pub fn addSignal(self: *Store, name: []const u8, kind: bytecode.SigKind) !u32 {
        if (self.by_name.get(name)) |existing| return existing;
        const id: u32 = @intCast(self.signals.items.len);
        try self.signals.append(.{
            .name = name,
            .kind = kind,
            .subs = std.ArrayList(u32).init(self.alloc),
        });
        try self.by_name.put(name, id);
        return id;
    }

    pub fn indexOf(self: *const Store, name: []const u8) ?u32 {
        return self.by_name.get(name);
    }

    pub fn addEffect(self: *Store, label: []const u8, priority: u8, run: EffectFn, ctx: *anyopaque) !u32 {
        const id: u32 = @intCast(self.effects.items.len);
        try self.effects.append(.{
            .label = label,
            .priority = priority,
            .run = run,
            .ctx = ctx,
            .deps = std.ArrayList(u32).init(self.alloc),
        });
        return id;
    }

    /// Read a signal, subscribing the currently tracking effect.
    /// The returned value is borrowed — retain it if you keep it.
    pub fn read(self: *Store, idx: u32) value.Value {
        if (self.tracking) |eid| self.subscribe(idx, eid);
        return self.signals.items[idx].value;
    }

    /// Read without creating a dependency.
    pub fn peek(self: *const Store, idx: u32) value.Value {
        return self.signals.items[idx].value;
    }

    fn subscribe(self: *Store, sig: u32, effect: u32) void {
        const s = &self.signals.items[sig];
        for (s.subs.items) |e| if (e == effect) return;
        s.subs.append(effect) catch return;
        const ef = &self.effects.items[effect];
        for (ef.deps.items) |d| if (d == sig) return;
        ef.deps.append(sig) catch return;
    }

    /// Write a signal. Consumes ownership of `v` (the caller's retain is transferred).
    pub fn write(self: *Store, idx: u32, v: value.Value) void {
        const s = &self.signals.items[idx];
        if (s.value.deepEqual(v)) {
            v.release();
            return; // no change, no notification
        }
        s.value.release();
        s.value = v;
        s.version +%= 1;
        self.writes += 1;
        for (s.subs.items) |eid| {
            const e = &self.effects.items[eid];
            if (!e.enabled) continue;
            e.dirty = true;
        }
    }

    /// In-place mutation (`tasks.append(x)`) changes a box that a signal still
    /// points at, so no `write` happens. Find every signal whose value *contains*
    /// that box and notify its subscribers. State graphs are small, so a bounded
    /// containment walk costs far less than copy-on-write would.
    pub fn markMutated(self: *Store, v: value.Value) void {
        if (!v.isRefcounted()) return;
        for (self.signals.items, 0..) |*s, i| {
            if (s.kind == .theme or s.kind == .style) continue;
            if (!containsBox(s.value, v, 0)) continue;
            s.version +%= 1;
            self.writes += 1;
            for (s.subs.items) |eid| {
                const e = &self.effects.items[eid];
                if (e.enabled) e.dirty = true;
            }
            _ = i;
        }
    }

    pub fn beginTrack(self: *Store, effect_id: u32) void {
        const e = &self.effects.items[effect_id];
        for (e.deps.items) |sig| {
            const s = &self.signals.items[sig];
            for (s.subs.items, 0..) |sub, i| {
                if (sub == effect_id) {
                    _ = s.subs.orderedRemove(i);
                    break;
                }
            }
        }
        e.deps.clearRetainingCapacity();
        self.tracking = effect_id;
    }

    pub fn endTrack(self: *Store) void {
        self.tracking = null;
    }

    pub fn markDirty(self: *Store, effect_id: u32) void {
        self.effects.items[effect_id].dirty = true;
    }

    pub fn anyDirty(self: *const Store) bool {
        for (self.effects.items) |e| if (e.dirty and e.enabled) return true;
        return false;
    }

    /// Run dirty effects in priority order until the graph settles.
    /// Writes performed by effects re-dirty their subscribers, which the next
    /// pass picks up; the loop is bounded so a cycle cannot hang the server.
    pub fn flush(self: *Store) !void {
        if (self.flushing) return;
        self.flushing = true;
        defer self.flushing = false;

        var pass: usize = 0;
        while (pass < 16) : (pass += 1) {
            var ran = false;
            var prio: u8 = 0;
            while (prio <= Priority.render) : (prio += 1) {
                var i: usize = 0;
                while (i < self.effects.items.len) : (i += 1) {
                    const e = &self.effects.items[i];
                    if (!e.dirty or !e.enabled or e.priority != prio) continue;
                    e.dirty = false;
                    ran = true;
                    const eid: u32 = @intCast(i);
                    self.beginTrack(eid);
                    const res = e.run(e.ctx, eid);
                    self.endTrack();
                    e.runs += 1;
                    if (res) |_| {} else |err| {
                        // Re-throw so the caller can report it; the graph stays consistent.
                        return err;
                    }
                }
            }
            if (!ran) break;
        }
    }

    /// Snapshot of every state signal (used by `weave inspect` and debugging).
    pub fn dumpState(self: *Store) !value.Value {
        const map = try value.makeMap();
        errdefer map.release();
        for (self.signals.items) |*s| {
            if (s.kind != .state) continue;
            const copy = try s.value.deepCopy();
            try map.map.set(s.name, copy);
        }
        return map;
    }
};
