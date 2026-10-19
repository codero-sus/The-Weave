"""Tests for the `weave` command line interface."""

from __future__ import annotations

import contextlib
import io
import json
import tempfile
import unittest
from pathlib import Path

from the_weave.cli import main
from the_weave.compiler import compile_file

TODO_SOURCE = '''
app CliApp:
    state:
        clicks = 0
    view:
        stack(padding: 16):
            text(f"Clicks: {clicks}")
            button("Go", click: {
                clicks += 1
            })
'''


def run_cli(args):
    out = io.StringIO()
    err = io.StringIO()
    with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
        code = main(args)
    return code, out.getvalue(), err.getvalue()


class CliTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.dir = Path(self.tmp.name)
        self.app = self.dir / "app.weave"
        self.app.write_text(TODO_SOURCE, encoding="utf-8")

    def tearDown(self):
        self.tmp.cleanup()

    def test_check(self):
        code, out, _ = run_cli(["check", str(self.app)])
        self.assertEqual(code, 0)
        self.assertIn("compiled cleanly", out)
        self.assertIn("CliApp", out)

    def test_check_json(self):
        code, out, _ = run_cli(["check", str(self.app), "--json"])
        self.assertEqual(code, 0)
        data = json.loads(out)
        self.assertEqual(data["name"], "CliApp")
        self.assertEqual(data["state"], ["clicks"])

    def test_check_failure_reports_snippet(self):
        bad = self.dir / "bad.weave"
        bad.write_text('app Bad:\n    view:\n        textt("x")\n', encoding="utf-8")
        code, out, _ = run_cli(["check", str(bad)])
        self.assertEqual(code, 1)
        self.assertIn("error[W2000]", out)
        self.assertIn("unknown component", out)
        self.assertIn("did you mean 'text'", out)
        self.assertIn("textt(\"x\")", out)

    def test_missing_file(self):
        code, out, _ = run_cli(["check", str(self.dir / "nope.weave")])
        self.assertEqual(code, 1)
        self.assertIn("no such file", out)

    def test_ast_python(self):
        code, out, _ = run_cli(["ast", str(self.app), "--python"])
        self.assertEqual(code, 0)
        self.assertIn("def _weave_h0(ctx):", out)
        self.assertIn("ctx.st['clicks'] += 1", out)

    def test_ast_json(self):
        code, out, _ = run_cli(["ast", str(self.app)])
        self.assertEqual(code, 0)
        data = json.loads(out)
        self.assertEqual(data["name"], "CliApp")
        self.assertEqual(data["view"][0]["name"], "stack")

    def test_components_json(self):
        code, out, _ = run_cli(["components", "--json"])
        self.assertEqual(code, 0)
        data = json.loads(out)
        self.assertIn("input", data)
        self.assertEqual(data["button"]["positional"], [1, 1])

    def test_components_listing(self):
        code, out, _ = run_cli(["components", "--examples"])
        self.assertEqual(code, 0)
        self.assertIn("vertical flex container", out)
        self.assertIn("input(bind:", out)

    def test_init_and_compile(self):
        project = self.dir / "project"
        code, out, _ = run_cli(["init", str(project)])
        self.assertEqual(code, 0)
        created = project / "app.weave"
        self.assertTrue(created.exists())
        program = compile_file(str(created))
        self.assertEqual(program.name, "HelloWeave")
        # refuses to overwrite without --force
        code, out, _ = run_cli(["init", str(project)])
        self.assertEqual(code, 1)
        self.assertIn("already exists", out)
        code, _, _ = run_cli(["init", str(project), "--force"])
        self.assertEqual(code, 0)

    def test_build(self):
        out_dir = self.dir / "dist"
        code, out, _ = run_cli(["build", str(self.app), "-o", str(out_dir), "--port", "9999"])
        self.assertEqual(code, 0)
        for name in ("index.html", "app.py", "weave.json", "README.md"):
            self.assertTrue((out_dir / name).exists(), name)
        html = (out_dir / "index.html").read_text(encoding="utf-8")
        self.assertIn("Clicks: 0", html)
        self.assertIn("--weave-primary", html)
        script = (out_dir / "app.py").read_text(encoding="utf-8")
        self.assertIn("SOURCE = ", script)
        self.assertIn("9999", script)
        compile(script, "app.py", "exec")  # must be valid Python
        manifest = json.loads((out_dir / "weave.json").read_text(encoding="utf-8"))
        self.assertEqual(manifest["name"], "CliApp")
        self.assertIn("def _weave_h0", manifest["generated_python"])

    def test_version(self):
        code, out, _ = run_cli(["version"])
        self.assertEqual(code, 0)
        self.assertIn("weave 0.1.0", out)

    def test_no_command_shows_help(self):
        code, out, _ = run_cli([])
        self.assertEqual(code, 0)
        self.assertIn("usage: weave", out)


if __name__ == "__main__":
    unittest.main()
