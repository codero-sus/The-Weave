# The Weave language

Weave is a single-file full-stack language. One `.weave` file holds the state, the
logic, the effects and the layout; the engine compiles it to bytecode, runs it on a
server-authoritative VM, and streams the resulting UI to a browser.

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

Run it:

```sh
weave examples/todo.weave          # http://127.0.0.1:8080
```

---

## 1. File shape

A file contains one `app` declaration and any number of `component` declarations.
`#` starts a comment that runs to the end of the line.

```weave
component StatCard(label, value, tone = "neutral"):
    card(shadow: sm):
        text(label)
        badge(tone)

app Dashboard:
    state:
        users = 128

    view:
        stack(gap: 12):
            StatCard("users", users, "accent")
```

Blocks are indentation based, like Python: a line ending in `:` opens a block, the
block is every following line indented *more* than the header, and dedenting closes
it. Any consistent indent width works (spaces or tabs); the examples use four spaces.
Mixing widths inside one file is an error rather than a guess.

### Sections

An `app` body is a sequence of named sections. All of them are optional, and they
may appear in any order.

| Section      | What it holds                                                        |
| ------------ | -------------------------------------------------------------------- |
| `state:`     | Mutable signals, initialised once when the app starts                 |
| `computed:`  | Derived signals, recomputed whenever a signal they read changes        |
| `theme:`     | Colour/scale tokens, addressable as `theme.<name>`                     |
| `styles:`    | Reusable prop maps, addressable as `styles.<name>`                     |
| `handlers:`  | Named functions callable from the view or from other handlers          |
| `effects:`   | `on_mount:` and `on <signal>:` reactive side effects                  |
| `view:`      | The layout tree                                                        |

```weave
app Themed:
    state:
        dark = false

    theme:
        bg = "#0f1115" if dark else "#f7f7f9"
        fg = "#eceef4" if dark else "#14161a"

    styles:
        page = { "padding": 32, "gap": 16 }
        title = { "font": 30, "bold": true }

    view:
        stack(padding: styles.page["padding"], gap: styles.page["gap"],
              bg: theme.bg, color: theme.fg):
            heading("Theming", font: styles.title["font"], bold: styles.title["bold"])
```

`theme:` and `styles:` compile to one map-valued signal each, so a handler can write
to them like any other state (`theme.accent = "#f00"`) and the view re-renders. Read
individual entries with an index (`styles.page["padding"]`); a whole-map spread form
is not in this release.

---

## 2. Values and expressions

| Value    | Syntax                                              |
| -------- | --------------------------------------------------- |
| Integer  | `0`, `42`, `-7` (arbitrary precision is *not* used; `i64`) |
| Float    | `1.5`, `0.25`, `2.0`                                |
| Boolean  | `true`, `false`                                     |
| Nil      | `nil` (also `null`, `none`)                         |
| String   | `"text"`, `'text'`, escapes `\n \t \\ \" \{ \}`     |
| List     | `[1, 2, 3]`, `[]`                                   |
| Map      | `{ "key": value }`, `{}`                             |

### Operators

```
Arithmetic   +  -  *  /  //  %  **        (unary -)
Comparison   == != <  <= >  >=
Membership   in   not in
Logical      and  or  not
Conditional  A if cond else B
Indexing     xs[i]   m["k"]   xs[1:4]   s[2:]
Member       theme.bg   xs.len()
Interpolation "count: {n}, doubled: {n * 2}"
```

`+` is overloaded: number + number adds, string + string concatenates, list + list
extends. `/` always produces a float; `//` is floor division. `**` is power.

String interpolation uses `{ … }` and accepts any expression. A literal brace is
written `\{` / `\}` or `{{` / `}}` — both mean the same thing. Interpolations compile
to a `concat` instruction rather than runtime string scanning, so they cost one pass
over the parts:

```weave
"brace \{ literal \}"        ->  brace { literal }
"{{double}}"                 ->  {double}
"mix {1 + 1} and \{"         ->  mix 2 and {
```

### Precedence

`or` < `and` < `not` < comparisons/`in` < `+ -` < `* / // %` < unary `-` < `**`.
Parenthesise when in doubt; the parser is a straightforward precedence climber and
never surprises you.

### Reserved words

```
if else elif for in and or not true false null none return
after key while break continue pass is
```

`while`, `is` and `pass` are reserved so they can be implemented later without
breaking code that used them as identifiers. Use `for` for iteration today.

---

## 3. Statements

```weave
handlers:
    bump(by):
        count += by            # = += -= *= /=
        items.append(by)
        items.extend([1, 2])

        if count > 10:
            items.pop()
        elif count > 5:
            items.remove(by)
        else:
            pass

        for i, x in items:     # or: for x in items:
            if x == nil:
                break
            elif x < 0:
                continue
            count += i

        after 500:             # schedule on the session clock, in milliseconds
            count = 0

        return count
```

* **Assignment** targets a name, an index (`m["k"] = v`, `xs[0] = v`) or a member
  (`theme.accent = "#f00"`). Augmented forms exist for `+ - * /`.
* **`for`** iterates lists, strings, maps (key order = insertion order) and ranges.
  `for i, x in xs` binds the index and the value; `for k, v in m` binds key/value.
  The `key` form (`for x in xs key x:`) exists in *view* loops only — see §5.
* **`after <ms>:`** arms a timer on the running session. Its body is a normal block
  and may contain further statements, including another `after`. The session clock
  advances in `--poll` milliseconds (default 50), which is also the timer resolution.
* **`return`** exits the current handler; a handler without `return` yields `nil`.

Handler parameters may have defaults (`component Badge(tone = "neutral")`) and are
called positionally or by name (`StatCard(value: 3, label: "users")`).

---

## 4. Builtins

Functions: `len count str int float bool abs min max sum round floor ceil range
sorted reversed print log now random rand_int type_of clone keys values items first
last contains join enumerate has get push remove insert pop clear upper lower strip
split replace starts_with ends_with index_of slice set`

Methods on lists, strings and maps (`xs.len()` and `len(xs)` are the same call):

```
list    len append extend insert remove pop clear sort reverse contains index
        first last slice join count at
string  len upper lower strip trim split replace starts_with ends_with contains
        index_of substr slice find
map     len keys values items has get put set delete clear
number  abs round floor ceil min max
any     str int float bool clone type_of
```

`log(...)` writes to the server log; `print(...)` does the same. Neither blocks the
render loop.

---

## 5. The view

A view is a tree of element calls. Every element takes positional arguments (its
content) and named arguments (its props and events). A trailing `:` opens a child
block.

```weave
view:
    stack(padding: 24, gap: 12, align: center):
        heading("Tasks", font: 28, bold: true)
        text("{tasks.len()} open")

        for task in tasks key task:
            card(shadow: sm, padding: 12):
                text(task)
                button("Done", click: complete(task))

        if tasks.len() == 0:
            badge("all clear", tone: "success")

        input(bind: draft, placeholder: "Add a task", on_enter: add())
```

### Elements

| Group     | Tags                                                                        |
| --------- | --------------------------------------------------------------------------- |
| Layout    | `stack` `column` `row` `box` `div` `card` `grid` `scroll` `spacer` `divider` |
| Text      | `text` `p` `span` `heading` `h1` `h2` `h3` `badge` `code` `pre`             |
| Input     | `input` `textfield` `textarea` `checkbox` `toggle` `button` `btn`           |
| Media     | `image` `img` `link` `a`                                                     |

The first positional argument of `input`/`textfield`/`textarea` is its `placeholder`,
of `image`/`img` its `src`, of `spacer` its `size`. For everything else the first
positional argument is text content. A bare string in a view is a text node.

### Props

Layout and appearance props are passed through to the client renderer:
`padding margin gap align justify grow shrink width height min_width max_width
min_height max_height bg color font weight bold italic radius border shadow opacity
flex wrap order z`. Numeric values become pixels; `align` maps to `align-items` on
containers and `text-align` on text; `shadow` takes `sm | md | lg`; `radius: full`
means a pill. Unknown props are still delivered, so custom client themes can read
them.

### Events

```weave
button("Save", click: save())                 # inline expression
button("Reset", click: { count = 0 })         # inline block
input(bind: draft, on_enter: submit())
row(scroll: on_scroll())
card(dblclick: open(item))
```

Supported event names: `click dblclick change input enter submit key focus blur
scroll`. The `on_` prefix is optional (`on_click` ≡ `click`). Handler bodies run on
the server, against the real signal values, inside the session that owns the click.

### Two-way binding

`bind: <signal>` on an input ties its value to a signal. Typing sends an `input`
frame; the server writes the signal, re-renders, and patches the value back — the
client suppresses the echo while the field has focus so the caret does not jump.

### Control flow in a view

`for` and `if/elif/else` are view-level constructs: they expand at render time and
produce real nodes. Give a loop a `key` expression when items can be reordered or
removed — the diff pairs keyed nodes across renders, so identity (and DOM state such
as focus or scroll position) survives. Without a key, nodes are matched positionally.

A view with more than one top-level node is wrapped in an implicit `stack`; an empty
view renders an empty `box`.

---

## 6. Components

```weave
component StatCard(label, value, tone = "neutral"):
    card(shadow: sm, padding: 16, gap: 4):
        text(label, font: 12, color: "#6b7280")
        text("{value}", font: 24, bold: true)
        badge(tone)

component Counter(display, on_click):
    row(gap: 8, align: center):
        text(display, font: 18)
        button("click", click: on_click())

app Dashboard:
    state:
        clicks = 0
    handlers:
        register_click():
            clicks += 1
    view:
        stack(gap: 12):
            StatCard("clicks", clicks, "accent")
            Counter(display: "clicks: {clicks}", on_click: register_click)
```

A component is a compiled function that writes into the view builder. Its parameters
are ordinary values, so passing a handler name (`on_click: register_click`) passes a
callable the component can invoke — that is how a child raises an event to its parent.
Component bodies may use an optional explicit `view:` header; a bare indented block
is the same thing.

---

## 7. Effects

```weave
effects:
    on_mount:
        log("app is live")
        load()

    on count:
        log("count is now {count}")

    on count:
        after 250:
            log("settled at {count}")
```

* `on_mount:` runs once, after the first render, outside the dependency tracker —
  writes it makes do not retrigger it.
* `on <signal>:` runs whenever that signal changes. Reads inside an effect body are
  tracked, so an effect that reads other signals also reruns when *those* change.
* Effects run on the session's thread between renders; they are not concurrent with
  the view.

---

## 8. Reactivity rules

1. A signal write that does not change the value (structural comparison) notifies
   nobody. `count = count` is free.
2. In-place mutation is tracked: `tasks.append(x)`, `m.put(k, v)` and friends mark
   the owning signal dirty, so views and computeds that read it update.
3. Every change settles to a fixpoint in a fixed order: computed signals (priority 0),
   then effects (1), then the render (2). The scheduler makes at most 16 passes and
   reports a cycle instead of hanging.
4. Render output is diffed against the previous tree; only the delta goes over the
   wire. Node ids are stable across patches, so a click on id 42 still addresses the
   node the client drew.
5. Each browser connection owns an independent session: its own signal values, its
   own timers. There is no shared mutable state between connections in this release.

---

## 9. Diagnostics

Errors and warnings point at the source with a caret, a span and a hint:

```
[E001]: expected an indented block, found card
  --> examples/components.weave:5:5
    |
  5 |     card(shadow: sm, padding: 16, gap: 4):
    |     ^^^^

[W001]: unknown name 'totl'
  --> app.weave:12:21
    = hint: did you mean 'total'?
```

`weave check` prints them and exits non-zero; `weave run` prints them and refuses to
serve. Runtime failures report the signal/handler that threw plus a VM stack trace
(`weave dump` shows the bytecode line numbers those traces refer to).

---

## 10. What is not in this release

* `while` loops, `is`/`is not`, a style-map spread (`**styles.page`), `try/except`.
* Persistence and cross-session broadcast: state lives in the session, so a reload
  starts from the source defaults.
* A package manager and imports: one file is the unit of compilation.
* Server-side HTTP clients (no `fetch`), file I/O and process spawning inside `.weave`
  code — the VM is sandboxed to signals, builtins, timers and the view.
* Source maps beyond line numbers, and a formatter.
