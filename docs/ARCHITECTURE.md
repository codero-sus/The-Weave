# Weave Engine Architecture

How a `.weave` file becomes a running, reactive application — and why the
engine is shaped the way it is.

---

## 1. Design constraints

| constraint | consequence |
|---|---|
| single file owns state, logic and UI | one compile unit; no cross-file resolution |
| Python semantics, not a look-alike | reuse CPython's `ast` + `eval`/`exec` |
| no build step, no dependencies | plain HTTP server + hand-written CSS/JS |
| server owns truth | server-side rendering with an event round trip |
| prototype clarity over maximal speed | small modules, explicit passes, heavy tests |

Two decisions dominate everything else:

1. **Logic is compiled to Python, not interpreted.** Weave does not implement
   arithmetic, comprehensions, f-strings or method calls. It rewrites ASTs so
   CPython does the work.
2. **The view is rendered on the server.** Weave does not ship a template
   compiler to the browser. It renders HTML and streams fragments back.

---

## 2. Pipeline

```
                 ┌──────────────────────────────────────────────────┐
  .weave  ──────►│ source.py     tokenizer                          │
                 │   indentation → INDENT/DEDENT                    │
                 │   brackets    → depth on every token             │
                 │   strings     → Python literal rules            │
                 └───────────────┬──────────────────────────────────┘
                                 ▼
                 ┌──────────────────────────────────────────────────┐
                 │ parser.py     recursive descent                  │
                 │   app / state / view / routes / styles / theme   │
                 │   functions, component args, handler braces      │
                 └───────────────┬──────────────────────────────────┘
                                 ▼
                 ┌──────────────────────────────────────────────────┐
                 │ components.py registry validation                │
                 │ analyzer.py   names, binds, types, duplicates    │
                 │   • unknown names with difflib suggestions        │
                 │   • bareword tolerance for attribute values       │
                 └───────────────┬──────────────────────────────────┘
                                 ▼
                 ┌──────────────────────────────────────────────────┐
                 │ codegen.py    CPython AST rewriting              │
                 │   state reads/writes → ctx.st['name']            │
                 │   function calls     → ctx threaded through      │
                 │   loop captures      → extra parameters          │
                 └───────────────┬──────────────────────────────────┘
                                 ▼
                 ┌──────────────────────────────────────────────────┐
                 │ compiler.py   exec in a restricted namespace     │
                 │ program.py    Program: state template, handlers,  │
                 │               renderer, expression cache          │
                 └───────┬──────────────────────────────┬───────────┘
                         ▼                              ▼
              renderer.py  ── HTML ──►  server.py  ── HTTP ──►  browser
                                           │
                                           └─ sessions, events, hot reload
```

### Module responsibilities

| module | owns | never does |
|---|---|---|
| `source.py` | tokens, locations, string decoding | grammar |
| `parser.py` | AST + syntax diagnostics | name resolution |
| `components.py` | the vocabulary and its metadata | HTML |
| `analyzer.py` | semantic validation | code generation |
| `codegen.py` | generated Python + line map | execution |
| `runtime.py` | sandbox surface, `Context`, JSON bridge | rendering |
| `program.py` | compiled program facade, initial state, error translation | HTTP |
| `renderer.py` | HTML + design tokens + event map | state mutation |
| `server.py` | sessions, event loop, assets, reload | language rules |
| `static/weave.js` | DOM events, patching, focus/caret | business logic |

---

## 3. Code generation

Given

```weave
app TodoApp:
    state:
        tasks = []
        new_task = ""
    view:
        input(bind: new_task, on_enter: {
            tasks.append(new_task)
            new_task = ""
        })
        for task in tasks:
            button("Done", click: tasks.remove(task))
```

Weave produces approximately:

```python
def _weave_h0(ctx):
    state = ctx.st
    log = ctx.log
    toast = ctx.toast
    navigate = ctx.navigate
    emit = ctx.emit
    print = ctx.log
    ctx.st['tasks'].append(ctx.st['new_task'])
    ctx.st['new_task'] = ''

def _weave_h1(ctx, task):
    state = ctx.st
    ...
    ctx.st['tasks'].remove(task)
```

Key mechanics:

* **State rewriting.** `StateRewriter` is an `ast.NodeTransformer`. Loads and
  stores of known state names become `ctx.st['name']`. Locals, parameters,
  comprehension targets, `for` targets and captured loop variables are tracked
  in a `bound` set so they are never rewritten.
* **Context threading.** Calls to user functions become
  `_weave_f_name(ctx, …)`, so functions can read and mutate the same state.
* **Captures.** During parsing, every handler records the loop variables in
  scope. Codegen adds them as parameters; the renderer records their *values*
  in the event map, keyed by the element's `data-w` path.
* **Prelude.** Each generated function binds `state`, `log`, `toast`,
  `navigate`, `emit` and `print` from its `ctx`. This is why handlers can use
  effect helpers without imports.
* **Line map.** Generated source keeps a parallel `line_origins` array.
  Runtime tracebacks are translated back to `.weave` lines for diagnostics.

Annotations on parameters are stripped (they are documentation), because the
compiled module has no type objects for user-defined names.

### Why not translate expressions to JavaScript?

A JS backend would need its own semantics for dicts, tuples, comprehension
scoping, Python string formatting, methods and exceptions. Every divergence is
a bug class. Server execution makes `tasks.remove(task)` mean exactly what it
means in Python — including object identity and mutation through captures.

The price is a round trip per interaction. For a prototype on localhost this is
~2–5 ms of server work per event (rendering a 202-line app twice: once to resolve
the handler, once for the response).

---

## 4. Rendering and paths

`Renderer` walks the AST and returns:

```python
RenderResult(
    html=...,          # fragment for <main id="weave-root">
    title=...,         # document title
    path=...,          # resolved route
    status=200,
    events={           # data-w path → DOM event → [EventBinding]
        "r.0.1": {"enter": [EventBinding("_weave_h0", {}, 8, 9)]},
        "r.0.3$1.0.1": {"click": [EventBinding("_weave_h1", {"task": ...}, 13, 22)]},
    },
    bindings={"r.0.1": "new_task"},
)
```

### Path grammar

| segment | meaning |
|---|---|
| `r` | root |
| `.N` | Nth child of a node |
| `$K` | Kth iteration of a `for` |
| `t` / `f` | then / else branch of an `if` |

Paths are deterministic for a given state shape. They are used for handler
lookup, focus restoration, scroll restoration and stale detection.

### Design tokens

Attribute values are resolved through a small style engine:

* numbers → pixels (`padding: 24`)
* named scales → px (`sm` → 8, `lg` → 20)
* palette names → `var(--weave-primary)`
* shadows/radii → token maps
* everything else → escaped raw CSS

Inline styles keep the prototype dependency-free and let one `theme:` block
recolour the entire app. `static/weave.css` supplies what inline styles cannot:
hover/active/focus states, custom checkbox/toggle rendering, transitions,
toasts and the error overlay.

All text and attribute values are escaped with `html.escape`. The only unescaped
path is the explicit `html("<b>…</b>")` escape hatch.

---

## 5. Reactivity protocol

### Requests

```
GET  /                       full page (shell + first paint)
GET  /about                  route render, same shell
GET  /_weave/page?path=…     fragment for client-side navigation (JSON)
POST /_weave/event           one interaction (JSON)
POST /_weave/reset           reset the session state
GET  /_weave/static/*        client runtime and CSS
GET  /assets/*               files next to the .weave source
GET  /_weave/source          the original source
GET  /_weave/inspect         manifest + generated Python
GET  /_weave/health          readiness probe
```

### Event payload

```json
{
  "session": "…",
  "path": "r.0.3$1.0.1",
  "event": "click",
  "values": {"new_task": "Ship it", "priority": 4},
  "rev": 12
}
```

`values` contains every bound control on the page. This solves the classic race
between a debounced input event and a click: bound values are always applied
before the handler runs, so the handler sees what the user sees.

### Event processing

```
lock session
  working ← deepcopy(session.state)          (transaction)
  apply(values)
  preliminary ← render(working)              (re-resolve handlers + captures)
  handlers ← preliminary.events[path][event]
  if no handlers and no binding → stale
  for handler in handlers: execute(handler, ctx=working, captures)
  commit session.state ← working; rev += 1
  response ← render(working, redirect or session.path)
unlock
```

Rendering *before* executing is what makes captures correct: the loop item
passed to `tasks.remove(task)` or mutated by `row["done"] = …` is an object
inside the transaction snapshot, not a stale reference from an earlier render.

### Response payload

```json
{
  "ok": true,
  "html": "<div data-w=\"r.0\">…</div>",
  "title": "Weaveboard",
  "path": "/",
  "status": 200,
  "rev": 13,
  "state": {"tasks": ["…"]},
  "toasts": [{"message": "Task added", "kind": "success"}],
  "logs": [],
  "redirect": null
}
```

On failure `ok` is false and `error` carries `{code, message, line, col, hint,
snippet, traceback}`. The transaction is discarded; the client keeps a
consistent view.

### Client runtime

`static/weave.js` (~10 KB, no dependencies) implements:

* delegated `click`, `input`, `change`, `submit`, `keydown` (Enter), focus/blur;
* a **serialized request queue** so responses cannot arrive out of order;
* fragment patching with focus, caret, scroll and typing preservation;
* `history.pushState` navigation and `popstate` back/forward;
* toast rendering, error overlay, busy indicator and theme toggle;
* a small `window.Weave` debugging API.

Two details matter for feel:

* **Pending edits.** While a bound field is focused, its local value wins over a
  render that has not caught up yet; the map is cleared whenever a non-typing
  event is sent (so `on_enter` clearing a field is visible immediately).
* **Range inputs.** Sliders update on release; replacing a range node mid-drag
  would cancel the gesture.

---

## 6. Sessions, state and reload

* A session is created on first request and identified by an HttpOnly
  `weave_sid` cookie (also included in payloads, for robustness).
* Each session holds a deep-copied state dict, a revision counter, the current
  route and the last render's event/binding maps.
* Mutations are transactional per event; concurrent events for one session are
  serialized by an `RLock` (and by the client's request queue).
* Idle sessions are reaped after six hours.
* `ProgramHandle` watches the `.weave` file's mtime. On change it recompiles;
  sessions are reconciled by adding new state variables and dropping removed
  ones. A failed reload keeps the previous program running and prints the
  diagnostic; the shell shows a warning banner on the next load.

Hot reload swaps the `Program`, not the server: sessions survive, state is
preserved across compatible edits, and the next event resolves handlers against
the new program.

---

## 7. Security model

Weave is a development tool for local, trusted code. Still, the obvious footguns
are closed:

| risk | mitigation |
|---|---|
| XSS via state values | `html.escape` on every text and attribute; JSON `</` escaping |
| script injection through config | `window.__WEAVE__` is JSON with `<\/` escaping |
| arbitrary code execution via expressions | fixed source only; no user-supplied expressions are evaluated |
| filesystem/network access from handlers | curated builtins dict; no `import`, `open`, `os`, `sys`, `eval`, `exec` |
| path traversal on `/assets` | resolved path must stay under the app directory |
| CSRF | no privileged cross-origin actions; session cookie is `SameSite=Lax` |
| stale/malicious event paths | handler lookup by deterministic path; unknown paths are rejected |
| runaway handlers | not sandboxed by time; this is an in-process development server |

The `html()` component bypasses escaping by design; treat it as an unsafe
escape hatch inside trusted source.

---

## 8. Performance

Measured on the 202-line dashboard example (CPython 3.11, this sandbox):

| operation | cost |
|---|---|
| full compile (tokenize → exec) | ~14 ms |
| render the app (63 components) | ~2.1 ms |
| execute a handler | ~1 µs |
| one HTTP event (transaction + two renders) | a few ms |

The design favours predictability over micro-optimisation: deep copies are cheap
for JSON-shaped state, compiled expressions are cached per source string, and
rendering is a single linear pass. A production engine would add HTML diffing,
state-store offloading and WebSocket batching rather than change the language.

---

## 9. Testing strategy

76 tests, no external dependencies:

* **Tokenizer** — indentation, bracket depth, string prefixes, errors.
* **Parser** — the spec example, typed state, routes, styles, functions,
  diagnostics for malformed input.
* **Analyzer** — unknown components/attributes/names, bind validation,
  suggestions, duplicate declarations.
* **Renderer** — escaping, conditionals, loops with indices, every component,
  named styles, barewords, 404 routes, state isolation.
* **Runtime** — handlers, captures, mutation through captured objects,
  augmented assignment, function calls, effects, rollback on error, type checks.
* **Server** — real HTTP servers on ephemeral ports, cookie sessions, event
  round trips, stale events, reset, session isolation, error payloads, hot
  reload.
* **CLI** — check/ast/build/init/components/version, including compiling the
  generated standalone `app.py`.

Run with `python3 -m unittest discover -s tests -v`.

---

## 10. Extending the language

Adding a primitive is a three-step change:

1. Register a `ComponentSpec` in `components.py` (arity, attributes, events).
2. Implement `_c_<name>` in `renderer.py` using the shared `_element` and
   `_box`/`_text_style` helpers.
3. Add CSS in `static/weave.css` if inline styles are not enough, plus a test.

Adding syntax means: a node in `nodes.py`, parsing in `parser.py`, checks in
`analyzer.py`, and either a renderer case or a codegen rewrite. The compiler
has no global mutable state, so passes are easy to test in isolation.

---

## 11. Known trade-offs

* Two renders per event is simple and correct; it is not the cheapest possible
  strategy. The preliminary pass could be replaced by caching the event map
  and rebinding captures by path.
* Full-fragment replacement avoids virtual DOM complexity but resets node
  identity; focus/scroll/typing restoration papers over the gap. A morphing
  patcher would improve animation and input smoothness.
* Inline styles are easy to theme but cannot express media queries or complex
  states; the static sheet carries those.
* Session memory is per process and per tab. Horizontal scaling needs shared
  state or sticky routing.
* The sandbox is a policy boundary for accidental damage, not a hardened
  security boundary against hostile code; never run untrusted `.weave` files.
