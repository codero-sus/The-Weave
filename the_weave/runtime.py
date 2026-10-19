"""The Weave runtime.

Weave compiles its logic half into real Python and executes it inside a
sandboxed namespace.  This module supplies:

* :class:`Context` — the per-request execution context (state + effects)
* :data:`SYMBOLS`  — bareword design tokens (``sm``, ``center``, ``primary``…)
* :data:`SAFE_BUILTINS` / :data:`MODULES` — the whitelisted runtime surface
* small helpers such as ``now()``, ``slugify()`` and ``to_jsonable()``
"""

from __future__ import annotations

import base64
import builtins
import collections
import copy
import datetime as _datetime
import hashlib
import itertools
import json
import math
import random as _random
import re as _re
import statistics
import string
import time as _time
import uuid as _uuid
from typing import Any, Dict, List, Optional

# ---------------------------------------------------------------------------
# Design tokens: bare words usable in attribute values
# ---------------------------------------------------------------------------

SYMBOL_NAMES = [
    # sizes / spacing
    "xs", "sm", "md", "lg", "xl", "xxl", "full", "half", "third", "auto",
    "fit", "screen", "none",
    # alignment
    "start", "end", "center", "between", "around", "evenly", "stretch",
    "baseline", "left", "right", "top", "bottom", "middle",
    # direction / flow
    "row", "column", "wrap", "nowrap", "reverse",
    # palettes / emphasis
    "primary", "secondary", "accent", "muted", "danger", "success", "warning",
    "info", "ghost", "outline", "solid", "subtle", "transparent", "inherit",
    # misc
    "hidden", "visible", "cover", "contain", "thin", "thick", "dashed",
    "dotted", "round", "pill", "bold", "normal", "italic", "mono", "sans",
    "uppercase", "lowercase", "fast", "slow", "smooth",
]

SYMBOLS: Dict[str, str] = {name: name for name in SYMBOL_NAMES}


# ---------------------------------------------------------------------------
# Modules and helpers available to Weave code
# ---------------------------------------------------------------------------

class _Module:
    """A tiny import-free module wrapper so ``math.pi`` etc. work."""

    def __init__(self, name: str, **attrs: Any):
        self.__name__ = name
        self.__dict__.update(attrs)


MODULES: Dict[str, Any] = {
    "math": _Module("math", **{k: getattr(math, k) for k in dir(math) if not k.startswith("_")}),
    "json": _Module("json", dumps=json.dumps, loads=json.loads, dump=json.dumps),
    "datetime": _Module(
        "datetime",
        datetime=_datetime.datetime,
        date=_datetime.date,
        time=_datetime.time,
        timedelta=_datetime.timedelta,
        timezone=_datetime.timezone,
        now=_datetime.datetime.now,
        today=_datetime.date.today,
    ),
    "time": _Module("time", time=_time.time, sleep=_time.sleep),
    "random": _Module(
        "random",
        choice=_random.choice,
        choices=_random.choices,
        shuffle=_random.shuffle,
        randint=_random.randint,
        random=_random.random,
        sample=_random.sample,
        uniform=_random.uniform,
        seed=_random.seed,
    ),
    "re": _Module(
        "re",
        match=_re.match,
        search=_re.search,
        findall=_re.findall,
        sub=_re.sub,
        split=_re.split,
        compile=_re.compile,
        escape=_re.escape,
        IGNORECASE=_re.IGNORECASE,
    ),
    "itertools": _Module("itertools", count=itertools.count, chain=itertools.chain, groupby=itertools.groupby,
                         islice=itertools.islice, cycle=itertools.cycle, combinations=itertools.combinations,
                         permutations=itertools.permutations, product=itertools.product),
    "collections": _Module("collections", Counter=collections.Counter, defaultdict=collections.defaultdict,
                          OrderedDict=collections.OrderedDict, deque=collections.deque),
    "statistics": _Module("statistics", mean=statistics.mean, median=statistics.median,
                          mode=statistics.mode, stdev=statistics.stdev, variance=statistics.variance),
    "hashlib": _Module("hashlib", sha256=hashlib.sha256, md5=hashlib.md5, sha1=hashlib.sha1),
    "base64": _Module("base64", b64encode=base64.b64encode, b64decode=base64.b64decode),
    "string": _Module("string", ascii_letters=string.ascii_letters, ascii_lowercase=string.ascii_lowercase,
                      ascii_uppercase=string.ascii_uppercase, digits=string.digits, punctuation=string.punctuation),
}


def _now() -> _datetime.datetime:
    return _datetime.datetime.now()


def _today() -> _datetime.date:
    return _datetime.date.today()


def _uuid4() -> str:
    return str(_uuid.uuid4())


def _parse_date(value: Any, fmt: str = "%Y-%m-%d") -> Any:
    if isinstance(value, _datetime.date):
        return value
    return _datetime.datetime.strptime(str(value), fmt).date()


def _format_date(value: Any, fmt: str = "%b %d, %Y") -> str:
    if isinstance(value, (_datetime.date, _datetime.datetime)):
        return value.strftime(fmt)
    return _parse_date(value).strftime(fmt)


def _slugify(value: Any) -> str:
    text = _re.sub(r"[^\w\s-]", "", str(value).strip().lower())
    return _re.sub(r"[-\s]+", "-", text).strip("-")


def _clamp(value: float, low: float = 0, high: float = 1) -> float:
    return max(low, min(high, value))


def _truncate(value: Any, length: int = 80, suffix: str = "…") -> str:
    text = str(value)
    return text if len(text) <= length else text[: max(0, length - len(suffix))] + suffix


def _plural(count: Any, singular: str, plural: Optional[str] = None) -> str:
    try:
        n = float(count)
    except (TypeError, ValueError):
        n = 0
    word = singular if n == 1 else (plural or singular + "s")
    return f"{count} {word}"


def _group_by(items: Any, key: Any) -> Dict[str, List[Any]]:
    key_fn = key if callable(key) else (lambda item: item.get(key) if isinstance(item, dict) else getattr(item, key))
    out: Dict[str, List[Any]] = {}
    for item in items:
        out.setdefault(str(key_fn(item)), []).append(item)
    return out


HELPERS: Dict[str, Any] = {
    "now": _now,
    "today": _today,
    "uuid": _uuid4,
    "parse_date": _parse_date,
    "format_date": _format_date,
    "slugify": _slugify,
    "clamp": _clamp,
    "truncate": _truncate,
    "plural": _plural,
    "group_by": _group_by,
    "lower": lambda s: str(s).lower(),
    "upper": lambda s: str(s).upper(),
    "capitalize": lambda s: str(s).capitalize(),
    "title": lambda s: str(s).title(),
    "strip": lambda s: str(s).strip(),
    "replace": lambda s, a, b: str(s).replace(a, b),
    "join": lambda items, sep=", ": sep.join(str(i) for i in items),
    "keys": lambda d: list(d.keys()) if hasattr(d, "keys") else [],
    "values": lambda d: list(d.values()) if hasattr(d, "values") else [],
    "items": lambda d: list(d.items()) if hasattr(d, "items") else [],
    "is_empty": lambda v: not v,
    "default": lambda value, fallback: fallback if value is None or value == "" else value,
}

_SAFE_BUILTIN_NAMES = [
    "abs", "all", "any", "ascii", "bin", "bool", "bytearray", "bytes", "callable",
    "chr", "complex", "dict", "divmod", "enumerate", "filter", "float", "format",
    "frozenset", "getattr", "hasattr", "hash", "hex", "int", "isinstance", "iter",
    "len", "list", "map", "max", "min", "next", "oct", "ord", "pow", "range",
    "repr", "reversed", "round", "set", "slice", "sorted", "str", "sum", "tuple",
    "type", "zip", "Exception", "ValueError", "TypeError", "KeyError",
    "IndexError", "AttributeError", "StopIteration", "RuntimeError", "ZeroDivisionError",
    "NotImplementedError", "AssertionError",
]

SAFE_BUILTINS: Dict[str, Any] = {name: getattr(builtins, name) for name in _SAFE_BUILTIN_NAMES if hasattr(builtins, name)}

#: Design tokens safe to inject into the execution namespace. Tokens that
#: would shadow a builtin, helper or module (``round``, ``items``…) are dropped;
#: the renderer's bareword fallback still resolves them in view attributes.
SAFE_SYMBOLS: Dict[str, str] = {
    name: value
    for name, value in SYMBOLS.items()
    if name not in SAFE_BUILTINS and name not in HELPERS and name not in MODULES
}

#: Names that count as "known" during semantic analysis.
KNOWN_NAMES = (
    set(SYMBOLS)
    | set(MODULES)
    | set(HELPERS)
    | set(SAFE_BUILTINS)
    | {
        "True", "False", "None", "self", "state", "ctx", "log", "toast",
        "navigate", "emit", "print", "len", "str",
    }
)


# ---------------------------------------------------------------------------
# Execution context
# ---------------------------------------------------------------------------

class Context:
    """Carries one unit of execution: the mutable state plus side effects."""

    def __init__(self, state: Dict[str, Any], *, session_id: str = "", path: str = "/"):
        self.st = state
        self.session_id = session_id
        self.path = path
        self.logs: List[str] = []
        self.toasts: List[Dict[str, str]] = []
        self.redirect: Optional[str] = None
        self.emitted: List[Dict[str, Any]] = []

    # -- effect API available to Weave code ---------------------------
    def log(self, *args: Any) -> None:
        self.logs.append(" ".join(str(a) for a in args))

    def toast(self, message: Any, kind: str = "info") -> None:
        self.toasts.append({"message": str(message), "kind": kind})

    def navigate(self, path: Any) -> None:
        self.redirect = str(path)

    def emit(self, name: Any, payload: Any = None) -> None:
        self.emitted.append({"name": str(name), "payload": payload})

    # -- state helpers -----------------------------------------------
    def get(self, name: str, default: Any = None) -> Any:
        return self.st.get(name, default)

    def set(self, name: str, value: Any) -> None:
        if name in self.st:
            self.st[name] = value

    def snapshot(self) -> Dict[str, Any]:
        return {k: copy.deepcopy(v) for k, v in self.st.items()}


# ---------------------------------------------------------------------------
# Serialisation for the browser
# ---------------------------------------------------------------------------

def to_jsonable(value: Any, _depth: int = 0) -> Any:
    """Best-effort conversion of arbitrary Python values into JSON data."""
    if _depth > 12:
        return str(value)
    if value is None or isinstance(value, (bool, int, float, str)):
        return value
    if isinstance(value, dict):
        return {str(k): to_jsonable(v, _depth + 1) for k, v in value.items()}
    if isinstance(value, (list, tuple, set, frozenset)):
        return [to_jsonable(v, _depth + 1) for v in value]
    if isinstance(value, (_datetime.datetime, _datetime.date, _datetime.time)):
        return value.isoformat()
    if hasattr(value, "__dict__"):
        return {k: to_jsonable(v, _depth + 1) for k, v in vars(value).items() if not k.startswith("_")}
    return str(value)


def from_json(value: Any) -> Any:
    return value
