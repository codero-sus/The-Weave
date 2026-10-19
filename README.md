# Weave

**A single-file, full-stack language.** Python-flavoured logic and a declarative, HTML-like view language in one `.weave` file — compiled and served as a reactive web app by a zero-dependency Python engine.

```
   ╦ ╦╔═╗╔═╗╦  ╦╔═╗
   ║║║║╣ ╠═╣╚╗╔╝║╣
   ╚╩╝╚═╝╩ ╩ ╚╝ ╚═╝
```

```weave
app TodoApp:
    state:
        tasks = ["Learn Weave", "Build something cool"]
        new_task = ""

    view:
        stack(padding: 24, align: center):
            text("My Tasks", font: 28, bold: true)

            input(bind: new_task, placeholder: "Add a new task...", on_enter: {
                tasks.append(new_task)
                new_task = ""
            })

            for task in tasks:
                card(shadow: sm):
                    text(task)
                    button("Done", click: tasks.remove(task))
```

```bash
./weave run examples/todo.weave
# ➜ http://localhost:8420
```

No HTML file. No CSS file. No JavaScript. No `package.json`, no bundler, no build step.

---

## Contents

- [Why Weave](#why-weave)
- [Quick start](#quick-start)
- [How it works](#how-it-works)
- [Language tour](#language-tour)
- [Components](#components)
- [CLI](#cli)
- [Examples](#examples)
- [Testing](#testing)
- [Project layout](#project-layout)
- [Limitations & roadmap](#limitations--roadmap)
- [Further reading](#further-reading)

---

## Why Weave

Modern web apps spend most of their code on plumbing: a schema over here, an API
route there, a fetch call, a serializer, a loading state, a component tree, a
stylesheet. Weave asks a different question — *what if the unit of a web app was
the app itself?*

Three principles drive the language:

1. **One file, one program.** State, behaviour, structure and design live
   together. There is no frontend/backend seam to maintain because there is no
   frontend/backend seam.
2. **Python is the substrate, not a cousin.** Logic blocks are genuine Python.
   Weave reuses CPython's own parser and evaluator instead of inventing a second
   expression engine — so list comprehensions, f-strings, dicts, exceptions and
   mutation all behave exactly as you expect.
3. **The engine owns the hard parts.** Sessions, reactivity, escaping,
   focus/caret preservation, hot reload, error reporting and a small design
   system are provided. You describe *what* the app is; the engine handles *how*
   it runs.

---

## Quick start

Weave has **no third-party dependencies** and runs on Python 3.9+.

```bash
# from this checkout
./weave run examples/todo.weave          # the spec example
./weave run examples/dashboard.weave     # a richer app: routes, functions, tabs, tables
./weave init my-app && ./weave run my-app/app.weave
```

Or install it as a proper command:

```bash
pip install -e .
weave run examples/todo.weave --open
```

`weave run` starts a development server on **port 8420**, watches the `.weave`
file for changes, and reloads the compiled program on save. Every browser
session gets its own copy of the state (tabs share a session via the cookie;
use a private window for a fresh one).

> **Serving from a container or sandbox?** The server binds `0.0.0.0` by default,
> which is what remote preview environments need. Use `--host 127.0.0.1` to keep
> it local, or `--port` to change ports.

---

## How it works

```
 .weave source
      │
      ├─ tokenizer      indentation-aware lexer, bracket-depth tracking,
      │                 Python-style string literals (f/r/b prefixes)
      ├─ parser         recursive descent → AST (app / state / view / routes /
      │                 functions / styles / theme)
      ├─ checker        component & attribute validation, name resolution,
      │                 bind targets, type annotations — with suggestions
      ├─ codegen        logic blocks → real Python by rewriting CPython ASTs
      ├─ sandbox        exec in a restricted namespace (no open/os/import)
      │
      ▼
   Program ──────────► server-side renderer ──────────► HTML + design tokens
      │                                                        │
      └────────── event handlers executed on the server ◄───────┘
                     (fresh HTML streamed back to the client)
```

**Reactivity model.** Weave is server-driven, in the spirit of Phoenix
LiveView. The first paint is plain HTML. A ~10 KB client runtime forwards DOM
events (with the values of every bound field) to the server; Weave executes the
matching handler against a transactional copy of the session state, re-renders
the view, and returns a new HTML fragment. The client swaps it in while
preserving focus, caret position, scroll offsets and in-flight typing, so the
app feels native even though all logic runs in Python.

This buys correctness: your handler sees real Python objects, not a JavaScript
approximation of them. `tasks.remove(task)` removes the *actual* dict; mutating
a captured loop variable writes through to state.

---

## Language tour

### `app`

Every file declares one app. The optional title is used for the document title.

```weave
app Weaveboard(title: "Weaveboard — a full-stack app in one file"):
```

### `state`

State is a flat namespace of typed-or-untyped values. Initializers are Python
expressions and run once per session (sessions get a deep copy).

```weave
state:
    count = 0
    tasks = [{"title": "Write the compiler", "done": true}]
    draft = ""
    filter = "All"
    tasks_done: int = 0            # optional annotation
    names: list[str] = ["Ada"]     # nested annotations are checked too
```

Assignments inside handlers write back to state automatically:

```weave
button("+1", click: {
    count = count + 1
    count += 1
})
```

### `view`

Components are function-like calls. Children go in an indented block after `:`.
Arguments are positional first, then named.

```weave
view:
    stack(padding: 24, gap: 12, align: center):
        row(justify: between):
            text("My Tasks", font: 28, bold: true)
            badge(f"{len(tasks)} total", variant: primary)

        input(bind: new_task, placeholder: "Add a task…", on_enter: {
            tasks.append(new_task)
            new_task = ""
        })

        for task in tasks:
            card(shadow: sm):
                text(task)
                button("Done", click: tasks.remove(task))
```

#### Loops and conditionals

```weave
for task in tasks:
    text(task)

for index, task in enumerate(tasks):
    text(f"{index + 1}. {task}")

if not tasks:
    card():
        text("Nothing left to do.", muted: true)
else:
    text("Keep going.", bold: true)
```

`else if` is written `else if …:` on its own indented line.

#### Attributes are expressions

Any value position is a Python expression, so interpolation, ternaries and
function calls all work:

```weave
text(f"{completed(tasks)} / {len(tasks)} done", muted: completed(tasks) == 0)
button("Undo", variant: ghost if can_undo else outline)
```

#### Design tokens as barewords

Attribute values may be design tokens instead of strings: `sm`, `md`, `lg`,
`center`, `between`, `primary`, `ghost`, `full`, `cover`, `row`, `column`, …
Numbers mean pixels (`padding: 24` → `24px`; `"50%"` stays as written).

### `function`

Reusable Python functions. They can read and write state and call each other.

```weave
function completed(items):
    return len([t for t in items if t["done"]])

function percent(items):
    if not items:
        return 0
    return round(completed(items) / len(items) * 100)
```

Call them from views (`metric(percent(tasks), "Progress")`) or handlers
(`tasks = sorted(tasks, key=lambda t: t["title"])`).

### `routes`

An app can expose multiple pages. Paths are matched exactly; `/` falls back to
the `view` block if no explicit route is declared. Internal links navigate
without a full reload.

```weave
routes:
    "/about":
        stack(padding: 30, gap: 16):
            title("About")
            text("One file, front to back.", muted: true)
            button("← Back", href: "/")
```

Use `link("/about")` or `button("About", href: "/about")` from anywhere.

### `styles` and `theme`

Reusable style blocks are referenced by name; CSS custom properties are
available anywhere.

```weave
styles:
    dashed:
        background: "transparent"
        border: "1px dashed var(--weave-border)"

theme:
    primary: "#5b5ef0"
    radius: 16
    mode: auto          # auto | light | dark
```

```weave
card(style: dashed):
    text("A softer card")
```

`theme` maps onto the design system's CSS variables; `mode` controls the colour
scheme, and a floating ◐ button lets users override light/dark per browser.

### Events

Any component can take `click:`; inputs add `on_enter`, `on_input`,
`on_change`, `on_blur`, `on_focus`; forms add `on_submit`. An event body is
either a **brace block of Python statements** or a **single expression**:

```weave
button("Done", click: tasks.remove(task))         # expression shorthand
button("Reset", click: {                          # statement block
    tasks = []
    toast("Board cleared", "success")
})
```

Event bodies can call the effect helpers `toast(message, kind)`, `log(...)`,
`navigate(path)`, `emit(name, payload)` and `print(...)`, and are executed
transactionally: if a handler raises, the state is rolled back and the browser
gets a source-located error diagnostic.

### Expressions & standard library

Weave evaluates expressions with Python semantics and a curated surface:

| kind | available |
|---|---|
| builtins | `len`, `str`, `int`, `float`, `bool`, `list`, `dict`, `set`, `tuple`, `range`, `enumerate`, `zip`, `sorted`, `reversed`, `min`, `max`, `sum`, `abs`, `round`, `any`, `all`, … |
| modules | `math`, `json`, `datetime`, `time`, `random`, `re`, `itertools`, `collections`, `statistics`, `hashlib`, `base64`, `string` |
| helpers | `now`, `today`, `uuid`, `parse_date`, `format_date`, `slugify`, `clamp`, `truncate`, `plural`, `group_by`, `lower`, `upper`, `capitalize`, `title`, `strip`, `replace`, `join`, `keys`, `values`, `items`, `is_empty`, `default` |
| effects | `toast`, `log`, `navigate`, `emit`, `print` |
| literals | `true` / `false` / `null` are accepted as well as Python's `True` / `False` / `None` |

`open`, `os`, `sys`, `eval`, `exec`, `import` and friends are deliberately not
available; the sandbox is a dict of approved builtins, not the whole interpreter.

### Diagnostics

Errors are first-class. Every message carries a code, an exact location, a
source excerpt and, where possible, a fix:

```
error[W2000]: unknown state variable 'taks'
  --> examples/todo.weave:14:22
     |
  14 |             for task in taks:
     |                          ^^^^
  = help: did you mean 'tasks'?
```

Runtime errors from handlers are translated back to the `.weave` file, shown in
the browser in a dismissible overlay, and printed to the terminal.

---

## Components

Weave ships with 34 declarative primitives. Run `weave components --examples`
for the full list; the highlights:

| category | components |
|---|---|
| layout | `stack`, `row`, `grid`, `center`, `card`, `section`, `hero`, `scroll`, `form`, `tabs` + `tab`, `divider`, `spacer` |
| content | `text`, `title`, `label`, `code`, `badge`, `link`, `image`, `avatar`, `icon`, `metric`, `progress` |
| forms | `input`, `textarea`, `checkbox`, `toggle`, `select`, `slider`, `button`, `icon_button` |
| data | `table`, `html` |

Common attributes work everywhere: `width`, `height`, `padding`, `margin`,
`gap`, `background`, `radius`, `border`, `shadow`, `align`, `justify`,
`visible`, `style`, `class`, `id`, `animate`, `tooltip`.

```weave
grid(columns: 3, gap: 12):
    metric(completed(tasks), "Completed", icon: "✓")
    metric(len(tasks) - completed(tasks), "Open", icon: "◌")
    metric(f"{percent(tasks)}%", "Progress", icon: "◔")

table(tasks, columns: ["title", "done"], striped: true, hover: true)
```

---

## CLI

```
weave run <file>            compile + serve with hot reload   (alias: serve, dev)
weave check <file>          compile and print a summary       (--json)
weave build <file>          export static first paint + standalone app.py  (-o, --port)
weave ast <file>            dump the AST, or generated Python (--python)
weave components            list the primitive vocabulary      (--examples, --json)
weave init [dir]            scaffold a starter app             (--force)
weave version
```

`weave build` produces:

| file | purpose |
|---|---|
| `index.html` | the app's initial state rendered as static HTML, design system inlined |
| `app.py` | a standalone server with the `.weave` source embedded — `python app.py` |
| `weave.json` | manifest, including the generated Python for inspection |
| `README.md` | deployment notes |

Options on `run`: `--port`, `--host`, `--open`, `--no-reload`, `--no-debug`.
`WEAVE_PORT` sets the default port.

---

## Examples

| file | demonstrates |
|---|---|
| `examples/todo.weave` | the canonical spec example: state, binding, `on_enter`, loop + captured handler argument |
| `examples/hello.weave` | the smallest useful app: a bound input and design-token badges |
| `examples/dashboard.weave` | routes, functions, tabs, select/toggle/slider, tables, metrics, progress, nested conditionals, named styles, theme |
| `weave init` | a starter app with loops, f-strings, effects and a counter |

---

## Testing

The engine has **76 tests** across the tokenizer, parser, analyzer, codegen,
renderer, runtime, HTTP server and CLI. No test dependencies.

```bash
python3 -m unittest discover -s tests -v
```

The server tests boot real HTTP servers on ephemeral ports, use cookie-aware
clients, and assert the full request → handler → re-render loop, session
isolation, stale-event recovery, transactional rollback and hot reload.

---

## Project layout

```
the_weave/
    source.py      tokenizer + source locations
    parser.py      recursive-descent parser → AST
    nodes.py       AST dataclasses
    components.py  the component registry (name, arity, attrs, events)
    analyzer.py    semantic checks with suggestions
    codegen.py     CPython AST rewriting → generated Python
    runtime.py     sandbox, Context, symbols, helpers, JSON bridge
    program.py     compiled program: state, handlers, rendering
    renderer.py    view AST → HTML + design tokens
    server.py      HTTP server, sessions, hot reload, app shell
    cli.py         the `weave` command
    static/        weave.css (design system) + weave.js (client runtime)
examples/          todo.weave, dashboard.weave
tests/             engine, server, CLI suites
docs/              LANGUAGE.md, ARCHITECTURE.md
```

---

## Limitations & roadmap

This is a **prototype**: deliberately small, honest about its edges.

* Server-driven reactivity means each interaction costs a round trip; localhost
  is instant, but a remote deployment would want batching, compression or a
  hybrid client-side expression compiler.
* Session state is in memory (per-process). A production engine needs a store
  (Redis/signed state) and multi-worker coordination.
* Component visuals are inline styles + one CSS file; there is no arbitrary
  component authoring or CSS cascade control yet.
* Python syntax inside handlers is supported via CPython's parser, but imports,
  `async`/`await`, generators-as-views and arbitrary classes are out of scope.
* No package system, no static type checker beyond state annotations, no
  escape-hatch for raw JS (by design).

Roadmap ideas: component plugin API, client-side expression compiler for
optimistic UI, WebSocket transport, file-backed persistence, `weave fmt`, a
formatter/linter, snapshot rendering tests, and an LSP with the existing
diagnostics.

---

## Further reading

- [`docs/LANGUAGE.md`](docs/LANGUAGE.md) — grammar, semantics, component and attribute reference
- [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) — compiler internals, event protocol, security model

---

MIT licensed. Built as a working prototype of a language that treats a web app
as a single, coherent artefact.
