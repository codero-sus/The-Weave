# Wire protocol

The server is authoritative: it owns the state, runs the handlers and computes the
view. The browser is a renderer that receives a tree once and patches after that.

Transport: one WebSocket per connection at `/ws`, text frames, one JSON object per
frame. Everything is UTF-8. The client reconnects with backoff and remounts from
scratch; nothing in the protocol requires the client to keep history.

---

## Server → client

### `hello`

First frame after the handshake, before any render.

```json
{ "t": "hello", "app": "TodoApp", "v": 1, "p": 1 }
```

| Field | Meaning                                     |
| ----- | ------------------------------------------- |
| `app` | App name from the `app Name:` declaration    |
| `v`   | Protocol version (currently `1`)             |
| `p`   | Module generation (bumped on hot reload)     |

### `mount`

The full render tree. Sent once per session, and again after a reconnect.

```json
{ "t": "mount", "root": { … node … } }
```

### `patch`

A delta against the tree the client already has.

```json
{ "t": "patch", "ops": [ { "o": "u", "i": 6, "p": { "value": "Ship it" } } ] }
```

| `o` | Meaning | Fields                                            |
| --- | ------- | ------------------------------------------------- |
| `r` | remove  | `i` — node id                                      |
| `i` | insert  | `p` — parent id, `a` — index, `n` — node           |
| `m` | move    | `i` — node id, `p` — new parent, `a` — new index    |
| `u` | update  | `i`, plus any of `x` (text), `p` (props), `e` (events) |

Ops are ordered: removals first, then moves and inserts. A prop whose value is `null`
is removed from the node. Ids are stable across patches — the id from `mount` still
addresses the same logical node after any number of updates.

### `state`

Optional debug frame carrying the whole signal map.

```json
{ "t": "state", "state": { "tasks": ["Learn Weave"], "new_task": "" } }
```

### `error`

A runtime failure in a handler, effect or render. The session stays alive.

```json
{ "t": "error", "message": "handler 'submit': index out of bounds (line 14)" }
```

### `reload`

The source file changed and was recompiled. The client should close and reconnect,
which produces a fresh `hello` + `mount` against the new build.

```json
{ "t": "reload" }
```

### `pong`

Response to a client `ping`.

```json
{ "t": "pong" }
```

---

## Node encoding

Nodes are compact because they travel on every insert.

```json
{
  "i": 6,
  "t": "input",
  "x": "My Tasks",
  "p": { "font": 28, "bold": true },
  "e": ["click", "enter"],
  "b": "new_task",
  "c": [ { … } ]
}
```

| Key | Field           | Omitted when                     |
| --- | --------------- | -------------------------------- |
| `i` | node id         | never                            |
| `t` | tag name        | never                            |
| `x` | text content    | the node has no text             |
| `p` | props           | the node has no props            |
| `e` | event names     | the node has no handlers         |
| `b` | bound signal    | the node is not two-way bound    |
| `c` | children        | the node is a leaf               |

Text-only leaves (`{ "i": 3, "t": "text", "x": "My Tasks" }`) become DOM `Text` nodes
rather than elements, which keeps the DOM small for long lists.

`e` only ever contains names from this list; anything else is dropped at compile time:

```
click  dblclick  change  input  enter  submit  key  focus  blur  scroll
```

---

## Client → server

### `event`

A handler invocation. `id` is the node the event was registered on.

```json
{ "t": "event", "id": 7, "name": "click", "args": [] }
```

`args` is optional and defaults to `[]`. The server looks the id up in the current
tree; an unknown id or an event the node does not declare is ignored rather than
fatal, because a click can legitimately arrive just after the node was removed.

### `input`

A two-way binding write for a node carrying `b`.

```json
{ "t": "input", "id": 6, "value": "Ship something" }
```

The server writes the bound signal, flushes, and sends back a patch. The client
ignores value patches for the field it is currently typing in, so the caret stays put.

### `ping`

```json
{ "t": "ping" }
```

Answered with `pong`. The reference client sends one every 25 s.

---

## A complete exchange

Typing "Ship the prototype" into the bound input and pressing enter:

```
→ {"t":"input","id":6,"value":"Ship the prototype"}
← {"t":"patch","ops":[{"o":"u","i":6,"p":{"value":"Ship the prototype"}}]}
→ {"t":"event","id":6,"name":"enter"}
← {"t":"patch","ops":[
     {"o":"i","p":1,"a":3,"n":{"i":9,"t":"card","p":{"shadow":"sm"},"c":[…]}},
     {"o":"u","i":6,"p":{"value":""}}
   ]}
```

One interaction, two frames back, no state shipped to the client.

---

## HTTP surface

| Path                    | Response                                        |
| ----------------------- | ----------------------------------------------- |
| `/`, `/index.html`      | The client shell (`assets/index.html`)           |
| `/client.js`            | The renderer (`assets/client.js`)                |
| `/client.css`           | Default styles (`assets/client.css`)             |
| `/favicon.ico`          | `204`                                            |
| `/health`               | `{"ok":true,"app":…,"version":…,"generation":…,"connections":…,"uptime_ms":…}` |
| `/ws`                   | WebSocket upgrade                                |
| anything else           | `404`; non-GET methods `405`                     |

`GET /health` is the cheap liveness probe for CI and load balancers.
