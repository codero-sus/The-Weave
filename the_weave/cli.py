"""The ``weave`` command line interface.

Usage::

    weave run app.weave            # compile and serve with hot reload
    weave check app.weave          # type/structure check only
    weave build app.weave          # static first paint + standalone app.py
    weave ast app.weave            # dump the parsed AST as JSON
    weave components              # list the component vocabulary
    weave init my-app             # scaffold a new project
    weave version
"""

from __future__ import annotations

import argparse
import dataclasses
import json
import os
import sys
from pathlib import Path
from typing import Any, Optional, Sequence

from . import __version__
from .compiler import compile_file
from .components import COMPONENT_LIST, UNIVERSAL_ATTRS
from .errors import WeaveError
from .program import Program
from .runtime import Context

# ---------------------------------------------------------------------------
# terminal helpers
# ---------------------------------------------------------------------------

_COLOR = sys.stdout.isatty() and not os.environ.get("NO_COLOR")


def _c(text: str, code: str) -> str:
    if not _COLOR:
        return text
    return f"\x1b[{code}m{text}\x1b[0m"


def bold(text: str) -> str:
    return _c(text, "1")


def dim(text: str) -> str:
    return _c(text, "2")


def green(text: str) -> str:
    return _c(text, "32")


def red(text: str) -> str:
    return _c(text, "31")


def yellow(text: str) -> str:
    return _c(text, "33")


def cyan(text: str) -> str:
    return _c(text, "36")


def violet(text: str) -> str:
    return _c(text, "38;5;99")


LOGO = r"""
   ╦ ╦╔═╗╔═╗╦  ╦╔═╗
   ║║║║╣ ╠═╣╚╗╔╝║╣
   ╚╩╝╚═╝╩ ╩ ╚╝ ╚═╝
"""


def _print_logo() -> None:
    print(violet(LOGO))
    print(f"  {dim('the full-stack language · v' + __version__)}")
    print()


# ---------------------------------------------------------------------------
# errors
# ---------------------------------------------------------------------------

def _report(error: WeaveError, source_text: Optional[str] = None) -> None:
    print()
    print(red(f"error[{error.code}]") + " " + bold(error.message))
    where = error.filename or "<weave>"
    print(f"  {dim('-->')} {where}:{error.line}:{error.col}")
    if source_text:
        lines = source_text.splitlines()
        idx = error.line - 1
        if 0 <= idx < len(lines):
            gutter = str(error.line).rjust(3)
            print(f"{' ' * 3} {dim('|')}")
            print(f"{gutter} {dim('|')} {lines[idx]}")
            caret = " " * (error.col - 1) + "^" * max(1, min(30, len(lines[idx]) - error.col + 1))
            print(f"{' ' * 3} {dim('|')} {red(caret)}")
    if error.hint:
        print(f"  {cyan('=')} {dim('help:')} {error.hint}")
    print()


# ---------------------------------------------------------------------------
# commands
# ---------------------------------------------------------------------------

def cmd_run(args: argparse.Namespace) -> int:
    from .server import ProgramHandle, make_server

    path = args.file
    try:
        program = compile_file(path)
        source_text = Path(path).read_text(encoding="utf-8")
    except FileNotFoundError:
        print(red("error:") + f" no such file: {path}")
        return 1
    except WeaveError as exc:
        _report(exc, _read_quietly(path))
        return 1

    handle = ProgramHandle(program, path)
    port = args.port if args.port is not None else int(os.environ.get("WEAVE_PORT", 8420))
    try:
        server = make_server(handle, args.host, port, debug=not args.no_debug, watch=not args.no_reload)
    except OSError as exc:
        print(red("error:") + f" could not bind {args.host}:{port} — {exc}")
        print(dim("       try a different port with --port 9000"))
        return 1

    _print_logo()
    print(f"  {bold(program.name)}  {dim('· ' + str(len(source_text.splitlines())) + ' lines of Weave')}")
    print(f"  {dim('state')}    {', '.join(program.state_names) or '—'}")
    print(f"  {dim('handlers')} {len(program.handler_meta)}   {dim('components')} {program.describe()['components']}")
    url_host = "localhost" if args.host in ("0.0.0.0", "::") else args.host
    print(f"\n  {green('➜')}  {bold(f'http://{url_host}:{server.server_address[1]}')}")
    print(f"  {dim('watching ' + str(Path(path).resolve()) + (' for changes' if not args.no_reload else ''))}")
    print(f"  {dim('Ctrl+C to stop')}\n")

    if args.open:
        import threading
        import webbrowser

        threading.Timer(0.5, lambda: webbrowser.open(f"http://{url_host}:{server.server_address[1]}")).start()
    try:
        server.serve()
    except KeyboardInterrupt:
        pass
    return 0


def cmd_check(args: argparse.Namespace) -> int:
    try:
        program = compile_file(args.file)
    except FileNotFoundError:
        print(red("error:") + f" no such file: {args.file}")
        return 1
    except WeaveError as exc:
        _report(exc, _read_quietly(args.file))
        return 1

    info = program.describe()
    if args.json:
        print(json.dumps(info, indent=2, ensure_ascii=False))
        return 0
    print()
    print(f"  {green('✔')} {bold(os.path.basename(args.file))} compiled cleanly")
    print()
    print(f"  {dim('app')}        {bold(program.name)}  {dim('· ' + info['title'])}")
    print(f"  {dim('lines')}      {info['lines']}")
    print(f"  {dim('state')}      {len(info['state'])}  {dim(', '.join(info['state']))}")
    print(f"  {dim('functions')}  {len(info['functions'])}  {dim(', '.join(info['functions']) or '—')}")
    print(f"  {dim('handlers')}   {info['handlers']}")
    print(f"  {dim('components')} {info['components']} nodes")
    print(f"  {dim('routes')}     {', '.join(info['routes'])}")
    print(f"  {dim('python')}     {len(program.generated.source.splitlines())} generated lines")
    print()
    return 0


def cmd_ast(args: argparse.Namespace) -> int:
    try:
        program = compile_file(args.file)
    except FileNotFoundError:
        print(red("error:") + f" no such file: {args.file}")
        return 1
    except WeaveError as exc:
        _report(exc, _read_quietly(args.file))
        return 1
    if args.python:
        print(program.generated.source)
        return 0
    print(json.dumps(_dataclass_dict(program.app), indent=2, ensure_ascii=False))
    return 0


def cmd_build(args: argparse.Namespace) -> int:
    try:
        program = compile_file(args.file)
    except FileNotFoundError:
        print(red("error:") + f" no such file: {args.file}")
        return 1
    except WeaveError as exc:
        _report(exc, _read_quietly(args.file))
        return 1

    out_dir = Path(args.out or "dist")
    out_dir.mkdir(parents=True, exist_ok=True)

    ctx = Context(program.new_state())
    result = program.render(ctx)
    source_text = program.source.text

    css = (Path(__file__).parent / "static" / "weave.css").read_text(encoding="utf-8")
    html = _static_html(program, result, css)
    (out_dir / "index.html").write_text(html, encoding="utf-8")

    (out_dir / "app.py").write_text(_standalone_script(program, source_text, args.port), encoding="utf-8")
    try:
        os.chmod(out_dir / "app.py", 0o755)
    except OSError:
        pass

    manifest = program.describe()
    manifest["generated_python"] = program.generated.source
    (out_dir / "weave.json").write_text(json.dumps(manifest, indent=2, ensure_ascii=False), encoding="utf-8")

    readme = _build_readme(program)
    (out_dir / "README.md").write_text(readme, encoding="utf-8")

    print()
    print(f"  {green('✔')} built {bold(program.name)} → {bold(str(out_dir))}")
    print()
    print(f"  {dim('index.html')}   static first paint (initial state, inlined design system)")
    print(f"  {dim('app.py')}       standalone server — run with: python {out_dir / 'app.py'}")
    print(f"  {dim('weave.json')}   manifest + generated Python")
    print(f"  {dim('README.md')}    deployment notes")
    print()
    return 0


def cmd_components(args: argparse.Namespace) -> int:
    if args.json:
        print(json.dumps({
            spec.name: {
                "tag": spec.tag,
                "summary": spec.summary,
                "positional": list(spec.positional),
                "attrs": sorted(spec.attrs),
                "events": sorted(spec.events),
                "container": spec.container,
            }
            for spec in COMPONENT_LIST
        }, indent=2))
        return 0
    print()
    print(f"  {bold('Weave components')}   {dim(str(len(COMPONENT_LIST)) + ' primitives · positional args in parentheses')}")
    print()
    for spec in COMPONENT_LIST:
        args_hint = ""
        if spec.positional[1] == 1:
            args_hint = "value"
        elif spec.positional[1] and spec.positional[1] > 1:
            args_hint = ", ".join(f"arg{i + 1}" for i in range(spec.positional[1]))
        signature = f"{spec.name}({args_hint})" if args_hint else spec.name
        print(f"  {cyan(signature.ljust(22))} {spec.summary}")
        if args.examples and spec.example:
            for line in spec.example.splitlines():
                print(f"  {' ' * 22} {dim(line)}")
    print()
    print(f"  {dim('every component also accepts:')} {dim(', '.join(sorted(UNIVERSAL_ATTRS)))}")
    print(f"  {dim('run `weave components --examples` to see snippets')}")
    print()
    return 0


STARTER = '''app HelloWeave(title: "Hello, Weave"):

    state:
        name = ""
        clicks = 0
        items = ["write a .weave file", "run weave run", "ship it"]

    view:
        stack(padding: 28, gap: 18, align: stretch):
            title("Hello, Weave")
            text("A single file is the whole app — state, logic and UI.", muted: true)

            input(bind: name, placeholder: "What should we call you?", on_enter: {
                if name != "":
                    items.append(f"say hi to {name}")
                    name = ""
            })

            if name:
                text(f"Nice to meet you, {name}.", font: 18)

            row(gap: 10):
                button(f"Clicks: {clicks}", click: {
                    clicks = clicks + 1
                })
                button("Reset", variant: secondary, click: {
                    clicks = 0
                })

            section(title: "Todo"):
                for item in items:
                    card(padding: 12, shadow: xs):
                        row(justify: between):
                            text(item)
                            button("✕", variant: ghost, size: sm, click: items.remove(item))
'''


def cmd_init(args: argparse.Namespace) -> int:
    target_dir = Path(args.directory or ".")
    target_dir.mkdir(parents=True, exist_ok=True)
    file_path = target_dir / (args.name if args.name else "app.weave")
    if file_path.suffix != ".weave":
        file_path = target_dir / "app.weave"
    if file_path.exists() and not args.force:
        print(red("error:") + f" {file_path} already exists (use --force to overwrite)")
        return 1
    file_path.write_text(STARTER, encoding="utf-8")
    print()
    print(f"  {green('✔')} created {bold(str(file_path))}")
    print()
    print(f"  {dim('next:')}")
    print(f"    {cyan('weave run ' + str(file_path))}")
    print()
    return 0


def cmd_version(args: argparse.Namespace) -> int:
    print(f"weave {__version__}  ·  python {sys.version.split()[0]}")
    return 0


# ---------------------------------------------------------------------------
# build helpers
# ---------------------------------------------------------------------------

def _static_html(program: Program, result, css: str) -> str:
    import html as html_module

    theme_lines = []
    for key, value in program.app.theme.items():
        if key == "mode":
            continue
        var = "--weave-" + key.replace("_", "-")
        theme_lines.append(f"  {var}: {value};")
    theme_css = ":root {\n" + "\n".join(theme_lines) + "\n}" if theme_lines else ""
    return f"""<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>{html_module.escape(result.title)}</title>
<style>
{css}
{theme_css}
</style>
</head>
<body>
<main id="weave-root" data-w="r">{result.html}</main>
</body>
</html>
"""


def _standalone_script(program: Program, source_text: str, port: int) -> str:
    return f'''#!/usr/bin/env python3
"""Standalone build of the Weave app "{program.name}".

Run with:  python app.py [--port {port}]

Requires the ``the_weave`` package (``pip install the-weave`` or run from the
repository root). The original .weave source is embedded below, so this file
is fully self-contained apart from the engine itself.
"""

from the_weave import compile_source
from the_weave.server import serve

SOURCE = {source_text!r}

if __name__ == "__main__":
    import argparse

    parser = argparse.ArgumentParser(description="Run {program.name}")
    parser.add_argument("--port", type=int, default={port})
    parser.add_argument("--host", default="0.0.0.0")
    args = parser.parse_args()
    program = compile_source(SOURCE, filename="app.weave")
    serve(program, host=args.host, port=args.port, watch=False)
'''


def _build_readme(program: Program) -> str:
    return f"""# {program.name}

Built with **Weave** — a single-file, full-stack language.

- `index.html` — static first paint of the app using its initial state.
- `app.py` — standalone server with the `.weave` source embedded.
- `weave.json` — manifest, including the generated Python for inspection.

## Run

```bash
pip install the-weave      # or run from the Weave repository root
python app.py --port {8420}
```

## Structure

| | |
|---|---|
| state variables | {', '.join(program.state_names) or '—'} |
| functions | {', '.join(fn.name for fn in program.app.functions) or '—'} |
| handlers | {len(program.handler_meta)} |
| routes | {', '.join(program.route_paths())} |

Generated by Weave v{__version__}.
"""


def _read_quietly(path: str) -> Optional[str]:
    try:
        return Path(path).read_text(encoding="utf-8")
    except OSError:
        return None


def _dataclass_dict(obj: Any) -> Any:
    if dataclasses.is_dataclass(obj):
        return {k: _dataclass_dict(v) for k, v in dataclasses.asdict(obj).items()}
    if isinstance(obj, dict):
        return {k: _dataclass_dict(v) for k, v in obj.items()}
    if isinstance(obj, (list, tuple)):
        return [_dataclass_dict(v) for v in obj]
    return obj


# ---------------------------------------------------------------------------
# argument parsing
# ---------------------------------------------------------------------------

def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="weave",
        description="Weave — a single-file, full-stack language. Python logic, declarative UI.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""examples:
  weave run examples/todo.weave
  weave check examples/todo.weave
  weave init my-app
  weave components --examples
""",
    )
    parser.add_argument("-v", "--version", action="version", version=f"weave {__version__}")
    sub = parser.add_subparsers(dest="command")

    run = sub.add_parser("run", aliases=["serve", "dev"], help="compile and serve an app with hot reload")
    run.add_argument("file", help="path to a .weave file")
    run.add_argument("-p", "--port", type=int, default=None, help="port to listen on (default 8420)")
    run.add_argument("--host", default="0.0.0.0", help="host/interface to bind (default 0.0.0.0)")
    run.add_argument("--open", action="store_true", help="open the app in a browser")
    run.add_argument("--no-reload", action="store_true", help="disable hot reload")
    run.add_argument("--no-debug", action="store_true", help="hide Python tracebacks in error payloads")
    run.set_defaults(func=cmd_run)

    check = sub.add_parser("check", help="compile without running, and print a summary")
    check.add_argument("file")
    check.add_argument("--json", action="store_true")
    check.set_defaults(func=cmd_check)

    build = sub.add_parser("build", help="export a static first paint and a standalone app.py")
    build.add_argument("file")
    build.add_argument("-o", "--out", default="dist", help="output directory (default dist)")
    build.add_argument("--port", type=int, default=8420, help="default port baked into app.py")
    build.set_defaults(func=cmd_build)

    ast_cmd = sub.add_parser("ast", help="dump the parsed AST (or the generated Python)")
    ast_cmd.add_argument("file")
    ast_cmd.add_argument("--python", action="store_true", help="print generated Python instead")
    ast_cmd.set_defaults(func=cmd_ast)

    comps = sub.add_parser("components", help="list the component vocabulary")
    comps.add_argument("--examples", action="store_true", help="show usage snippets")
    comps.add_argument("--json", action="store_true")
    comps.set_defaults(func=cmd_components)

    init = sub.add_parser("init", aliases=["new"], help="scaffold a starter .weave file")
    init.add_argument("directory", nargs="?", default=".", help="project directory (default .)")
    init.add_argument("--name", default=None, help="file name inside the directory")
    init.add_argument("--force", action="store_true", help="overwrite an existing file")
    init.set_defaults(func=cmd_init)

    version = sub.add_parser("version", help="print the engine version")
    version.set_defaults(func=cmd_version)

    return parser


def main(argv: Optional[Sequence[str]] = None) -> int:
    try:
        sys.stdout.reconfigure(line_buffering=True)
        sys.stderr.reconfigure(line_buffering=True)
    except (AttributeError, TypeError):  # pragma: no cover - unusual streams
        pass
    parser = build_parser()
    args = parser.parse_args(list(argv) if argv is not None else None)
    if not getattr(args, "command", None):
        _print_logo()
        parser.print_help()
        return 0
    try:
        return args.func(args) or 0
    except KeyboardInterrupt:
        print("\n  stopped.")
        return 130
    except WeaveError as exc:
        _report(exc)
        return 1


if __name__ == "__main__":  # pragma: no cover
    sys.exit(main())
