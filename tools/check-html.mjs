#!/usr/bin/env node
// Verify pages exported by `weave build --html`.
//
//   node tools/check-html.mjs dist/todo.html [more.html ...]
//
// There is no browser here, so this does exactly what the page does: lift the
// engine and the compiled app out of their base64 blocks, instantiate the
// WebAssembly, boot the app and drive it over the in-memory transport that
// `assets/client.js` picks up when `window.__WEAVE_LOCAL__` exists. If this
// passes, the file opens and runs — no server, no build step, no dependencies.
//
// Exit status is 0 when every page boots, 1 when one does not, 2 on bad usage.

import { readFileSync } from "node:fs";
import vm from "node:vm";

const pages = process.argv.slice(2);
if (pages.length === 0) {
  console.error("usage: node tools/check-html.mjs <page.html> [...]");
  process.exit(2);
}

let failures = 0;
for (const page of pages) {
  try {
    console.log(await check(page));
  } catch (err) {
    failures += 1;
    console.error(`${page}: FAILED — ${err.message}`);
  }
}
process.exit(failures === 0 ? 0 : 1);

async function check(path) {
  const html = readFileSync(path, "utf8");
  const need = (cond, what) => {
    if (!cond) throw new Error(what);
  };
  const blockOrNull = (id) => {
    const m = html.match(new RegExp(`<script id="${id}"[^>]*>([\\s\\S]*?)</script>`));
    return m ? m[1].trim() : null;
  };
  const block = (id) => {
    const text = blockOrNull(id);
    if (text === null) throw new Error(`the page has no <script id="${id}"> block`);
    return text;
  };

  // 1. The page itself: one document, everything inline, local transport on.
  need(html.startsWith("<!DOCTYPE html>"), "not an HTML document");
  need(html.includes("<style>"), "styles are not inline");
  need(html.includes("__WEAVE_LOCAL__"), "the local transport boot script is missing");
  need(html.includes('id="app"'), "no #app mount point");
  need(!/src="https?:/.test(html), "the page reaches out to the network");

  const core = Buffer.from(block("weave-core-b64"), "base64");
  const app = Buffer.from(block("weave-app-b64"), "base64");
  // A page built from a `.wvbc` carries no source text, and that is fine: the
  // bytecode is the app. Everything else has to be there.
  const source = blockOrNull("weave-source");
  need(core.subarray(0, 4).toString("latin1") === "\0asm", "the engine blob is not WebAssembly");
  need(app.subarray(0, 4).toString("latin1") === "WVBC", "the app blob is not .wvbc");
  if (source !== null) {
    need(source.startsWith("app ") || source.startsWith("#"), "the readable source block looks wrong");
  }

  // 2. Boot the engine the way the page does.
  const { instance } = await WebAssembly.instantiate(core, {});
  const ex = instance.exports;
  for (const fn of ["weave_alloc", "weave_load", "weave_start", "weave_dispatch", "weave_tick", "weave_next_frame", "weave_app_name", "weave_diagnostics", "weave_take_log", "weave_reset"]) {
    need(typeof ex[fn] === "function", `the engine does not export ${fn}()`);
  }

  const mem = () => new Uint8Array(ex.memory.buffer);
  const enc = new TextEncoder();
  const dec = new TextDecoder();
  const readStr = (packed) => {
    const bits = BigInt.asUintN(64, BigInt(packed));
    const ptr = Number(bits >> 32n);
    const len = Number(bits & 0xffffffffn);
    return len === 0 ? "" : dec.decode(mem().subarray(ptr, ptr + len));
  };
  const write = (bytes) => {
    const ptr = ex.weave_alloc(bytes.length);
    if (ptr === 0) throw new Error("weave_alloc returned 0 (out of memory)");
    mem().set(bytes, ptr);
    return ptr;
  };
  const drain = () => {
    const out = [];
    let frame;
    while ((frame = ex.weave_next_frame()) !== 0n) out.push(readStr(frame));
    return out;
  };
  const send = (msg) => {
    const bytes = enc.encode(JSON.stringify(msg));
    const ptr = write(bytes);
    const rc = ex.weave_dispatch(ptr, bytes.length);
    if (rc !== 0) throw new Error(`weave_dispatch(${msg.t}) returned ${rc}: ${readStr(ex.weave_diagnostics())}`);
    return drain();
  };

  const boot = (bytes, kind) => {
    const ptr = write(bytes);
    const rc = ex.weave_load(ptr, bytes.length, kind);
    if (rc !== 0) throw new Error(`weave_load returned ${rc}: ${readStr(ex.weave_diagnostics())}`);
    const name = readStr(ex.weave_app_name());
    need(name.length > 0, "the engine reported no app name");
    if (ex.weave_start() !== 0) throw new Error(`weave_start failed: ${readStr(ex.weave_diagnostics())}`);
    return { name, frames: drain() };
  };

  // 3. The compiled app: hello, then a mount tree.
  const first = boot(app, 1);
  const hello = JSON.parse(first.frames[0]);
  const mount = JSON.parse(first.frames[1]);
  need(hello.t === "hello", `expected a hello frame, got ${hello.t}`);
  need(hello.app === first.name, `hello says ${hello.app}, engine says ${first.name}`);
  need(mount.t === "mount" && mount.root && typeof mount.root.t === "string", "the mount frame has no root node");

  // 4. The transport still answers, and the clock can be driven.
  const pong = send({ t: "ping" });
  need(pong.some((f) => f.includes('"t":"pong"')), "no pong came back");
  need(ex.weave_tick(Date.now()) === 0, "weave_tick failed");

  const log = readStr(ex.weave_take_log());
  const dropped = ex.weave_log_dropped();
  need(dropped === 0, `${dropped} log bytes were dropped before the page could read them`);

  // 5. The readable source in the page compiles in-browser too, so a person can
  //    edit the file and reload without ever running `weave`.
  let sourceNote = "built from .wvbc, no source embedded";
  if (source !== null) {
    ex.weave_reset();
    const second = boot(enc.encode(source), 0);
    need(second.name === first.name, `the source block compiles to ${second.name}, the bytecode to ${first.name}`);
    need(second.frames.length >= 2, "the source build did not emit hello + mount");
    sourceNote = "source recompiles in-page";
  }

  // 6. Render it. The page's own boot script and the real client.js run against
  //    a DOM just large enough to mount a tree, so this checks the renderer and
  //    the local transport too — not only the engine.
  const rendered = renderPage(html);

  const kb = (n) => `${(n / 1024).toFixed(0)} KB`;
  return [
    `${path}: ok`,
    `    app ${first.name}  page ${kb(html.length)}  engine ${kb(core.length)}  bytecode ${kb(app.length)}`,
    `    ${first.frames.length} frames, root <${mount.root.t}>, ${countNodes(mount.root)} nodes; ${sourceNote}`,
    `    page renders: ${rendered.elements} elements, ${rendered.texts} text node(s), ${rendered.fired} interaction(s) driven, transport ${rendered.transport}`,
    rendered.note ? `    note: ${rendered.note}` : null,
    log.trim() ? `    log: ${log.trim().split("\n")[0]}` : null,
  ]
    .filter(Boolean)
    .join("\n");
}

function countNodes(node) {
  if (!node || typeof node !== "object") return 0;
  let n = 1;
  for (const child of node.c || []) n += countNodes(child);
  return n;
}

// --------------------------------------------------------------------------
// A DOM just large enough for assets/client.js: elements, text nodes, styles,
// attributes and listeners. No layout, no parsing — the point is to prove the
// exported page mounts a tree and responds to events, using its own boot script
// and the same client the server-backed app uses.
// --------------------------------------------------------------------------

function makeDom() {
  const makeStyle = () => {
    const s = {};
    s.setProperty = (k, v) => {
      s[k] = v;
    };
    s.removeProperty = (k) => {
      delete s[k];
    };
    return s;
  };
  const el = (tag) => {
    const n = {
      nodeType: 1,
      tagName: String(tag).toUpperCase(),
      childNodes: [],
      attrs: {},
      listeners: {},
      style: makeStyle(),
      textContent: "",
      value: "",
      checked: false,
      parentNode: null,
      id: "",
      appendChild(c) {
        c.parentNode = n;
        n.childNodes.push(c);
        return c;
      },
      insertBefore(c, ref) {
        c.parentNode = n;
        const i = ref ? n.childNodes.indexOf(ref) : -1;
        if (i < 0) n.childNodes.push(c);
        else n.childNodes.splice(i, 0, c);
        return c;
      },
      removeChild(c) {
        const i = n.childNodes.indexOf(c);
        if (i >= 0) n.childNodes.splice(i, 1);
        c.parentNode = null;
        return c;
      },
      setAttribute(k, v) {
        n.attrs[k] = String(v);
      },
      getAttribute(k) {
        return k in n.attrs ? n.attrs[k] : null;
      },
      removeAttribute(k) {
        delete n.attrs[k];
      },
      addEventListener(t, fn) {
        (n.listeners[t] = n.listeners[t] || []).push(fn);
      },
      removeEventListener(t, fn) {
        const list = n.listeners[t] || [];
        const i = list.indexOf(fn);
        if (i >= 0) list.splice(i, 1);
      },
      fire(t, ev) {
        for (const fn of n.listeners[t] || []) fn.call(n, ev);
      },
    };
    Object.defineProperty(n, "children", {
      get: () => n.childNodes.filter((c) => c.nodeType === 1),
    });
    Object.defineProperty(n, "firstChild", {
      get: () => n.childNodes[0] || null,
    });
    return n;
  };
  const byId = {};
  for (const id of ["app", "weave-error", "weave-status"]) {
    byId[id] = el("div");
    byId[id].id = id;
  }
  const document = {
    title: "",
    activeElement: null,
    createElement: el,
    createTextNode: (t) => ({ nodeType: 3, textContent: String(t), childNodes: [], parentNode: null }),
    getElementById: (id) => byId[id] || null,
  };
  return { document, byId, el };
}

// Function declarations, not arrow consts: `check()` runs before this point in
// the file, and a const would still be in its temporal dead zone.
function walk(node, fn) {
  fn(node);
  for (const c of node.childNodes || []) walk(c, fn);
}

function countElements(node) {
  let n = 0;
  walk(node, (c) => {
    if (c.nodeType === 1) n += 1;
  });
  return n;
}

function collectText(node) {
  const out = [];
  walk(node, (c) => {
    if (c.nodeType === 3 && c.textContent) out.push(c.textContent);
  });
  return out;
}

function renderPage(html) {
  const fail = (what) => {
    throw new Error(what);
  };
  const dom = makeDom();

  // The data blocks the page's boot script reads with getElementById + atob.
  for (const id of ["weave-core-b64", "weave-app-b64", "weave-source"]) {
    const m = html.match(new RegExp(`<script id="${id}"[^>]*>([\\s\\S]*?)</script>`));
    if (!m) continue;
    const node = dom.el("script");
    node.id = id;
    node.textContent = m[1].trim();
    dom.byId[id] = node;
  }

  // Then the two plain <script> bodies: the boot script, and the client.
  const scripts = [...html.matchAll(/<script(?![^>]*\bid=)[^>]*>([\s\S]*?)<\/script>/g)].map((m) => m[1]);
  if (scripts.length < 2) fail("the page is missing its boot script or its client");

  const timers = [];
  const sandbox = {
    document: dom.document,
    console: { log() {}, warn() {}, error() {} },
    Date,
    JSON,
    Math,
    TextEncoder,
    TextDecoder,
    WebAssembly,
    Uint8Array,
    BigInt,
    atob: (s) => Buffer.from(s, "base64").toString("binary"),
    setInterval: (fn, ms) => {
      timers.push({ fn, ms });
      return timers.length;
    },
    setTimeout: (fn, ms) => {
      timers.push({ fn, ms, once: true });
      return timers.length;
    },
    WebSocket: function () {
      fail("the page opened a WebSocket instead of running its own engine");
    },
    location: { protocol: "file:", host: "" },
  };
  sandbox.window = sandbox;
  const ctx = vm.createContext(sandbox);

  vm.runInContext(scripts[0], ctx, { filename: "weave-boot.js" });
  const local = sandbox.__WEAVE_LOCAL__;
  if (!local) fail("the boot script did not define window.__WEAVE_LOCAL__");
  if (local.loadStatus !== 0) fail(`the embedded app did not load (status ${local.loadStatus})`);

  vm.runInContext(scripts[1], ctx, { filename: "weave-client.js" });
  const weave = sandbox.weave;
  if (!weave) fail("client.js did not expose window.weave");
  if (weave.transport !== "wasm") fail(`the client chose the ${weave.transport} transport, not the in-page engine`);

  const app = dom.byId.app;
  if (app.children.length === 0) fail("the page mounted nothing into #app");
  const errEl = dom.byId["weave-error"];
  const shown = () => errEl.style.display && errEl.style.display !== "none";
  if (shown()) fail(`the page reported an error on load: ${errEl.textContent}`);

  // The 50 ms tick is what drives `after <ms>:` timers in a page.
  const tick = timers.find((t) => t.ms === 50);
  if (!tick) fail("the client never started the local tick loop");
  tick.fn();

  // Drive every listener the render installed, the way a person would.
  const nodes = [];
  walk(app, (n) => nodes.push(n));
  let fired = 0;
  for (const n of nodes) {
    if (n.nodeType !== 1) continue;
    for (const type of Object.keys(n.listeners || {})) {
      if (type === "input" || type === "change") n.value = "typed by check-html";
      const ev = { type, key: "Enter", target: n, preventDefault() {}, stopPropagation() {} };
      n.fire(type, ev);
      fired += 1;
    }
  }

  let note = null;
  if (shown()) {
    // An app may raise on purpose (the language fixture does); that is a note,
    // not a broken page — it mounted and it answered events first.
    note = `an interaction raised: ${String(errEl.textContent).split("\n")[0]}`;
  }

  return {
    transport: weave.transport,
    app: weave.app,
    elements: countElements(app),
    texts: collectText(app).length,
    fired,
    note,
  };
}
