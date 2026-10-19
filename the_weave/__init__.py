"""Weave — a single-file, full-stack language.

Weave blends Python-flavoured logic with a declarative, HTML-like view
language.  A ``.weave`` file is compiled into a runnable, reactive web
application by the zero-dependency engine in this package.

Public entry points::

    from the_weave import compile_file, compile_source
    program = compile_file("app.weave")

    from the_weave.server import serve
    serve(program, port=8000)
"""

from __future__ import annotations

from pathlib import Path
from typing import Union

from .errors import (
    WeaveError,
    WeaveSyntaxError,
    WeaveCompileError,
    WeaveRuntimeError,
    WeaveDiagnostic,
)
from .program import Program
from .compiler import compile_source, compile_file

__version__ = "0.1.0"
__all__ = [
    "__version__",
    "Program",
    "compile_source",
    "compile_file",
    "WeaveError",
    "WeaveSyntaxError",
    "WeaveCompileError",
    "WeaveRuntimeError",
    "WeaveDiagnostic",
]


def run_file(path: Union[str, Path], **kwargs) -> None:  # pragma: no cover - convenience
    """Compile *path* and serve it.  Thin wrapper around :func:`serve`."""
    from .server import serve

    serve(compile_file(path), **kwargs)
