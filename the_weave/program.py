"""The compiled Weave program.

A :class:`Program` owns the parsed app, the generated Python functions, the
initial state, and the renderer.  It is immutable after compilation, so a
single instance can serve many sessions concurrently; each session simply
holds its own state dictionary.
"""

from __future__ import annotations

import copy
import functools
import json
import re
import traceback
from typing import Any, Dict, List, Optional, Sequence

from . import nodes as N
from .codegen import GeneratedCode, HandlerMeta
from .errors import WeaveCompileError, WeaveRuntimeError
from .renderer import RenderResult, Renderer
from .runtime import (
    HELPERS, MODULES, SAFE_BUILTINS, SAFE_SYMBOLS, Context, to_jsonable,
)
from .source import Source

_IDENT = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*$")

_STATE_TYPES = {
    "str": str,
    "string": str,
    "int": int,
    "integer": int,
    "float": float,
    "number": (int, float),
    "bool": bool,
    "boolean": bool,
    "list": list,
    "array": list,
    "dict": dict,
    "map": dict,
    "set": set,
    "any": object,
}


class Program:
    def __init__(self, app: N.App, source: Source, generated: GeneratedCode, namespace: Dict[str, Any]):
        self.app = app
        self.source = source
        self.generated = generated
        self.namespace = namespace
        self.filename = source.filename
        self.state_decls: List[N.StateDecl] = list(app.state)
        self.state_names: List[str] = [decl.name for decl in app.state]
        self.handlers: Dict[str, Any] = {name: namespace[name] for name in generated.handler_meta}
        self.handler_meta: Dict[str, HandlerMeta] = generated.handler_meta
        self.user_functions: Dict[str, Any] = {
            meta.name: namespace[meta.func_name] for meta in generated.function_meta.values()
        }
        self.renderer = Renderer(self)
        self._expr_cache: Dict[str, Any] = {}
        self.initial_state_template: Dict[str, Any] = self._build_initial_state()

    # ------------------------------------------------------------------
    # metadata
    # ------------------------------------------------------------------
    @property
    def name(self) -> str:
        return self.app.name

    @property
    def title(self) -> str:
        return self.app.title or _humanise(self.app.name)

    @property
    def routes(self) -> List[N.Route]:
        return self.app.routes

    def route_paths(self) -> List[str]:
        paths = [route.path for route in self.app.routes]
        if self.app.view and "/" not in paths:
            paths.insert(0, "/")
        return paths

    # ------------------------------------------------------------------
    # state
    # ------------------------------------------------------------------
    def _build_initial_state(self) -> Dict[str, Any]:
        ns: Dict[str, Any] = {"__builtins__": SAFE_BUILTINS}
        ns.update(SAFE_SYMBOLS)
        ns.update(MODULES)
        ns.update(HELPERS)
        state: Dict[str, Any] = {}
        for decl in self.state_decls:
            try:
                value = eval(compile(decl.value, self.filename, "eval"), ns)
            except Exception as exc:
                raise WeaveCompileError(
                    f"could not evaluate the initializer for '{decl.name}': {type(exc).__name__}: {exc}",
                    line=decl.line,
                    col=decl.col,
                    filename=self.filename,
                ) from None
            self._check_declared_type(decl, value)
            state[decl.name] = value
            ns[decl.name] = value
        return state

    def _check_declared_type(self, decl: N.StateDecl, value: Any) -> None:
        if not decl.type_name:
            return
        expected = _STATE_TYPES.get(decl.type_name)
        if expected is None:
            return
        if not isinstance(value, expected):
            raise WeaveCompileError(
                f"state '{decl.name}' is declared as {decl.type_name} but its initial value "
                f"is {type(value).__name__}",
                line=decl.line,
                col=decl.col,
                hint="fix the annotation or the initial value",
                filename=self.filename,
            )
        if decl.type_name in ("list", "array") and decl.type_args:
            inner = _STATE_TYPES.get(decl.type_args[0].name)
            if inner is not None:
                for item in value:
                    if not isinstance(item, inner):
                        raise WeaveCompileError(
                            f"state '{decl.name}' expects a list of {decl.type_args[0].name}, "
                            f"but contains {type(item).__name__}",
                            line=decl.line,
                            col=decl.col,
                            filename=self.filename,
                        )
                        break

    def new_state(self) -> Dict[str, Any]:
        return copy.deepcopy(self.initial_state_template)

    def coerce_binding(self, name: str, value: Any) -> Any:
        """Coerce a value coming from the browser to the state variable's type."""
        old = self.initial_state_template.get(name)
        if isinstance(old, bool):
            if isinstance(value, str):
                return value.strip().lower() in ("true", "on", "1", "yes")
            return bool(value)
        if isinstance(old, int) and not isinstance(old, bool):
            try:
                return int(float(value))
            except (TypeError, ValueError):
                return old
        if isinstance(old, float):
            try:
                return float(value)
            except (TypeError, ValueError):
                return old
        if isinstance(old, list):
            if isinstance(value, list):
                return value
            try:
                parsed = json.loads(str(value))
                if isinstance(parsed, list):
                    return parsed
            except (ValueError, TypeError):
                pass
            return old
        if isinstance(old, dict):
            if isinstance(value, dict):
                return value
            try:
                parsed = json.loads(str(value))
                if isinstance(parsed, dict):
                    return parsed
            except (ValueError, TypeError):
                pass
            return old
        return value

    # ------------------------------------------------------------------
    # execution
    # ------------------------------------------------------------------
    def make_namespace(self, ctx: Context, env: Optional[Dict[str, Any]] = None) -> Dict[str, Any]:
        ns: Dict[str, Any] = {"__builtins__": SAFE_BUILTINS}
        ns.update(SAFE_SYMBOLS)
        ns.update(MODULES)
        ns.update(HELPERS)
        ns.update(ctx.st)
        if env:
            ns.update(env)
        ns["state"] = ctx.st
        ns["ctx"] = ctx
        ns["print"] = ctx.log
        ns["log"] = ctx.log
        ns["toast"] = ctx.toast
        ns["navigate"] = ctx.navigate
        ns["emit"] = ctx.emit
        for name, fn in self.user_functions.items():
            ns[name] = functools.partial(fn, ctx)
        return ns

    def runtime_error(self, message: str, node, *, hint: str = "") -> WeaveRuntimeError:
        return WeaveRuntimeError(
            message,
            line=getattr(node, "line", 1),
            col=getattr(node, "col", 1),
            hint=hint,
            filename=self.filename,
        )

    def eval_expr(self, expr: str, ctx: Context, env: Dict[str, Any], node, *, bareword: bool = False) -> Any:
        expr = expr.strip()
        if not expr:
            return None
        try:
            code = self._expr_cache.get(expr)
            if code is None:
                code = compile(expr, f"<weave:{self.app.name}:expr>", "eval")
                self._expr_cache[expr] = code
        except SyntaxError as exc:
            raise self.runtime_error(f"invalid expression '{expr}': {exc.msg}", node) from None
        ns = self.make_namespace(ctx, env)
        if bareword and _IDENT.match(expr) and expr not in ns:
            return expr
        try:
            return eval(code, ns)
        except NameError as exc:
            if bareword and _IDENT.match(expr):
                return expr
            name = getattr(exc, "name", None) or str(exc)
            raise self.runtime_error(
                f"unknown name '{name}' while evaluating '{expr}'",
                node,
                hint="declare it in state: or check the spelling",
            ) from None
        except Exception as exc:
            raise self.runtime_error(
                f"{type(exc).__name__} while evaluating '{expr}': {exc}",
                node,
            ) from None

    def execute_handler(self, func_name: str, ctx: Context, captures: Dict[str, Any]) -> None:
        fn = self.handlers.get(func_name)
        meta = self.handler_meta.get(func_name)
        if fn is None:
            raise WeaveRuntimeError(f"unknown handler '{func_name}'", filename=self.filename)
        try:
            fn(ctx, **captures)
        except WeaveRuntimeError:
            raise
        except Exception as exc:
            raise self._translate_exception(exc, meta) from None

    def _translate_exception(self, exc: Exception, meta: Optional[HandlerMeta]) -> WeaveRuntimeError:
        line = meta.origin_start if meta else 1
        col = meta.col if meta else 1
        tb = exc.__traceback__
        generated_filename = f"<weave:{self.app.name}>"
        best = None
        while tb is not None:
            if tb.tb_frame.f_code.co_filename == generated_filename:
                best = tb
            tb = tb.tb_next
        if best is not None:
            origin = self.generated.origin_for_line(best.tb_lineno)
            if origin:
                line = origin
            elif meta is not None:
                line = meta.origin_start + max(0, best.tb_lineno - meta.body_start)
        message = f"{type(exc).__name__}: {exc}" if str(exc) else type(exc).__name__
        err = WeaveRuntimeError(
            message,
            line=line,
            col=col,
            hint=_snippet(self.source, line),
            filename=self.filename,
        )
        err.python_traceback = "".join(traceback.format_exception(type(exc), exc, exc.__traceback__))
        return err

    # ------------------------------------------------------------------
    # rendering / serialisation
    # ------------------------------------------------------------------
    def render(self, ctx: Context, path: str = "/") -> RenderResult:
        return self.renderer.render(ctx, path)

    def public_state(self, state: Dict[str, Any]) -> Dict[str, Any]:
        return to_jsonable(state)

    def describe(self) -> Dict[str, Any]:
        return {
            "name": self.app.name,
            "title": self.title,
            "state": self.state_names,
            "functions": [fn.name for fn in self.app.functions],
            "routes": self.route_paths(),
            "components": _count_components(self.app.view),
            "handlers": len(self.handler_meta),
            "lines": len(self.source.text.splitlines()),
        }


def _humanise(name: str) -> str:
    out = []
    for i, ch in enumerate(name):
        if ch.isupper() and i:
            out.append(" ")
        out.append(ch)
    return "".join(out).strip()


def _snippet(source: Source, line: int) -> str:
    text = source.line(line).strip()
    return text[:120]


def _count_components(nodes: Sequence[N.Node]) -> int:
    total = 0
    for node in nodes:
        if isinstance(node, N.Component):
            total += 1 + _count_components(node.children)
        elif isinstance(node, N.For):
            total += _count_components(node.children)
        elif isinstance(node, N.If):
            total += _count_components(node.children) + _count_components(node.orelse)
    return total
