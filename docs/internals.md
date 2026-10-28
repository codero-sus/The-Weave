# How Weave works

Everything below is implemented in Zig 0.13 with no libC, no runtime dependencies and
no generated code. One binary contains the compiler, the VM, the reactive store, the
diff engine, the HTTP server, the WebSocket server and the browser client (embedded
with `@embedFile`).

The engine half of that — lexer through diff, everything except the sockets and the CLI —
is also compiled to WebAssembly (`src/wasm.zig`), so the same VM can run inside an
exported `.html` page with no server anywhere. `src/host.zig` is the only module that
knows which of the two worlds it is in.

```
.weave source ──► lexer ──► parser ──► AST ──► compiler ──► bytecode (.wvbc)
                                                                │
                                     ┌──────────────────────────┘
                                     ▼
                    VM  ──►  reactive store  ──►  vdom builder  ──►  diff
                                     │                                │
                                     ▼                                ▼
                              session (per connection)  ──►  JSON frames ──► browser
```

Source modules and what they own:

| File                 | Role                                                              |
| -------------------- | ----------------------------------------------------------------- |
| `src/diag.zig`       | Source file model, spans, diagnostics with carets and hints        |
| `src/lexer.zig`      | Tokens, INDENT/DEDENT, string escapes, brace-block detection       |
| `src/ast.zig`        | Normalised parse tree (app, sections, statements, expressions)     |
| `src/parser.zig`     | Recursive-descent parser, precedence climbing, error recovery      |
| `src/astprint.zig`   | `weave ast` — pretty-printer for the parse tree                    |
| `src/compiler.zig`   | AST → bytecode, name resolution, arity checks, view compilation    |
| `src/bytecode.zig`   | Instruction/func/unit types, `.wvbc` encoder + decoder, disassembler |
| `src/builtins.zig`   | Builtin table (ids, names, arity)                                  |
| `src/value.zig`      | Refcounted `Value`: nil, bool, int, float, string, list, map, callable |
| `src/vm.zig`         | Stack VM, method dispatch, closures, timers, stack traces          |
| `src/reactive.zig`   | Signals, dependency tracking, effect scheduler                     |
| `src/vdom.zig`       | Node tree + builder intrinsics the render function drives          |
| `src/diff.zig`       | Old vs new tree → minimal patch ops                                |
| `src/proto.zig`      | JSON wire format for frames, nodes and patch ops                   |
| `src/session.zig`    | One app instance per connection: start, dispatch, tick, settle     |
| `src/host.zig`       | Clock and log, pruned at comptime for wasm (no `std.posix` there)  |
| `src/ws.zig`         | Hand-rolled WebSocket: handshake, framing, masking, fragmentation  |
| `src/module.zig`     | Load a `.weave` or `.wvbc` file into a `CodeUnit`, hot-reload mtime |
| `src/server.zig`     | HTTP routing, static assets, upgrade, thread-per-connection        |
| `src/cli.zig`        | Argument parsing, commands, scaffold, help                         |
| `src/wasm.zig`       | Headless engine API: one app, a queue of JSON frames in and out    |
| `src/html.zig`       | Renders the single-file page: engine + bytecode + styles + client  |
| `src/package.zig`    | Build output formats, the executable payload trailer, embedded apps |
| `assets/`            | `index.html`, `client.js`, `client.css`, `weave-core.wasm`, embedded via `embed.zig` |
| `tools/`             | `copyfile.zig` (`zig build wasm`), `check-html.mjs` (boots an exported page in Node) |

---

## 1. Lexing

The lexer produces INDENT/DEDENT tokens so the parser never counts whitespace. The
indent stack compares the leading column of each logical line; a dedent to a column
that is not on the stack is an error, not a guess.

Inside brackets (`(`, `[`, `{`) INDENT/DEDENT are suppressed, which is what lets a
list literal or a handler block span lines. A `{` after `click:` opens a *statement
block* rather than a map literal — the lexer looks ahead for `key:` / `=` patterns to
decide, so `click: { count = 0 }` and `styles = { "gap": 8 }` both work.

Strings are scanned once: escapes (`\n \t \r \\ \" \' \0`) are decoded into an
arena-owned copy, while `\{` and `\}` are kept verbatim so the parser can tell an
escaped brace from an interpolation. Every owned buffer is tracked in `Lexer.owned`
and freed in `deinit`.

## 2. Parsing

A recursive-descent parser with precedence climbing for expressions. Two details
matter:

* **Body blocks.** A `{ … }` handler body reuses the statement parser but cannot rely
  on INDENT tokens, so `parseBodyBlock(header_span)` reconstructs statement boundaries
  from token line/column. This is what makes `if`/`for`/`after` nested inside a brace
  body parse correctly.
* **Interpolations.** `parseInterpolation` builds a sub-source for the text between
  `{` and `}`, runs a nested lexer + parser on it, and shifts the resulting spans back
  into the parent file's coordinate space so diagnostics point at the right column of
  the real line.

Error recovery: on a bad token the parser reports once and synchronises to the next
newline/DEDENT at the current depth, so one mistake does not cascade into a wall of
noise. A cap on reported errors prevents runaway output.

## 3. Compiling

`compiler.zig` walks the AST once and emits instructions into a `Func` per compiled
body: one init function per signal, one per handler, one per component, one per effect,
and one render function for the view.

Name resolution order (later entries never shadow earlier ones):

```
local slot → captured slot → signal → handler → component → builtin → keyword
```

Declarations deliberately beat builtins: a handler named `clear` or `sort` calls your
code, not the stdlib.

The result is a `CodeUnit`:

```zig
CodeUnit {
    app_name, render_fn,
    consts:   []Const,      // nil | bool | int | float | string
    funcs:    []Func,       // name, kind, params, locals, captures, code
    signals:  []Signal,     // name, kind(state|computed|theme|style), init_fn
    handlers: []Handler,    // name → func_idx
    components: []Component,// name → func_idx
    effects:  []Effect,     // func_idx, on_mount, label
}
```

`Func` slots are laid out `[params…, captures…, temps…]`. A closure instruction copies
the listed capture slots into a heap `Closure`, which the callee copies into its own
locals on entry — that is how `for task in tasks: button("Done", click: tasks.remove(task))`
keeps the right `task` per row.

**The view is compiled, not walked.** Element calls become builder intrinsics:

```
stack(padding: 24):            ui_begin  "stack"
    text("hi", font: 28)       <expr> ; ui_prop "font"
                               <expr> ; ui_text
button("go", click: bump(1))   <closure> ; ui_event "click"
for t in tasks key t:          … iter … ; ui_key
input(bind: draft)             ui_bind "draft"
```

Every body ends with `ui_end` + `ui_child`. More than one top-level node gets wrapped
in an implicit `stack`; an empty view yields a `box`. Rendering therefore costs one
function call and a linear instruction walk — there is no AST at runtime.

## 4. Bytecode format (`.wvbc`)

```
offset  field
0       magic  "WVBC"                    (4 bytes)
4       format version                   (u32, currently 1)
8       string count                     (u32)
12      strings: len (u32) + bytes …     (deduplicated; all names/keys/consts index here)
…       body length                      (u32)
…       body: app_name, render_fn, consts, funcs, signals, handlers, components, effects
```

Integers are fixed width and **little-endian** (`u8`, `u32`, `i32`, `i64`; floats go out
as their `u64` bit pattern), written with `std.mem.writeInt(…, .little)` rather than
`std.mem.toBytes`, so an artifact does not inherit the byte order of the machine that
compiled it. Nothing in the body is a raw struct image, so there is no padding or pointer
size baked in either: a `.wvbc` written by a Debug glibc build and one written by a
ReleaseSafe static musl build are byte-for-byte identical, and each loads in the other.
`bytecode.encodeUnit` writes the body into a scratch buffer first (ids are assigned as
it goes), then emits the header, string table and body. `bytecode.decode` rebuilds the
whole unit in an arena, and `Loaded` owns both the arena and the file bytes. The format
version in the header is the compatibility gate — a decoder that meets a version it does
not know refuses the file instead of guessing.

A `.wvbc` file is a complete program: `weave run app.wvbc` serves it without a lexer,
parser or compiler in the process. `weave dump` prints the disassembly of either form.

```
; weave bytecode v1  app=TodoApp
; 25 consts, 5 funcs, 2 signals

signals:
    0 state     tasks  (init fn 0)
    1 state     new_task  (init fn 1)

constants:
    0 "Learn Weave"
    1 "Ship something"
    2 ""
    3 "stack"
    4 "padding"
    …

fn 0 tasks <init> params=0 locals=0 captures=0
     0  const_           0 ; "Learn Weave"   (line 10)
     1  const_           1 ; "Ship something"   (line 10)
     2  list             2   (line 10)
     3  ret                (line 10)

fn 1 new_task <init> params=0 locals=0 captures=0
     0  const_           2 ; ""   (line 11)
     1  ret                (line 11)
```

## 5. Values

`Value` is a tagged union with refcounted heap boxes for strings, lists, maps and
closures; nil/bool/int/float are inline. A single global, thread-safe
`GeneralPurposeAllocator` backs everything (`value.alloc`), installed by
`initRuntime()` and replaced by `std.testing.allocator` in tests so every allocation
is leak-checked. `deinitRuntime()` reports leaks and returns a bool the binary turns
into an exit code.

Ownership rules the VM depends on:

* The operand stack holds one owned reference per slot. `push` transfers ownership in,
  `pop` transfers it out. Call instructions **take** their arguments from the stack
  (no extra retain).
* `Store.write` consumes the value it is given.
* Mutating a list or map in place calls `markMutated(v)`, which walks signal values
  (depth-limited) so views depending on the container re-render.

## 6. The VM

A stack machine over `Instr { op, a: i32, b: i32, line: u32 }`. Function calls are
native recursion with a depth cap (`max_call_depth = 200`) rather than a second stack.
Each call allocates its own `locals`, zero-fills, copies captures, then copies args.

Every executed instruction pushes a `TraceFrame` (function, instruction index, line)
onto a bounded ring, so a runtime failure can print a Weave-level stack trace with
source lines via `renderTrace`. `fail()` surfaces as `error.WeaveRuntime`; the session
turns it into an `error` frame and a server log line instead of killing the connection.

Arithmetic: `+` overloads string concatenation and list extension; integer `/` and
`**` produce floats, every other integer op stays integer. Method calls dispatch on
the receiver kind through a static name table (`.call_method`), so `xs.len()` never
allocates a lookup structure.

`schedule_after` pops a callable and a delay and arms a timer on the owning session.
The PRNG is a seeded xorshift64 — deterministic per session start, no OS entropy call.

## 7. Reactivity

Signals are unified under `SigKind { state, computed, theme, style }`, each with an
`init_fn`. Effects (including the render effect and computed recomputation) run inside
`beginTrack`/`endTrack`, which records every `sig` read into the effect's dependency
set.

`Store.flush()` is a bounded fixpoint: up to 16 passes, each running dirty effects in
priority order — computed (0), user effects (1), render (2). A write that does not
change the value (structural `deepEqual`) notifies nobody. If the fixpoint does not
converge, the cycle is reported rather than spun on forever.

## 8. Rendering and diffing

`Session.render()` calls the render function, which drives `vdom.Builder` into a fresh
tree; the previous tree is then diffed against it and destroyed.

`diff.diffNode` pairs children with `sameNode` (same tag, and keys must match when
either side carries one), using a cursor fast path for the common append-only case.
Removals are emitted first, then a simulated client id-list produces only the moves and
inserts actually needed. Matched nodes keep their ids, which is what makes a click on
id 42 still address the node the browser drew after several patches.

Patch ops:

| `o` | Meaning  | Fields                          |
| --- | -------- | ------------------------------- |
| `r` | remove   | `i`                             |
| `i` | insert   | `p` (parent), `a` (index), `n` (node) |
| `m` | move     | `i`, `p`, `a`                   |
| `u` | update   | `i`, optional `x` (text), `p` (props), `e` (events) |

A `null` prop value removes the prop.

## 9. Sessions

One `Session` per browser connection owns its signals, timers and render state:

```
create → start → (dispatchEvent | dispatchInput | tick)* → destroy
```

`start()` initialises signals from their `init_fn`s, marks computeds and effects dirty,
marks the render effect dirty, sends `hello`, runs one `flush()` (which produces the
`mount` frame), then runs `on_mount` effects once, untracked. Every dispatch ends in
`settle()` — flush, diff, send — so a handler that changes three signals produces one
patch frame. `tick(now_ms)` snapshots the due timers first, so a timer body that arms
a new timer cannot loop forever inside a single tick.

## 10. Server

Hand-rolled HTTP over `std.net`. There is no `std.http.Server` here because the socket
has to be hijacked mid-request for the WebSocket upgrade.

* One thread per connection. Each thread owns its session; shared state (the current
  module, the generation counter, the stop flag, the connection count) is atomic or
  mutex-guarded.
* `SO_RCVTIMEO = --poll` (default 50 ms) makes a blocking read the timer wheel: a
  timeout means "no client message", which is the cue to run `tick()`.
* Hot reload polls the source mtime every 200 ms. On change it compiles a new `Module`
  under a mutex, bumps `generation`, and every session whose generation is stale sends
  `reload` and closes. The browser reconnects and remounts against the new build.
  Retired modules are freed at shutdown, never while a session may reference them.
* Routes: `/` and `/index.html` (shell), `/client.js`, `/client.css`, `/favicon.ico`
  (204), `/health` (JSON), `/ws` (upgrade); anything else 404, non-GET 405.

The WebSocket implementation covers the handshake (`Sec-WebSocket-Accept` via SHA-1),
client-to-server masking, extended payload lengths, fragmented-message assembly,
ping/pong and close. A server receives masked frames and sends unmasked ones; the
client in `itest.zig` is the same code with `server_side = false`.

## 11. The browser client

`assets/client.js` (no framework, ~16 KB) keeps a mirror of the server's node table
keyed by id, applies patch ops directly to the DOM, and maps tags to elements through
a table with aliases (`column`→div, `btn`→button, `h1..h3`, `textfield`→input…).
Numeric props become pixels except for unitless ones (`opacity flex weight z order
grow shrink`); `align` becomes `align-items` on containers and `text-align` on text;
`shadow: sm|md|lg` and `radius: full` map to preset styles.

`bind` installs an input/change listener; while the field has focus the client ignores
echoed value patches so the caret does not jump. Disconnects reconnect with backoff,
a 25 s ping keeps proxies honest, and a runtime error frame raises an overlay.
`window.weave` exposes the transport and stats for debugging.

The renderer never talks to a socket directly. It talks to a `transport` object with
three members — `send(json)`, `close()` and an incoming-frame callback — and picks one at
startup:

* `connectSocket()` opens `ws://…/ws`, which is what `weave run` serves;
* `connectLocal()` uses `window.__WEAVE_LOCAL__`, the in-page engine, and ticks it every
  50 ms with `Date.now()` so `after <ms>:` timers fire without a socket poll.

Both end at the same `handleMessage(data)`, so a frame is a frame however it arrived.
`drainLocal()` is the local loop's other half: it pulls frames until the queue is empty,
forwards `log()` output to the console as `[weave] …`, and warns if the engine dropped log
bytes because the page stopped reading.

## 12. The in-page engine

`src/wasm.zig` is a sibling root source file (not imported by `main.zig`), compiled twice:

```sh
zig build wasm      # -> assets/weave-core.wasm, wasm32-freestanding, ReleaseSmall
zig build test      # -> the same file, natively, under the leak-checking allocator
```

It exposes an `Engine` — one app, one arena, a queue of JSON frames — and a dozen
`export fn`s over the top of it, because a page hosts a single app:

```
weave_alloc(len) -> ptr          scratch buffer for whatever the page hands in
weave_load(ptr, len, kind)       kind 0 = .weave source, 1 = .wvbc; 0 ok, 1 diagnostics,
                                 2 bad bytecode, 3 out of memory
weave_start()                    run signal initialisers, queue hello + mount
weave_dispatch(ptr, len)         one client message: event, input or ping
weave_tick(now_ms)               set the clock, fire due `after` timers
weave_next_frame() -> i64        oldest queued frame as (ptr << 32) | len, 0 when empty
weave_diagnostics() -> i64       compile text, or the last runtime error
weave_app_name() -> i64          from the `app Name:` declaration
weave_take_log() -> i64          `log()` output since the last read
weave_log_dropped() -> u32       log bytes lost because the page stopped reading
weave_reset()                    tear the app down
```

Three details that are easy to get wrong, and are therefore written down:

* **Only `build-exe -target wasm32-freestanding -rdynamic` works.** `-dynamic` on a
  library and `--no-entry` both fail on this target. The entry point is exported only for
  wasm (`@export(wasmEntry, …)` inside a `comptime` arch check), because a native test
  binary already has a `_start`.
* **Nothing in the wasm cone may touch `std.time`, `std.io.getStdErr` or `std.debug.print`.**
  Each pulls in `std.posix`, which does not exist on `wasm32-freestanding`. `src/host.zig`
  owns those three and prunes them at comptime; the result is a wasm module with **no
  imports at all**, only exports and its own memory.
* **The value allocator and the engine arena are different allocators.** `value.alloc` is
  process-wide and owns every refcounted box; a session or engine may be handed an arena
  instead. Anything that a `Value` can outlive — closure boxes and their capture slices,
  and the scratch strings from `displayString` — must be allocated *and* freed through
  `value.alloc`, or an arena-backed engine frees memory it never owned. The native engine
  tests exist mainly to keep that rule true.

Diagnostics are allocated from the engine's parent, not its arena: on a compile error the
arena is torn down before the caller reads the text, and a page that loads a broken app
must still be able to show why.

The build is byte-for-byte reproducible (same bytes from `zig build wasm` and from a bare
`zig build-exe`), which is what makes the committed blob checkable: CI runs `zig build wasm`
and fails if `assets/weave-core.wasm` differs from what is in git.

## 13. Exporting

`src/package.zig` owns the three output formats and `src/html.zig` renders the page.

* **`.wvbc`** — `bytecode.encodeUnit`, unchanged from what `weave run` loads.
* **`.html`** — `html.render` writes one document: inlined `client.css`, the mount point,
  the engine and the bytecode as base64 in `<script type="application/base64">` blocks
  (never fetched, so `file://` works), the readable source in
  `<script type="text/weave">`, a boot script that defines `window.__WEAVE_LOCAL__`, and
  inlined `client.js`. Text goes through `escapeHtml`; script bodies through
  `escapeScriptText`, which breaks up `</script` and `<!--` so a source file containing
  either cannot end the block early.
* **executable** — copy `std.fs.selfExePath()` to the output, strip any payload already
  there, append the `.wvbc` bytes and a 16-byte trailer: the magic `WVEXAPP1` and the
  payload length as a little-endian `u64`. At startup `isPackaged()` reads its own last
  16 bytes; `embeddedApp()` returns the bytecode, which `module.fromBytecode` decodes into
  a module the server can run with reload disabled. On macOS the copy is re-signed ad-hoc
  (`codesign --force --sign -`) on a best-effort basis, since appending bytes invalidates
  any existing signature.

`weave run --selftest` and a packaged binary's `--selftest` share one path: load the
module, create a session with a sink that discards frames, start it, and report the app
name, signal count, function count and rendered node count. It is how CI proves an
artifact runs without opening a socket.

## 14. Testing

* `zig build test` — unit tests over the lexer, parser, compiler, VM, reactivity, diff
  and the wire format, each leak-checked by `std.testing.allocator`, plus the in-page
  engine driven natively: the shipped `examples/todo.weave` boots, mounts, takes typed
  input, runs `on_enter`, closes over a loop variable, survives a runtime error and drains
  `log()` output — the whole page transport, without a browser.
* `zig build itest` — boots the real server on an ephemeral port and drives it with a
  real WebSocket client over a real socket: static assets, handshake, mount tree shape,
  input binding, event dispatch, patch shape, ping/pong, a second independent session,
  and a live file edit that must produce a `reload` frame.
* `zig build examples` — compiles every `examples/*.weave`, mounts a session, dispatches
  every event and input on every interactive node, advances the clock 60 s and asserts
  the app settled. This is the regression net for the language surface.
* `node tools/check-html.mjs page.html` — boots an exported page in Node: decode the
  base64 blocks, instantiate the WebAssembly, start the app, ping it, tick it, and
  re-compile the embedded source. Exit 0 means the file opens and runs.
* CI additionally cross-compiles all six release targets on every pull request,
  pre-compiles the examples to `.wvbc` and exports each as a `.html` page, loads every
  artifact back, boots every page, packages an executable and runs its `--selftest`, and
  checks that the committed engine blob matches a fresh `zig build wasm`.
  See `.github/workflows/`.
