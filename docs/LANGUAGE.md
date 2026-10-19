# The Weave Language

Version 0.1 · prototype specification

Weave is an indentation-sensitive, single-file language. A file declares exactly
one app, and that app is the whole program: state, behaviour, structure,
styling and routing.

The reference implementation is the Python package in `the_weave/`. This
document describes the language *as implemented*, including deliberate limits.

---

## 1. Lexical structure

* **Indentation** — spaces only. Tabs are rejected with a diagnostic. Blocks are
  introduced by `:` at the end of a line; the following indented lines form the
  block. Dedents must match an enclosing indentation level.
* **Newlines** — significant at bracket depth 0. Inside `( … )`, `[ … ]` or
  a handler `{ … }`, newlines are insignificant.
* **Comments** — `#` to end of line.
* **Names** — `[A-Za-z_][A-Za-z0-9_]*`.
* **Numbers** — integers and floats, `_` separators allowed (`1_000`).
* **Strings** — single or double quoted, Python escape rules, optional prefixes
  `f`, `r`, `b`, `u` and combinations (`fr"…"`). Strings cannot span lines.
* **Literals** — `true`/`false`/`null` (and `nil`, `none`) are accepted in
  expression position and normalised to Python's `True`/`False`/`None`.
* **Symbols** — barewords used as attribute values (`sm`, `center`, `primary`)
  are design tokens, not variables. Unknown single identifiers in attribute
  position degrade to strings (so `type: email` and `color: red` work).

---

## 2. Grammar

```ebnf
program     = "app" NAME [ "(" config ")" ] ":" NEWLINE INDENT section+ DEDENT EOF ;

config      = config_item ("," config_item)* ;
config_item = NAME ":" expression ;

section     = state | view | routes | styles | theme | function ;

state       = "state" ":" NEWLINE INDENT decl+ DEDENT ;
decl        = NAME [ ":" type ] "=" expression NEWLINE ;

view        = "view" ":" NEWLINE INDENT view_item+ DEDENT ;

routes      = "routes" ":" NEWLINE INDENT route+ DEDENT ;
route       = STRING [ "(" "title" ":" STRING ")" ] ":" NEWLINE INDENT view_item+ DEDENT ;

styles      = "styles" ":" NEWLINE INDENT style+ DEDENT ;
style       = NAME ":" NEWLINE INDENT property+ DEDENT ;
property    = NAME ":" expression NEWLINE ;

theme       = "theme" ":" NEWLINE INDENT property+ DEDENT ;

function    = ("function" | "def" | "fn" | "computed") NAME
              [ "(" python_params ")" ] [ "->" type ] ":" NEWLINE INDENT python+ DEDENT ;

view_item   = component | for | if ;

component   = NAME [ "(" args ")" ] [ ":" NEWLINE INDENT view_item+ DEDENT ] ;

for         = "for" NAME [ "," NAME ] "in" expression ":" NEWLINE INDENT view_item+ DEDENT ;
if          = "if" expression ":" NEWLINE INDENT view_item+ DEDENT
              [ "else" ":" NEWLINE INDENT view_item+ DEDENT
              | "else" if ] ;

args        = argument ("," argument)* [","] ;
argument    = NAME ":" value | expression ;
value       = expression | handler ;
handler     = "{" python+ "}" | expression ;

type        = NAME [ "[" type ("," type)* "]" ] ;
expression  = Python expression ;
python      = Python statement block, dedented relative to its braces ;
```

Notes:

* A component block must be indented on following lines; inline
  `row(): text("x")` is **not** valid.
* `for` accepts at most two targets — `item` or `index, item`. The index is the
  enumeration index (`enumerate(items)`).
* `else if cond:` is supported as sugar for a nested `if` in the else branch.
* Function parameters and bodies are Python; annotations are accepted for
  documentation but stripped before execution.

---

## 3. State

```weave
state:
    count = 0
    tasks: list[dict] = []
    draft = ""
```

* Declarations run **in order**; an initializer may reference earlier state.
* Each session receives a deep copy of the evaluated template.
* Annotations (`int`, `float`, `str`, `bool`, `list`, `dict`, `set`, `any`, and
  `list[T]`) are validated at compile time. Unsupported annotation names are
  ignored rather than rejected.
* State is the only durable data. Local variables inside handlers/functions are
  discarded when the handler returns.
* Reserved-by-convention names: `state`, `ctx`, `log`, `toast`, `navigate`,
  `emit`, `print`. The engine binds these inside every generated function; do
  not use them as state or function names.

### Assignment semantics

Inside handlers and functions, a bare assignment to a state name writes through:

```weave
count = count + 1        # → ctx.st['count'] = ctx.st['count'] + 1
tasks.append("new")      # mutations persist
row["done"] = True       # captured loop items are live objects
total += 1               # augmented assignment works
```

The compiler rewrites state access at the AST level. Any name that is *not*
state stays a normal Python local.

---

## 4. Views

A view is a tree of component calls. Positional arguments come first, then named
attributes.

```weave
card(shadow: sm):
    row(justify: between, align: center):
        text("Inbox", font: 20, bold: true)
        badge(f"{count}", variant: primary)
    divider()
    for message in messages:
        text(message["subject"])
```

### Conditionals

```weave
if loading:
    text("Loading…", muted: true)
else:
    text("Ready")
```

`visible: false` hides a node without removing it from the tree; `if` removes it
entirely. Use `if` when surrounding layout should collapse.

### Loops

```weave
for item in items:              # item
for i, item in enumerate(items):  # index, item
```

Loop variables are available to expressions and are captured by event handlers
that appear inside the loop body.

### Attribute values

Attribute values are Python expressions evaluated on the server against the
current state:

```weave
text(task["title"], color: danger if task["late"] else muted)
input(placeholder: f"Add to {project_name}…")
image(task["cover"], radius: lg)
```

Common attributes are shared by all components:

| attribute | meaning |
|---|---|
| `width`, `height` | dimensions; numbers are px, also `full`, `half`, `auto`, `fit` |
| `padding`, `margin`, `gap` | spacing; numbers are px, tokens map to a scale, `"8 16"` works |
| `background`, `color` | theme colour names or any CSS colour |
| `radius`, `shadow`, `border` | design tokens or raw CSS |
| `align`, `justify`, `direction`, `wrap` | flexbox controls |
| `visible`, `opacity`, `z`, `grow`, `align_self` | layout/visibility controls |
| `style`, `class`, `id` | named style reference, extra classes, DOM id |
| `animate` | `fade`, `slide`, `pop` |
| `tooltip` | native title text |

### Design tokens

```
sizes      xs sm md lg xl xxl full half third auto fit screen
alignment  start end center between around evenly stretch baseline
           left right top bottom middle
flow       row column wrap nowrap reverse
palette    primary secondary accent muted danger success warning info
emphasis   ghost outline solid subtle transparent inherit
misc       hidden visible cover contain thin thick dashed dotted
           round pill bold normal italic mono sans uppercase lowercase
           fast slow smooth
```

---

## 5. Events

| attribute | DOM event | typical components |
|---|---|---|
| `click` / `on_click` | click | everything |
| `on_enter` / `enter` | Enter key | inputs, textareas |
| `on_input` | input | inputs, textareas |
| `on_change` / `change` | change | inputs, selects, checkboxes, sliders |
| `on_blur`, `on_focus` | focus events | inputs |
| `on_submit` / `submit` | form submit | `form` |
| `on_dblclick`, `on_keydown`, `on_keyup` | as named | interactive components |

Two handler forms:

```weave
button("Done", click: tasks.remove(task))

button("Clear", click: {
    tasks = []
    toast("Cleared", "success")
})
```

The expression form is evaluated when the event fires; the block form executes
as a Python statement block. Both receive captured loop variables.

### `bind`

`bind: <state variable>` connects a form control to state. Bound values are
applied to state *before* the event handler runs, and are coerced to the state
variable's type (ints, floats, booleans, lists and dicts via JSON).

```weave
input(bind: draft, on_enter: save())
checkbox(bind: notify_me)
slider(bind: priority, min: 1, max: 5)
select(bind: status, options: ["Backlog", "Doing", "Done"])
```

`tabs(bind: current)` is special: it is not an input, but writes the selected
tab label into the bound state variable.

### Effects

| function | effect |
|---|---|
| `toast(message, kind="info")` | transient notification (`info`, `success`, `warning`, `error`) |
| `log(*args)` | print to the server console and browser console |
| `print(*args)` | alias for `log` inside Weave code |
| `navigate(path)` | client-side navigation after the handler completes |
| `emit(name, payload)` | record a custom event (delivered in the response payload) |

---

## 6. Components

The registry is authoritative; `weave components --examples` prints it, and
`weave components --json` emits machine-readable metadata.

Container components take an indented child block; the rest are self-contained
(some, like `table`, take data).

| signature | purpose | attributes (abridged) | events |
|---|---|---|---|
| `stack` | vertical flex container | `align`, `background`, `border`, `direction`, `divider`, `gap`, `grow`, `height`, `justify`, `margin` … | `click` |
| `row` | horizontal flex container | `align`, `background`, `border`, `direction`, `gap`, `grow`, `height`, `justify`, `margin`, `max_height` … | `click` |
| `grid` | CSS grid container (columns: 3) | `align`, `background`, `border`, `columns`, `direction`, `gap`, `grow`, `height`, `justify`, `margin` … | `click` |
| `center` | centres its children on both axes | `align`, `background`, `border`, `direction`, `gap`, `grow`, `height`, `justify`, `margin`, `max_height` … | `click` |
| `card` | surface container with padding, radius and shadow | `align`, `background`, `border`, `collapsible`, `direction`, `gap`, `grow`, `height`, `hover`, `justify` … | `click`, `on_click` |
| `section` | labelled page section | `align`, `background`, `border`, `direction`, `gap`, `grow`, `height`, `justify`, `margin`, `max_height` … | `click` |
| `hero` | page hero / banner | `align`, `background`, `border`, `direction`, `gap`, `grow`, `height`, `justify`, `margin`, `max_height` … | `click` |
| `scroll` | scrollable container | `align`, `background`, `border`, `direction`, `gap`, `grow`, `height`, `justify`, `margin`, `max_height` … | `click` |
| `form` | form wrapper (fires on_submit) | `align`, `background`, `border`, `direction`, `gap`, `grow`, `height`, `justify`, `margin`, `max_height` … | `click`, `on_submit`, `submit` |
| `tabs` | segmented control; `bind` holds the selected tab label | `bind`, `class`, `full`, `gap`, `id`, `margin`, `padding`, `style`, `variant`, `visible` | — |
| `tab(arg1)` | a single tab inside tabs() | `count`, `icon` | — |
| `divider` | horizontal rule | `class`, `color`, `id`, `margin`, `padding`, `style`, `visible` | — |
| `spacer` | flexible empty space | `class`, `grow`, `height`, `id`, `style`, `visible`, `width` | — |
| `text(arg1)` | paragraph of text; first argument is the content | `align`, `bold`, `color`, `font`, `font_family`, `italic`, `letter_spacing`, `line_height`, `max_width`, `mono` … | `click` |
| `title(arg1)` | page heading | `align`, `bold`, `color`, `font`, `font_family`, `italic`, `letter_spacing`, `line_height`, `max_width`, `mono` … | `click` |
| `label(arg1)` | small inline label | `align`, `bold`, `color`, `font`, `font_family`, `italic`, `letter_spacing`, `line_height`, `max_width`, `mono` … | — |
| `code(arg1)` | monospace code block | `background`, `class`, `color`, `font`, `id`, `margin`, `padding`, `radius`, `style`, `visible` … | — |
| `badge(arg1)` | small pill label | `background`, `class`, `color`, `id`, `radius`, `size`, `style`, `variant`, `visible` | — |
| `link(arg1)` | hyperlink | `bold`, `class`, `color`, `external`, `href`, `id`, `size`, `style`, `underline`, `visible` | `click` |
| `image(arg1)` | image by URL or local path | `alt`, `bg`, `border`, `class`, `fit`, `height`, `id`, `margin`, `padding`, `radius` … | `click`, `on_click` |
| `avatar(arg1)` | round profile image | `alt`, `border`, `class`, `id`, `radius`, `size`, `style`, `visible` | — |
| `icon(arg1)` | emoji or single glyph icon | `background`, `class`, `color`, `id`, `padding`, `radius`, `size`, `style`, `visible` | `click` |
| `metric(arg1[, …])` | big number with a caption: metric(value, label) | `align`, `background`, `border`, `class`, `color`, `icon`, `id`, `label`, `padding`, `radius` … | — |
| `progress(arg1[, …])` | progress bar: progress(0.7) or progress(done, total) | `background`, `class`, `color`, `height`, `id`, `label`, `max`, `radius`, `show_value`, `style` … | — |
| `input` | single-line text input, usually with bind: | `autocomplete`, `autofocus`, `bind`, `clearable`, `disabled`, `error`, `help`, `icon`, `label`, `mask` … | `change`, `enter`, `on_blur`, `on_change`, `on_enter`, `on_focus`, `on_input`, `submit` |
| `textarea` | multi-line text input | `autocomplete`, `autofocus`, `bind`, `clearable`, `disabled`, `error`, `help`, `icon`, `label`, `mask` … | `change`, `enter`, `on_blur`, `on_change`, `on_enter`, `on_focus`, `on_input`, `submit` |
| `checkbox` | checkbox bound to a boolean state | `autocomplete`, `autofocus`, `bind`, `clearable`, `disabled`, `error`, `help`, `icon`, `label`, `mask` … | `change`, `enter`, `on_blur`, `on_change`, `on_enter`, `on_focus`, `on_input`, `submit` |
| `toggle` | switch bound to a boolean state | `autocomplete`, `autofocus`, `bind`, `clearable`, `disabled`, `error`, `help`, `icon`, `label`, `mask` … | `change`, `enter`, `on_blur`, `on_change`, `on_enter`, `on_focus`, `on_input`, `submit` |
| `select` | dropdown bound to a state value | `autocomplete`, `autofocus`, `bind`, `clearable`, `disabled`, `error`, `help`, `icon`, `label`, `mask` … | `change`, `enter`, `on_blur`, `on_change`, `on_enter`, `on_focus`, `on_input`, `submit` |
| `slider` | range slider bound to a number | `autocomplete`, `autofocus`, `bind`, `clearable`, `disabled`, `error`, `help`, `icon`, `label`, `mask` … | `change`, `enter`, `on_blur`, `on_change`, `on_enter`, `on_focus`, `on_input`, `submit` |
| `button(arg1)` | button with a click handler | `color`, `disabled`, `full`, `href`, `icon`, `icon_right`, `loading`, `size`, `submit`, `title` … | `click`, `on_click`, `on_press` |
| `icon_button(arg1)` | square icon-only button | `color`, `disabled`, `full`, `href`, `icon`, `icon_right`, `loading`, `size`, `submit`, `title` … | `click`, `on_click` |
| `table(arg1)` | table from a list of dicts: table(rows, columns: [...]) | `background`, `border`, `class`, `columns`, `compact`, `header`, `hover`, `id`, `margin`, `padding` … | — |
| `html(arg1)` | raw HTML escape hatch | `class`, `id`, `margin`, `padding`, `style`, `visible`, `width` | — |

### Child-only components

`tab` is only meaningful inside `tabs`; rendering it elsewhere produces a
standalone pill.

---

## 7. Evaluation model

1. The server renders the view with the session's state. Every element receives
   a deterministic `data-w` path.
2. The browser sends `{ path, event, values }` for an interaction, including
   the current values of all bound fields.
3. The engine copies the state (transaction), applies bound values, re-renders
   to resolve the handler and its loop captures, then executes the handler.
4. On success the state replaces the session state and a fresh HTML fragment is
   returned. On failure the transaction is discarded and a structured error is
   returned.
5. The client swaps the fragment in, restoring focus, caret, scroll and any
   in-flight typing.

Because re-rendering is deterministic, paths are stable across renders while
the tree shape is unchanged. If a path no longer exists, the engine reports a
*stale event* and refreshes the client.

---

## 8. Errors

| code | stage | meaning |
|---|---|---|
| `W1000` | lexer/parser | indentation, bracket, string or grammar error |
| `W2000` | compiler | unknown component/attribute/name, bad bind, type mismatch |
| `W3000` | runtime | Python exception inside an expression or handler |
| `W4004` | runtime | expired session |
| `W4090` | runtime | stale event path (view changed) |
| `W5000` | server | internal engine error |

Diagnostics include `file:line:col`, a caret excerpt and a hint (often a
`did you mean …?` suggestion from `difflib`).

---

## 9. Deliberate limits

* No imports or module system; the approved runtime surface is fixed.
* No user-defined components (the primitive vocabulary is the extension point).
* No `async` handlers, threads or background jobs.
* No client-side computation beyond binding echo; all expressions run on the
  server.
* No arbitrary CSS files; the design system is themeable but opinionated.
* No persistence: session state lives in memory for the lifetime of the process.

These are prototype boundaries, not accidents; see the roadmap in the README.
