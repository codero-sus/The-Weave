/* Weave browser client.
 *
 * The server owns all application state. This file is a thin, dependency-free
 * renderer: it turns the JSON vdom it receives into DOM, applies patch ops in
 * place, and sends user interaction back over the same socket.
 *
 * Frames in:  hello | mount | patch | error | reload | state | pong
 * Frames out: event | input | ping
 */
(function () {
  "use strict";

  var WS_PATH = "/ws";
  var nodes = new Map(); // id -> { el, spec, textNode, bind }
  var root = null;
  var appEl = document.getElementById("app");
  var statusEl = document.getElementById("weave-status");
  var errorEl = document.getElementById("weave-error");
  var ws = null;
  var retry = 0;
  var lastSentValue = new Map(); // id -> string we last reported
  var appName = "Weave";

  // ---------------------------------------------------------------- tags ---

  var TAGS = {
    stack: { el: "div", cls: "weave-stack", flex: "column" },
    column: { el: "div", cls: "weave-stack", flex: "column" },
    row: { el: "div", cls: "weave-row", flex: "row" },
    box: { el: "div", cls: "weave-box", flex: "column" },
    div: { el: "div", cls: "weave-box", flex: "column" },
    card: { el: "div", cls: "weave-card", flex: "column" },
    grid: { el: "div", cls: "weave-grid", flex: "grid" },
    text: { el: "p", cls: "weave-text" },
    p: { el: "p", cls: "weave-text" },
    span: { el: "span", cls: "weave-text" },
    heading: { el: "h2", cls: "weave-heading" },
    h1: { el: "h1", cls: "weave-heading" },
    h2: { el: "h2", cls: "weave-heading" },
    h3: { el: "h3", cls: "weave-heading" },
    button: { el: "button", cls: "weave-button" },
    btn: { el: "button", cls: "weave-button" },
    input: { el: "input", cls: "weave-input" },
    textfield: { el: "input", cls: "weave-input" },
    textarea: { el: "textarea", cls: "weave-textarea" },
    checkbox: { el: "input", cls: "weave-checkbox", type: "checkbox" },
    toggle: { el: "input", cls: "weave-checkbox", type: "checkbox" },
    image: { el: "img", cls: "weave-image" },
    img: { el: "img", cls: "weave-image" },
    link: { el: "a", cls: "weave-link" },
    a: { el: "a", cls: "weave-link" },
    divider: { el: "hr", cls: "weave-divider" },
    hr: { el: "hr", cls: "weave-divider" },
    badge: { el: "span", cls: "weave-badge" },
    code: { el: "pre", cls: "weave-code" },
    pre: { el: "pre", cls: "weave-code" },
    scroll: { el: "div", cls: "weave-scroll", flex: "column" },
    spacer: { el: "div", cls: "weave-spacer" },
  };

  function isTextLeaf(n) {
    return (
      n.t === "text" &&
      n.x !== undefined &&
      !n.p &&
      !n.e &&
      !n.c &&
      !n.b
    );
  }

  // --------------------------------------------------------------- props ---

  var PX_PROPS = {
    padding: "padding",
    margin: "margin",
    gap: "gap",
    width: "width",
    height: "height",
    min_width: "min-width",
    min_height: "min-height",
    max_width: "max-width",
    max_height: "max-height",
    top: "top",
    left: "left",
    right: "right",
    bottom: "bottom",
    font: "font-size",
    size: "font-size",
    radius: "border-radius",
    border: "border-width",
    letter_spacing: "letter-spacing",
    line_height: "line-height",
    flex_grow: "flex-grow",
    flex_basis: "flex-basis",
  };

  var RAW_PROPS = {
    opacity: "opacity",
    flex: "flex",
    weight: "font-weight",
    z: "z-index",
    order: "order",
    grow: "flex-grow",
    shrink: "flex-shrink",
  };

  var ALIGN = {
    center: "center",
    middle: "center",
    start: "flex-start",
    left: "flex-start",
    end: "flex-end",
    right: "flex-end",
    stretch: "stretch",
    between: "space-between",
    around: "space-around",
    evenly: "space-evenly",
    baseline: "baseline",
  };

  var SHADOWS = {
    none: "none",
    sm: "0 1px 2px rgba(16,24,40,.08), 0 1px 3px rgba(16,24,40,.10)",
    md: "0 4px 8px rgba(16,24,40,.10), 0 2px 4px rgba(16,24,40,.06)",
    lg: "0 12px 24px rgba(16,24,40,.14), 0 4px 8px rgba(16,24,40,.08)",
  };

  var ATTR_PROPS = {
    placeholder: "placeholder",
    type: "type",
    src: "src",
    href: "href",
    url: "href",
    alt: "alt",
    title: "title",
    rows: "rows",
    cols: "cols",
    name: "name",
    id: "id",
    target: "target",
    role: "role",
    step: "step",
    min: "min",
    max: "max",
  };

  function display(v) {
    if (v === null || v === undefined) return "";
    if (typeof v === "boolean") return v ? "true" : "false";
    if (typeof v === "object") return JSON.stringify(v);
    return String(v);
  }

  function isFlex(entry) {
    return entry && entry.flex !== undefined;
  }

  function applyProp(rec, name, value) {
    var el = rec.el;
    if (value === null || value === undefined) {
      el.style.removeProperty(cssName(name));
      el.removeAttribute(name);
      return;
    }

    if (name === "value") {
      // Never fight the user's caret: if this element is focused and already
      // shows what we last sent, the server is just echoing our own input.
      if (document.activeElement === el && lastSentValue.get(rec.id) === display(value)) {
        return;
      }
      if (el.type === "checkbox") el.checked = !!value;
      else el.value = display(value);
      return;
    }
    if (name === "checked") {
      el.checked = !!value;
      return;
    }
    if (name === "disabled" || name === "readonly" || name === "required") {
      var on = value === true || value === "true" || value === "";
      if (on) el.setAttribute(name, "");
      else el.removeAttribute(name);
      if (name === "readonly") el.readOnly = on;
      return;
    }
    if (name === "text" || name === "content" || name === "label") {
      setText(rec, display(value));
      return;
    }
    if (name === "class" || name === "className") {
      rec.extraClass = display(value);
      applyClasses(rec);
      return;
    }
    if (name === "bold") {
      el.style.fontWeight = value ? "700" : "";
      return;
    }
    if (name === "italic") {
      el.style.fontStyle = value ? "italic" : "";
      return;
    }
    if (name === "underline") {
      el.style.textDecoration = value ? "underline" : "";
      return;
    }
    if (name === "shadow") {
      var key = display(value);
      el.style.boxShadow = SHADOWS[key] !== undefined ? SHADOWS[key] : key;
      return;
    }
    if (name === "align") {
      var mapped = ALIGN[display(value)] || display(value);
      if (isFlex(rec.spec)) el.style.alignItems = mapped;
      else el.style.textAlign = mapped === "flex-start" ? "left" : mapped === "flex-end" ? "right" : mapped;
      return;
    }
    if (name === "justify") {
      el.style.justifyContent = ALIGN[display(value)] || display(value);
      return;
    }
    if (name === "bg" || name === "background") {
      el.style.background = display(value);
      return;
    }
    if (name === "color" || name === "fg") {
      el.style.color = display(value);
      return;
    }
    if (name === "visible" || name === "show") {
      el.style.display = value ? "" : "none";
      return;
    }
    if (PX_PROPS[name] !== undefined) {
      el.style.setProperty(PX_PROPS[name], cssLen(value));
      return;
    }
    if (RAW_PROPS[name] !== undefined) {
      el.style.setProperty(RAW_PROPS[name], display(value));
      return;
    }
    if (ATTR_PROPS[name] !== undefined) {
      el.setAttribute(ATTR_PROPS[name], display(value));
      return;
    }
    // Anything else lands as a data attribute so it is at least inspectable.
    if (typeof value !== "object") el.setAttribute("data-" + name, display(value));
  }

  function cssName(name) {
    if (PX_PROPS[name] !== undefined) return PX_PROPS[name];
    if (RAW_PROPS[name] !== undefined) return RAW_PROPS[name];
    return name.replace(/_/g, "-");
  }

  function cssLen(v) {
    if (typeof v === "number") return v === 0 ? "0" : v + "px";
    var s = display(v);
    if (/^-?\d+(\.\d+)?$/.test(s)) return s + "px";
    if (s === "full") return "9999px";
    return s;
  }

  function applyClasses(rec) {
    var cls = [rec.baseClass];
    if (rec.extraClass) cls.push(rec.extraClass);
    if (rec.events && rec.events.length) cls.push("weave-interactive");
    rec.el.className = cls.filter(Boolean).join(" ");
  }

  function setText(rec, text) {
    if (!rec.textNode) {
      rec.textNode = document.createTextNode("");
      rec.el.insertBefore(rec.textNode, rec.el.firstChild);
    }
    if (rec.textNode.nodeValue !== text) rec.textNode.nodeValue = text;
  }

  // -------------------------------------------------------------- events ---

  function send(obj) {
    if (ws && ws.readyState === 1) ws.send(JSON.stringify(obj));
  }

  function fireEvent(rec, name, args) {
    send({ t: "event", id: rec.id, name: name, args: args || [] });
  }

  function attachEvents(rec, names) {
    rec.listeners = rec.listeners || [];
    for (var i = 0; i < rec.listeners.length; i++) {
      var l = rec.listeners[i];
      l.el.removeEventListener(l.type, l.fn);
    }
    rec.listeners = [];
    rec.events = names;
    applyClasses(rec);

    names.forEach(function (name) {
      var el = rec.el;
      var fn;
      if (name === "enter") {
        fn = function (e) {
          if (e.key === "Enter") {
            e.preventDefault();
            fireEvent(rec, "enter", []);
          }
        };
        el.addEventListener("keydown", fn);
        rec.listeners.push({ el: el, type: "keydown", fn: fn });
      } else if (name === "key") {
        fn = function (e) {
          fireEvent(rec, "key", [e.key]);
        };
        el.addEventListener("keydown", fn);
        rec.listeners.push({ el: el, type: "keydown", fn: fn });
      } else if (name === "submit") {
        fn = function (e) {
          e.preventDefault();
          fireEvent(rec, "submit", []);
        };
        el.addEventListener("submit", fn);
        el.addEventListener("keydown", function (e2) {
          if (e2.key === "Enter") {
            e2.preventDefault();
            fireEvent(rec, "submit", []);
          }
        });
        rec.listeners.push({ el: el, type: "submit", fn: fn });
      } else {
        fn = function () {
          fireEvent(rec, name, []);
        };
        el.addEventListener(name, fn);
        rec.listeners.push({ el: el, type: name, fn: fn });
      }
    });

    // Two-way binding: report edits so the server can write the signal.
    if (rec.bind) {
      var onInput = function () {
        var v = rec.el.type === "checkbox" ? rec.el.checked : rec.el.value;
        lastSentValue.set(rec.id, display(v));
        send({ t: "input", id: rec.id, value: v });
      };
      var evName = rec.el.type === "checkbox" ? "change" : "input";
      rec.el.addEventListener(evName, onInput);
      rec.listeners.push({ el: rec.el, type: evName, fn: onInput });
    }
  }

  // ---------------------------------------------------------------- build ---

  function build(n) {
    if (isTextLeaf(n)) {
      var t = document.createTextNode(display(n.x));
      nodes.set(n.i, { id: n.i, el: t, spec: TAGS.text, isTextLeaf: true, textNode: t });
      return t;
    }

    var spec = TAGS[n.t] || { el: "div", cls: "weave-" + n.t, flex: "column" };
    var el = document.createElement(spec.el);
    var rec = {
      id: n.i,
      el: el,
      spec: spec,
      tagName: n.t,
      baseClass: spec.cls,
      extraClass: "",
      events: [],
      listeners: [],
      children: [],
      bind: n.b || "",
    };
    nodes.set(n.i, rec);

    if (spec.type) el.type = spec.type;
    if (n.x !== undefined) setText(rec, display(n.x));
    rec.spec = spec;
    attachEvents(rec, n.e || []);
    if (n.b) rec.el.setAttribute("data-bind", n.b);
    if (n.p) for (var k in n.p) applyProp(rec, k, n.p[k]);

    if (n.c) {
      n.c.forEach(function (child) {
        var cel = build(child);
        el.appendChild(cel);
        rec.children.push(child.i);
      });
    }
    return el;
  }

  function insertAt(parentEl, el, index) {
    var kids = parentEl.childNodes;
    if (index >= kids.length) parentEl.appendChild(el);
    else parentEl.insertBefore(el, kids[index]);
  }

  // ---------------------------------------------------------------- patch ---

  function applyOps(ops) {
    for (var i = 0; i < ops.length; i++) {
      var op = ops[i];
      if (op.o === "r") {
        var rec = nodes.get(op.i);
        if (rec) {
          dropSubtree(op.i);
          if (rec.el.parentNode) rec.el.parentNode.removeChild(rec.el);
        }
      } else if (op.o === "i") {
        var parent = nodes.get(op.p);
        if (!parent) continue;
        var el = build(op.n);
        insertAt(parent.el, el, op.a);
        parent.children.splice(op.a, 0, op.n.i);
      } else if (op.o === "m") {
        var prec = nodes.get(op.p);
        var mrec = nodes.get(op.i);
        if (!prec || !mrec) continue;
        insertAt(prec.el, mrec.el, op.a);
      } else if (op.o === "u") {
        var urec = nodes.get(op.i);
        if (!urec) continue;
        if (urec.isTextLeaf) {
          if (op.x !== undefined) urec.el.nodeValue = display(op.x);
          continue;
        }
        if (op.x !== undefined) setText(urec, display(op.x));
        if (op.p) for (var pk in op.p) applyProp(urec, pk, op.p[pk]);
        if (op.e) attachEvents(urec, op.e);
      }
    }
  }

  function dropSubtree(id) {
    var rec = nodes.get(id);
    if (!rec) return;
    if (rec.children) rec.children.forEach(dropSubtree);
    nodes.delete(id);
    lastSentValue.delete(id);
  }

  // ----------------------------------------------------------------- wire ---

  function setStatus(text, cls) {
    if (!statusEl) return;
    statusEl.textContent = text;
    statusEl.className = "weave-status " + (cls || "");
    statusEl.style.display = text ? "" : "none";
  }

  function showError(msg) {
    if (!errorEl) return;
    errorEl.textContent = msg;
    errorEl.style.display = msg ? "block" : "none";
  }

  function mount(n) {
    nodes.forEach(function (rec) {
      if (rec.listeners)
        rec.listeners.forEach(function (l) {
          l.el.removeEventListener(l.type, l.fn);
        });
    });
    nodes.clear();
    lastSentValue.clear();
    appEl.textContent = "";
    root = build(n);
    appEl.appendChild(root);
    document.title = appName;
  }

  function connect() {
    var proto = location.protocol === "https:" ? "wss://" : "ws://";
    setStatus("connecting…", "pending");
    ws = new WebSocket(proto + location.host + WS_PATH);

    ws.onopen = function () {
      retry = 0;
      setStatus("", "");
    };

    ws.onmessage = function (ev) {
      var msg;
      try {
        msg = JSON.parse(ev.data);
      } catch (e) {
        return;
      }
      switch (msg.t) {
        case "hello":
          appName = msg.app || "Weave";
          break;
        case "mount":
          showError("");
          mount(msg.root);
          break;
        case "patch":
          showError("");
          applyOps(msg.ops || []);
          break;
        case "state":
          window.__weave_state = msg.state;
          break;
        case "error":
          showError(msg.message || "runtime error");
          break;
        case "reload":
          setStatus("reloading…", "pending");
          try {
            ws.close();
          } catch (e) {}
          setTimeout(connect, 60);
          break;
        case "pong":
          break;
      }
    };

    ws.onclose = function () {
      setStatus("disconnected — retrying", "down");
      var delay = Math.min(4000, 200 * Math.pow(1.7, retry++));
      setTimeout(connect, delay);
    };

    ws.onerror = function () {
      setStatus("connection error", "down");
    };
  }

  // Keep the server's timers ticking even when the tab is idle.
  setInterval(function () {
    send({ t: "ping" });
  }, 25000);

  connect();

  // A tiny handle for tests and the devtools console.
  window.weave = {
    nodes: nodes,
    send: send,
    get state() {
      return window.__weave_state;
    },
  };
})();
