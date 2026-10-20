//! Aggregate test root: `zig build test` compiles this file, which pulls in
//! every module so their `test` blocks run under the leak-checking allocator.

const std = @import("std");

const diag = @import("diag.zig");
const lexer = @import("lexer.zig");
const ast = @import("ast.zig");
const parser = @import("parser.zig");
const value = @import("value.zig");
const jsonw = @import("jsonw.zig");
const bytecode = @import("bytecode.zig");
const builtins = @import("builtins.zig");
const compiler = @import("compiler.zig");
const reactive = @import("reactive.zig");
const vdom = @import("vdom.zig");
const vm = @import("vm.zig");
const session = @import("session.zig");

test "value: refcounting round-trips" {
    value.useAllocator(std.testing.allocator);

    const s = try value.makeStr("hello");
    const s2 = s.retain();
    s.release();
    try std.testing.expectEqualStrings("hello", s2.str.bytes);
    s2.release();

    const l = try value.makeList();
    try l.list.items.append(try value.makeStr("a"));
    try l.list.items.append(value.Value.intOf(7));
    const copy = try l.deepCopy();
    try std.testing.expect(l.deepEqual(copy));
    l.release();
    copy.release();
}

test "value: maps keep insertion order" {
    value.useAllocator(std.testing.allocator);

    const m = try value.makeMap();
    try m.map.set("z", value.Value.intOf(1));
    try m.map.set("a", value.Value.intOf(2));
    try m.map.set("z", value.Value.intOf(3));
    try std.testing.expectEqual(@as(usize, 2), m.map.len());
    try std.testing.expectEqualStrings("z", m.map.entries.items[0].key);
    try std.testing.expectEqual(@as(i64, 3), m.map.get("z").?.int);
    m.release();
}

test "jsonw: escaping and numbers" {
    value.useAllocator(std.testing.allocator);

    var w = jsonw.Writer.init(value.alloc);
    defer w.deinit();
    try w.beginObj();
    try w.key("a");
    try w.str("he said \"hi\"\n\ttab");
    try w.sep();
    try w.key("b");
    try w.float(2.0);
    try w.sep();
    try w.key("c");
    try w.float(1.5);
    try w.endObj();
    const out = try w.toOwnedSlice();
    defer value.alloc.free(out);
    try std.testing.expectEqualStrings(
        \\{"a":"he said \"hi\"\n\ttab","b":2,"c":1.5}
    , out);
}

test "lexer: indentation becomes INDENT/DEDENT" {
    value.useAllocator(std.testing.allocator);

    const src_text =
        \\app X:
        \\    state:
        \\        n = 1
        \\    view:
        \\        text("hi")
    ;
    var src = try diag.Source.init(value.alloc, "t.weave", src_text);
    defer src.deinit();
    var rep = diag.Reporter.init(value.alloc, &src);
    defer rep.deinit();

    var lx = lexer.Lexer.init(value.alloc, &src, &rep);
    defer lx.deinit();
    const toks = try lx.run();

    try std.testing.expect(!rep.hasErrors());
    var indents: usize = 0;
    var dedents: usize = 0;
    for (toks) |t| {
        if (t.kind == .indent) indents += 1;
        if (t.kind == .dedent) dedents += 1;
    }
    try std.testing.expectEqual(@as(usize, 3), indents);
    try std.testing.expectEqual(indents, dedents);
}

test "lexer: braces classify map vs handler block" {
    value.useAllocator(std.testing.allocator);

    const src_text =
        \\input(on_enter: {
        \\    tasks.append(x)
        \\}, style: { padding: 8 })
    ;
    var src = try diag.Source.init(value.alloc, "t.weave", src_text);
    defer src.deinit();
    var rep = diag.Reporter.init(value.alloc, &src);
    defer rep.deinit();
    var lx = lexer.Lexer.init(value.alloc, &src, &rep);
    defer lx.deinit();
    const toks = try lx.run();
    try std.testing.expect(!rep.hasErrors());

    var blocks: usize = 0;
    var maps: usize = 0;
    for (toks) |t| {
        if (t.kind == .lbrace) {
            if (t.block_brace) blocks += 1 else maps += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 1), blocks);
    try std.testing.expectEqual(@as(usize, 1), maps);
}

test "parser: the canonical TodoApp example" {
    value.useAllocator(std.testing.allocator);

    const src_text =
        \\app TodoApp:
        \\    state:
        \\        tasks = ["Learn Weave", "Build something cool"]
        \\        new_task = ""
        \\
        \\    view:
        \\        stack(padding: 24, align: center):
        \\            text("My Tasks", font: 28, bold: true)
        \\
        \\            input(bind: new_task, placeholder: "Add a new task...", on_enter: {
        \\                tasks.append(new_task)
        \\                new_task = ""
        \\            })
        \\
        \\            for task in tasks:
        \\                card(shadow: sm):
        \\                    text(task)
        \\                    button("Done", click: tasks.remove(task))
    ;
    var src = try diag.Source.init(value.alloc, "todo.weave", src_text);
    defer src.deinit();
    var rep = diag.Reporter.init(value.alloc, &src);
    defer rep.deinit();

    var res = (try parser.parse(value.alloc, &src, &rep)) orelse {
        const txt = try rep.render(false);
        std.debug.print("{s}\n", .{txt});
        return error.ParseFailed;
    };
    defer res.deinit();

    try std.testing.expectEqualStrings("TodoApp", res.program.app.name);
    try std.testing.expectEqual(@as(usize, 2), res.program.app.state.len);
    try std.testing.expectEqual(@as(usize, 1), res.program.app.view.len);

    const stack = res.program.app.view[0].element;
    try std.testing.expectEqualStrings("stack", stack.tag);
    try std.testing.expectEqual(@as(usize, 2), stack.args.len);
    try std.testing.expectEqual(@as(usize, 3), stack.children.len);

    const input = stack.children[1].element;
    try std.testing.expectEqualStrings("input", input.tag);
    // on_enter is a handler block
    var found_block = false;
    for (input.args) |a| {
        if (a.name != null and std.mem.eql(u8, a.name.?, "on_enter")) {
            try std.testing.expect(a.block != null);
            try std.testing.expectEqual(@as(usize, 2), a.block.?.len);
            found_block = true;
        }
    }
    try std.testing.expect(found_block);

    const loop = stack.children[2].loop;
    try std.testing.expectEqualStrings("task", loop.item_name);
    try std.testing.expectEqual(@as(usize, 1), loop.children.len);
    const card = loop.children[0].element;
    try std.testing.expectEqualStrings("card", card.tag);
    try std.testing.expectEqual(@as(usize, 2), card.children.len);
}

test "parser: string interpolation splits into parts" {
    value.useAllocator(std.testing.allocator);

    const src_text =
        \\app X:
        \\    state:
        \\        n = 1
        \\        msg = "count: {n + 1}, name: {name}"
    ;
    var src = try diag.Source.init(value.alloc, "t.weave", src_text);
    defer src.deinit();
    var rep = diag.Reporter.init(value.alloc, &src);
    defer rep.deinit();
    var res = (try parser.parse(value.alloc, &src, &rep)) orelse {
        const txt = try rep.render(false);
        std.debug.print("{s}\n", .{txt});
        return error.ParseFailed;
    };
    defer res.deinit();

    const msg = res.program.app.state[1].value;
    const parts = msg.str_lit.parts;
    try std.testing.expectEqual(@as(usize, 4), parts.len);
    try std.testing.expectEqualStrings("count: ", parts[0].lit);
    try std.testing.expect(parts[1] == .expr);
    try std.testing.expectEqualStrings(", name: ", parts[2].lit);
}

test "diag: renders a caret underline" {
    value.useAllocator(std.testing.allocator);

    const src_text = "app X:\n    state\n";
    var src = try diag.Source.init(value.alloc, "bad.weave", src_text);
    defer src.deinit();
    var rep = diag.Reporter.init(value.alloc, &src);
    defer rep.deinit();
    rep.err(src.spanOf(11, 16), "expected ':' after section name", .{});
    const out = try rep.render(false);
    defer value.alloc.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "bad.weave:2:5") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "^^^^^") != null);
}

test "modules: type-check" {
    // Referenced so every module is semantically analysed by `zig build test`.
    try std.testing.expect(bytecode.format_version == 1);
    try std.testing.expect(builtins.table.len > 20);
    try std.testing.expect(reactive.Priority.render == 2);
    try std.testing.expect(vdom.Tag.of("card") == .card);
    try std.testing.expect(vm.countOf(.{ .nil = {} }) == 0);
    try std.testing.expect(compiler.eventName("on_enter") != null);
}

const todo_source =
    \\app TodoApp:
    \\    state:
    \\        tasks = ["Learn Weave", "Build something cool"]
    \\        new_task = ""
    \\        done_count = 0
    \\
    \\    computed:
    \\        summary = "{done_count} of {tasks.len()} done"
    \\
    \\    view:
    \\        stack(padding: 24, align: center):
    \\            text("My Tasks", font: 28, bold: true)
    \\            text(summary)
    \\
    \\            input(bind: new_task, placeholder: "Add a new task...", on_enter: {
    \\                tasks.append(new_task)
    \\                new_task = ""
    \\            })
    \\
    \\            for task in tasks:
    \\                card(shadow: sm):
    \\                    text(task)
    \\                    button("Done", click: {
    \\                        tasks.remove(task)
    \\                        done_count += 1
    \\                    })
;

/// Parse + compile a source string, returning the arena-owned unit.
fn compileSource(a: std.mem.Allocator, text: []const u8, rep: *diag.Reporter, src: *diag.Source) !*bytecode.CodeUnit {
    src.* = try diag.Source.init(a, "test.weave", text);
    var parsed = (try parser.parse(a, src, rep)) orelse return error.ParseFailed;
    const unit = (try compiler.compile(parsed.arena.allocator(), &parsed.program, rep)) orelse return error.CompileFailed;
    // The parse arena must stay alive for the unit's slices, so leak it
    // deliberately in tests (std.testing.allocator would flag it), and instead
    // hand the arena to the caller through a static slot.
    test_arena = parsed.arena;
    return unit;
}

var test_arena: ?*std.heap.ArenaAllocator = null;

fn initStore(v: *vm.Vm, store: *reactive.Store, unit: *const bytecode.CodeUnit) !void {
    for (unit.signals) |s| {
        const idx = try store.addSignal(s.name, s.kind);
        const rv = try v.callFunc(s.init_fn, &.{}, null);
        store.write(idx, rv);
    }
}

fn renderOnce(v: *vm.Vm, b: *vdom.Builder, unit: *const bytecode.CodeUnit) !void {
    v.builder = b;
    const rv = try v.callFunc(unit.render_fn, &.{}, null);
    rv.release();
    v.builder = null;
}

test "vm: compiles and renders the TodoApp" {
    value.useAllocator(std.testing.allocator);
    var rep = diag.Reporter.init(value.alloc, null);
    defer rep.deinit();
    var src: diag.Source = undefined;
    defer src.deinit();
    const unit = compileSource(value.alloc, todo_source, &rep, &src) catch {
        const txt = try rep.render(false);
        std.debug.print("{s}\n", .{txt});
        return error.Failed;
    };
    defer if (test_arena) |ta| {
        ta.deinit();
        value.alloc.destroy(ta);
        test_arena = null;
    };

    var store = reactive.Store.init(value.alloc);
    defer store.deinit();
    var v = try vm.Vm.init(value.alloc, unit, &store);
    defer v.deinit();
    try initStore(&v, &store, unit);

    // computed signals recompute from state
    const summary_idx = store.indexOf("summary").?;
    {
        const rv = try v.callFunc(unit.signals[summary_idx].init_fn, &.{}, null);
        store.write(summary_idx, rv);
    }
    var buf = std.ArrayList(u8).init(value.alloc);
    defer buf.deinit();
    try store.peek(summary_idx).display(&buf);
    try std.testing.expectEqualStrings("0 of 2 done", buf.items);

    var b = vdom.Builder.init(value.alloc);
    defer b.deinit();
    try renderOnce(&v, &b, unit);

    const root = b.root orelse return error.NoRoot;
    try std.testing.expect(root.tag == .stack);
    // text, text(summary), input, card, card
    try std.testing.expectEqual(@as(usize, 5), root.children.items.len);
    try std.testing.expectEqual(@as(i64, 24), root.getProp("padding").?.int);

    const title = root.children.items[0];
    try std.testing.expect(title.tag == .text);
    try std.testing.expectEqualStrings("My Tasks", title.children.items[0].text.str.bytes);
    try std.testing.expectEqual(@as(i64, 28), title.getProp("font").?.int);
    try std.testing.expect(title.getProp("bold").?.boolean);

    const input = root.children.items[2];
    try std.testing.expect(input.tag == .input);
    try std.testing.expectEqualStrings("new_task", input.bind);
    try std.testing.expectEqualStrings("", input.getProp("value").?.str.bytes);
    try std.testing.expectEqualStrings("Add a new task...", input.getProp("placeholder").?.str.bytes);
    try std.testing.expect(input.findEvent("enter") != null);

    const card0 = root.children.items[3];
    try std.testing.expect(card0.tag == .card);
    try std.testing.expect(card0.key != null);
    const card_text = card0.children.items[0].children.items[0].text.str.bytes;
    try std.testing.expectEqualStrings("Learn Weave", card_text);
    const card1_text = root.children.items[4].children.items[0].children.items[0].text.str.bytes;
    try std.testing.expectEqualStrings("Build something cool", card1_text);

    // The two cards captured *different* loop variables.
    const h0 = card0.children.items[1].findEvent("click").?.func;
    const h1 = root.children.items[4].children.items[1].findEvent("click").?.func;
    try std.testing.expect(h0.captures.len >= 1);
    try std.testing.expectEqualStrings("Learn Weave", h0.captures[0].str.bytes);
    try std.testing.expectEqualStrings("Build something cool", h1.captures[0].str.bytes);

    // Dispatch the first card's click handler: the task disappears, counter moves.
    const callable = card0.children.items[1].findEvent("click").?;
    const rv = try v.invokePublic(callable, &.{});
    rv.release();

    const tasks_idx = store.indexOf("tasks").?;
    try std.testing.expectEqual(@as(usize, 1), store.peek(tasks_idx).list.items.items.len);
    try std.testing.expectEqualStrings("Build something cool", store.peek(tasks_idx).list.items.items[0].str.bytes);
    const dc = store.peek(store.indexOf("done_count").?);
    try std.testing.expectEqual(@as(i64, 1), dc.int);

    // The in-place mutation must have marked the render effect dirty.
    try std.testing.expect(store.writes >= 1);
}


// ---------------------------------------------------------------------------
// session: the whole app over the wire protocol
// ---------------------------------------------------------------------------

const Wire = struct {
    alloc: std.mem.Allocator,
    frames: std.ArrayList([]u8),

    fn init(a: std.mem.Allocator) Wire {
        return .{ .alloc = a, .frames = std.ArrayList([]u8).init(a) };
    }

    fn deinit(self: *Wire) void {
        for (self.frames.items) |f| self.alloc.free(f);
        self.frames.deinit();
    }

    fn send(ctx: *anyopaque, bytes: []const u8) session.SendError!void {
        const self: *Wire = @ptrCast(@alignCast(ctx));
        const copy = self.alloc.dupe(u8, bytes) catch return error.OutOfMemory;
        self.frames.append(copy) catch {
            self.alloc.free(copy);
            return error.OutOfMemory;
        };
    }

    fn last(self: *const Wire) []const u8 {
        return self.frames.items[self.frames.items.len - 1];
    }
};

fn countOccurrences(haystack: []const u8, needle: []const u8) usize {
    var n: usize = 0;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) {
        if (std.mem.eql(u8, haystack[i .. i + needle.len], needle)) {
            n += 1;
            i += needle.len;
        } else i += 1;
    }
    return n;
}

fn findByTag(n: *vdom.Node, tag: []const u8) ?*vdom.Node {
    if (std.mem.eql(u8, n.tag_name, tag)) return n;
    for (n.children.items) |c| {
        if (findByTag(c, tag)) |hit| return hit;
    }
    return null;
}

fn findAllByTag(n: *vdom.Node, tag: []const u8, out: *std.ArrayList(*vdom.Node)) void {
    if (std.mem.eql(u8, n.tag_name, tag)) out.append(n) catch {};
    for (n.children.items) |c| findAllByTag(c, tag, out);
}

test "session: full round trip over the wire protocol" {
    value.useAllocator(std.testing.allocator);
    var rep = diag.Reporter.init(value.alloc, null);
    defer rep.deinit();
    var src: diag.Source = undefined;
    defer src.deinit();
    const unit = compileSource(value.alloc, todo_source, &rep, &src) catch {
        const txt = try rep.render(false);
        std.debug.print("{s}\n", .{txt});
        return error.Failed;
    };
    defer if (test_arena) |ta| {
        ta.deinit();
        value.alloc.destroy(ta);
        test_arena = null;
    };

    var wire = Wire.init(value.alloc);
    defer wire.deinit();

    const s = try session.Session.create(value.alloc, unit, "test.weave", Wire.send, @ptrCast(&wire));
    defer s.destroy();
    try s.start();

    // --- mount -------------------------------------------------------------
    try std.testing.expectEqual(@as(usize, 2), wire.frames.items.len);
    try std.testing.expect(std.mem.startsWith(u8, wire.frames.items[0], "{\"t\":\"hello\""));
    const mount = wire.frames.items[1];
    try std.testing.expect(std.mem.startsWith(u8, mount, "{\"t\":\"mount\""));
    try std.testing.expect(std.mem.indexOf(u8, mount, "My Tasks") != null);
    try std.testing.expect(std.mem.indexOf(u8, mount, "\"t\":\"input\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, mount, "\"b\":\"new_task\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, mount, "\"e\":[\"enter\"]") != null);
    try std.testing.expect(std.mem.indexOf(u8, mount, "\"placeholder\":\"Add a new task...\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, mount, "\"font\":28,\"bold\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, mount, "\"shadow\":\"sm\"") != null);
    try std.testing.expectEqual(@as(usize, 2), countOccurrences(mount, "\"t\":\"card\""));
    try std.testing.expect(std.mem.indexOf(u8, mount, "0 of 2 done") != null);
    // every node carries an id
    try std.testing.expect(countOccurrences(mount, "\"i\":") >= 10);

    // --- typing into a bound input ----------------------------------------
    // Snapshot ids, not node pointers: every render frees the previous tree.
    const input_id = findByTag(s.root.?, "input").?.id;
    const typed = try value.makeStr("Ship the prototype");
    try s.dispatchInput(input_id, typed, "input");
    const new_task_idx = s.store.indexOf("new_task").?;
    try std.testing.expectEqualStrings("Ship the prototype", s.store.peek(new_task_idx).str.bytes);

    // --- enter: append + clear --------------------------------------------
    try s.dispatchEvent(input_id, "enter", value.Value{ .nil = {} });
    const tasks_idx = s.store.indexOf("tasks").?;
    try std.testing.expectEqual(@as(usize, 3), s.store.peek(tasks_idx).list.items.items.len);
    try std.testing.expectEqual(@as(usize, 0), s.store.peek(new_task_idx).str.bytes.len);

    try std.testing.expect(wire.frames.items.len > 2);
    var inserts: usize = 0;
    for (wire.frames.items[2..]) |f| inserts += countOccurrences(f, "\"o\":\"i\"");
    try std.testing.expectEqual(@as(usize, 1), inserts);
    // the inserted card is the new task, and the computed summary followed
    try std.testing.expect(std.mem.indexOf(u8, wire.last(), "Ship the prototype") != null);
    try std.testing.expect(std.mem.indexOf(u8, wire.last(), "0 of 3 done") != null);
    // the input's value prop was reset to ""
    try std.testing.expect(std.mem.indexOf(u8, wire.last(), "\"p\":{\"value\":\"\"}") != null);

    // --- click: remove + increment ----------------------------------------
    var buttons = std.ArrayList(*vdom.Node).init(value.alloc);
    defer buttons.deinit();
    findAllByTag(s.root.?, "button", &buttons);
    try std.testing.expectEqual(@as(usize, 3), buttons.items.len);
    const first_button_id = buttons.items[0].id;
    const second_button_id = buttons.items[1].id;

    const before = wire.frames.items.len;
    try s.dispatchEvent(first_button_id, "click", value.Value{ .nil = {} });
    try std.testing.expectEqual(@as(usize, 2), s.store.peek(tasks_idx).list.items.items.len);
    try std.testing.expectEqual(@as(i64, 1), s.store.peek(s.store.indexOf("done_count").?).int);

    var removals: usize = 0;
    for (wire.frames.items[before..]) |f| removals += countOccurrences(f, "\"o\":\"r\"");
    try std.testing.expect(removals >= 1);
    try std.testing.expect(std.mem.indexOf(u8, wire.last(), "1 of 2 done") != null);
    // the surviving cards were reused, not re-inserted
    var later_inserts: usize = 0;
    for (wire.frames.items[before..]) |f| later_inserts += countOccurrences(f, "\"o\":\"i\"");
    try std.testing.expectEqual(@as(usize, 0), later_inserts);

    try std.testing.expect(s.stats.renders >= 3);

    // --- a second click, using an id captured before the first re-render ---
    try s.dispatchEvent(second_button_id, "click", value.Value{ .nil = {} });
    try std.testing.expectEqual(@as(usize, 1), s.store.peek(tasks_idx).list.items.items.len);
    try std.testing.expectEqual(@as(i64, 2), s.store.peek(s.store.indexOf("done_count").?).int);
    try std.testing.expect(std.mem.indexOf(u8, wire.last(), "2 of 1 done") != null);

    // --- one more round trip: type, then enter ----------------------------
    const typed2 = try value.makeStr("Write the docs");
    try s.dispatchInput(input_id, typed2, "input");
    try s.dispatchEvent(input_id, "enter", value.Value{ .nil = {} });
    try std.testing.expectEqual(@as(usize, 2), s.store.peek(tasks_idx).list.items.items.len);
    try std.testing.expectEqual(@as(usize, 0), s.store.peek(new_task_idx).str.bytes.len);
    try std.testing.expect(std.mem.indexOf(u8, wire.last(), "2 of 2 done") != null);
    try std.testing.expect(std.mem.indexOf(u8, wire.last(), "Write the docs") != null);
    // ids are stable across every re-render, so the client never re-mounts
    try std.testing.expectEqual(input_id, findByTag(s.root.?, "input").?.id);
}


const timer_source =
    \\app TimerApp:
    \\    state:
    \\        n = 0
    \\        label = "idle"
    \\
    \\    view:
    \\        stack:
    \\            text("{label}: {n}")
    \\            button("Go", click: {
    \\                label = "waiting"
    \\                after 50:
    \\                    n += 1
    \\                    label = "done"
    \\            })
;

test "session: `after` arms a timer the session fires on tick" {
    value.useAllocator(std.testing.allocator);
    var rep = diag.Reporter.init(value.alloc, null);
    defer rep.deinit();
    var src: diag.Source = undefined;
    defer src.deinit();
    const unit = compileSource(value.alloc, timer_source, &rep, &src) catch {
        const txt = try rep.render(false);
        std.debug.print("{s}\n", .{txt});
        return error.Failed;
    };
    defer if (test_arena) |ta| {
        ta.deinit();
        value.alloc.destroy(ta);
        test_arena = null;
    };

    var wire = Wire.init(value.alloc);
    defer wire.deinit();
    const s = try session.Session.create(value.alloc, unit, "timer.weave", Wire.send, @ptrCast(&wire));
    defer s.destroy();
    try s.start();


    var buttons = std.ArrayList(*vdom.Node).init(value.alloc);
    defer buttons.deinit();
    findAllByTag(s.root.?, "button", &buttons);
    try std.testing.expectEqual(@as(usize, 1), buttons.items.len);
    const go_id = buttons.items[0].id;

    try s.dispatchEvent(go_id, "click", value.Value{ .nil = {} });
    try std.testing.expectEqualStrings("waiting", s.store.peek(s.store.indexOf("label").?).str.bytes);
    try std.testing.expectEqual(@as(i64, 0), s.store.peek(s.store.indexOf("n").?).int);
    try std.testing.expectEqual(@as(usize, 1), s.timers.items.len);
    const due = s.timers.items[0].due_ms;

    // Not due yet: nothing happens.
    try s.tick(due - 1);
    try std.testing.expectEqual(@as(i64, 0), s.store.peek(s.store.indexOf("n").?).int);
    try std.testing.expectEqual(@as(usize, 1), s.timers.items.len);

    // Due: the body runs once and the queue drains.
    const frames_before = wire.frames.items.len;
    try s.tick(due);
    try std.testing.expectEqual(@as(i64, 1), s.store.peek(s.store.indexOf("n").?).int);
    try std.testing.expectEqualStrings("done", s.store.peek(s.store.indexOf("label").?).str.bytes);
    try std.testing.expectEqual(@as(usize, 0), s.timers.items.len);
    try std.testing.expect(wire.frames.items.len > frames_before);
    try std.testing.expect(std.mem.indexOf(u8, wire.last(), "done: 1") != null);
}

// --------------------------------------------------------------- engine ----
//
// `wasm.zig` is the headless engine a browser page drives: it compiles a whole
// `.weave` source (or loads `.wvbc`) and speaks the wire protocol over an
// in-memory frame queue instead of a socket. It ships as `weave-core.wasm`
// inside every `weave build --html` file, and it is compiled natively here so
// `zig build test` covers the page transport without a browser in sight.

const host = @import("host.zig");
const wasm = @import("wasm.zig");

const samples = @import("samples");

/// The shipped sample, verbatim: `weave build examples/todo.weave --html`
/// embeds exactly these bytes.
const todo_file_source = samples.todo;

const loggy_source =
    \\app Loggy:
    \\    state:
    \\        n = 0
    \\    handlers:
    \\        bump():
    \\            n += 1
    \\            log("n is {n}")
    \\    effects:
    \\        on_mount:
    \\            log("mounted")
    \\    view:
    \\        text("n={n}")
    \\        button("go", click: bump())
    \\
;

fn contains(hay: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, hay, needle) != null;
}

fn anyFrameContains(frames: []const []const u8, needle: []const u8) bool {
    for (frames) |f| if (contains(f, needle)) return true;
    return false;
}

fn jsonOf(a: std.mem.Allocator, text: []const u8) !std.json.Parsed(std.json.Value) {
    return std.json.parseFromSlice(std.json.Value, a, text, .{});
}

fn strOf(v: std.json.Value) ?[]const u8 {
    return switch (v) {
        .string => |s| s,
        else => null,
    };
}

fn strField(o: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const v = o.get(key) orelse return null;
    return strOf(v);
}

fn tagOf(node: std.json.Value) ?[]const u8 {
    return switch (node) {
        .object => |o| strField(o, "t"),
        else => null,
    };
}

/// Depth-first search of a wire-protocol node tree for the first node of `tag`.
fn findNode(node: std.json.Value, tag: []const u8) ?std.json.Value {
    switch (node) {
        .object => |o| {
            if (strField(o, "t")) |t| {
                if (std.mem.eql(u8, t, tag)) return node;
            }
            if (o.get("c")) |c| return findNode(c, tag);
            return null;
        },
        .array => |items| {
            for (items.items) |child| {
                if (findNode(child, tag)) |hit| return hit;
            }
            return null;
        },
        else => return null,
    }
}

/// How many nodes of `tag` are in this subtree?
fn countNodes(node: std.json.Value, tag: []const u8) usize {
    var n: usize = 0;
    switch (node) {
        .object => |o| {
            if (o.get("t")) |t| {
                if (std.mem.eql(u8, strOf(t) orelse "", tag)) n += 1;
            }
            if (o.get("c")) |c| n += countNodes(c, tag);
        },
        .array => |items| {
            for (items.items) |child| n += countNodes(child, tag);
        },
        else => {},
    }
    return n;
}

fn nodeId(node: std.json.Value) !i64 {
    const v = node.object.get("i") orelse return error.NoId;
    return switch (v) {
        .integer => |n| n,
        .float => |f| @intFromFloat(f),
        else => error.NoId,
    };
}

/// Everything the engine has queued since the last call. The slices live in the
/// engine arena, so they stay valid until `destroy()`.
fn drain(a: std.mem.Allocator, e: *wasm.Engine) !std.ArrayList([]const u8) {
    var out = std.ArrayList([]const u8).init(a);
    errdefer out.deinit();
    while (e.nextFrame()) |f| try out.append(f);
    return out;
}

test "engine: source app boots and mounts exactly as the page sees it" {
    value.useAllocator(std.testing.allocator);
    const a = std.testing.allocator;

    var diags: []const u8 = "";
    defer if (diags.len > 0) a.free(diags);

    const e = try wasm.Engine.create(a, "todo.weave", todo_file_source, .source, &diags);
    defer e.destroy();

    try std.testing.expectEqualStrings("TodoApp", e.appName());
    try std.testing.expectEqual(@as(usize, 0), diags.len);

    try e.start();
    var frames = try drain(a, e);
    defer frames.deinit();
    try std.testing.expectEqual(@as(usize, 2), frames.items.len);

    var hello = try jsonOf(a, frames.items[0]);
    defer hello.deinit();
    try std.testing.expectEqualStrings("hello", strField(hello.value.object, "t").?);
    try std.testing.expectEqualStrings("TodoApp", strField(hello.value.object, "app").?);

    var mount = try jsonOf(a, frames.items[1]);
    defer mount.deinit();
    try std.testing.expectEqualStrings("mount", strField(mount.value.object, "t").?);
    const root = mount.value.object.get("root") orelse return error.NoRoot;
    try std.testing.expectEqualStrings("stack", tagOf(root).?);

    // The bound input is there, wired to `new_task` and listening for Enter, and
    // the two seeded tasks rendered as two cards.
    try std.testing.expectEqual(@as(usize, 2), countNodes(root, "card"));
    try std.testing.expectEqual(@as(usize, 2), countNodes(root, "button"));
    const input = findNode(root, "input") orelse return error.NoInput;
    try std.testing.expectEqualStrings("new_task", strField(input.object, "b").?);
    const events = input.object.get("e") orelse return error.NoEvents;
    var has_enter = false;
    for (events.array.items) |ev| {
        if (std.mem.eql(u8, strOf(ev) orelse "", "enter")) has_enter = true;
    }
    try std.testing.expect(has_enter);
}

test "engine: typing, Enter and click all come back as patches" {
    value.useAllocator(std.testing.allocator);
    const a = std.testing.allocator;

    var diags: []const u8 = "";
    defer if (diags.len > 0) a.free(diags);
    const e = try wasm.Engine.create(a, "todo.weave", todo_file_source, .source, &diags);
    defer e.destroy();
    try e.start();

    var frames = try drain(a, e);
    defer frames.deinit();
    var mount = try jsonOf(a, frames.items[1]);
    defer mount.deinit();
    const input_id = try nodeId(findNode(mount.value.object.get("root").?, "input").?);

    var msg: [256]u8 = undefined;

    // Typing into a bound input echoes the value straight back.
    const typed = try std.fmt.bufPrint(
        &msg,
        "{{\"t\":\"input\",\"id\":{d},\"value\":\"Ship the prototype\"}}",
        .{input_id},
    );
    try e.dispatch(typed);
    frames = try drainInto(a, e, frames);
    try std.testing.expect(anyFrameContains(frames.items, "\"value\":\"Ship the prototype\""));

    // Enter runs `on_enter`, which appends to `tasks` and clears the input.
    const enter = try std.fmt.bufPrint(
        &msg,
        "{{\"t\":\"event\",\"id\":{d},\"name\":\"enter\",\"args\":[]}}",
        .{input_id},
    );
    try e.dispatch(enter);
    frames = try drainInto(a, e, frames);
    try std.testing.expect(anyFrameContains(frames.items, "\"o\":\"i\"")); // a card was inserted
    try std.testing.expect(anyFrameContains(frames.items, "\"value\":\"\"")); // and the input cleared

    // The freshly rendered Done button closes over its own task.
    var button_id: ?i64 = null;
    for (frames.items) |f| {
        var p = try jsonOf(a, f);
        defer p.deinit();
        const ops = p.value.object.get("ops") orelse continue;
        for (ops.array.items) |op| {
            const n = op.object.get("n") orelse continue;
            if (findNode(n, "button")) |btn| {
                button_id = try nodeId(btn);
                break;
            }
        }
        if (button_id != null) break;
    }
    const click = try std.fmt.bufPrint(
        &msg,
        "{{\"t\":\"event\",\"id\":{d},\"name\":\"click\",\"args\":[]}}",
        .{button_id orelse return error.NoButton},
    );
    try e.dispatch(click);
    frames = try drainInto(a, e, frames);
    try std.testing.expect(anyFrameContains(frames.items, "\"o\":\"r\"")); // the card went away
}

fn drainInto(a: std.mem.Allocator, e: *wasm.Engine, into: std.ArrayList([]const u8)) !std.ArrayList([]const u8) {
    var out = into;
    while (e.nextFrame()) |f| try out.append(f);
    _ = a;
    return out;
}

test "engine: bytecode loads, bad input reports, nothing crashes" {
    value.useAllocator(std.testing.allocator);
    const a = std.testing.allocator;

    var d1: []const u8 = "";
    const garbage = wasm.Engine.create(a, "x.wvbc", "not bytecode at all", .bytecode, &d1);
    try std.testing.expectError(error.BadBytecode, garbage);
    try std.testing.expect(contains(d1, "not a .wvbc file"));
    a.free(d1);

    // A source that does not parse comes back as text, not as a crash.
    var d2: []const u8 = "";
    const broken =
        \\app Broken:
        \\    view:
        \\        text("unterminated
        \\
    ;
    const bad_src = wasm.Engine.create(a, "broken.weave", broken, .source, &d2);
    try std.testing.expectError(error.Diagnostics, bad_src);
    // "[E001]: unterminated string literal --> broken.weave:3:14"
    try std.testing.expect(contains(d2, "E001"));
    try std.testing.expect(contains(d2, "unterminated"));
    try std.testing.expect(contains(d2, "broken.weave"));
    a.free(d2);

    // A real round trip: compile the sample, serialise it, boot from the bytes.
    var d3: []const u8 = "";
    defer if (d3.len > 0) a.free(d3);
    const e = try wasm.Engine.create(a, "todo.weave", todo_file_source, .source, &d3);
    defer e.destroy();

    var enc = bytecode.Encoder.init(a);
    defer enc.deinit();
    const blob = try enc.encodeUnit(e.unit);
    defer a.free(blob);

    var d4: []const u8 = "";
    defer if (d4.len > 0) a.free(d4);
    const e2 = try wasm.Engine.create(a, "todo.wvbc", blob, .bytecode, &d4);
    defer e2.destroy();
    try std.testing.expectEqualStrings("TodoApp", e2.appName());
    try e2.start();
    var frames = try drain(a, e2);
    defer frames.deinit();
    try std.testing.expect(anyFrameContains(frames.items, "\"t\":\"mount\""));
}

/// A handler that raises must not take the page down with it.
const boom_source =
    \\app Boom:
    \\    state:
    \\        items = ["a"]
    \\        clicks = 0
    \\    handlers:
    \\        go():
    \\            clicks += 1
    \\        explode():
    \\            clicks += items[99].len()
    \\    view:
    \\        text("clicks={clicks}")
    \\        button("ok", click: go())
    \\        button("boom", click: explode())
    \\
;

test "engine: a runtime error becomes an error frame and the page lives on" {
    value.useAllocator(std.testing.allocator);
    const a = std.testing.allocator;

    var diags: []const u8 = "";
    defer if (diags.len > 0) a.free(diags);
    const e = try wasm.Engine.create(a, "boom.weave", boom_source, .source, &diags);
    defer e.destroy();
    try e.start();

    var frames = try drain(a, e);
    defer frames.deinit();
    var mount = try jsonOf(a, frames.items[1]);
    defer mount.deinit();
    const root = mount.value.object.get("root").?;

    // Two buttons: "ok" and "boom", in source order.
    var ids = std.ArrayList(i64).init(a);
    defer ids.deinit();
    try collectNodes(root, "button", &ids);
    try std.testing.expectEqual(@as(usize, 2), ids.items.len);

    var msg: [128]u8 = undefined;
    const boom = try std.fmt.bufPrint(
        &msg,
        "{{\"t\":\"event\",\"id\":{d},\"name\":\"click\",\"args\":[]}}",
        .{ids.items[1]},
    );
    try e.dispatch(boom);
    frames = try drainInto(a, e, frames);
    try std.testing.expect(anyFrameContains(frames.items, "\"t\":\"error\""));

    // The session survived: the next event still renders a patch.
    const ok = try std.fmt.bufPrint(
        &msg,
        "{{\"t\":\"event\",\"id\":{d},\"name\":\"click\",\"args\":[]}}",
        .{ids.items[0]},
    );
    frames.clearRetainingCapacity();
    try e.dispatch(ok);
    frames = try drainInto(a, e, frames);
    try std.testing.expect(anyFrameContains(frames.items, "\"t\":\"patch\""));
}

/// Every node id of `tag`, in document order.
fn collectNodes(node: std.json.Value, tag: []const u8, out: *std.ArrayList(i64)) !void {
    switch (node) {
        .object => |o| {
            if (o.get("t")) |t| {
                if (std.mem.eql(u8, strOf(t) orelse "", tag)) {
                    if (o.get("i")) |i| {
                        switch (i) {
                            .integer => |n| try out.append(n),
                            else => {},
                        }
                    }
                }
            }
            if (o.get("c")) |c| try collectNodes(c, tag, out);
        },
        .array => |items| {
            for (items.items) |child| try collectNodes(child, tag, out);
        },
        else => {},
    }
}

test "engine: effects and log() reach the page, and timers tick" {
    value.useAllocator(std.testing.allocator);
    const a = std.testing.allocator;

    var diags: []const u8 = "";
    defer if (diags.len > 0) a.free(diags);
    const e = try wasm.Engine.create(a, "loggy.weave", loggy_source, .source, &diags);
    defer e.destroy();
    try e.start();

    var frames = try drain(a, e);
    defer frames.deinit();
    // on_mount ran while the page was still booting.
    try std.testing.expect(contains(host.takeLog(), "mounted"));

    var mount = try jsonOf(a, frames.items[1]);
    defer mount.deinit();
    const btn_id = try nodeId(findNode(mount.value.object.get("root").?, "button").?);

    var msg: [128]u8 = undefined;
    const click = try std.fmt.bufPrint(&msg, "{{\"t\":\"event\",\"id\":{d},\"name\":\"click\",\"args\":[]}}", .{btn_id});
    try e.dispatch(click);
    frames = try drainInto(a, e, frames);
    try std.testing.expect(anyFrameContains(frames.items, "\"t\":\"patch\""));
    try std.testing.expect(contains(host.takeLog(), "n is 1"));

    // A page also keeps the connection warm and drives the clock: a ping is
    // answered, and a tick with nothing due sends no frame at all.
    try e.dispatch("{\"t\":\"ping\"}");
    frames = try drainInto(a, e, frames);
    try std.testing.expect(anyFrameContains(frames.items, "\"t\":\"pong\""));

    const before = frames.items.len;
    try e.tick(1_700_000_000_000);
    frames = try drainInto(a, e, frames);
    try std.testing.expectEqual(before, frames.items.len);
}
