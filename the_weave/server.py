"""The Weave development server.

A tiny, dependency-free HTTP server that:

* renders the app server-side (initial paint needs no JavaScript),
* keeps one state dictionary per browser session,
* executes Weave event handlers on the server and streams back a fresh
  HTML fragment ("server-driven reactivity", in the spirit of LiveView),
* serves the client runtime and any static assets next to the ``.weave``
  file,
* hot-reloads when the ``.weave`` file changes.
"""

from __future__ import annotations

import copy
import json
import mimetypes
import os
import secrets
import threading
import time
import traceback
import urllib.parse
from dataclasses import dataclass, field
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any, Dict, Optional, Tuple

from .errors import WeaveError, WeaveRuntimeError
from .program import Program
from .renderer import RenderResult
from .runtime import Context

STATIC_DIR = Path(__file__).resolve().parent / "static"
SESSION_TTL = 60 * 60 * 6  # six hours of inactivity
DEFAULT_PORT = 8420

#: Theme keys accepted in a `theme:` block → CSS custom properties.
THEME_VARS = {
    "primary": "--weave-primary",
    "primary_text": "--weave-primary-text",
    "accent": "--weave-accent",
    "secondary": "--weave-secondary",
    "background": "--weave-bg",
    "surface": "--weave-surface",
    "text": "--weave-text",
    "muted": "--weave-muted",
    "border": "--weave-border",
    "subtle": "--weave-subtle",
    "success": "--weave-success",
    "danger": "--weave-danger",
    "warning": "--weave-warning",
    "info": "--weave-info",
    "radius": "--weave-radius",
    "font": "--weave-font",
    "mono": "--weave-mono",
}


# ---------------------------------------------------------------------------
# Sessions
# ---------------------------------------------------------------------------

@dataclass
class Session:
    id: str
    state: Dict[str, Any]
    rev: int = 0
    path: str = "/"
    events: Dict[str, Dict[str, list]] = field(default_factory=dict)
    bindings: Dict[str, str] = field(default_factory=dict)
    last_seen: float = field(default_factory=time.time)
    lock: threading.RLock = field(default_factory=threading.RLock)


class ProgramHandle:
    """Holds the current program and supports hot reload."""

    def __init__(self, program: Program, path: Optional[str] = None):
        self.program = program
        self.path = path
        self.error: Optional[WeaveError] = None
        self.mtime: Optional[float] = None
        self.lock = threading.Lock()
        if path:
            try:
                self.mtime = os.path.getmtime(path)
            except OSError:
                self.mtime = None

    def needs_reload(self) -> bool:
        if not self.path:
            return False
        try:
            return os.path.getmtime(self.path) != self.mtime
        except OSError:
            return False

    def reload(self) -> bool:
        from .compiler import compile_file

        if not self.path:
            return False
        with self.lock:
            try:
                program = compile_file(self.path)
                self.program = program
                self.error = None
                self.mtime = os.path.getmtime(self.path)
                return True
            except WeaveError as exc:
                self.error = exc
                self.mtime = os.path.getmtime(self.path)
                return False
            except Exception as exc:  # pragma: no cover - defensive
                self.error = WeaveRuntimeError(f"{type(exc).__name__}: {exc}", filename=self.path or "")
                self.mtime = os.path.getmtime(self.path)
                return False


# ---------------------------------------------------------------------------
# Server
# ---------------------------------------------------------------------------

class WeaveServer(ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = True

    def __init__(self, handle: ProgramHandle, host: str = "0.0.0.0", port: int = DEFAULT_PORT,
                 *, debug: bool = True, watch: bool = True, quiet: bool = False):
        self.handle = handle
        self.debug = debug
        self.watch = watch
        self.quiet = quiet
        self.sessions: Dict[str, Session] = {}
        self._sessions_lock = threading.Lock()
        super().__init__((host, port), WeaveRequestHandler)
        self._stop_watcher = threading.Event()
        if watch and handle.path:
            threading.Thread(target=self._watch_loop, daemon=True, name="weave-reload").start()
        threading.Thread(target=self._reaper_loop, daemon=True, name="weave-sessions").start()

    # -- lifecycle ----------------------------------------------------
    @property
    def program(self) -> Program:
        return self.handle.program

    def serve(self) -> None:
        try:
            self.serve_forever(poll_interval=0.2)
        except KeyboardInterrupt:
            pass
        finally:
            self.shutdown()

    def stop(self) -> None:
        self._stop_watcher.set()
        self.shutdown()

    def _watch_loop(self) -> None:
        while not self._stop_watcher.wait(0.75):
            if self.handle.needs_reload():
                started = time.time()
                ok = self.handle.reload()
                if ok:
                    print(f"  ↻ reloaded {self.handle.path} in {(time.time() - started) * 1000:.0f} ms")
                elif self.handle.error is not None:
                    print("\n" + self.handle.error.render() + "\n")
                    print("  ! keeping the previous version running\n")

    def _reaper_loop(self) -> None:
        while not self._stop_watcher.wait(60):
            cutoff = time.time() - SESSION_TTL
            with self._sessions_lock:
                stale = [sid for sid, s in self.sessions.items() if s.last_seen < cutoff]
                for sid in stale:
                    self.sessions.pop(sid, None)

    # -- sessions -----------------------------------------------------
    def new_session(self) -> Session:
        sid = secrets.token_urlsafe(18)
        session = Session(id=sid, state=self.program.new_state())
        with self._sessions_lock:
            self.sessions[sid] = session
        return session

    def get_session(self, sid: Optional[str], create: bool = True) -> Optional[Session]:
        if sid:
            with self._sessions_lock:
                session = self.sessions.get(sid)
            if session is not None:
                session.last_seen = time.time()
                self._sync_state(session)
                return session
        return self.new_session() if create else None

    def _sync_state(self, session: Session) -> None:
        """Keep sessions valid across a hot reload (new/removed state vars)."""
        program = self.program
        for name in list(session.state):
            if name not in program.state_names:
                session.state.pop(name, None)
        template = program.initial_state_template
        for name, value in template.items():
            if name not in session.state:
                session.state[name] = copy.deepcopy(value)


# ---------------------------------------------------------------------------
# Request handling
# ---------------------------------------------------------------------------

class WeaveRequestHandler(BaseHTTPRequestHandler):
    server: WeaveServer
    protocol_version = "HTTP/1.1"

    # -- helpers ------------------------------------------------------
    @property
    def program(self) -> Program:
        return self.server.program

    def log_message(self, fmt: str, *args: Any) -> None:  # quieter, aligned logs
        if getattr(self.server, "quiet", False):
            return
        message = fmt % args
        print(f"  {self.log_date_time_string()}  {message}")

    def _send(self, status: int, body: bytes, content_type: str, *, extra_headers: Optional[Dict[str, str]] = None) -> None:
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        for key, value in (extra_headers or {}).items():
            self.send_header(key, value)
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)

    def _send_json(self, status: int, payload: Dict[str, Any], *, cookies: Optional[list] = None) -> None:
        body = json.dumps(payload, ensure_ascii=False, default=str).encode("utf-8")
        headers = {}
        if cookies:
            headers["Set-Cookie"] = cookies[0] if len(cookies) == 1 else cookies
        self._send(status, body, "application/json; charset=utf-8", extra_headers=headers)

    def _send_text(self, status: int, text: str, content_type: str = "text/plain; charset=utf-8") -> None:
        self._send(status, text.encode("utf-8"), content_type)

    def _session_id(self) -> Optional[str]:
        cookie = self.headers.get("Cookie", "")
        for part in cookie.split(";"):
            key, _, value = part.strip().partition("=")
            if key == "weave_sid":
                return value
        return None

    def _cookie_header(self, sid: str) -> str:
        return f"weave_sid={sid}; Path=/; HttpOnly; SameSite=Lax"

    def _read_json(self) -> Dict[str, Any]:
        length = int(self.headers.get("Content-Length") or 0)
        if length <= 0:
            return {}
        raw = self.rfile.read(length)
        try:
            data = json.loads(raw.decode("utf-8"))
            return data if isinstance(data, dict) else {}
        except (ValueError, UnicodeDecodeError):
            return {}

    # -- HTTP verbs ---------------------------------------------------
    def do_HEAD(self) -> None:
        self.do_GET()

    def do_GET(self) -> None:
        parsed = urllib.parse.urlsplit(self.path)
        path = urllib.parse.unquote(parsed.path)
        query = urllib.parse.parse_qs(parsed.query)
        try:
            if path.startswith("/_weave/static/"):
                return self._serve_static(path[len("/_weave/static/"):])
            if path.startswith("/assets/"):
                return self._serve_asset(path[len("/assets/"):])
            if path == "/favicon.ico":
                return self._send(204, b"", "image/x-icon")
            if path == "/_weave/health":
                return self._send_json(200, {"ok": True, "app": self.program.name})
            if path == "/_weave/source":
                return self._send_text(200, self.program.source.text, "text/plain; charset=utf-8")
            if path == "/_weave/inspect":
                return self._send_json(200, {
                    "program": self.program.describe(),
                    "python": self.program.generated.source,
                })
            if path == "/_weave/page":
                return self._page_fragment(query.get("path", ["/"])[0])
            return self._serve_page(path)
        except BrokenPipeError:  # pragma: no cover
            return
        except Exception:  # pragma: no cover - last-resort guard
            tb = traceback.format_exc()
            print(tb)
            return self._send_text(500, "Internal Weave server error\n\n" + (tb if self.server.debug else ""))

    def do_POST(self) -> None:
        parsed = urllib.parse.urlsplit(self.path)
        path = parsed.path
        try:
            if path == "/_weave/event":
                return self._handle_event(self._read_json())
            if path == "/_weave/reset":
                return self._handle_reset()
            if path == "/_weave/reload":
                ok = self.server.handle.reload()
                return self._send_json(200, {"ok": ok, "error": self.server.handle.error.to_dict() if self.server.handle.error else None})
            self._send_json(404, {"ok": False, "error": {"message": "unknown endpoint"}})
        except BrokenPipeError:  # pragma: no cover
            return
        except Exception:  # pragma: no cover
            tb = traceback.format_exc()
            print(tb)
            self._send_json(500, {"ok": False, "error": {"message": "internal server error", "traceback": tb}})

    # -- pages --------------------------------------------------------
    def _get_or_create_session(self) -> Tuple[Session, list]:
        sid = self._session_id()
        existing = self.server.get_session(sid, create=False)
        if existing is not None:
            return existing, []
        session = self.server.new_session()
        return session, [self._cookie_header(session.id)]

    def _serve_page(self, path: str) -> None:
        session, cookies = self._get_or_create_session()
        with session.lock:
            try:
                result = self._render(session, path)
            except WeaveError as exc:
                return self._send_error_page(exc, status=500, cookies=cookies)
            session.path = result.path
            html = self._shell(result, session)
        self._send(result.status, html.encode("utf-8"), "text/html; charset=utf-8",
                   extra_headers={"Set-Cookie": cookies[0]} if cookies else None)

    def _page_fragment(self, path: str) -> None:
        session, cookies = self._get_or_create_session()
        with session.lock:
            try:
                result = self._render(session, path)
            except WeaveError as exc:
                return self._send_json(200, {"ok": False, "error": self._error_payload(exc)})
            session.path = result.path
            payload = {
                "ok": True,
                "html": result.html,
                "title": result.title,
                "path": result.path,
                "status": result.status,
                "rev": session.rev,
                "state": self.program.public_state(session.state),
            }
        self._send_json(200, payload, cookies=cookies)

    def _render(self, session: Session, path: str) -> RenderResult:
        ctx = Context(session.state, session_id=session.id, path=path)
        result = self.program.render(ctx, path)
        session.events = result.events
        session.bindings = result.bindings
        return result

    # -- events -------------------------------------------------------
    def _handle_event(self, payload: Dict[str, Any]) -> None:
        sid = payload.get("session") or self._session_id()
        session = self.server.get_session(sid, create=False)
        if session is None:
            return self._send_json(200, {"ok": False, "error": {"message": "Your session expired. Reload the page.", "code": "W4004", "stale": True}})

        path = str(payload.get("path") or "")
        event = str(payload.get("event") or "")
        values = payload.get("values") or {}
        program = self.program

        with session.lock:
            working = copy.deepcopy(session.state)
            ctx = Context(working, session_id=session.id, path=session.path)
            try:
                if isinstance(values, dict):
                    for name, value in values.items():
                        if name in program.state_names:
                            working[name] = program.coerce_binding(name, value)

                if event == "set":
                    name = payload.get("name")
                    if name not in program.state_names:
                        raise WeaveRuntimeError(f"'{name}' is not a state variable", filename=program.filename)
                    working[name] = program.coerce_binding(name, payload.get("value"))

                # Re-resolve handlers against the *working* snapshot. Rendering
                # deterministically reproduces the same data-w paths the browser
                # saw, and loop captures now point into the state we will commit.
                preliminary = program.render(ctx, session.path)
                session.events = preliminary.events
                session.bindings = preliminary.bindings
                handlers = preliminary.events.get(path, {}).get(event, [])

                if not handlers and event not in ("input", "change", "blur", "focus", "set"):
                    if path not in preliminary.bindings:
                        return self._send_json(200, {
                            "ok": False,
                            "stale": True,
                            "error": self._stale_error(),
                            "rev": session.rev,
                            "html": preliminary.html,
                            "state": program.public_state(working),
                        })

                for binding in handlers:
                    program.execute_handler(binding.func_name, ctx, binding.captures)

                session.state = working
                session.rev += 1
                target_path = ctx.redirect or session.path
                ctx.path = target_path
                result = program.render(ctx, target_path)
                session.events = result.events
                session.bindings = result.bindings
                session.path = result.path
                response = {
                    "ok": True,
                    "html": result.html,
                    "title": result.title,
                    "path": result.path,
                    "status": result.status,
                    "rev": session.rev,
                    "state": program.public_state(session.state),
                    "toasts": ctx.toasts,
                    "logs": ctx.logs,
                    "events": ctx.emitted,
                    "redirect": ctx.redirect,
                }
            except WeaveError as exc:
                result = self._render(session, session.path)
                response = {
                    "ok": False,
                    "error": self._error_payload(exc),
                    "rev": session.rev,
                    "html": result.html,
                    "title": result.title,
                    "state": program.public_state(session.state),
                }
            except Exception as exc:  # pragma: no cover - defensive
                tb = traceback.format_exc()
                print(tb)
                response = {
                    "ok": False,
                    "error": {"message": f"{type(exc).__name__}: {exc}", "code": "W5000",
                              "traceback": tb if self.server.debug else None},
                    "rev": session.rev,
                }
        self._send_json(200, response)

    def _stale_error(self) -> Dict[str, Any]:
        return {
            "message": "This view changed before your event arrived, so it was ignored.",
            "code": "W4090",
            "hint": "The page has been refreshed with the latest state.",
        }

    def _safe_render_html(self, session: Session) -> str:
        try:
            ctx = Context(session.state, session_id=session.id, path=session.path)
            result = self.program.render(ctx, session.path)
            session.events = result.events
            session.bindings = result.bindings
            return result.html
        except WeaveError:
            return ""

    def _handle_reset(self) -> None:
        session, cookies = self._get_or_create_session()
        with session.lock:
            session.state = self.program.new_state()
            session.rev += 1
            result = self._render(session, "/")
            session.path = "/"
            payload = {
                "ok": True,
                "html": result.html,
                "title": result.title,
                "path": "/",
                "rev": session.rev,
                "state": self.program.public_state(session.state),
                "toasts": [{"message": "State reset", "kind": "info"}],
            }
        self._send_json(200, payload, cookies=cookies)

    # -- errors -------------------------------------------------------
    def _error_payload(self, exc: WeaveError) -> Dict[str, Any]:
        payload = exc.to_dict()
        if exc.filename:
            try:
                text = Path(exc.filename).read_text(encoding="utf-8")
                lines = text.splitlines()
                if 1 <= exc.line <= len(lines):
                    payload["snippet"] = lines[exc.line - 1]
            except OSError:
                pass
        if isinstance(exc, WeaveRuntimeError):
            payload["traceback"] = getattr(exc, "python_traceback", None) if self.server.debug else None
        return payload

    def _send_error_page(self, exc: WeaveError, status: int = 500, *, cookies: Optional[list] = None) -> None:
        error = self._error_payload(exc)
        body = f"""<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Weave error</title><link rel="stylesheet" href="/_weave/static/weave.css"></head>
<body class="weave-error-page">
<main class="weave-error-card">
  <div class="weave-error-kicker">Weave error <code>{_esc(error.get('code', 'W0000'))}</code></div>
  <h1>{_esc(error.get('message', 'Unknown error'))}</h1>
  <p class="weave-error-loc">{_esc(error.get('filename') or '')}:{error.get('line', 1)}:{error.get('col', 1)}</p>
  {_snippet_block(error)}
  {_hint_block(error)}
  <p class="weave-error-help">Fix the source and save — the server reloads automatically.</p>
</main></body></html>"""
        self._send(status, body.encode("utf-8"), "text/html; charset=utf-8",
                   extra_headers={"Set-Cookie": cookies[0]} if cookies else None)

    # -- static files -------------------------------------------------
    def _serve_static(self, relative: str) -> None:
        target = (STATIC_DIR / relative).resolve()
        if STATIC_DIR not in target.parents or not target.is_file():
            return self._send_text(404, "not found")
        content_type = mimetypes.guess_type(str(target))[0] or "application/octet-stream"
        data = target.read_bytes()
        self._send(200, data, content_type)

    def _serve_asset(self, relative: str) -> None:
        base = Path(self.program.app.dirname or ".").resolve()
        target = (base / urllib.parse.unquote(relative)).resolve()
        if base not in target.parents or not target.is_file():
            return self._send_text(404, "not found")
        content_type = mimetypes.guess_type(str(target))[0] or "application/octet-stream"
        self._send(200, target.read_bytes(), content_type)

    # -- shell --------------------------------------------------------
    def _shell(self, result: RenderResult, session: Session) -> str:
        program = self.program
        theme_css = self._theme_css()
        config = {
            "session": session.id,
            "path": result.path,
            "rev": session.rev,
            "state": program.public_state(session.state),
            "app": program.name,
            "title": result.title,
        }
        config_json = json.dumps(config, ensure_ascii=False, default=str).replace("</", "<\\/")
        reload_banner = ""
        if self.server.handle.error is not None:
            err = self.server.handle.error
            reload_banner = (
                f'<div class="weave-reload-error" role="alert">'
                f'<strong>Compile error</strong> — still running the previous version.'
                f'<span>{_esc(err.message)} (line {err.line})</span></div>'
            )
        theme_mode = str(program.app.theme.get("mode", "auto")).strip().lower()
        theme_attr = f' data-theme="{theme_mode}"' if theme_mode in ("dark", "light") else ""
        return f"""<!doctype html>
<html lang="en"{theme_attr}>
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
<meta name="generator" content="Weave {_version()}">
<title>{_esc(result.title)}</title>
<link rel="preconnect" href="https://fonts.googleapis.com">
<link rel="stylesheet" href="/_weave/static/weave.css">
<style>{theme_css}</style>
</head>
<body data-weave-app="{_esc(program.name)}">
{reload_banner}
<main id="weave-root" data-w="r" aria-live="polite">{result.html}</main>
<div id="weave-toasts" class="weave-toasts" aria-live="polite"></div>
<div id="weave-error" class="weave-error-overlay" hidden></div>
<button id="weave-theme-toggle" class="weave-theme-toggle" type="button" aria-label="Toggle colour theme" title="Toggle light / dark">◐</button>
<div id="weave-progress" class="weave-progress-line" aria-hidden="true"></div>
<script>window.__WEAVE__ = {config_json};</script>
<script src="/_weave/static/weave.js" defer></script>
</body>
</html>"""

    def _theme_css(self) -> str:
        return build_theme_css(self.program)


def build_theme_css(program: Program) -> str:
    theme = program.app.theme
    mode = str(theme.get("mode", "auto")).strip().lower()
    if mode not in ("dark", "light"):
        mode = "auto"
    declarations = []
    for key, var in THEME_VARS.items():
        if key in theme:
            value = str(theme[key]).strip().strip('"').strip("'")
            if key == "radius":
                value = _css_len(value)
            declarations.append(f"  {var}: {value};")
    if mode != "auto":
        declarations.append(f"  color-scheme: {mode};")
    if not declarations:
        return ""
    selector = ":root" if mode == "auto" else f'html[data-theme="{mode}"]'
    return f"{selector} {{\n" + "\n".join(declarations) + "\n}"


def _version() -> str:
    from . import __version__

    return __version__


def _css_len(value: str) -> str:
    try:
        float(value)
        return f"{value}px"
    except ValueError:
        return value


def _esc(value: Any) -> str:
    import html as html_module

    return html_module.escape(str(value), quote=True)


def _snippet_block(error: Dict[str, Any]) -> str:
    snippet = error.get("snippet")
    if not snippet:
        return ""
    return f'<pre class="weave-error-snippet"><code>{_esc(snippet)}</code></pre>'


def _hint_block(error: Dict[str, Any]) -> str:
    hint = error.get("hint")
    if not hint:
        return ""
    return f'<p class="weave-error-hint">{_esc(hint)}</p>'


# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

def make_server(handle: ProgramHandle, host: str = "0.0.0.0", port: int = DEFAULT_PORT, *,
                debug: bool = True, watch: bool = True, quiet: bool = False) -> WeaveServer:
    return WeaveServer(handle, host, port, debug=debug, watch=watch, quiet=quiet)


def serve(program: Program, host: str = "0.0.0.0", port: int = DEFAULT_PORT, *,
          path: Optional[str] = None, debug: bool = True, watch: bool = True,
          open_browser: bool = False) -> None:
    handle = ProgramHandle(program, path)
    server = make_server(handle, host, port, debug=debug, watch=watch)
    url_host = "localhost" if host in ("0.0.0.0", "::") else host
    actual_port = server.server_address[1]
    print()
    print(f"  Weave · {program.name}")
    print(f"  running at  http://{url_host}:{actual_port}")
    print(f"  source      {path or '<in-memory>'}")
    print(f"  python      {len(program.generated.source.splitlines())} generated lines"
          f" · {len(program.handler_meta)} handlers · {len(program.state_names)} state vars")
    print("  press Ctrl+C to stop\n")
    if open_browser:
        import webbrowser

        threading.Timer(0.4, lambda: webbrowser.open(f"http://{url_host}:{actual_port}")).start()
    try:
        server.serve()
    except KeyboardInterrupt:  # pragma: no cover
        pass
