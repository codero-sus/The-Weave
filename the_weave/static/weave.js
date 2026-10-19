/* ==========================================================================
   Weave client runtime
   Minimal server-driven reactivity:

     DOM event  ──POST /_weave/event──►  Python handler mutates state
                ◄──fresh HTML + state──  DOM is patched in place

   Focus, caret position, scroll offsets and in-flight typing are preserved
   across patches so the app feels native even though the logic lives on the
   server. No build step, no framework, ~10 KB.
   ========================================================================== */
(function () {
  "use strict";

  var cfg = window.__WEAVE__ || {};
  var root = document.getElementById("weave-root");
  if (!root) return;

  var current = {
    session: cfg.session,
    path: cfg.path || location.pathname || "/",
    rev: cfg.rev || 0,
    state: cfg.state || {},
    title: cfg.title || document.title,
  };

  // ---------------------------------------------------------------- utils
  function cssEscape(value) {
    if (window.CSS && CSS.escape) return CSS.escape(value);
    return String(value).replace(/["\\]/g, "\\$&");
  }

  function escapeHtml(value) {
    return String(value == null ? "" : value)
      .replace(/&/g, "&amp;")
      .replace(/</g, "&lt;")
      .replace(/>/g, "&gt;")
      .replace(/"/g, "&quot;");
  }

  function debounce(fn, wait) {
    var timer = null;
    return function () {
      var args = arguments, self = this;
      clearTimeout(timer);
      timer = setTimeout(function () { fn.apply(self, args); }, wait);
    };
  }

  // ---------------------------------------------------------------- state
  function readValue(el) {
    if (el.type === "checkbox") return el.checked;
    if (el.type === "range" || el.type === "number") {
      var n = Number(el.value);
      return Number.isNaN(n) ? el.value : n;
    }
    return el.value;
  }

  function gatherValues() {
    var values = {};
    root.querySelectorAll("[data-weave-bind]").forEach(function (el) {
      var name = el.getAttribute("data-weave-bind");
      if (!name) return;
      if (el.type === "radio" && !el.checked) return;
      values[name] = readValue(el);
    });
    return values;
  }

  function pathOf(el) {
    var holder = el.closest("[data-w]");
    return holder ? holder.getAttribute("data-w") : null;
  }

  // ------------------------------------------------------------- requests
  var queue = Promise.resolve();
  var busyCount = 0;
  var pendingEdits = new Map(); // bind name -> { value, start, end }

  function setBusy(delta) {
    busyCount = Math.max(0, busyCount + delta);
    document.body.dataset.busy = busyCount > 0 ? "1" : "0";
  }

  function request(payload, options) {
    options = options || {};
    var snapshot = null;
    if (options.preserveEdits) {
      snapshot = new Map(pendingEdits);
    } else {
      pendingEdits.clear();
    }
    setBusy(1);
    return fetch("/_weave/event", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      credentials: "same-origin",
      body: JSON.stringify(payload),
    })
      .then(function (response) { return response.json(); })
      .then(function (data) {
        if (!data) return;
        if (data.rev == null || data.rev >= current.rev - 1) {
          handleResponse(data, options);
        }
        if (snapshot) restoreTyping(snapshot);
      })
      .catch(function (err) {
        console.error("[weave] request failed", err);
        showError({
          message: "Could not reach the Weave server.",
          hint: "Is `weave run` still running? Check the terminal for details.",
        });
      })
      .finally(function () { setBusy(-1); });
  }

  function enqueue(fn) {
    queue = queue.then(fn, fn);
    return queue;
  }

  function send(event, el, extra, options) {
    var path = pathOf(el);
    if (!path) return Promise.resolve();
    var payload = Object.assign(
      {
        session: current.session,
        path: path,
        event: event,
        values: gatherValues(),
        rev: current.rev,
      },
      extra || {}
    );
    return enqueue(function () { return request(payload, options); });
  }

  // -------------------------------------------------------------- applying
  function captureFocus() {
    var el = document.activeElement;
    if (!el || el === document.body || !root.contains(el)) return null;
    var holder = el.closest("[data-w]");
    if (!holder) return null;
    var info = {
      path: holder.getAttribute("data-w"),
      bind: el.getAttribute("data-weave-bind"),
      isField: el.matches("input, textarea, select"),
      tag: el.tagName,
      selection: null,
    };
    try {
      if (typeof el.selectionStart === "number" && typeof el.selectionEnd === "number") {
        info.selection = [el.selectionStart, el.selectionEnd, el.selectionDirection];
      }
    } catch (err) { /* number inputs throw */ }
    return info;
  }

  function findField(path, bind) {
    var holder = root.querySelector('[data-w="' + cssEscape(path) + '"]');
    if (!holder) {
      // The node may have moved into a nested block; fall back to prefix match.
      holder = root.querySelector('[data-w^="' + cssEscape(path) + '"]');
    }
    if (!holder) return null;
    if (holder.matches("input, textarea, select")) return holder;
    if (bind) {
      var byBind = holder.querySelector('[data-weave-bind="' + cssEscape(bind) + '"]');
      if (byBind) return byBind;
    }
    return holder.querySelector("input, textarea, select");
  }

  function restoreFocus(info) {
    if (!info) return;
    var el = findField(info.path, info.bind);
    if (!el) return;
    if (info.isField && typeof el.focus === "function") {
      try { el.focus({ preventScroll: true }); } catch (err) { el.focus(); }
      if (info.selection && typeof el.setSelectionRange === "function") {
        try {
          el.setSelectionRange(info.selection[0], info.selection[1], info.selection[2] || "none");
        } catch (err) { /* unsupported input type */ }
      }
    }
  }

  function restoreTyping(snapshot) {
    if (!snapshot || !snapshot.size) return;
    snapshot.forEach(function (edit, bind) {
      var el = root.querySelector('[data-weave-bind="' + cssEscape(bind) + '"]');
      if (!el) return;
      var serverValue = current.state ? current.state[bind] : undefined;
      if (serverValue === edit.value) { pendingEdits.delete(bind); return; }
      if (document.activeElement !== el) return;
      if (el.value !== String(edit.value)) {
        el.value = edit.value;
        try { el.setSelectionRange(edit.start, edit.end); } catch (err) { /* ignore */ }
      }
      pendingEdits.set(bind, edit);
    });
  }

  function captureScroll() {
    var scrolls = new Map();
    root.querySelectorAll("[data-w]").forEach(function (el) {
      if (el.scrollTop > 0 || el.scrollLeft > 0) {
        scrolls.set(el.getAttribute("data-w"), [el.scrollTop, el.scrollLeft]);
      }
    });
    return scrolls;
  }

  function restoreScroll(scrolls) {
    if (!scrolls || !scrolls.size) return;
    scrolls.forEach(function (pos, path) {
      var el = root.querySelector('[data-w="' + cssEscape(path) + '"]');
      if (el) { el.scrollTop = pos[0]; el.scrollLeft = pos[1]; }
    });
  }

  function apply(data, options) {
    options = options || {};
    if (typeof data.html === "string") {
      var focus = captureFocus();
      var windowScroll = [window.scrollX, window.scrollY];
      var scrolls = captureScroll();
      root.innerHTML = data.html;
      if (options.animate) {
        root.classList.remove("weave-root-swap");
        void root.offsetWidth;
        root.classList.add("weave-root-swap");
      }
      restoreScroll(scrolls);
      restoreFocus(focus);
      if (!options.keepScroll) window.scrollTo(windowScroll[0], windowScroll[1]);
    }
    if (data.title) {
      current.title = data.title;
      document.title = data.title;
    }
    if (data.state) current.state = data.state;
    if (typeof data.rev === "number") current.rev = data.rev;
    if (data.path) current.path = data.path;
    (data.toasts || []).forEach(function (toast) { showToast(toast.message, toast.kind); });
    (data.logs || []).forEach(function (line) { console.log("[weave]", line); });
    (data.events || []).forEach(function (custom) {
      window.dispatchEvent(new CustomEvent("weave:event", { detail: custom }));
    });
    if (data.error && data.error.code === "W4004") {
      // session expired on the server: the simplest recovery is a reload
      location.reload();
      return;
    }
    if (data.error && !data.stale) showError(data.error);
    if (data.stale) showToast("View refreshed to the latest state", "info");
    if (data.redirect) {
      history.pushState({ path: data.redirect }, "", data.redirect);
      current.path = data.redirect;
    }
  }

  function handleResponse(data, options) {
    if (data.ok) {
      apply(data, options);
      return;
    }
    if (data.html) {
      apply(data, options);
      return;
    }
    if (data.error) showError(data.error);
  }

  // --------------------------------------------------------------- toasts
  var toastHost = document.getElementById("weave-toasts");

  function showToast(message, kind) {
    if (!toastHost || !message) return;
    kind = kind || "info";
    var el = document.createElement("div");
    el.className = "weave-toast weave-toast-" + kind;
    el.setAttribute("role", kind === "error" ? "alert" : "status");
    var text = document.createElement("div");
    text.textContent = message;
    el.appendChild(text);
    toastHost.appendChild(el);
    setTimeout(function () {
      el.classList.add("weave-toast-out");
      setTimeout(function () { el.remove(); }, 240);
    }, kind === "error" ? 6000 : 3600);
  }

  // ---------------------------------------------------------- error panel
  var errorHost = document.getElementById("weave-error");

  function showError(error) {
    if (!errorHost || !error) return;
    var code = error.code || "W0000";
    var location = (error.filename || "weave") + ":" + (error.line || 1) + ":" + (error.col || 1);
    var parts = [
      '<div class="weave-error-card" role="alertdialog" aria-modal="true" aria-label="Weave runtime error">',
      '<div class="weave-error-kicker">Runtime error <code>' + escapeHtml(code) + "</code></div>",
      "<h2>" + escapeHtml(error.message || "Something went wrong") + "</h2>",
      '<p class="weave-error-loc">' + escapeHtml(location) + "</p>",
    ];
    if (error.snippet) {
      parts.push('<pre class="weave-error-snippet"><code>' + escapeHtml(error.snippet) + "</code></pre>");
    }
    if (error.hint) {
      parts.push('<p class="weave-error-hint">' + escapeHtml(error.hint) + "</p>");
    }
    parts.push(
      '<button type="button" class="weave-btn weave-btn-secondary" data-weave-dismiss>Dismiss</button>',
      "</div>"
    );
    errorHost.innerHTML = parts.join("");
    errorHost.hidden = false;
    errorHost.querySelector("[data-weave-dismiss]").addEventListener("click", hideError);
    if (error.traceback) console.error("[weave]", error.message + "\n" + error.traceback);
    else console.error("[weave]", error.message);
  }

  function hideError() {
    if (!errorHost) return;
    errorHost.hidden = true;
    errorHost.innerHTML = "";
  }

  document.addEventListener("keydown", function (event) {
    if (event.key === "Escape" && errorHost && !errorHost.hidden) hideError();
  });

  // ---------------------------------------------------------- navigation
  function navigate(path, push) {
    if (!path) return Promise.resolve();
    return fetch("/_weave/page?path=" + encodeURIComponent(path), {
      credentials: "same-origin",
    })
      .then(function (response) { return response.json(); })
      .then(function (data) {
        if (!data.ok) {
          if (data.error) showError(data.error);
          return;
        }
        apply(data, { animate: true, keepScroll: true });
        current.path = data.path || path;
        if (push !== false) history.pushState({ path: path }, "", path);
        window.scrollTo({ top: 0, behavior: "instant" in document.documentElement.style ? "instant" : "auto" });
      })
      .catch(function (err) {
        console.error("[weave] navigation failed", err);
        location.href = path;
      });
  }

  window.addEventListener("popstate", function () {
    navigate(location.pathname, false);
  });

  // ------------------------------------------------------ event plumbing
  document.addEventListener("click", function (event) {
    var target = event.target;
    if (!(target instanceof Element)) return;

    if (target.closest("[data-weave-dismiss], #weave-theme-toggle")) return;

    var clickEl = target.closest("[data-weave-click]");
    if (clickEl) {
      send("click", clickEl);
      return;
    }

    var setEl = target.closest("[data-weave-set]");
    if (setEl) {
      send("set", setEl, {
        name: setEl.getAttribute("data-weave-set"),
        value: setEl.getAttribute("data-weave-set-value"),
      });
      return;
    }

    var navEl = target.closest("[data-weave-nav]");
    if (navEl) {
      event.preventDefault();
      var href = navEl.getAttribute("data-weave-nav");
      if (href && href !== current.path) navigate(href);
    }
  });

  var flushInput = debounce(function (el) {
    send("input", el, {}, { preserveEdits: true });
  }, 85);

  document.addEventListener("input", function (event) {
    var el = event.target;
    if (!(el instanceof Element)) return;
    var field = el.closest("[data-weave-bind], [data-weave-input]");
    if (!field) return;

    var bind = field.getAttribute("data-weave-bind");
    if (bind) {
      var edit = { value: readValue(field), start: 0, end: 0 };
      try {
        edit.start = field.selectionStart;
        edit.end = field.selectionEnd;
      } catch (err) { /* number inputs */ }
      pendingEdits.set(bind, edit);
    }

    var holder = field.closest("[data-w]");
    if (!holder) return;

    // Range inputs are updated on release: replacing the node mid-drag
    // would cancel the gesture. Mirror the value locally meanwhile.
    if (field.type === "range") {
      var output = field.parentElement && field.parentElement.querySelector(".weave-slider-value");
      if (output) output.textContent = field.value;
      return;
    }

    var live = bind || field.hasAttribute("data-weave-input");
    if (live) flushInput(field);
  });

  ["dblclick", "keydown", "keyup"].forEach(function (domEvent) {
    document.addEventListener(domEvent, function (event) {
      var target = event.target;
      if (!(target instanceof Element)) return;
      var holder = target.closest("[data-weave-" + domEvent + "]");
      if (!holder) return;
      if (domEvent === "keydown" && event.key === "Enter" && holder.hasAttribute("data-weave-enter")) return;
      send(domEvent, holder);
    });
  });

  document.addEventListener("keydown", function (event) {
    if (event.key !== "Enter") return;
    var el = event.target;
    if (!(el instanceof Element)) return;
    if (el.tagName === "TEXTAREA" && !(event.metaKey || event.ctrlKey)) return;
    var holder = el.closest("[data-weave-enter]");
    if (holder) {
      event.preventDefault();
      send("enter", holder);
    }
  });

  document.addEventListener("change", function (event) {
    var el = event.target;
    if (!(el instanceof Element)) return;
    var nativeCommit = ["checkbox", "radio", "range", "file"].indexOf(el.type) !== -1 || el.tagName === "SELECT";
    if (nativeCommit) {
      var bind = el.getAttribute("data-weave-bind");
      if (bind) pendingEdits.set(bind, { value: readValue(el), start: 0, end: 0 });
      var owner = el.closest("[data-weave-change]") || el.closest("[data-w]");
      if (owner) { send("change", owner); return; }
    }
    var holder = el.closest("[data-weave-change]");
    if (holder) send("change", holder);
  });

  document.addEventListener("focusin", function (event) {
    var el = event.target;
    if (!(el instanceof Element)) return;
    var holder = el.closest("[data-weave-focus]");
    if (holder) send("focus", holder);
  });

  document.addEventListener("focusout", function (event) {
    var el = event.target;
    if (!(el instanceof Element)) return;
    var holder = el.closest("[data-weave-blur]");
    if (holder) send("blur", holder);
  });

  document.addEventListener("submit", function (event) {
    var form = event.target;
    if (!(form instanceof Element) || !form.matches("[data-weave-form]")) return;
    event.preventDefault();
    if (form.hasAttribute("data-weave-submit")) {
      send("submit", form);
    }
  });

  // --------------------------------------------------------- theme toggle
  var themeButton = document.getElementById("weave-theme-toggle");
  try {
    var storedTheme = localStorage.getItem("weave-theme");
    if (storedTheme === "dark" || storedTheme === "light") {
      document.documentElement.dataset.theme = storedTheme;
    }
  } catch (err) { /* private mode */ }

  if (themeButton) {
    themeButton.addEventListener("click", function () {
      var currentTheme = document.documentElement.dataset.theme;
      if (!currentTheme) {
        currentTheme = window.matchMedia("(prefers-color-scheme: dark)").matches ? "dark" : "light";
      }
      var next = currentTheme === "dark" ? "light" : "dark";
      document.documentElement.dataset.theme = next;
      try { localStorage.setItem("weave-theme", next); } catch (err) { /* ignore */ }
    });
  }

  // ------------------------------------------------------------ debugging
  window.Weave = {
    get state() { return current.state; },
    get revision() { return current.rev; },
    get path() { return current.path; },
    send: function (event, path, extra) {
      return enqueue(function () {
        return request(
          Object.assign(
            { session: current.session, path: path, event: event, values: gatherValues(), rev: current.rev },
            extra || {}
          ),
          {}
        );
      });
    },
    navigate: navigate,
    reset: function () {
      return fetch("/_weave/reset", {
        method: "POST",
        credentials: "same-origin",
        headers: { "Content-Type": "application/json" },
        body: "{}",
      })
        .then(function (r) { return r.json(); })
        .then(function (data) { if (data.ok) apply(data); });
    },
    showError: showError,
    version: "0.1.0",
  };

  // Announce readiness for embedding / automated tests.
  document.documentElement.setAttribute("data-weave-ready", "true");
  window.dispatchEvent(new CustomEvent("weave:ready", { detail: { path: current.path } }));
})();
