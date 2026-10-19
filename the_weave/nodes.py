"""AST node definitions for Weave.

Deliberately simple dataclasses; the compiler walks them in three passes:

* :mod:`the_weave.parser`      — source  -> AST
* :mod:`the_weave.codegen`     — handlers -> Python source
* :mod:`the_weave.renderer`    — view    -> HTML
* :mod:`the_weave.analyzer`    — semantic checks shared by both
"""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import Dict, List, Optional


# ---------------------------------------------------------------------------
# Base
# ---------------------------------------------------------------------------

@dataclass
class Node:
    line: int = 1
    col: int = 1


# ---------------------------------------------------------------------------
# Program structure
# ---------------------------------------------------------------------------

@dataclass
class StateDecl(Node):
    name: str = ""
    #: Python source for the initial value, e.g. ``["a", "b"]``
    value: str = ""
    type_name: Optional[str] = None
    type_args: List["TypeRef"] = field(default_factory=list)


@dataclass
class TypeRef:
    name: str
    args: List["TypeRef"] = field(default_factory=list)


@dataclass
class StateBlock(Node):
    decls: List[StateDecl] = field(default_factory=list)


@dataclass
class Handler(Node):
    """A Python-source code block attached to an event."""

    body: str = ""
    #: ``event`` (click, on_enter, ...) or ``function`` / ``computed``
    kind: str = "event"
    #: names captured from enclosing ``for`` loops (passed back at event time)
    captures: List[str] = field(default_factory=list)
    #: generated Python function name
    func_name: str = ""
    #: 1-based line in the .weave file where the body starts
    body_line: int = 1


@dataclass
class FunctionDecl(Node):
    name: str = ""
    params: str = ""
    body: str = ""
    kind: str = "function"  # function | computed
    return_type: Optional[str] = None
    body_line: int = 1


@dataclass
class Attribute(Node):
    name: str = ""
    #: canonical Python-ish source for the value expression
    expr: str = ""
    #: for event attributes: the handler, if written as a ``{ ... }`` block
    handler: Optional[Handler] = None
    #: raw source text of the value (useful in diagnostics)
    raw: str = ""


@dataclass
class Component(Node):
    name: str = ""
    positional: List[str] = field(default_factory=list)
    attrs: Dict[str, Attribute] = field(default_factory=dict)
    children: List[Node] = field(default_factory=list)


@dataclass
class For(Node):
    target: str = ""
    iterable: str = ""
    children: List[Node] = field(default_factory=list)
    index: Optional[str] = None


@dataclass
class If(Node):
    condition: str = ""
    children: List[Node] = field(default_factory=list)
    orelse: List[Node] = field(default_factory=list)


@dataclass
class ViewBlock(Node):
    children: List[Node] = field(default_factory=list)


@dataclass
class Route(Node):
    path: str = ""
    body: List[Node] = field(default_factory=list)
    title: Optional[str] = None


@dataclass
class App(Node):
    name: str = ""
    title: Optional[str] = None
    state: List[StateDecl] = field(default_factory=list)
    view: List[Node] = field(default_factory=list)
    routes: List[Route] = field(default_factory=list)
    functions: List[FunctionDecl] = field(default_factory=list)
    styles: Dict[str, Dict[str, str]] = field(default_factory=dict)
    theme: Dict[str, str] = field(default_factory=dict)
    dirname: str = "."
