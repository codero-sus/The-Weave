# Weave

**One file, full stack.** Write Python-like logic and declarative HTML-like layout in a
single `.weave` file. `weave` compiles it to bytecode, runs it on a server-authoritative
VM, and streams the UI to a browser that stays in sync with every keystroke.

No JavaScript, no framework, no build step, no dependencies — and when you are done,
`weave build` hands you **one file**: a `.html` page that runs the app in a browser, or
a standalone executable that serves it.

```weave
app TodoApp:
    state:
        tasks = ["Learn Weave", "Ship something"]
        new_task = ""

    view:
        stack(padding: 24, align: center):
            text("My Tasks", font: 28, bold: true)

            input(bind: new_task, placeholder: "Add a task...", on_enter: {
                tasks.append(new_task)
                new_task = ""
            })

            for task in tasks:
                card(shadow: sm):
                    text(task)
                    button("Done", click: tasks.remove(task))
```

```sh
weave examples/todo.weave        # → http://127.0.0.1:8080
```

Edit the file and the browser updates itself — the server recompiles on save, pushes a
reload, and the client remounts.

---

## Install

One binary, nothing beside it — the way `python.exe` is the whole interpreter.
Pre-built binaries for Linux, macOS and Windows are attached to each
[release](../../releases), together with the examples pre-compiled to `.wvbc` bytecode
and exported as single-file `.html` apps:

```sh
tar -xzf weave-0.1.0-x86_64-linux-musl.tar.gz
cd weave-0.1.0-x86_64-linux-musl
./bin/weave run examples/todo.weave       # or: ./bin/weave run examples/todo.wvbc
```

Put `weave` on your `PATH` and a `.weave` file is runnable the way a `.py` file is:

```sh
weave app.weave        # compile it, serve it, open the browser
weave                  # ... or just run the one app in this directory
weave check app.weave  # compile only, non-zero exit on errors
```

From source (needs [Zig 0.13](https://ziglang.org/download/) and nothing else):

```sh
zig build                     # Debug, safety checks + leak detection on
zig build -Doptimize=ReleaseSafe --prefix ~/.local
zig build wasm                # refresh assets/weave-core.wasm, the in-page engine
weave examples/counter.weave --port 3000 --open
```

## CLI

```
weave [COMMAND] [OPTIONS] <file.weave|file.wvbc>

    run        Serve the app over HTTP+WebSocket with hot reload (default)
    serve      Alias for run
    check      Parse, type-check and compile; exit non-zero on errors
    build      Compile to a standalone artifact: .wvbc, .html or an executable
    dump       Print the bytecode disassembly of a source or .wvbc file
    ast        Print the normalised parse tree
    new        Write a starter app to a new file
    version    Print the version and exit

    --host ADDR    Address to bind            (default 127.0.0.1)
    --port N       Port to bind               (default 8080, 0 = any free port)
    --open         Open the app in a browser once the server is up
    --no-open      Do not; a terminal opens the browser by default
    --no-reload    Disable hot reload
    --poll MS      Socket poll interval / timer resolution (default 50)
    --quiet        Suppress server log lines
    --selftest     Boot the app once, report what rendered, and exit
    --format F     `build` output: wvbc (default), html or exe
    --html, --exe  Shorthand for --format, and they take the output path
    -o, --out F    Output path for `build`    (default: input name + format)
```

```sh
weave new myapp                          # scaffold a starter app
weave check examples/*.weave             # lint a whole directory
weave build examples/todo.weave -o dist/todo.wvbc
weave run dist/todo.wvbc                 # serve pre-compiled bytecode
weave run dist/todo.wvbc --selftest      # boot it once, no server
weave dump dist/todo.wvbc                # read the generated instructions
```

---

## Ship it

`weave build` turns one `.weave` file into one artifact. Pick the artifact:

| Format | Command | You get | Needs `weave` to run |
| ------ | ------------------------------------------------------ | --------------------------------------------- | -------------------- |
| `.wvbc` | `weave build app.weave` | pre-compiled bytecode, 1–3 KB | yes |
| `.html` | `weave build app.weave --html dist/app.html` | one page, ~425 KB: WebAssembly engine, bytecode, styles and client inline | **no** — just a browser |
| executable | `weave build app.weave --exe dist/app` | one file, ~6 MB: this engine with your app compiled into it | **no** |

```sh
weave build examples/todo.weave --html dist/todo.html   # then open dist/todo.html
weave build examples/todo.weave --exe  dist/todoapp     # then ./dist/todoapp
./dist/todoapp --selftest                               # boots, renders, reports
./dist/todoapp --port 3000                              # serves the embedded app
```

The `.html` file runs the *same* compiler and VM as the server, compiled to
WebAssembly: state, handlers, effects and the diff all execute inside the page, so it
works offline, from a `file://` URL, on any static host, or as an email attachment. The
executable is the `weave` binary with your bytecode appended — and it is still a full
`weave`, so `./dist/todoapp build other.weave --html other.html` works too.

Cross-compiling, macOS/Windows notes, what is inside each artifact and CI recipes:
[`docs/exporting.md`](docs/exporting.md).

---

## What it does

| Area        | Status                                                              |
| ----------- | ------------------------------------------------------------------- |
| Compiler    | Lexer → parser → AST → bytecode → stack VM. Real `.wvbc` artifacts   |
| Reactivity  | Signals, computeds, dependency tracking, bounded fixpoint scheduler  |
| UI          | Layout/text/input elements, props, themes, style maps, keys          |
| Components  | Parameterised view functions with defaults, callables as props       |
| Effects     | `on_mount:`, `on <signal>:`, `after <ms>:` timers                    |
| Runtime     | Server-authoritative sessions, per-connection state, hot reload      |
| Transport   | Hand-rolled HTTP + WebSocket, minimal JSON diff patches              |
| Client      | Framework-free renderer embedded in the binary (~16 KB of JS)        |
| In-page engine | The same compiler + VM as WebAssembly, so a page needs no server  |
| Export      | `build --html` (one self-contained page), `build --exe` (one file)   |
| Tooling     | `check`, `build`, `dump`, `ast`, `new`, `--selftest`, diagnostics     |

See [`examples/`](examples): `todo.weave` (the canonical app), `counter.weave`
(handlers, computeds, inline blocks), `components.weave` (props and callbacks),
`effects.weave` (mount, watch, timers), `theme.weave` (theme and style signals).

## How it works

```
.weave ─► lexer ─► parser ─► AST ─► compiler ─► bytecode (.wvbc) ─► VM
                                                                     │
        browser ◄─ JSON patches ◄─ diff ◄─ vdom ◄─ reactive store ◄──┘
```

That one VM has two homes, and they are the same code:

```
weave run app.weave          engine in a server thread ─ HTTP + WebSocket ─► browser
weave build app.weave --exe  engine in one file, your app appended to it
weave build app.weave --html engine as WebAssembly inside the page, no server at all
```

* **The view is compiled, not interpreted.** Element calls become builder
  instructions (`ui_begin`, `ui_prop`, `ui_event`, `ui_key`, `ui_end`), so rendering is
  one function call and a linear instruction walk.
* **Closures are real.** `for task in tasks: button("Done", click: tasks.remove(task))`
  captures the right `task` per row through a `closure` instruction.
* **Only deltas cross the wire.** Trees are diffed by tag and key; node ids are stable,
  so a click still addresses the node the browser drew.
* **Each connection owns a session** — its own signal values and timers, flushed to a
  fixpoint after every event.
* **A `.wvbc` file is a complete program.** `weave run app.wvbc` serves it without a
  parser in the process, and `weave build app.wvbc --html` exports it as a page.
* **The engine is one codebase, compiled twice.** `src/wasm.zig` wraps the same
  compiler, VM, store and diff for WebAssembly, so an exported page computes its own
  patches — the browser is still just a renderer. `src/host.zig` is the only place that
  knows whether there is an operating system to talk to.

Diagnostics point at the source with a caret, a span and a hint:

```
[E001]: expected an indented block, found card
  --> examples/components.weave:5:5
    |
  5 |     card(shadow: sm, padding: 16, gap: 4):
    |     ^^^^
```

## Documentation

* [`docs/language.md`](docs/language.md) — the language reference: sections, values,
  operators, statements, builtins, the view, components, effects, reactivity rules.
* [`docs/internals.md`](docs/internals.md) — the compiler, bytecode format, VM,
  reactive store, diff engine, server and client.
* [`docs/exporting.md`](docs/exporting.md) — `weave build` output: what is inside a
  `.html` page and a packaged executable, cross-compiling, signing, CI recipes.
* [`docs/wire-protocol.md`](docs/wire-protocol.md) — every frame, node field and patch
  op, for anyone writing a different client.

## Development

```sh
zig build test        # unit tests: lexer, parser, compiler, VM, reactivity, diff,
                      # and the in-page engine driven exactly as a page drives it
zig build itest       # boots the real server, drives it over a real WebSocket
zig build examples    # compiles, renders and exercises every bundled example
zig build wasm        # rebuild assets/weave-core.wasm (the in-page engine)
zig build run -- examples/todo.weave --port 3000

weave build examples/todo.weave --html /tmp/todo.html
node tools/check-html.mjs /tmp/todo.html   # boots the exported page, no browser
```

All three run leak-checked in Debug. CI additionally cross-compiles all six release
targets on every pull request and pre-compiles the examples to `.wvbc`, loading each
artifact back to prove the bytecode format round-trips.

### CI and releases

| Workflow                             | Trigger            | What it does                                                       |
| ------------------------------------ | ------------------ | ------------------------------------------------------------------ |
| [`.github/workflows/ci.yml`](.github/workflows/ci.yml)         | push, PR   | Builds Debug + ReleaseSafe, runs unit/integration/example suites, smoke-tests the CLI, pre-compiles the examples to `.wvbc` and verifies they load, then cross-compiles all six release targets |
| [`.github/workflows/release.yml`](.github/workflows/release.yml) | tag `v*.*.*`, manual dispatch, or a PR that touches the workflow | Cross-compiles the CLI for every target, pre-compiles the bundled examples into each package, archives them with SHA-256 sums and publishes a GitHub Release |

The release pipeline self-tests: a pull request that changes `release.yml` (or a
manual dispatch with `dry_run`) runs the entire packaging matrix and prints the
archive contents and checksums, but stops short of publishing. A pull request can
never publish a release.

Release targets: `x86_64-linux-musl` (static), `x86_64-linux-gnu`, `aarch64-linux-gnu`,
`x86_64-macos`, `aarch64-macos`, `x86_64-windows`. Every package contains the binary,
the example sources, their pre-compiled `.wvbc` artifacts and a `VERSION.txt`.

```sh
git tag v0.1.0 && git push origin v0.1.0     # the pipeline does the rest
```

## Status

This is a working prototype (v0.1.0), not a production language runtime. Known gaps:
no `while` loops or `try/except`, no imports or package manager, no persistence
(state lives in the session), no cross-session broadcast, and the VM is sandboxed to
signals, builtins, timers and the view — no file, network or process access from
`.weave` code. See [`docs/language.md` §10](docs/language.md#10-what-is-not-in-this-release).
