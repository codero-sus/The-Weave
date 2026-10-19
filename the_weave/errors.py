"""Error types and pretty diagnostics for the Weave toolchain.

Every error carries a source location so the CLI can render a Rust-style
snippet::

    error[W1020]: unknown attribute 'bindd'
      --> app.weave:12:9
       |
    12 |         input(bindd: new_task)
       |         ^^^^^ did you mean 'bind'?
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import Optional


@dataclass(frozen=True)
class SourceLocation:
    line: int
    col: int

    def __str__(self) -> str:  # pragma: no cover - trivial
        return f"{self.line}:{self.col}"


class WeaveError(Exception):
    """Base class for every error produced by the Weave engine."""

    code = "W0000"

    def __init__(self, message: str, *, line: int = 1, col: int = 1, hint: str = "", filename: str = ""):
        super().__init__(message)
        self.message = message
        self.line = line
        self.col = col
        self.hint = hint
        self.filename = filename

    # -- diagnostics -------------------------------------------------
    def render(self, source: Optional[str] = None) -> str:
        parts = [f"error[{self.code}]: {self.message}"]
        where = self.filename or "<weave>"
        parts.append(f"  --> {where}:{self.line}:{self.col}")
        if source:
            lines = source.splitlines()
            idx = self.line - 1
            if 0 <= idx < len(lines):
                gutter = str(self.line).rjust(max(3, len(str(self.line))))
                parts.append(f"{' ' * len(gutter)} |")
                parts.append(f"{gutter} | {lines[idx]}")
                caret_len = max(1, min(len(lines[idx]) - self.col + 1, 40))
                parts.append(f"{' ' * len(gutter)} | {' ' * (self.col - 1)}{'^' * caret_len}")
        if self.hint:
            parts.append(f"  = help: {self.hint}")
        return "\n".join(parts)

    def to_dict(self) -> dict:
        return {
            "code": self.code,
            "message": self.message,
            "line": self.line,
            "col": self.col,
            "hint": self.hint,
            "filename": self.filename,
        }


class WeaveSyntaxError(WeaveError):
    """The source could not be tokenised or parsed."""

    code = "W1000"


class WeaveCompileError(WeaveError):
    """The parsed program is structurally invalid (unknown components...)."""

    code = "W2000"


class WeaveRuntimeError(WeaveError):
    """An error raised while executing a Weave handler or expression."""

    code = "W3000"


class WeaveDiagnostic(WeaveError):
    """Generic diagnostic (used for warnings surfaced by the CLI)."""

    code = "W9000"
