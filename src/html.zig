//! `weave build --html` — one self-contained page that runs the app.
//!
//! The output embeds three things as data: the WebAssembly engine built from
//! `src/wasm.zig`, the app's compiled `.wvbc` bytecode, and the browser client.
//! There is no server, no network and no build step at the other end: opening the
//! file instantiates the engine, loads the bytecode, and the same renderer that
//! `weave serve` drives takes over. Interaction stays server-authoritative in
//! shape — the engine runs the real VM, and the DOM only ever applies the frames
//! it emits — so an exported app behaves exactly like the hosted one.
//!
//! The original source is included as inert text (`<script type="text/weave">`)
//! so the page is self-describing: view-source shows what built it.

const std = @import("std");

pub const Options = struct {
    app_name: []const u8,
    /// Original `.weave` text, embedded for reference. May be empty.
    source_text: []const u8,
    /// Compiled `.wvbc` bytes the page loads at startup.
    bytecode: []const u8,
    /// `weave-core.wasm`.
    wasm: []const u8,
    client_js: []const u8,
    client_css: []const u8,
};

pub fn render(alloc: std.mem.Allocator, o: Options) ![]u8 {
    var buf = std.ArrayList(u8).init(alloc);
    errdefer buf.deinit();
    const w = buf.writer();

    const wasm_b64 = try toBase64(alloc, o.wasm);
    defer alloc.free(wasm_b64);
    const app_b64 = try toBase64(alloc, o.bytecode);
    defer alloc.free(app_b64);
    const title = try escapeHtml(alloc, o.app_name);
    defer alloc.free(title);

    try w.writeAll(
        \\<!DOCTYPE html>
        \\<html lang="en">
        \\  <head>
        \\    <meta charset="utf-8" />
        \\    <meta name="viewport" content="width=device-width, initial-scale=1" />
        \\
    );
    try w.print("    <title>{s} — Weave</title>\n", .{title});
    try w.writeAll(
        \\    <meta name="generator" content="weave build --html" />
        \\    <link
        \\      rel="icon"
        \\      href="data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 32 32'%3E%3Crect width='32' height='32' rx='7' fill='%234f46e5'/%3E%3Cpath d='M7 11h18M7 16h18M7 21h12' stroke='white' stroke-width='2.4' stroke-linecap='round'/%3E%3C/svg%3E"
        \\    />
        \\    <style>
        \\
    );
    try w.writeAll(o.client_css);
    try w.writeAll(
        \\
        \\    </style>
        \\  </head>
        \\  <body>
        \\    <div id="app" class="weave-root"></div>
        \\    <div id="weave-error" class="weave-error" style="display: none"></div>
        \\    <div id="weave-status" class="weave-status" style="display: none"></div>
        \\
    );

    try w.print("    <script id=\"weave-core-b64\" type=\"application/base64\">{s}</script>\n", .{wasm_b64});
    try w.print("    <script id=\"weave-app-b64\" type=\"application/base64\">{s}</script>\n", .{app_b64});
    if (o.source_text.len > 0) {
        const src = try escapeScriptText(alloc, o.source_text);
        defer alloc.free(src);
        try w.print("    <script id=\"weave-source\" type=\"text/weave\">{s}</script>\n", .{src});
    }

    try w.writeAll("    <script>\n");
    try w.writeAll(boot_js);
    try w.writeAll("\n    </script>\n");

    try w.writeAll("    <script>\n");
    try w.writeAll(o.client_js);
    try w.writeAll("\n    </script>\n");
    try w.writeAll(
        \\  </body>
        \\</html>
        \\
    );

    return buf.toOwnedSlice();
}

/// Instantiate the embedded engine and expose it as `window.__WEAVE_LOCAL__`,
/// which is the transport client.js picks up instead of a WebSocket.
const boot_js =
    \\(function () {
    \\  "use strict";
    \\
    \\  function bytesOf(id) {
    \\    var el = document.getElementById(id);
    \\    var bin = atob(el.textContent.trim());
    \\    var out = new Uint8Array(bin.length);
    \\    for (var i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
    \\    return out;
    \\  }
    \\
    \\  function fail(msg) {
    \\    var el = document.getElementById("weave-error");
    \\    if (!el) return;
    \\    el.textContent = msg;
    \\    el.style.display = "block";
    \\  }
    \\
    \\  var core, app, inst;
    \\  try {
    \\    core = bytesOf("weave-core-b64");
    \\    app = bytesOf("weave-app-b64");
    \\    inst = new WebAssembly.Instance(new WebAssembly.Module(core), {});
    \\  } catch (e) {
    \\    fail("the embedded Weave engine did not start: " + e);
    \\    return;
    \\  }
    \\
    \\  var ex = inst.exports;
    \\
    \\  // Exported pointers come back as (ptr << 32) | len packed into an i64.
    \\  function readStr(packed) {
    \\    if (packed === 0n) return "";
    \\    var ptr = Number(packed >> 32n);
    \\    var len = Number(packed & 0xffffffffn);
    \\    if (len === 0) return "";
    \\    return new TextDecoder().decode(new Uint8Array(ex.memory.buffer, ptr, len));
    \\  }
    \\
    \\  // One buffer at a time: allocate, write, call one export.
    \\  function write(bytes) {
    \\    var ptr = ex.weave_alloc(bytes.length);
    \\    if (!ptr) throw new Error("out of memory in the Weave runtime");
    \\    new Uint8Array(ex.memory.buffer, ptr, bytes.length).set(bytes);
    \\    return ptr;
    \\  }
    \\
    \\  var status = 3;
    \\  try {
    \\    status = ex.weave_load(write(app), app.length, 1);
    \\  } catch (e) {
    \\    fail("the embedded app did not load: " + e);
    \\    return;
    \\  }
    \\
    \\  window.__WEAVE_LOCAL__ = {
    \\    kind: "wasm",
    \\    loadStatus: status,
    \\    start: function () {
    \\      if (status !== 0) return 1;
    \\      return ex.weave_start();
    \\    },
    \\    dispatch: function (json) {
    \\      var b = new TextEncoder().encode(json);
    \\      ex.weave_dispatch(write(b), b.length);
    \\    },
    \\    tick: function (nowMs) {
    \\      ex.weave_tick(nowMs);
    \\    },
    \\    nextFrame: function () {
    \\      return readStr(ex.weave_next_frame());
    \\    },
    \\    takeLog: function () {
    \\      return readStr(ex.weave_take_log());
    \\    },
    \\    logDropped: function () {
    \\      return ex.weave_log_dropped();
    \\    },
    \\    diagnostics: function () {
    \\      return readStr(ex.weave_diagnostics());
    \\    },
    \\    appName: function () {
    \\      return readStr(ex.weave_app_name());
    \\    },
    \\    source: function () {
    \\      var el = document.getElementById("weave-source");
    \\      return el ? el.textContent : "";
    \\    },
    \\  };
    \\
    \\  if (status !== 0) {
    \\    fail(readStr(ex.weave_diagnostics()) || "the embedded app failed to load (code " + status + ")");
    \\  }
    \\})();
;

fn toBase64(alloc: std.mem.Allocator, bytes: []const u8) ![]u8 {
    const out = try alloc.alloc(u8, std.base64.standard.Encoder.calcSize(bytes.len));
    _ = std.base64.standard.Encoder.encode(out, bytes);
    return out;
}

fn escapeHtml(alloc: std.mem.Allocator, s: []const u8) ![]u8 {
    var buf = std.ArrayList(u8).init(alloc);
    errdefer buf.deinit();
    for (s) |c| switch (c) {
        '&' => try buf.appendSlice("&amp;"),
        '<' => try buf.appendSlice("&lt;"),
        '>' => try buf.appendSlice("&gt;"),
        '"' => try buf.appendSlice("&quot;"),
        else => try buf.append(c),
    };
    return buf.toOwnedSlice();
}

/// The source is embedded as element text, so the only sequences that can break
/// out of it are `</script` and the HTML comment open.
fn escapeScriptText(alloc: std.mem.Allocator, s: []const u8) ![]u8 {
    var buf = std.ArrayList(u8).init(alloc);
    errdefer buf.deinit();
    var i: usize = 0;
    while (i < s.len) {
        if (std.ascii.startsWithIgnoreCase(s[i..], "</script")) {
            try buf.appendSlice("<\\/script");
            i += "</script".len;
            continue;
        }
        if (std.mem.startsWith(u8, s[i..], "<!--")) {
            try buf.appendSlice("<\\!--");
            i += 4;
            continue;
        }
        try buf.append(s[i]);
        i += 1;
    }
    return buf.toOwnedSlice();
}
