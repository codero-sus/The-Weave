"""Semantic analysis for Weave.

Runs after parsing and before code generation.  Errors are reported with
source locations, and where possible with a suggestion::

    error[W2000]: unknown state variable 'taks'
      --> app.weave:14:22
       |
    14 |             for task in taks:
       |                          ^^^^ did you mean 'tasks'?
"""

from __future__ import annotations

import ast
import difflib
from typing import Dict, Iterable, List, Optional, Sequence, Set

from . import nodes as N
from .errors import WeaveCompileError
from .parser import BINDING_ATTRIBUTES
from .runtime import KNOWN_NAMES, SYMBOLS
from .source import Source

_MODULE_NAMES = set(KNOWN_NAMES)


def _parse_expr(src: str) -> Optional[ast.AST]:
    try:
        return ast.parse(src, mode="eval").body
    except SyntaxError:
        return None


def _collect_loads(tree: ast.AST) -> List[ast.Name]:
    loads: List[ast.Name] = []
    for node in ast.walk(tree):
        if isinstance(node, ast.Name) and isinstance(node.ctx, ast.Load):
            loads.append(node)
    return loads


def _bound_names(tree: ast.AST) -> Set[str]:
    """Every name that is *defined* somewhere inside a code block."""
    bound: Set[str] = set()

    def add_target(target: ast.AST) -> None:
        if isinstance(target, ast.Name):
            bound.add(target.id)
        elif isinstance(target, (ast.Tuple, ast.List)):
            for elt in target.elts:
                add_target(elt)
        elif isinstance(target, ast.Starred):
            add_target(target.value)

    for node in ast.walk(tree):
        if isinstance(node, (ast.Assign,)):
            for t in node.targets:
                add_target(t)
        elif isinstance(node, (ast.AugAssign, ast.AnnAssign)):
            add_target(node.target)
        elif isinstance(node, (ast.For, ast.AsyncFor)):
            add_target(node.target)
        elif isinstance(node, ast.withitem):
            if node.optional_vars is not None:
                add_target(node.optional_vars)
        elif isinstance(node, ast.ExceptHandler):
            if node.name:
                bound.add(node.name)
        elif isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef, ast.Lambda)):
            args = node.args
            for arg in args.posonlyargs + args.args + args.kwonlyargs:
                bound.add(arg.arg)
            if args.vararg:
                bound.add(args.vararg.arg)
            if args.kwarg:
                bound.add(args.kwarg.arg)
            if not isinstance(node, ast.Lambda):
                bound.add(node.name)
        elif isinstance(node, (ast.ListComp, ast.SetComp, ast.DictComp, ast.GeneratorExp)):
            for gen in node.generators:
                add_target(gen.target)
    return bound


class Analyzer:
    def __init__(self, app: N.App, source: Source):
        self.app = app
        self.source = source
        self.state_names: List[str] = [decl.name for decl in app.state]
        self.state_set: Set[str] = set(self.state_names)
        self.function_names: List[str] = [fn.name for fn in app.functions]
        self.known: Set[str] = (
            _MODULE_NAMES
            | self.state_set
            | set(self.function_names)
            | set(SYMBOLS)
            | {"True", "False", "None"}
        )

    # ------------------------------------------------------------------
    def check(self) -> None:
        self._check_state()
        self._check_functions()
        self._check_binds(self.app.view, set())
        for route in self.app.routes:
            self._check_binds(route.body, set())
        self._check_view_names(self.app.view, set())
        for route in self.app.routes:
            self._check_view_names(route.body, set())
        self._check_handlers(self.app.view)
        for route in self.app.routes:
            self._check_handlers(route.body)
        self._check_routes()

    # ------------------------------------------------------------------
    def _error(self, message: str, node, *, hint: str = "") -> WeaveCompileError:
        return WeaveCompileError(message, line=node.line, col=node.col, hint=hint, filename=self.source.filename)

    def _suggest(self, name: str, candidates: Iterable[str]) -> str:
        close = difflib.get_close_matches(name, list(candidates), n=1)
        return f"did you mean '{close[0]}'?" if close else ""

    def _check_state(self) -> None:
        seen: Dict[str, N.StateDecl] = {}
        available: Set[str] = set()
        for decl in self.app.state:
            if decl.name in seen:
                raise self._error(f"state variable '{decl.name}' is declared twice", decl,
                                  hint=f"first declared on line {seen[decl.name].line}")
            seen[decl.name] = decl
            tree = _parse_expr(decl.value)
            if tree is None:
                continue
            allowed = available | _MODULE_NAMES | set(SYMBOLS)
            for name_node in _collect_loads(tree):
                if name_node.id not in allowed and name_node.id not in {"True", "False", "None"}:
                    raise self._error(
                        f"unknown name '{name_node.id}' in the initializer for '{decl.name}'",
                        decl,
                        hint=self._suggest(name_node.id, allowed),
                    )
            available.add(decl.name)

    def _check_functions(self) -> None:
        if len(set(self.function_names)) != len(self.function_names):
            dupes = {n for n in self.function_names if self.function_names.count(n) > 1}
            fn = next(f for f in self.app.functions if f.name in dupes)
            raise self._error(f"function '{fn.name}' is defined twice", fn)
        for fn in self.app.functions:
            if fn.name in self.state_set:
                raise self._error(
                    f"function '{fn.name}' clashes with a state variable of the same name",
                    fn,
                    hint="rename one of them; state and functions share a namespace",
                )
            try:
                params = (
                    {a.arg for a in ast.parse(f"def _f({fn.params}): pass").body[0].args.args}
                    if fn.params.strip() else set()
                )
            except SyntaxError as exc:
                raise self._error(f"invalid parameters for function '{fn.name}': {exc.msg}", fn) from None
            self._check_code_names(
                fn.body,
                node=fn,
                known=self.known | params,
                context=f"function '{fn.name}'",
            )

    def _check_routes(self) -> None:
        seen: Set[str] = set()
        for route in self.app.routes:
            if not route.path.startswith("/"):
                raise self._error(
                    f"route path '{route.path}' must start with '/'",
                    route,
                )
            if route.path in seen:
                raise self._error(f"duplicate route '{route.path}'", route)
            seen.add(route.path)

    # ------------------------------------------------------------------
    def _check_binds(self, nodes: Sequence[N.Node], scope: Set[str]) -> None:
        for node in nodes:
            if isinstance(node, N.Component):
                bind = node.attrs.get("bind") or node.attrs.get("bind_value")
                if bind is not None:
                    target = bind.expr.strip()
                    if target not in self.state_set:
                        raise self._error(
                            f"'bind' must reference a state variable, but '{target}' is not declared",
                            bind,
                            hint=self._suggest(target, self.state_names) or "declare it in the state: block",
                        )
                if node.name == "tabs" and "bind" not in node.attrs:
                    raise self._error("tabs() requires bind: <state variable>", node,
                                      hint="e.g. tabs(bind: selected_tab):")
                self._check_binds(node.children, scope)
            elif isinstance(node, N.For):
                self._check_binds(node.children, scope | {node.target} | ({node.index} if node.index else set()))
            elif isinstance(node, N.If):
                self._check_binds(node.children, scope)
                self._check_binds(node.orelse, scope)

    # ------------------------------------------------------------------
    def _check_view_names(self, nodes: Sequence[N.Node], scope: Set[str]) -> None:
        for node in nodes:
            if isinstance(node, N.Component):
                for arg in node.positional:
                    self._check_expression(arg, node, scope, "argument")
                for attr in node.attrs.values():
                    if attr.handler is not None:
                        continue
                    if attr.name in BINDING_ATTRIBUTES:
                        continue
                    self._check_expression(attr.expr, attr, scope, f"attribute '{attr.name}'", allow_bareword=True)
                self._check_view_names(node.children, scope)
            elif isinstance(node, N.For):
                self._check_expression(node.iterable, node, scope, "for loop")
                inner = scope | {node.target} | ({node.index} if node.index else set())
                self._check_view_names(node.children, inner)
            elif isinstance(node, N.If):
                self._check_expression(node.condition, node, scope, "if condition")
                self._check_view_names(node.children, scope)
                self._check_view_names(node.orelse, scope)

    def _check_expression(
        self,
        src: str,
        node,
        scope: Set[str],
        context: str,
        *,
        allow_bareword: bool = False,
    ) -> None:
        tree = _parse_expr(src)
        if tree is None:
            raise self._error(f"invalid expression in {context}: {src}", node)
        if allow_bareword and isinstance(tree, ast.Name) and tree.id not in self.known and tree.id not in scope:
            return  # a design bareword such as `type: email`
        unknown = [
            n for n in _collect_loads(tree)
            if n.id not in self.known and n.id not in scope and n.id not in {"True", "False", "None"}
        ]
        if unknown:
            name = unknown[0].id
            known_names = self.known | scope
            raise self._error(
                f"unknown name '{name}' in {context}",
                node,
                hint=self._suggest(name, known_names) or "check the spelling, or declare it in state:",
            )

    # ------------------------------------------------------------------
    def _check_handlers(self, nodes: Sequence[N.Node]) -> None:
        for node in nodes:
            if isinstance(node, N.Component):
                for attr in node.attrs.values():
                    if attr.handler is not None:
                        self._check_code_names(
                            attr.handler.body,
                            node=attr.handler,
                            known=self.known,
                            context=f"'{attr.name}' handler",
                            extra=set(attr.handler.captures),
                        )
                self._check_handlers(node.children)
            elif isinstance(node, N.For):
                self._check_handlers(node.children)
            elif isinstance(node, N.If):
                self._check_handlers(node.children)
                self._check_handlers(node.orelse)

    def _check_code_names(self, body: str, *, node, known: Set[str], context: str, extra: Optional[Set[str]] = None) -> None:
        if not body.strip():
            return
        try:
            tree = ast.parse(body)
        except SyntaxError:
            return  # reported precisely by the code generator
        bound = _bound_names(tree)
        allowed = set(known) | bound | (extra or set())
        for name_node in _collect_loads(tree):
            if name_node.id in allowed or name_node.id in {"True", "False", "None"}:
                continue
            raise self._error(
                f"unknown name '{name_node.id}' in {context}",
                node,
                hint=self._suggest(name_node.id, allowed) or "state variables must be declared in state:",
            )


def analyze(app: N.App, source: Source) -> None:
    Analyzer(app, source).check()
