"""Translate Weave's logic half into Python.

Handlers and functions are written in Python-ish syntax.  Instead of
inventing a second expression engine, Weave reuses CPython's ``ast`` module
and rewrites only what it must:

* reads of state variables   → ``ctx.st['name']``
* writes to state variables  → ``ctx.st['name'] = …``
* calls to Weave functions   → ``ctx`` is threaded through as first argument
* loop variables captured by a handler are passed in as parameters

The output is genuine Python, executed by CPython.  That means Weave gets
Python's semantics — mutating lists, dict comprehensions, exceptions,
f-strings — for free.
"""

from __future__ import annotations

import ast
from dataclasses import dataclass, field
from typing import Dict, List, Optional, Sequence, Set, Tuple

from . import nodes as N
from .errors import WeaveCompileError
from .source import Source


# ---------------------------------------------------------------------------
# Compiled artifacts
# ---------------------------------------------------------------------------

@dataclass
class HandlerMeta:
    func_name: str
    node: N.Handler
    line: int
    col: int
    body_start: int          # first generated line of the body (1-based)
    origin_start: int        # matching line in the .weave file
    captures: Tuple[str, ...]
    filename: str


@dataclass
class FunctionMeta:
    name: str
    func_name: str
    line: int
    col: int
    body_start: int
    origin_start: int
    params: str
    filename: str


@dataclass
class GeneratedCode:
    source: str
    line_origins: List[Optional[int]]
    handler_meta: Dict[str, HandlerMeta] = field(default_factory=dict)
    function_meta: Dict[str, FunctionMeta] = field(default_factory=dict)
    handler_nodes: List[N.Handler] = field(default_factory=list)

    def origin_for_line(self, lineno: int) -> Optional[int]:
        if 1 <= lineno <= len(self.line_origins):
            return self.line_origins[lineno - 1]
        return None


# ---------------------------------------------------------------------------
# AST rewriting
# ---------------------------------------------------------------------------

def _target_names(target: ast.AST) -> Set[str]:
    names: Set[str] = set()
    if isinstance(target, ast.Name):
        names.add(target.id)
    elif isinstance(target, (ast.Tuple, ast.List)):
        for elt in target.elts:
            names |= _target_names(elt)
    elif isinstance(target, ast.Starred):
        names |= _target_names(target.value)
    return names


def _param_names(args: ast.arguments) -> Set[str]:
    names = {a.arg for a in args.posonlyargs + args.args + args.kwonlyargs}
    if args.vararg:
        names.add(args.vararg.arg)
    if args.kwarg:
        names.add(args.kwarg.arg)
    return names


class StateRewriter(ast.NodeTransformer):
    """Rewrites state access and threads ``ctx`` through user function calls."""

    def __init__(self, state_names: Sequence[str], function_names: Sequence[str], bound: Sequence[str] = ()):
        self.state = set(state_names)
        self.functions = set(function_names)
        self.bound: Set[str] = set(bound)

    # -- helpers ------------------------------------------------------
    @staticmethod
    def _ctx() -> ast.expr:
        return ast.Name(id="ctx", ctx=ast.Load())

    def _state_ref(self, name: str, ctx: ast.expr_context) -> ast.Subscript:
        return ast.Subscript(
            value=ast.Attribute(value=self._ctx(), attr="st", ctx=ast.Load()),
            slice=ast.Constant(value=name),
            ctx=ctx,
        )

    # -- names --------------------------------------------------------
    def visit_Name(self, node: ast.Name) -> ast.AST:
        if node.id in self.bound or node.id not in self.state:
            return node
        if isinstance(node.ctx, ast.Load):
            return ast.copy_location(self._state_ref(node.id, ast.Load()), node)
        if isinstance(node.ctx, (ast.Store, ast.Del)):
            return ast.copy_location(self._state_ref(node.id, node.ctx), node)
        return node

    # -- scopes -------------------------------------------------------
    def visit_For(self, node: ast.For) -> ast.AST:
        node.iter = self.visit(node.iter)
        names = _target_names(node.target)
        self.bound |= names
        node.body = [self.visit(stmt) for stmt in node.body]
        node.orelse = [self.visit(stmt) for stmt in node.orelse]
        self.bound -= names
        return node

    def visit_AsyncFor(self, node):  # pragma: no cover - not used by Weave
        return node

    def visit_With(self, node: ast.With) -> ast.AST:
        for item in node.items:
            item.context_expr = self.visit(item.context_expr)
        names: Set[str] = set()
        for item in node.items:
            if item.optional_vars is not None:
                names |= _target_names(item.optional_vars)
        self.bound |= names
        node.body = [self.visit(stmt) for stmt in node.body]
        self.bound -= names
        return node

    def visit_ExceptHandler(self, node: ast.ExceptHandler) -> ast.AST:
        if node.name:
            self.bound.add(node.name)
        node.body = [self.visit(stmt) for stmt in node.body]
        if node.name:
            self.bound.discard(node.name)
        return node

    def visit_Lambda(self, node: ast.Lambda) -> ast.AST:
        names = _param_names(node.args)
        self.bound |= names
        node.body = self.visit(node.body)
        self.bound -= names
        return node

    def visit_FunctionDef(self, node: ast.FunctionDef) -> ast.AST:
        # Nested functions are an escape hatch; their parameters are local,
        # but they may still close over state.
        names = _param_names(node.args)
        self.bound |= names
        node.body = [self.visit(stmt) for stmt in node.body]
        self.bound -= names
        return node

    def visit_AsyncFunctionDef(self, node):  # pragma: no cover
        return node

    # -- comprehensions ----------------------------------------------
    def _visit_comp(self, node):
        added: Set[str] = set()
        for gen in node.generators:
            gen.iter = self.visit(gen.iter)
            names = _target_names(gen.target)
            added |= names
            self.bound |= names
            gen.ifs = [self.visit(expr) for expr in gen.ifs]
        if isinstance(node, ast.DictComp):
            node.key = self.visit(node.key)
            node.value = self.visit(node.value)
        else:
            node.elt = self.visit(node.elt)
        self.bound -= added
        return node

    visit_ListComp = _visit_comp
    visit_SetComp = _visit_comp
    visit_GeneratorExp = _visit_comp
    visit_DictComp = _visit_comp

    # -- calls --------------------------------------------------------
    def visit_Call(self, node: ast.Call) -> ast.AST:
        node = self.generic_visit(node)
        if isinstance(node.func, ast.Name) and node.func.id in self.functions:
            # user-facing name -> generated function + threaded context
            node.func.id = f"_weave_f_{node.func.id}"
            already = node.args and isinstance(node.args[0], ast.Name) and node.args[0].id == "ctx"
            if not already:
                node.args.insert(0, ast.Name(id="ctx", ctx=ast.Load()))
        return node


# ---------------------------------------------------------------------------
# Code generation
# ---------------------------------------------------------------------------

_IDENT_RE = __import__("re").compile(r"^[A-Za-z_][A-Za-z0-9_]*$")


def _normalise_params(params: str, fn: N.FunctionDecl, source: Source) -> str:
    """Validate a parameter list and strip annotations (documentation only)."""
    params = params.strip()
    if not params:
        return ""
    try:
        node = ast.parse(f"def _f({params}): pass").body[0]
    except SyntaxError as exc:
        raise WeaveCompileError(
            f"invalid parameters for function '{fn.name}': {exc.msg}",
            line=fn.line,
            col=fn.col,
            filename=source.filename,
        ) from None
    if not isinstance(node, ast.FunctionDef):  # pragma: no cover - defensive
        return params
    arguments = node.args
    for arg in arguments.posonlyargs + arguments.args + arguments.kwonlyargs:
        arg.annotation = None
    if arguments.vararg:
        arguments.vararg.annotation = None
    if arguments.kwarg:
        arguments.kwarg.annotation = None
    text = ast.unparse(node)
    start = text.index("(") + 1
    end = text.index(")")
    return text[start:end].strip()


class CodeGen:
    def __init__(self, app: N.App, source: Source):
        self.app = app
        self.source = source
        self.state_names = [decl.name for decl in app.state]
        self.function_names = [fn.name for fn in app.functions]
        self.lines: List[str] = []
        self.line_origins: List[Optional[int]] = []
        self.handler_meta: Dict[str, HandlerMeta] = {}
        self.function_meta: Dict[str, FunctionMeta] = {}
        self.handler_nodes: List[N.Handler] = []
        self._handler_count = 0

    #: Names bound inside every generated function so user code can use them.
    PRELUDE = (
        ("state", "ctx.st"),
        ("log", "ctx.log"),
        ("toast", "ctx.toast"),
        ("navigate", "ctx.navigate"),
        ("emit", "ctx.emit"),
        ("print", "ctx.log"),
    )

    def _emit_prelude(self, params: Set[str], origin: int) -> int:
        first = self.next_line
        for name, expr in self.PRELUDE:
            if name in params or name == "ctx":
                continue
            self.emit(f"    {name} = {expr}", origin=origin)
        return first

    # -- emission -----------------------------------------------------
    def emit(self, text: str, origin: Optional[int] = None) -> None:
        for line in text.split("\n"):
            self.lines.append(line)
            self.line_origins.append(origin)

    @property
    def next_line(self) -> int:
        return len(self.lines) + 1

    # -- public API ---------------------------------------------------
    def generate(self) -> GeneratedCode:
        for fn in self.app.functions:
            self._compile_function(fn)
        self._collect_handlers(self.app.view, [])
        for route in self.app.routes:
            self._collect_handlers(route.body, [])
        return GeneratedCode(
            source="\n".join(self.lines) + "\n",
            line_origins=self.line_origins,
            handler_meta=self.handler_meta,
            function_meta=self.function_meta,
            handler_nodes=self.handler_nodes,
        )

    # -- functions ----------------------------------------------------
    def _compile_function(self, fn: N.FunctionDecl) -> None:
        if not _IDENT_RE.match(fn.name):
            raise WeaveCompileError(
                f"invalid function name '{fn.name}'",
                line=fn.line,
                col=fn.col,
                filename=self.source.filename,
            )
        func_name = f"_weave_f_{fn.name}"
        params = _normalise_params(fn.params, fn, self.source)
        signature = f"def {func_name}(ctx{', ' + params if params else ''}):"
        body, body_start, param_names = self._compile_body(
            fn.body,
            origin_start=fn.body_line,
            captures=(),
            extra_bound=(),
            context=f"function '{fn.name}'",
            line=fn.line,
            col=fn.col,
        )
        # Validate the signature by compiling a stub.
        try:
            compile(signature + "\n    pass\n", "<weave-signature>", "exec")
        except SyntaxError as exc:
            raise WeaveCompileError(
                f"invalid parameters for function '{fn.name}': {exc.msg}",
                line=fn.line,
                col=fn.col,
                filename=self.source.filename,
            ) from None
        self.emit(signature)
        try:
            param_ast = ast.parse(f"def _f({params}): pass").body[0]
            param_names = _param_names(param_ast.args) if isinstance(param_ast, ast.FunctionDef) else set()
        except SyntaxError:  # pragma: no cover - validated above
            param_names = set()
        self._emit_prelude(param_names, fn.body_line)
        body_start_gen = self.next_line
        for offset, line in enumerate(body.split("\n")):
            self.emit("    " + line, origin=fn.body_line + offset)
        if not body.strip():
            self.emit("    pass", origin=fn.body_line)
        self.function_meta[func_name] = FunctionMeta(
            name=fn.name,
            func_name=func_name,
            line=fn.line,
            col=fn.col,
            body_start=body_start_gen,
            origin_start=fn.body_line,
            params=params,
            filename=self.source.filename,
        )
        self.emit("", None)

    # -- handlers -----------------------------------------------------
    def _collect_handlers(self, nodes: Sequence[N.Node], _stack: List[str]) -> None:
        for node in nodes:
            if isinstance(node, N.Component):
                for attr in node.attrs.values():
                    if attr.handler is not None:
                        self._compile_handler(attr.handler)
                self._collect_handlers(node.children, _stack)
            elif isinstance(node, N.For):
                self._collect_handlers(node.children, _stack)
            elif isinstance(node, N.If):
                self._collect_handlers(node.children, _stack)
                self._collect_handlers(node.orelse, _stack)

    def _compile_handler(self, handler: N.Handler) -> None:
        func_name = f"_weave_h{self._handler_count}"
        self._handler_count += 1
        handler.func_name = func_name
        captures = tuple(handler.captures)
        body, _, _ = self._compile_body(
            handler.body,
            origin_start=handler.body_line,
            captures=captures,
            extra_bound=(),
            context="event handler",
            line=handler.line,
            col=handler.col,
        )
        signature = f"def {func_name}(ctx{''.join(', ' + name for name in captures)}):"
        self.emit(signature)
        self._emit_prelude(set(captures), handler.body_line)
        body_start_gen = self.next_line
        for offset, line in enumerate(body.split("\n")):
            self.emit("    " + line, origin=handler.body_line + offset)
        if not body.strip():
            self.emit("    pass", origin=handler.body_line)
        self.handler_meta[func_name] = HandlerMeta(
            func_name=func_name,
            node=handler,
            line=handler.line,
            col=handler.col,
            body_start=body_start_gen,
            origin_start=handler.body_line,
            captures=captures,
            filename=self.source.filename,
        )
        self.handler_nodes.append(handler)
        self.emit("", None)

    # -- body compilation ---------------------------------------------
    def _compile_body(
        self,
        body: str,
        *,
        origin_start: int,
        captures: Sequence[str],
        extra_bound: Sequence[str],
        context: str,
        line: int,
        col: int,
    ) -> Tuple[str, int, Set[str]]:
        body = body.strip("\n")
        if not body.strip():
            return "", 0, set()
        try:
            tree = ast.parse(body, filename=self.source.filename)
        except SyntaxError as exc:
            err_line = origin_start + (exc.lineno or 1) - 1
            raise WeaveCompileError(
                f"invalid Python in {context}: {exc.msg}",
                line=err_line,
                col=exc.offset or col,
                hint=(exc.text or "").strip(),
                filename=self.source.filename,
            ) from None

        params = set(captures) | set(extra_bound)
        rewriter = StateRewriter(self.state_names, self.function_names, bound=params)
        try:
            tree = rewriter.visit(tree)
            ast.fix_missing_locations(tree)
            text = ast.unparse(tree)
        except Exception as exc:  # pragma: no cover - defensive
            raise WeaveCompileError(
                f"could not compile {context}: {exc}",
                line=line,
                col=col,
                filename=self.source.filename,
            ) from None
        return text, origin_start, params


def generate(app: N.App, source: Source) -> GeneratedCode:
    return CodeGen(app, source).generate()
