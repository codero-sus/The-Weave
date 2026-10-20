# Exporting: one file out

`weave build` compiles a `.weave` file into a single artifact you can hand to someone
else. There are three, and they differ in what the *recipient* has to have installed:

| Format | Command | Artifact | Recipient needs |
| ------ | ----------------------------------------------- | ----------------------------- | ----------------------- |
| `.wvbc` | `weave build app.weave` | pre-compiled bytecode, 1–3 KB | `weave` |
| `.html` | `weave build app.weave --html dist/app.html` | one page, ~424 KB | **a browser** |
| executable | `weave build app.weave --exe dist/app` | one file, ~5.3 MB | **nothing** |

```sh
weave build examples/todo.weave                       # -> todo.wvbc
weave build examples/todo.weave --html dist/todo.html  # -> dist/todo.html
weave build examples/todo.weave --exe  dist/todoapp    # -> dist/todoapp
weave build examples/todo.weave --format exe -o dist/todoapp   # the long form
```

`--html` and `--exe` also take the output path directly (`--html dist/todo.html`), and
`-o` implies the format from its extension (`-o app.html` means `--format html`). With no
`-o`, the output is the input's name with the format's extension — `.exe` on Windows,
nothing extra elsewhere.

All three accept a `.wvbc` as input as well, so a pre-compiled app can be exported
without re-parsing anything:

```sh
weave build dist/todo.wvbc --html dist/todo.html
```

---

## `.html` — the app as a page

One file, no server, no network. Open it from a `file://` URL, put it on a static host,
attach it to an email; it runs the same way everywhere.

```sh
weave build examples/todo.weave --html dist/todo.html
open dist/todo.html          # macOS; xdg-open on Linux, start on Windows
```

What is inside, in order:

| Block | Contents |
| ----------------------------- | ------------------------------------------------------------- |
| `<style>` | `assets/client.css`, inlined (~9 KB) |
| `<div id="app" class="weave-root">` | the mount point, plus `#weave-error` and `#weave-status` |
| `<script id="weave-core-b64">` | the engine, WebAssembly, base64 (303 KB → ~404 KB) |
| `<script id="weave-app-b64">` | your app as `.wvbc` bytecode, base64 (1–3 KB) |
| `<script id="weave-source">` | your app as readable source, for editing in place |
| boot script | decodes the two blobs, instantiates the engine, exposes `window.__WEAVE_LOCAL__` |
| `<script>` | `assets/client.js`, inlined (~18 KB) — the same renderer the server-backed client uses |

The engine is `src/wasm.zig` compiled to `wasm32-freestanding`: the same lexer, parser,
compiler, bytecode decoder, VM, reactive store, vdom builder and diff engine that the
server runs, with `src/host.zig` standing in for the operating system. So the page does
not fake the app — it *computes* it:

* signals, computeds and effects run in the page;
* `after <ms>:` timers fire from a 50 ms tick driven by `Date.now()`;
* every event goes through `weave_dispatch`, and the frames that come back are the same
  JSON the WebSocket would have carried, so the renderer is unchanged;
* `log()` in a handler or effect arrives in the browser console as `[weave] …`.

Everything is inline on purpose. A page loaded from `file://` may not `fetch()` a
neighbouring file, and a page on a static host should not depend on a CDN, so the engine
and the bytecode travel as base64 inside `<script>` tags and are decoded in memory. The
page makes no requests at all — you can serve it from a USB stick.

`assets/client.js` picks its transport by looking for `window.__WEAVE_LOCAL__`: present
means "drive the in-page engine", absent means "open the WebSocket". One renderer, two
ways to reach the VM.

**Editing the page.** The readable source block is what the page compiles when you ask it
to, and `weave-source` is a real `<script type="text/weave">`, so a person can open the
exported file in an editor, change the app, and reload — no `weave` installed. To ship
the change, edit the `.weave` file and re-export; hand-edits to the base64 blobs do not
work.

**What a page cannot do.** There is no server, so there is no shared state between two
open tabs, no persistence, no HTTP calls from handlers and no hot reload. State lives for
the lifetime of the tab. If the app needs any of that, export an executable instead (or
run `weave app.weave`, which is the same engine with a server attached).

### Checking a page without a browser

`tools/check-html.mjs` does what a browser would do, minus the browser. It decodes the
blobs, instantiates the WebAssembly, boots the app, drives a `ping` and a tick and
re-compiles the embedded source; then it runs the page's own boot script and the real
`assets/client.js` against a DOM stub — enough of a DOM to mount a tree — and fires every
listener the render installed:

```sh
node tools/check-html.mjs dist/todo.html
# dist/todo.html: ok
#     app TodoApp  page 424 KB  engine 296 KB  bytecode 2 KB
#     2 frames, root <stack>, 14 nodes; source recompiles in-page
#     page renders: 7 elements, 2 text node(s), 4 interaction(s) driven, transport wasm
```

It fails if the page would open blank: no engine blob, no bytecode, a client that reaches
for a WebSocket instead of the in-page engine, nothing mounted into `#app`, or an error
overlay raised while loading. An app that raises *on purpose* is reported as a note rather
than a failure — the whole-language fixture exports like this:

```sh
node tools/check-html.mjs out/features.html
#     page renders: 53 elements, 35 text node(s), 13 interaction(s) driven, transport wasm
#     note: an interaction raised: index 999 is out of range for a list of 3 item(s)
#     log: [Features] counter is 0 (even)
```

Exit status is 0 when the page boots and renders, 1 when it does not. CI runs it over every
exported example and the language fixture, so a page that would open blank never reaches a
release.

---

## Executable — the app as a program

`weave build --exe` copies the running `weave` binary and appends your compiled app to
it. The result is one file that serves the app on <http://127.0.0.1:8080>:

```sh
weave build examples/todo.weave --exe dist/todoapp
./dist/todoapp                  # compile nothing, serve the embedded app
./dist/todoapp --port 3000      # any server option still works
./dist/todoapp --selftest       # boot it, render once, report, exit
```

`--selftest` is the fast check — no socket, no browser, non-zero exit if the app does not
render:

```
weave: <embedded> ok — app TodoApp, 2 signals, 5 functions, 14 nodes rendered
```

A packaged executable is still a full `weave`. It carries the engine (including the
WebAssembly blob) and the whole CLI, so it can compile and export other apps, which is
handy on a machine that has nothing installed:

```sh
./dist/todoapp build other.weave --html other.html
./dist/todoapp check *.weave
```

### How the app is carried

```
┌──────────────────────────────┐
│ the weave executable         │  ← unchanged, still runnable as a normal weave
├──────────────────────────────┤
│ app.wvbc bytecode            │  ← what `weave build` produced
├──────────────────────────────┤
│ "WVEXAPP1" │ payload_len u64 │  ← 16-byte trailer, little-endian
└──────────────────────────────┘
```

At startup the binary looks at its own last 16 bytes (`src/package.zig`). If the magic
matches, it loads that many bytes of bytecode from just before the trailer and runs the
app; if not, it is an ordinary `weave` and behaves like one. Packaging strips any payload
already present before appending the new one, so re-packaging a packaged binary never
nests apps inside each other — CI asserts the sizes stay within 64 KB.

Because the app is appended rather than linked in, `--exe` needs no toolchain, no linker
and no recompilation: it is a file copy. That also means the artifact inherits whatever
the host binary was — build with Zig's cross-compilation and the app follows.

### Platform notes

| Platform | Note |
| -------- | ---- |
| Linux | `chmod +x` is preserved by `weave build --exe`. A musl (static) build produces an executable with no libc dependency at all. |
| macOS | Gatekeeper wants a signature. `weave build --exe` re-signs ad-hoc with `codesign --force --sign -` when it can; if it prints a note instead, run that command yourself. A downloaded file also needs `xattr -d com.apple.quarantine ./app`. |
| Windows | The default output name gains `.exe`. SmartScreen may ask for confirmation on an unsigned build. |

---

## Cross-compiling an app

An exported executable runs where the *engine* runs, so targeting another platform means
building `weave` for it and using that binary to export. Zig cross-compiles from anywhere,
no toolchain installed:

```sh
# a static Linux executable that runs on any x86_64 distro
zig build -Dtarget=x86_64-linux-musl -Doptimize=ReleaseSafe --prefix dist/linux
dist/linux/bin/weave build app.weave --exe dist/app-linux

# a Windows .exe, built on Linux or macOS
zig build -Dtarget=x86_64-windows-gnu -Doptimize=ReleaseSafe --prefix dist/win
dist/win/bin/weave.exe build app.weave --exe dist/app.exe

# Apple Silicon
zig build -Dtarget=aarch64-macos-none -Doptimize=ReleaseSafe --prefix dist/mac-arm
```

Note that a cross-built binary cannot execute on the build machine, so `--selftest` has to
run on the target (CI does this for the two Linux targets). `.html` needs none of this: a
page is the same bytes on every platform, which is why the release ships all five example
apps as pages alongside the six platform packages.

Sizes, measured with Zig 0.13 and `-Doptimize=ReleaseSafe`:

| Artifact | Size |
| ---------------------------------------- | --------- |
| `weave` (x86_64-linux-gnu) | 5.3 MB |
| `weave build --exe` output | 5.3 MB (+1.7 KB for the todo app) |
| `weave build --exe`, x86_64-linux-musl | 5.3 MB, static |
| `weave build --html` output | 424 KB |
| `assets/weave-core.wasm`, the engine | 303 KB |
| `todo.wvbc`, the compiled app | 1.7 KB |

---

## Which one?

* **`.html`** — demos, prototypes, dashboards, anything read-only or single-user, and
  every case where the recipient has a browser but no terminal. Smallest thing that runs
  with nothing installed.
* **executable** — the app is a product: it needs a real port, several concurrent users,
  per-connection state, `after` timers driven by a socket poll, and a process a supervisor
  can restart.
* **`.wvbc`** — deployment inside your own pipeline: ship bytecode next to a known
  `weave` and skip parsing at startup. Also the fastest iteration loop
  (`weave build` then `weave run app.wvbc`).

## CI recipes

Verify both exports on every commit — neither needs a browser or a second machine:

```yaml
- name: Export and check
  run: |
    set -euo pipefail
    weave=./zig-out/bin/weave

    "$weave" build app.weave --html dist/app.html
    node tools/check-html.mjs dist/app.html      # boots the page's engine

    "$weave" build app.weave --exe dist/app
    ./dist/app --selftest                        # boots the embedded app
```

The engine blob is committed (`assets/weave-core.wasm`) so a plain clone can export
pages. It is regenerated by `zig build wasm`, the build is byte-for-byte reproducible, and
CI fails if the committed copy is stale:

```yaml
- name: In-page engine blob is up to date
  run: |
    zig build wasm
    git diff --exit-code assets/weave-core.wasm
```

## Troubleshooting

| Symptom | Cause and fix |
| ------- | ------------- |
| Exported page is blank | Open the console. A compile error in the app shows as `[weave] …` and in `#weave-error`; `node tools/check-html.mjs page.html` prints the same diagnostics on the command line. |
| Page works locally but not on a host | The host rewrote the HTML (minifier, template engine) and broke a base64 block. Serve the file as-is. |
| `cannot execute binary file` | The executable was built for another platform, or lost its execute bit (`chmod +x`). |
| macOS: "cannot be opened because the developer cannot be verified" | Unsigned and quarantined: `xattr -d com.apple.quarantine ./app`, then `codesign --force --sign - ./app`. |
| `weave build --exe` produced a file that behaves like plain `weave` | The trailer was stripped — by a transfer that rewrote the file, or by an antivirus. Re-export, and check the last 16 bytes contain `WVEXAPP1`. |
| Exported app is stale | `--exe` and `--html` compile at build time. Re-run `weave build` after editing the source; there is no hot reload in an artifact. |
