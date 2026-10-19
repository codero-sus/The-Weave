"""Integration tests for the Weave HTTP server and session reactivity."""

from __future__ import annotations

import http.cookiejar
import json
import threading
import unittest
import urllib.error
import urllib.request

from the_weave.compiler import compile_source
from the_weave.server import ProgramHandle, build_theme_css, make_server

APP = '''
app Counter:
    state:
        count = 0
        name = ""
        tasks = ["one", "two"]

    view:
        stack(padding: 20):
            text(f"Count: {count}", font: 24, bold: true)
            button("Increment", click: {
                count = count + 1
            })
            input(bind: name, placeholder: "Name", on_enter: {
                tasks.append(name)
                name = ""
            })
            for task in tasks:
                card():
                    text(task)
                    button("x", variant: ghost, click: tasks.remove(task))
    routes:
        "/about":
            text("About this app")
'''

BOOM = '''
app Boom:
    state:
        x = 1
    view:
        button("boom", click: {
            x = x / 0
        })
'''


class Client:
    def __init__(self, base: str):
        self.base = base
        self.jar = http.cookiejar.CookieJar()
        self.opener = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(self.jar))

    def get(self, path: str):
        try:
            response = self.opener.open(self.base + path)
        except urllib.error.HTTPError as exc:
            body = exc.read().decode("utf-8")
            return exc.code, body, dict(exc.headers)
        with response:
            return response.status, response.read().decode("utf-8"), dict(response.headers)

    def post(self, path: str, payload: dict):
        data = json.dumps(payload).encode("utf-8")
        request = urllib.request.Request(
            self.base + path, data=data, method="POST",
            headers={"Content-Type": "application/json"},
        )
        with self.opener.open(request) as response:
            return response.status, json.loads(response.read().decode("utf-8"))


class ServerHarness:
    def __init__(self, source: str, name: str = "test.weave"):
        program = compile_source(source, name)
        self.handle = ProgramHandle(program)
        self.server = make_server(self.handle, "127.0.0.1", 0, watch=False, quiet=True)
        self.base = f"http://127.0.0.1:{self.server.server_address[1]}"
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()

    def client(self) -> Client:
        return Client(self.base)

    def close(self):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join(timeout=3)


class ServerTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.app = ServerHarness(APP)
        cls.boom = ServerHarness(BOOM)

    @classmethod
    def tearDownClass(cls):
        cls.app.close()
        cls.boom.close()

    def test_index_renders_and_sets_cookie(self):
        client = self.app.client()
        status, html, headers = client.get("/")
        self.assertEqual(status, 200)
        self.assertIn("Count: 0", html)
        self.assertIn('id="weave-root"', html)
        self.assertIn("window.__WEAVE__", html)
        self.assertIn("weave_sid=", headers.get("Set-Cookie", ""))

    def test_static_assets(self):
        client = self.app.client()
        status, css, headers = client.get("/_weave/static/weave.css")
        self.assertEqual(status, 200)
        self.assertIn("--weave-primary", css)
        status, js, _ = client.get("/_weave/static/weave.js")
        self.assertEqual(status, 200)
        self.assertIn("data-weave-bind", js)

    def test_click_increments_state(self):
        client = self.app.client()
        client.get("/")
        status, data = client.post("/_weave/event", {"path": "r.0.1", "event": "click", "values": {}})
        self.assertEqual(status, 200)
        self.assertTrue(data["ok"], data)
        self.assertEqual(data["state"]["count"], 1)
        self.assertIn("Count: 1", data["html"])
        self.assertEqual(data["rev"], 1)

    def test_enter_appends_and_clears_binding(self):
        client = self.app.client()
        client.get("/")
        _, data = client.post("/_weave/event", {
            "path": "r.0.2", "event": "enter", "values": {"name": "three"},
        })
        self.assertTrue(data["ok"])
        self.assertEqual(data["state"]["tasks"], ["one", "two", "three"])
        self.assertEqual(data["state"]["name"], "")

    def test_click_removes_captured_task(self):
        client = self.app.client()
        client.get("/")
        _, data = client.post("/_weave/event", {
            "path": "r.0.3$0.0.1", "event": "click", "values": {},
        })
        self.assertTrue(data["ok"])
        self.assertEqual(data["state"]["tasks"], ["two"])

    def test_stale_path_is_reported(self):
        client = self.app.client()
        client.get("/")
        _, data = client.post("/_weave/event", {"path": "r.99.0", "event": "click", "values": {}})
        self.assertFalse(data["ok"])
        self.assertTrue(data.get("stale"))
        self.assertIn("html", data)

    def test_reset(self):
        client = self.app.client()
        client.get("/")
        client.post("/_weave/event", {"path": "r.0.1", "event": "click", "values": {}})
        _, data = client.post("/_weave/reset", {})
        self.assertTrue(data["ok"])
        self.assertEqual(data["state"]["count"], 0)
        self.assertIn("Count: 0", data["html"])

    def test_page_fragment_and_404(self):
        client = self.app.client()
        client.get("/")
        code, body, _ = client.get("/_weave/page?path=/about")
        self.assertEqual(code, 200)
        payload = json.loads(body)
        self.assertTrue(payload["ok"])
        self.assertIn("About this app", payload["html"])
        code, body, _ = client.get("/_weave/page?path=/nowhere")
        payload = json.loads(body)
        self.assertTrue(payload["ok"])
        self.assertIn("No page at", payload["html"])

    def test_direct_route_render(self):
        client = self.app.client()
        status, html, _ = client.get("/about")
        self.assertEqual(status, 200)
        self.assertIn("About this app", html)

    def test_unknown_route_returns_404(self):
        client = self.app.client()
        status, html, _ = client.get("/definitely-not-here")
        self.assertEqual(status, 404)
        self.assertIn("No page at", html)

    def test_sessions_are_isolated(self):
        a = self.app.client()
        b = self.app.client()
        a.get("/")
        b.get("/")
        a.post("/_weave/event", {"path": "r.0.1", "event": "click", "values": {}})
        _, html, _ = b.get("/")
        self.assertIn("Count: 0", html)
        _, html, _ = a.get("/")
        self.assertIn("Count: 1", html)

    def test_runtime_error_payload_and_rollback(self):
        client = self.boom.client()
        client.get("/")
        _, data = client.post("/_weave/event", {"path": "r.0", "event": "click", "values": {}})
        self.assertFalse(data["ok"])
        self.assertEqual(data["error"]["code"], "W3000")
        self.assertIn("ZeroDivisionError", data["error"]["message"])
        self.assertGreaterEqual(data["error"]["line"], 5)
        self.assertEqual(data["state"]["x"], 1)

    def test_health_and_inspect(self):
        client = self.app.client()
        _, body, _ = client.get("/_weave/health")
        self.assertEqual(json.loads(body)["app"], "Counter")
        _, body, _ = client.get("/_weave/inspect")
        payload = json.loads(body)
        self.assertIn("python", payload)

    def test_asset_path_traversal_is_blocked(self):
        client = self.app.client()
        status, _, _ = client.get("/assets/../../etc/passwd")
        self.assertEqual(status, 404)
        status, _, _ = client.get("/_weave/static/../../server.py")
        self.assertEqual(status, 404)

    def test_404_path_is_escaped_safely(self):
        client = self.app.client()
        status, html, _ = client.get("/_weave/page?path=/'%3Cscript%3E")
        payload = json.loads(html)
        self.assertTrue(payload["ok"])
        self.assertNotIn("<script>", payload["html"])
        self.assertIn("No page at", payload["html"])

    def test_generated_python_visible(self):
        client = self.app.client()
        _, body, _ = client.get("/_weave/source")
        self.assertIn("app Counter:", body)


class ThemeTests(unittest.TestCase):
    def test_dark_mode_selector_and_attribute(self):
        program = compile_source("""
app Dark:
    theme:
        primary: "#7d80ff"
        mode: dark
    view:
        text("hi")
""", "dark.weave")
        # build_theme_css is pure; no server needed
        css = build_theme_css(program)
        self.assertIn('html[data-theme="dark"]', css)
        self.assertIn("--weave-primary: #7d80ff", css)
        self.assertIn("color-scheme: dark", css)

    def test_light_mode_overrides_media_query(self):
        program = compile_source("""
app Light:
    theme:
        mode: light
    view:
        text("hi")
""", "light.weave")
        css = build_theme_css(program)
        self.assertIn('html[data-theme="light"]', css)

    def test_auto_mode_uses_root(self):
        program = compile_source("""
app Auto:
    theme:
        primary: "#123456"
    view:
        text("hi")
""", "auto.weave")
        css = build_theme_css(program)
        self.assertTrue(css.startswith(":root"))


class HotReloadTests(unittest.TestCase):
    def test_program_handle_reloads(self):
        import os
        import tempfile
        import time

        from the_weave.compiler import compile_file

        with tempfile.TemporaryDirectory() as tmp:
            path = os.path.join(tmp, "app.weave")
            with open(path, "w", encoding="utf-8") as fh:
                fh.write('app Reload:\n    view:\n        text("one")\n')
            handle = ProgramHandle(compile_file(path), path)
            self.assertFalse(handle.needs_reload())
            time.sleep(0.01)
            with open(path, "w", encoding="utf-8") as fh:
                fh.write('app Reload:\n    view:\n        text("two")\n')
            os.utime(path, None)
            self.assertTrue(handle.needs_reload())
            self.assertTrue(handle.reload())
            self.assertIn("two", handle.program.render(__import__("the_weave").runtime.Context(handle.program.new_state())).html)


if __name__ == "__main__":
    unittest.main()
