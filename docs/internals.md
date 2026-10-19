# How Weave works

Everything below is implemented in Zig 0.13 with no libC, no runtime dependencies and
no generated code. One binary contains the compiler, the VM, the reactive store, the
diff engine, the HTTP server, the WebSocket server and the browser client (embedded
with `@embedFile`).

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
| `src/ws.zig`         | Hand-rolled WebSocket: handshake, framing, masking, fragmentation  |
| `src/module.zig`     | Load a `.weave` or `.wvbc` file into a `CodeUnit`, hot-reload mtime |
| `src/server.zig`     | HTTP routing, static assets, upgrade, thread-per-connection        |
| `src/cli.zig`        | Argument parsing, commands, scaffold, help                         |
| `assets/`            | `index.html`, `client.js`, `client.css`, embedded via `embed.zig`  |

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

Integers use a varint-style encoding (`u32v`/`i32v`) so small values cost one byte.
`bytecode.encodeUnit` writes the body into a scratch buffer first (ids are assigned as
it goes), then emits the header, string table and body. `bytecode.decode` rebuilds the
whole unit in an arena, and `Loaded` owns both the arena and the file bytes.

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
`window.weave` exposes the socket and stats for debugging.

## 12. Testing

* `zig build test` — unit tests over the lexer, parser, compiler, VM, reactivity, diff
  and the wire format, each leak-checked by `std.testing.allocator`.
* `zig build itest` — boots the real server on an ephemeral port and drives it with a
  real WebSocket client over a real socket: static assets, handshake, mount tree shape,
  input binding, event dispatch, patch shape, ping/pong, a second independent session,
  and a live file edit that must produce a `reload` frame.
* `zig build examples` — compiles every `examples/*.weave`, mounts a session, dispatches
  every event and input on every interactive node, advances the clock 60 s and asserts
  the app settled. This is the regression net for the language surface.
* CI additionally cross-compiles all six release targets on every pull request and
  pre-compiles the examples to `.wvbc`, loading each artifact back to prove the format
  round-trips. See `.github/workflows/`.
