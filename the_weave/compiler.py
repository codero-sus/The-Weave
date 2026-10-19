"""The Weave compiler pipeline.

    .weave source
        │  tokenize + parse       (source.py, parser.py)
        │  structural checks      (components registry)
        │  semantic analysis      (analyzer.py)
        │  Python code generation (codegen.py)
        │  exec into a sandbox    (runtime.py)
        ▼
    Program  ──►  renderer.py  ──►  HTML
             └─►  server.py    ──►  live app
"""

from __future__ import annotations

from pathlib import Path
from typing import Any, Dict

from .analyzer import analyze
from .codegen import GeneratedCode, generate
from .errors import WeaveCompileError
from .parser import validate_component_names
from .program import Program
from .runtime import HELPERS, MODULES, SAFE_BUILTINS, SAFE_SYMBOLS
from .source import Source
from . import parser as _parser


def _execute(generated: GeneratedCode, app_name: str) -> Dict[str, Any]:
    filename = f"<weave:{app_name}>"
    namespace: Dict[str, Any] = {"__builtins__": SAFE_BUILTINS, "__name__": "weave_program"}
    namespace.update(SAFE_SYMBOLS)
    namespace.update(MODULES)
    namespace.update(HELPERS)
    try:
        code = compile(generated.source, filename, "exec")
    except SyntaxError as exc:
        raise WeaveCompileError(
            f"internal code generation error: {exc.msg}",
            line=generated.origin_for_line(exc.lineno or 1) or 1,
            col=exc.offset or 1,
            hint=(exc.text or "").strip(),
        ) from None
    exec(code, namespace)
    return namespace


def compile_source(text: str, filename: str = "<weave>") -> Program:
    """Compile Weave source code into a runnable :class:`Program`."""
    source = Source(text, filename=filename)
    app = _parser.parse(source)
    validate_component_names(app, source)
    analyze(app, source)
    generated = generate(app, source)
    namespace = _execute(generated, app.name)
    return Program(app, source, generated, namespace)


def compile_file(path: str) -> Program:
    """Compile a ``.weave`` file into a runnable :class:`Program`."""
    file_path = Path(path)
    if not file_path.exists():
        raise FileNotFoundError(f"no such file: {path}")
    text = file_path.read_text(encoding="utf-8")
    program = compile_source(text, filename=str(file_path))
    program.app.dirname = str(file_path.resolve().parent)
    program.filename = str(file_path)
    return program


def check_source(text: str, filename: str = "<weave>") -> Dict[str, Any]:
    program = compile_source(text, filename)
    return program.describe()
