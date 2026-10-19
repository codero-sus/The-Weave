"""Server-side rendering of Weave views.

The renderer walks the view AST, evaluates expressions against the current
state, and emits accessible HTML with inline design-system styles.  Every
DOM node gets a stable ``data-w`` path so the client runtime can map clicks
and keystrokes back to the exact handler (including loop captures) that
produced it.
"""

from __future__ import annotations

import html as _html
from dataclasses import dataclass, field
from typing import Any, Dict, List, Optional, Sequence, Tuple

from . import nodes as N
from .runtime import Context

# ---------------------------------------------------------------------------
# Data structures
# ---------------------------------------------------------------------------

@dataclass
class EventBinding:
    func_name: str
    captures: Dict[str, Any]
    line: int
    col: int


@dataclass
class RenderResult:
    html: str
    title: str
    path: str
    events: Dict[str, Dict[str, List[EventBinding]]] = field(default_factory=dict)
    bindings: Dict[str, str] = field(default_factory=dict)
    status: int = 200


#: Weave event attribute → DOM event name used by the client runtime.
EVENT_DOM = {
    "click": "click",
    "on_click": "click",
    "on_press": "click",
    "on_dblclick": "dblclick",
    "on_enter": "enter",
    "enter": "enter",
    "on_change": "change",
    "change": "change",
    "on_input": "input",
    "on_blur": "blur",
    "on_focus": "focus",
    "on_submit": "submit",
    "submit": "submit",
    "on_keydown": "keydown",
    "on_keyup": "keyup",
    "on_remove": "click",
    "on_toggle": "click",
    "on_select": "change",
    "on_open": "click",
    "on_close": "click",
}

SPACING = {"xs": 4, "sm": 8, "md": 12, "lg": 20, "xl": 32, "xxl": 48, "none": 0}
SIZE_WORDS = {
    "full": "100%",
    "half": "50%",
    "third": "33.3333%",
    "auto": "auto",
    "fit": "fit-content",
    "screen": "100vw",
    "min": "min-content",
    "max": "max-content",
}
RADIUS = {"none": "0", "xs": "4px", "sm": "8px", "md": "12px", "lg": "18px", "xl": "28px",
          "full": "999px", "pill": "999px", "round": "50%"}
SHADOWS = {
    "none": "none",
    "xs": "0 1px 2px rgba(15, 23, 42, .06)",
    "sm": "0 1px 2px rgba(15, 23, 42, .05), 0 2px 8px -2px rgba(15, 23, 42, .08)",
    "md": "0 4px 12px -2px rgba(15, 23, 42, .10), 0 2px 4px -2px rgba(15, 23, 42, .06)",
    "lg": "0 12px 32px -8px rgba(15, 23, 42, .18), 0 4px 8px -4px rgba(15, 23, 42, .06)",
    "xl": "0 24px 64px -16px rgba(15, 23, 42, .28)",
}
THEME_COLORS = {
    "primary", "secondary", "accent", "muted", "danger", "success", "warning",
    "info", "background", "surface", "text", "border", "primary_text", "subtle",
}
ALIGN_MAP = {
    "start": "flex-start", "end": "flex-end", "center": "center", "stretch": "stretch",
    "baseline": "baseline", "between": "space-between", "around": "space-around",
    "evenly": "space-evenly", "left": "left", "right": "right", "top": "top",
    "bottom": "bottom", "middle": "middle", "auto": "auto", "normal": "normal",
}


def esc(value: Any) -> str:
    return _html.escape(str(value), quote=True)


def _css_measure(value: Any) -> str:
    """Numbers are pixels; bare words pass through."""
    if isinstance(value, bool):
        return "1" if value else "0"
    if isinstance(value, (int, float)):
        return f"{value:g}px" if value else "0"
    text = str(value).strip()
    if text in SIZE_WORDS:
        return SIZE_WORDS[text]
    try:
        float(text)
        return f"{float(text):g}px"
    except ValueError:
        return text


def _spacing(value: Any) -> str:
    if isinstance(value, (int, float)) and not isinstance(value, bool):
        return f"{value:g}px" if value else "0"
    text = str(value).strip()
    if text in SPACING:
        return f"{SPACING[text]}px"
    parts = text.split()
    if len(parts) > 1:
        return " ".join(_spacing(p) for p in parts)
    return _css_measure(text)


def _font(value: Any) -> str:
    return _css_measure(value)


def _color(value: Any) -> str:
    text = str(value).strip()
    if text in THEME_COLORS:
        return f"var(--weave-{text})"
    return text


def _shadow(value: Any) -> str:
    text = str(value).strip()
    return SHADOWS.get(text, text)


def _radius(value: Any) -> str:
    text = str(value).strip()
    return RADIUS.get(text, _css_measure(text))


def _truthy(value: Any) -> bool:
    if isinstance(value, str):
        return value.strip().lower() not in ("", "false", "0", "no", "none", "null")
    return bool(value)


def _style_attr(style: Dict[str, str]) -> str:
    return "; ".join(f"{k}: {v}" for k, v in style.items() if v not in (None, ""))


# ---------------------------------------------------------------------------
# Renderer
# ---------------------------------------------------------------------------

class Renderer:
    def __init__(self, program):
        self.program = program
        self.app: N.App = program.app
        self.events: Dict[str, Dict[str, List[EventBinding]]] = {}
        self.bindings: Dict[str, str] = {}
        self._depth = 0

    # ------------------------------------------------------------------
    # entry point
    # ------------------------------------------------------------------
    def render(self, ctx: Context, path: str = "/") -> RenderResult:
        self.events = {}
        self.bindings = {}
        nodes, title, status = self._select_nodes(path)
        body = self.render_nodes(nodes, "r", ctx, {})
        return RenderResult(html=body, title=title, path=path, events=self.events,
                            bindings=self.bindings, status=status)

    def _select_nodes(self, path: str) -> Tuple[Sequence[N.Node], str, int]:
        default_title = self.app.title or self._humanise(self.app.name)
        if not self.app.routes:
            return self.app.view, default_title, 200
        for route in self.app.routes:
            if route.path == path:
                return route.body, route.title or default_title, 200
        if path == "/" and self.app.view:
            return self.app.view, default_title, 200
        not_found = [
            N.Component(
                name="stack",
                positional=[],
                attrs={
                    "padding": N.Attribute(name="padding", expr="48"),
                    "align": N.Attribute(name="align", expr="'center'"),
                    "gap": N.Attribute(name="gap", expr="12"),
                },
                children=[
                    N.Component(name="text", positional=["'404'"],
                                attrs={"font": N.Attribute(name="font", expr="56"),
                                       "bold": N.Attribute(name="bold", expr="True"),
                                       "muted": N.Attribute(name="muted", expr="True")}),
                    N.Component(name="text", positional=[repr(f"No page at {path}")]),
                ],
            )
        ]
        return not_found, "Not found", 404

    @staticmethod
    def _humanise(name: str) -> str:
        out = ""
        for i, ch in enumerate(name):
            if ch.isupper() and i:
                out += " "
            out += ch
        return out.strip()

    # ------------------------------------------------------------------
    # traversal
    # ------------------------------------------------------------------
    def render_nodes(self, nodes: Sequence[N.Node], parent_path: str, ctx: Context, env: Dict[str, Any]) -> str:
        parts: List[str] = []
        for index, node in enumerate(nodes):
            path = f"{parent_path}.{index}"
            if isinstance(node, N.Component):
                parts.append(self.render_component(node, path, ctx, env))
            elif isinstance(node, N.For):
                parts.append(self._render_for(node, path, ctx, env))
            elif isinstance(node, N.If):
                parts.append(self._render_if(node, path, ctx, env))
        return "".join(parts)

    def _render_for(self, node: N.For, path: str, ctx: Context, env: Dict[str, Any]) -> str:
        iterable = self.program.eval_expr(node.iterable, ctx, env, node)
        if iterable is None:
            iterable = []
        try:
            items = list(iterable)
        except TypeError:
            raise self.program.runtime_error(f"'{node.iterable}' is not iterable", node)
        parts: List[str] = []
        for index, item in enumerate(items):
            inner_env = dict(env)
            if node.index:
                inner_env[node.index] = index
                inner_env[node.target] = item
            else:
                inner_env[node.target] = item
            parts.append(self.render_nodes(node.children, f"{path}${index}", ctx, inner_env))
        return "".join(parts)

    def _render_if(self, node: N.If, path: str, ctx: Context, env: Dict[str, Any]) -> str:
        condition = self.program.eval_expr(node.condition, ctx, env, node)
        if _truthy(condition):
            return self.render_nodes(node.children, f"{path}t", ctx, env)
        if node.orelse:
            return self.render_nodes(node.orelse, f"{path}f", ctx, env)
        return ""

    # ------------------------------------------------------------------
    # attribute helpers
    # ------------------------------------------------------------------
    def _get(self, comp: N.Component, name: str, ctx: Context, env: Dict[str, Any], default: Any = None) -> Any:
        attr = comp.attrs.get(name)
        if attr is None:
            return default
        if attr.handler is not None:
            return default
        return self.program.eval_expr(attr.expr, ctx, env, attr, bareword=True)

    def _has(self, comp: N.Component, name: str) -> bool:
        return name in comp.attrs

    def _flag(self, comp: N.Component, name: str, ctx: Context, env: Dict[str, Any]) -> bool:
        return _truthy(self._get(comp, name, ctx, env, False))

    def _bind_var(self, comp: N.Component) -> Optional[str]:
        for key in ("bind", "bind_value"):
            attr = comp.attrs.get(key)
            if attr is not None:
                return attr.expr.strip()
        return None

    def _arg(self, comp: N.Component, index: int, ctx: Context, env: Dict[str, Any], default: Any = None) -> Any:
        if index >= len(comp.positional):
            return default
        return self.program.eval_expr(comp.positional[index], ctx, env, comp)

    # ------------------------------------------------------------------
    # element assembly
    # ------------------------------------------------------------------
    def _element(
        self,
        comp: N.Component,
        path: str,
        ctx: Context,
        env: Dict[str, Any],
        tag: str,
        *,
        inner: str = "",
        style: Optional[Dict[str, str]] = None,
        classes: Sequence[str] = (),
        extra: str = "",
        void: bool = False,
        data_attrs: Optional[Dict[str, str]] = None,
        register_events: bool = True,
    ) -> str:
        style = style if style is not None else {}
        class_list = list(classes)

        # ---- universal attributes -----------------------------------
        width = comp.attrs.get("width")
        if width is not None:
            style["width"] = _css_measure(self._get(comp, "width", ctx, env))
        height = comp.attrs.get("height")
        if height is not None:
            style["height"] = _css_measure(self._get(comp, "height", ctx, env))
        margin = comp.attrs.get("margin")
        if margin is not None:
            style["margin"] = _spacing(self._get(comp, "margin", ctx, env))
        padding = comp.attrs.get("padding")
        if padding is not None:
            style["padding"] = _spacing(self._get(comp, "padding", ctx, env))
        if self._has(comp, "align_self"):
            style["align-self"] = ALIGN_MAP.get(str(self._get(comp, "align_self", ctx, env)).strip(), "auto")
        if self._has(comp, "grow"):
            grow = self._get(comp, "grow", ctx, env)
            style["flex-grow"] = "1" if grow is True else str(grow if grow is not None else 1)
        if self._has(comp, "opacity"):
            style["opacity"] = str(self._get(comp, "opacity", ctx, env))
        if self._has(comp, "z"):
            style["z-index"] = str(self._get(comp, "z", ctx, env))
        if self._has(comp, "transition"):
            style["transition"] = str(self._get(comp, "transition", ctx, env))
        if self._has(comp, "animate"):
            class_list.append(f"weave-anim-{self._get(comp, 'animate', ctx, env)}")
        if self._has(comp, "visible") and not self._flag(comp, "visible", ctx, env):
            style["display"] = "none"
        if self._has(comp, "style"):
            raw_style = str(self._get(comp, "style", ctx, env)).strip()
            if raw_style in self.app.styles:
                style = {**style, **self._named_style(raw_style, ctx, env, comp)}
            elif raw_style:
                style = {**style, **self._parse_style(raw_style)}
        if self._has(comp, "class"):
            class_list.extend(str(self._get(comp, "class", ctx, env)).split())

        # ---- identity ----------------------------------------------
        attrs: List[str] = [f'data-w="{esc(path)}"']
        if self._has(comp, "id"):
            attrs.append(f'id="{esc(self._get(comp, "id", ctx, env))}"')
        if class_list:
            attrs.append(f'class="{esc(" ".join(dict.fromkeys(class_list)))}"')
        if self._has(comp, "tooltip"):
            attrs.append(f'title="{esc(self._get(comp, "tooltip", ctx, env))}"')

        # ---- events ------------------------------------------------
        markers: Dict[str, str] = {}
        if register_events:
            markers = self._register_events(comp, path, ctx, env)
        for dom_event, func_name in markers.items():
            attrs.append(f'data-weave-{dom_event}="{esc(func_name)}"')

        if data_attrs:
            for key, value in data_attrs.items():
                attrs.append(f'{key}="{esc(value)}"')

        if extra:
            attrs.append(extra.strip())

        css = _style_attr(style)
        if css:
            attrs.append(f'style="{esc(css)}"')

        attr_text = " ".join(a for a in attrs if a)
        if void:
            return f"<{tag} {attr_text}>"
        return f"<{tag} {attr_text}>{inner}</{tag}>"

    def _named_style(self, name: str, ctx: Context, env: Dict[str, Any], comp: N.Component) -> Dict[str, str]:
        props = self.app.styles.get(name, {})
        converted: Dict[str, str] = {}
        for prop, expr in props.items():
            try:
                value = self.program.eval_expr(expr, ctx, env, comp, bareword=True)
            except Exception:
                value = expr.strip("'\"")
            css_prop = prop.replace("_", "-")
            if css_prop in ("font", "font-size"):
                converted["font-size"] = _font(value)
            elif css_prop in ("padding", "margin", "gap"):
                converted[css_prop] = _spacing(value)
            elif css_prop in ("color", "background", "background-color", "border-color"):
                converted[css_prop] = _color(value)
            elif css_prop in ("radius", "border-radius"):
                converted["border-radius"] = _radius(value)
            elif css_prop == "shadow":
                converted["box-shadow"] = _shadow(value)
            elif isinstance(value, bool):
                converted[css_prop] = "1" if value else "0"
            else:
                converted[css_prop] = str(value)
        return converted

    @staticmethod
    def _parse_style(text: str) -> Dict[str, str]:
        out: Dict[str, str] = {}
        for chunk in text.split(";"):
            if ":" in chunk:
                key, value = chunk.split(":", 1)
                out[key.strip()] = value.strip()
        return out

    def _register_events(self, comp: N.Component, path: str, ctx: Context, env: Dict[str, Any]) -> Dict[str, str]:
        markers: Dict[str, str] = {}
        for attr in comp.attrs.values():
            if attr.handler is None:
                continue
            dom = EVENT_DOM.get(attr.name)
            if dom is None:
                continue
            captures = {name: env[name] for name in attr.handler.captures if name in env}
            binding = EventBinding(
                func_name=attr.handler.func_name,
                captures=captures,
                line=attr.handler.line,
                col=attr.handler.col,
            )
            self.events.setdefault(path, {}).setdefault(dom, []).append(binding)
            markers[dom] = attr.handler.func_name
        return markers

    # ------------------------------------------------------------------
    # shared style helpers
    # ------------------------------------------------------------------
    def _box(
        self,
        comp: N.Component,
        ctx: Context,
        env: Dict[str, Any],
        style: Dict[str, str],
        *,
        default_padding: Optional[str] = None,
        default_radius: Optional[str] = None,
        default_background: Optional[str] = None,
        default_shadow: Optional[str] = None,
    ) -> None:
        if self._has(comp, "background"):
            style["background"] = _color(self._get(comp, "background", ctx, env))
        elif default_background:
            style["background"] = default_background
        if self._has(comp, "radius"):
            style["border-radius"] = _radius(self._get(comp, "radius", ctx, env))
        elif default_radius:
            style["border-radius"] = default_radius
        if self._has(comp, "border"):
            border = self._get(comp, "border", ctx, env)
            if border is True:
                style["border"] = "1px solid var(--weave-border)"
            elif border not in (False, None):
                text = str(border)
                if text in ("solid", "dashed", "dotted"):
                    style["border"] = f"1px {text} var(--weave-border)"
                else:
                    style["border"] = text if " " in text else f"1px solid {_color(text)}"
        if self._has(comp, "shadow"):
            style["box-shadow"] = _shadow(self._get(comp, "shadow", ctx, env))
        elif default_shadow:
            style["box-shadow"] = default_shadow
        if self._has(comp, "gap"):
            style["gap"] = _spacing(self._get(comp, "gap", ctx, env))
        elif self._has(comp, "spacing"):
            style["gap"] = _spacing(self._get(comp, "spacing", ctx, env))

    def _text_style(self, comp: N.Component, ctx: Context, env: Dict[str, Any], style: Dict[str, str]) -> None:
        if self._has(comp, "font"):
            style["font-size"] = _font(self._get(comp, "font", ctx, env))
        if self._flag(comp, "bold", ctx, env):
            style["font-weight"] = "700"
        elif self._has(comp, "weight"):
            weight = self._get(comp, "weight", ctx, env)
            style["font-weight"] = "700" if weight is True else str(weight)
        if self._flag(comp, "italic", ctx, env):
            style["font-style"] = "italic"
        if self._has(comp, "color"):
            style["color"] = _color(self._get(comp, "color", ctx, env))
        elif self._flag(comp, "muted", ctx, env):
            style["color"] = "var(--weave-muted)"
        if self._has(comp, "align"):
            style["text-align"] = str(self._get(comp, "align", ctx, env))
        if self._flag(comp, "mono", ctx, env):
            style["font-family"] = "var(--weave-mono)"
        if self._has(comp, "font_family"):
            style["font-family"] = str(self._get(comp, "font_family", ctx, env))
        if self._has(comp, "line_height"):
            style["line-height"] = str(self._get(comp, "line_height", ctx, env))
        if self._has(comp, "letter_spacing"):
            style["letter-spacing"] = _css_measure(self._get(comp, "letter_spacing", ctx, env))
        if self._flag(comp, "uppercase", ctx, env):
            style["text-transform"] = "uppercase"
        if self._has(comp, "max_width"):
            style["max-width"] = _css_measure(self._get(comp, "max_width", ctx, env))
        if self._flag(comp, "truncate", ctx, env):
            style.update({"overflow": "hidden", "text-overflow": "ellipsis", "white-space": "nowrap"})
        if self._has(comp, "selectable") and not self._flag(comp, "selectable", ctx, env):
            style["user-select"] = "none"

    # ------------------------------------------------------------------
    # components
    # ------------------------------------------------------------------
    def render_component(self, comp: N.Component, path: str, ctx: Context, env: Dict[str, Any]) -> str:
        method = getattr(self, f"_c_{comp.name}", None)
        if method is None:  # pragma: no cover - registry/parser keep this in sync
            raise self.program.runtime_error(f"component '{comp.name}' has no renderer", comp)
        return method(comp, path, ctx, env)

    # -- layout -------------------------------------------------------
    def _c_stack(self, comp, path, ctx, env):
        style = {"display": "flex", "flex-direction": "column", "min-width": "0"}
        align = self._get(comp, "align", ctx, env, "stretch")
        style["align-items"] = ALIGN_MAP.get(str(align).strip(), "stretch")
        if self._has(comp, "justify"):
            justify = self._get(comp, "justify", ctx, env)
            style["justify-content"] = ALIGN_MAP.get(str(justify).strip(), str(justify))
        direction = self._get(comp, "direction", ctx, env)
        if direction:
            style["flex-direction"] = "row" if str(direction) == "row" else "column"
        self._box(comp, ctx, env, style)
        if self._has(comp, "max_width"):
            style["max-width"] = _css_measure(self._get(comp, "max_width", ctx, env))
        if self._has(comp, "min_width"):
            style["min-width"] = _css_measure(self._get(comp, "min_width", ctx, env))
        inner = self.render_nodes(comp.children, path, ctx, env)
        return self._element(comp, path, ctx, env, "div", inner=inner, style=style, classes=("weave-stack",))

    def _c_row(self, comp, path, ctx, env):
        style = {"display": "flex", "flex-direction": "row", "min-width": "0"}
        align = self._get(comp, "align", ctx, env, "center")
        style["align-items"] = ALIGN_MAP.get(str(align).strip(), "center")
        justify = self._get(comp, "justify", ctx, env)
        if justify:
            style["justify-content"] = ALIGN_MAP.get(str(justify).strip(), str(justify))
        if self._flag(comp, "wrap", ctx, env):
            style["flex-wrap"] = "wrap"
        self._box(comp, ctx, env, style)
        inner = self.render_nodes(comp.children, path, ctx, env)
        return self._element(comp, path, ctx, env, "div", inner=inner, style=style, classes=("weave-row",))

    def _c_grid(self, comp, path, ctx, env):
        style = {"display": "grid"}
        columns = self._get(comp, "columns", ctx, env)
        min_column = self._get(comp, "min_column", ctx, env)
        if min_column is not None:
            style["grid-template-columns"] = f"repeat(auto-fill, minmax({_css_measure(min_column)}, 1fr))"
        elif columns is not None:
            try:
                count = int(columns)
                style["grid-template-columns"] = f"repeat({count}, minmax(0, 1fr))"
            except (TypeError, ValueError):
                style["grid-template-columns"] = str(columns)
        else:
            style["grid-template-columns"] = "repeat(auto-fill, minmax(180px, 1fr))"
        gap = self._get(comp, "gap", ctx, env, 16)
        style["gap"] = _spacing(gap)
        self._box(comp, ctx, env, style)
        inner = self.render_nodes(comp.children, path, ctx, env)
        return self._element(comp, path, ctx, env, "div", inner=inner, style=style, classes=("weave-grid",))

    def _c_center(self, comp, path, ctx, env):
        style = {"display": "flex", "align-items": "center", "justify-content": "center",
                 "flex-direction": "column", "min-height": "100%"}
        self._box(comp, ctx, env, style)
        inner = self.render_nodes(comp.children, path, ctx, env)
        return self._element(comp, path, ctx, env, "div", inner=inner, style=style, classes=("weave-center",))

    def _c_card(self, comp, path, ctx, env):
        style = {"display": "flex", "flex-direction": "column"}
        self._box(comp, ctx, env, style, default_padding="20px", default_radius="14px",
                  default_background="var(--weave-surface)", default_shadow="0 1px 2px rgba(15,23,42,.05), 0 2px 8px -2px rgba(15,23,42,.08)")
        classes = ["weave-card"]
        if self._flag(comp, "hover", ctx, env) or self._has(comp, "click"):
            classes.append("weave-hover")
        if self._has(comp, "padding"):
            style["padding"] = _spacing(self._get(comp, "padding", ctx, env))
        if self._has(comp, "max_width"):
            style["max-width"] = _css_measure(self._get(comp, "max_width", ctx, env))
        inner = ""
        if self._has(comp, "title"):
            inner += f'<div class="weave-card-title">{esc(self._get(comp, "title", ctx, env))}</div>'
        inner += self.render_nodes(comp.children, path, ctx, env)
        return self._element(comp, path, ctx, env, "div", inner=inner, style=style, classes=classes)

    def _c_section(self, comp, path, ctx, env):
        style = {"display": "flex", "flex-direction": "column", "gap": "12px"}
        self._box(comp, ctx, env, style)
        if self._has(comp, "gap"):
            style["gap"] = _spacing(self._get(comp, "gap", ctx, env))
        inner = ""
        if self._has(comp, "title"):
            inner += f'<div class="weave-section-title">{esc(self._get(comp, "title", ctx, env))}</div>'
        inner += self.render_nodes(comp.children, path, ctx, env)
        return self._element(comp, path, ctx, env, "section", inner=inner, style=style, classes=("weave-section",))

    def _c_hero(self, comp, path, ctx, env):
        style = {
            "display": "flex", "flex-direction": "column", "gap": "12px",
            "padding": "44px 32px", "border-radius": "22px",
            "background": "linear-gradient(135deg, var(--weave-primary-soft), var(--weave-surface) 70%)",
            "border": "1px solid var(--weave-border)",
        }
        self._box(comp, ctx, env, style)
        inner = ""
        if self._has(comp, "title"):
            inner += f'<div class="weave-hero-title">{esc(self._get(comp, "title", ctx, env))}</div>'
        if self._has(comp, "subtitle"):
            inner += f'<div class="weave-hero-subtitle">{esc(self._get(comp, "subtitle", ctx, env))}</div>'
        inner += self.render_nodes(comp.children, path, ctx, env)
        return self._element(comp, path, ctx, env, "header", inner=inner, style=style, classes=("weave-hero",))

    def _c_scroll(self, comp, path, ctx, env):
        style = {"overflow-y": "auto", "display": "flex", "flex-direction": "column"}
        if self._has(comp, "max_height"):
            style["max-height"] = _css_measure(self._get(comp, "max_height", ctx, env))
        self._box(comp, ctx, env, style)
        inner = self.render_nodes(comp.children, path, ctx, env)
        return self._element(comp, path, ctx, env, "div", inner=inner, style=style, classes=("weave-scroll",))

    def _c_form(self, comp, path, ctx, env):
        style = {"display": "flex", "flex-direction": "column", "gap": "12px"}
        self._box(comp, ctx, env, style)
        inner = self.render_nodes(comp.children, path, ctx, env)
        extra = 'data-weave-form="1" novalidate'
        return self._element(comp, path, ctx, env, "form", inner=inner, style=style,
                             classes=("weave-form",), extra=extra)

    def _c_tabs(self, comp, path, ctx, env):
        bind = self._bind_var(comp)
        style = {"display": "flex", "gap": "4px", "padding": "4px",
                 "background": "var(--weave-subtle)", "border-radius": "12px", "flex-wrap": "wrap"}
        if self._flag(comp, "full", ctx, env):
            style["width"] = "100%"
        self._box(comp, ctx, env, style)
        selected = ctx.st.get(bind) if bind else None
        parts: List[str] = []
        for index, child in enumerate(comp.children):
            if not isinstance(child, N.Component) or child.name != "tab":
                continue
            label = self._arg(child, 0, ctx, env, "")
            active = str(selected) == str(label)
            inner = esc(label)
            if self._has(child, "icon"):
                inner = f'<span>{esc(self._get(child, "icon", ctx, env))}</span>' + inner
            if self._has(child, "count"):
                inner += f'<span class="weave-tab-count">{esc(self._get(child, "count", ctx, env))}</span>'
            classes = ["weave-tab", "weave-tab-active"] if active else ["weave-tab"]
            attrs = (
                f'type="button" data-weave-set="{esc(bind)}" '
                f'data-weave-set-value="{esc(label)}" role="tab" aria-selected="{str(active).lower()}"'
            )
            parts.append(f"<button class=\"{' '.join(classes)}\" {attrs}>{inner}</button>")
        return self._element(comp, path, ctx, env, "div", inner="".join(parts), style=style,
                             classes=("weave-tabs",), register_events=False)

    def _c_tab(self, comp, path, ctx, env):
        label = self._arg(comp, 0, ctx, env, "")
        return self._element(comp, path, ctx, env, "div", inner=esc(label), classes=("weave-tab",))

    def _c_divider(self, comp, path, ctx, env):
        style = {"border": "none", "border-top": "1px solid var(--weave-border)", "margin": "8px 0"}
        if self._has(comp, "color"):
            style["border-top-color"] = _color(self._get(comp, "color", ctx, env))
        return self._element(comp, path, ctx, env, "hr", style=style, void=True)

    def _c_spacer(self, comp, path, ctx, env):
        style = {"flex-grow": "1", "min-height": "8px"}
        if self._has(comp, "height"):
            style["height"] = _css_measure(self._get(comp, "height", ctx, env))
            style["min-height"] = style["height"]
        if self._has(comp, "width"):
            style["width"] = _css_measure(self._get(comp, "width", ctx, env))
            style["flex-grow"] = "0"
        return self._element(comp, path, ctx, env, "div", style=style, classes=("weave-spacer",))

    # -- content ------------------------------------------------------
    def _c_text(self, comp, path, ctx, env):
        style: Dict[str, str] = {}
        self._text_style(comp, ctx, env, style)
        self._box(comp, ctx, env, style)
        value = self._arg(comp, 0, ctx, env, "")
        inner = esc(value)
        return self._element(comp, path, ctx, env, "p", inner=inner, style=style, classes=("weave-text",))

    def _c_title(self, comp, path, ctx, env):
        style: Dict[str, str] = {"font-size": "30px", "font-weight": "750", "letter-spacing": "-0.02em"}
        self._text_style(comp, ctx, env, style)
        inner = esc(self._arg(comp, 0, ctx, env, ""))
        return self._element(comp, path, ctx, env, "h1", inner=inner, style=style, classes=("weave-title",))

    def _c_label(self, comp, path, ctx, env):
        style: Dict[str, str] = {"font-size": "13px", "font-weight": "600", "color": "var(--weave-muted)"}
        self._text_style(comp, ctx, env, style)
        inner = esc(self._arg(comp, 0, ctx, env, ""))
        return self._element(comp, path, ctx, env, "span", inner=inner, style=style, classes=("weave-label",))

    def _c_code(self, comp, path, ctx, env):
        style = {"font-family": "var(--weave-mono)", "font-size": "13px",
                 "background": "var(--weave-subtle)", "padding": "14px 16px",
                 "border-radius": "10px", "overflow-x": "auto"}
        self._box(comp, ctx, env, style)
        if self._flag(comp, "wrap", ctx, env):
            style["white-space"] = "pre-wrap"
            style["overflow-x"] = "hidden"
        inner = esc(self._arg(comp, 0, ctx, env, ""))
        return self._element(comp, path, ctx, env, "pre", inner=inner, style=style, classes=("weave-code",))

    def _variant_colors(self, variant: str) -> Tuple[str, str]:
        mapping = {
            "primary": ("var(--weave-primary-soft)", "var(--weave-primary)"),
            "secondary": ("var(--weave-subtle)", "var(--weave-text)"),
            "success": ("var(--weave-success-soft)", "var(--weave-success)"),
            "danger": ("var(--weave-danger-soft)", "var(--weave-danger)"),
            "warning": ("var(--weave-warning-soft)", "var(--weave-warning)"),
            "info": ("var(--weave-info-soft)", "var(--weave-info)"),
            "muted": ("var(--weave-subtle)", "var(--weave-muted)"),
        }
        return mapping.get(variant, ("var(--weave-subtle)", "var(--weave-muted)"))

    def _c_badge(self, comp, path, ctx, env):
        variant = str(self._get(comp, "variant", ctx, env, "primary"))
        background, color = self._variant_colors(variant)
        style = {"display": "inline-flex", "align-items": "center", "gap": "5px",
                 "padding": "3px 10px", "border-radius": "999px", "font-size": "12px",
                 "font-weight": "650", "background": background, "color": color}
        self._box(comp, ctx, env, style, default_radius="999px")
        if self._has(comp, "background"):
            style["background"] = _color(self._get(comp, "background", ctx, env))
        if self._has(comp, "color"):
            style["color"] = _color(self._get(comp, "color", ctx, env))
        inner = esc(self._arg(comp, 0, ctx, env, ""))
        return self._element(comp, path, ctx, env, "span", inner=inner, style=style, classes=("weave-badge",))

    def _c_link(self, comp, path, ctx, env):
        href = str(self._get(comp, "href", ctx, env, "#"))
        style: Dict[str, str] = {"color": "var(--weave-primary)", "text-decoration": "none",
                                 "font-weight": "600", "cursor": "pointer"}
        if self._flag(comp, "underline", ctx, env):
            style["text-decoration"] = "underline"
        if self._flag(comp, "bold", ctx, env):
            style["font-weight"] = "700"
        if self._has(comp, "size"):
            style["font-size"] = _font(self._get(comp, "size", ctx, env))
        if self._has(comp, "color"):
            style["color"] = _color(self._get(comp, "color", ctx, env))
        extra = f'href="{esc(href)}"'
        if self._flag(comp, "external", ctx, env) or href.startswith(("http://", "https://", "mailto:")):
            extra += ' target="_blank" rel="noopener noreferrer"'
        elif href.startswith("/"):
            extra += f' data-weave-nav="{esc(href)}"'
        inner = esc(self._arg(comp, 0, ctx, env, ""))
        return self._element(comp, path, ctx, env, "a", inner=inner, style=style, extra=extra, classes=("weave-link",))

    @staticmethod
    def _asset_src(src: Any) -> str:
        """Map local relative paths onto the app's asset route."""
        text = str(src)
        if not text or text.startswith(("http://", "https://", "data:", "/", "//", "#", "blob:")):
            return text
        return "/assets/" + text.lstrip("./")

    def _c_image(self, comp, path, ctx, env):
        src = self._asset_src(self._arg(comp, 0, ctx, env, ""))
        style: Dict[str, str] = {"display": "block", "object-fit": "cover"}
        if self._has(comp, "radius"):
            style["border-radius"] = _radius(self._get(comp, "radius", ctx, env))
        else:
            style["border-radius"] = "10px"
        if self._has(comp, "shadow"):
            style["box-shadow"] = _shadow(self._get(comp, "shadow", ctx, env))
        if self._has(comp, "fit"):
            style["object-fit"] = str(self._get(comp, "fit", ctx, env))
        if self._has(comp, "border"):
            style["border"] = "1px solid var(--weave-border)"
        extra = f'src="{esc(src)}" alt="{esc(self._get(comp, "alt", ctx, env, ""))}" loading="lazy"'
        classes = ["weave-image"]
        if self._flag(comp, "zoom", ctx, env):
            classes.append("weave-zoom")
        return self._element(comp, path, ctx, env, "img", style=style, extra=extra, classes=classes, void=True)

    def _c_avatar(self, comp, path, ctx, env):
        src = self._asset_src(self._arg(comp, 0, ctx, env, ""))
        size = _css_measure(self._get(comp, "size", ctx, env, 40))
        style = {"width": size, "height": size, "border-radius": "50%", "object-fit": "cover"}
        if self._has(comp, "border"):
            style["border"] = "2px solid var(--weave-surface)"
            style["box-shadow"] = "0 0 0 1px var(--weave-border)"
        extra = f'src="{esc(src)}" alt="{esc(self._get(comp, "alt", ctx, env, ""))}"'
        return self._element(comp, path, ctx, env, "img", style=style, extra=extra, classes=("weave-avatar",), void=True)

    def _c_icon(self, comp, path, ctx, env):
        style = {"display": "inline-flex", "align-items": "center", "justify-content": "center",
                 "font-size": _font(self._get(comp, "size", ctx, env, 18)), "line-height": "1"}
        if self._has(comp, "color"):
            style["color"] = _color(self._get(comp, "color", ctx, env))
        if self._has(comp, "background"):
            style["background"] = _color(self._get(comp, "background", ctx, env))
            style["padding"] = _spacing(self._get(comp, "padding", ctx, env, 8))
            style["border-radius"] = _radius(self._get(comp, "radius", ctx, env, "full"))
        inner = esc(self._arg(comp, 0, ctx, env, ""))
        return self._element(comp, path, ctx, env, "span", inner=inner, style=style, classes=("weave-icon",))

    def _c_metric(self, comp, path, ctx, env):
        value = self._arg(comp, 0, ctx, env, "")
        label = self._arg(comp, 1, ctx, env, self._get(comp, "label", ctx, env, ""))
        style = {"display": "flex", "flex-direction": "column", "gap": "4px",
                 "padding": "16px 18px", "border-radius": "14px",
                 "background": "var(--weave-surface)", "border": "1px solid var(--weave-border)"}
        self._box(comp, ctx, env, style, default_radius="14px")
        value_color = "var(--weave-text)"
        if self._has(comp, "color"):
            value_color = _color(self._get(comp, "color", ctx, env))
        icon = ""
        if self._has(comp, "icon"):
            icon = f'<span class="weave-metric-icon">{esc(self._get(comp, "icon", ctx, env))}</span>'
        inner = (
            f'{icon}<div class="weave-metric-value" style="color:{esc(value_color)}">{esc(value)}</div>'
            f'<div class="weave-metric-label">{esc(label)}</div>'
        )
        return self._element(comp, path, ctx, env, "div", inner=inner, style=style, classes=("weave-metric",))

    def _c_progress(self, comp, path, ctx, env):
        value = self._arg(comp, 0, ctx, env, 0)
        if len(comp.positional) >= 2:
            total = self._arg(comp, 1, ctx, env, 1)
        else:
            total = self._get(comp, "max", ctx, env, 1)
        try:
            ratio = float(value) / float(total) if float(total) else 0.0
        except (TypeError, ValueError):
            ratio = 0.0
        ratio = max(0.0, min(1.0, ratio))
        color = _color(self._get(comp, "color", ctx, env, "primary"))
        track_color = _color(self._get(comp, "background", ctx, env, "subtle"))
        height = _css_measure(self._get(comp, "height", ctx, env, 8))
        radius = _radius(self._get(comp, "radius", ctx, env, "full"))
        bar = (
            f'<div class="weave-progress-bar" style="width:{ratio * 100:.2f}%;'
            f'background:{esc(color)};height:100%;border-radius:{esc(radius)};'
            'transition:width .28s cubic-bezier(.4,0,.2,1)"></div>'
        )
        track = (
            f'<div class="weave-progress-track" style="height:{esc(height)};'
            f'background:{esc(track_color)};border-radius:{esc(radius)};'
            f'overflow:hidden;width:100%">{bar}</div>'
        )
        label = self._get(comp, "label", ctx, env)
        if self._flag(comp, "show_value", ctx, env):
            label = f"{ratio * 100:.0f}%"
        inner = f'<div class="weave-progress-label">{esc(label)}</div>{track}' if label else track
        outer_style = {"display": "flex", "flex-direction": "column", "gap": "6px", "width": "100%"}
        self._box(comp, ctx, env, outer_style)
        return self._element(comp, path, ctx, env, "div", inner=inner, style=outer_style,
                             classes=("weave-progress",))

    # -- forms --------------------------------------------------------
    def _input_attrs(self, comp, ctx, env) -> List[str]:
        attrs: List[str] = []
        bind = self._bind_var(comp)
        placeholder = self._get(comp, "placeholder", ctx, env)
        if placeholder is not None:
            attrs.append(f'placeholder="{esc(placeholder)}"')
        if bind is not None:
            value = ctx.st.get(bind)
            attrs.append(f'value="{esc("" if value is None else value)}"')
        elif self._has(comp, "value"):
            attrs.append(f'value="{esc(self._get(comp, "value", ctx, env))}"')
        if self._has(comp, "name"):
            attrs.append(f'name="{esc(self._get(comp, "name", ctx, env))}"')
        if self._flag(comp, "disabled", ctx, env):
            attrs.append("disabled")
        if self._flag(comp, "required", ctx, env):
            attrs.append("required")
        if self._flag(comp, "autofocus", ctx, env):
            attrs.append("autofocus")
        if self._has(comp, "autocomplete"):
            attrs.append(f'autocomplete="{esc(self._get(comp, "autocomplete", ctx, env))}"')
        if self._has(comp, "min"):
            attrs.append(f'min="{esc(self._get(comp, "min", ctx, env))}"')
        if self._has(comp, "max"):
            attrs.append(f'max="{esc(self._get(comp, "max", ctx, env))}"')
        if self._has(comp, "step"):
            attrs.append(f'step="{esc(self._get(comp, "step", ctx, env))}"')
        return attrs

    def _input_core(self, comp, path, ctx, env, input_type: str, tag: str = "input", extra_style: Optional[Dict[str, str]] = None,
                    inner: str = "", rows: Optional[int] = None) -> str:
        style = {"width": "100%", "box-sizing": "border-box", "padding": "11px 14px",
                 "font-size": "14px", "font-family": "inherit", "color": "var(--weave-text)",
                 "background": "var(--weave-surface)", "border": "1px solid var(--weave-border)",
                 "border-radius": "10px", "outline": "none", "transition": "border-color .15s, box-shadow .15s"}
        if extra_style:
            style.update(extra_style)
        if self._flag(comp, "mono", ctx, env):
            style["font-family"] = "var(--weave-mono)"
        attrs = self._input_attrs(comp, ctx, env)
        if tag == "input":
            attrs.append(f'type="{esc(input_type)}"')
        if rows is not None:
            attrs.append(f'rows="{rows}"')
        if self._has(comp, "error"):
            style["border-color"] = "var(--weave-danger)"
        attrs.append(f'style="{esc(_style_attr(style))}"')
        attrs.append("spellcheck=\"false\"" if input_type in ("email", "url", "password") else "autocapitalize=\"off\"")
        # events live on the inner control; the path is on the wrapper
        for attr in comp.attrs.values():
            if attr.handler is not None:
                dom = EVENT_DOM.get(attr.name)
                if dom in ("enter", "change", "input", "blur", "focus"):
                    attrs.append(f'data-weave-{dom}="1"')
        bind = self._bind_var(comp)
        if bind is not None:
            attrs.append(f'data-weave-bind="{esc(bind)}"')
            self.bindings[path] = bind
        element = f"<{tag} {' '.join(attrs)}>{inner}</{tag}>" if tag != "input" else f"<input {' '.join(attrs)}>"
        label = self._get(comp, "label", ctx, env)
        error = self._get(comp, "error", ctx, env)
        help_text = self._get(comp, "help", ctx, env)
        wrapper_children = ""
        if label:
            wrapper_children += f'<label class="weave-field-label">{esc(label)}</label>'
        icon = self._get(comp, "icon", ctx, env)
        if icon:
            wrapper_children += f'<div class="weave-field-row"><span class="weave-field-icon">{esc(icon)}</span>{element}</div>'
        else:
            wrapper_children += element
        if error:
            wrapper_children += f'<div class="weave-field-error">{esc(error)}</div>'
        elif help_text:
            wrapper_children += f'<div class="weave-field-help">{esc(help_text)}</div>'
        wrapper_style = {"display": "flex", "flex-direction": "column", "gap": "6px", "width": "100%"}
        self._box(comp, ctx, env, wrapper_style)
        if icon:
            wrapper_style["gap"] = "6px"
        return self._element(comp, path, ctx, env, "div", inner=wrapper_children,
                             style=wrapper_style, classes=("weave-field",))

    def _c_input(self, comp, path, ctx, env):
        input_type = str(self._get(comp, "type", ctx, env, "text"))
        if input_type not in {
            "text", "email", "password", "number", "tel", "url", "search", "date",
            "time", "datetime-local", "color", "file", "month", "week",
        }:
            input_type = "text"
        return self._input_core(comp, path, ctx, env, input_type)

    def _c_textarea(self, comp, path, ctx, env):
        rows = self._get(comp, "rows", ctx, env, 4)
        bind = self._bind_var(comp)
        value = esc(ctx.st.get(bind, "")) if bind else esc(self._get(comp, "value", ctx, env, ""))
        style = {"resize": "vertical", "min-height": "96px", "line-height": "1.5"}
        return self._input_core(comp, path, ctx, env, "text", tag="textarea", extra_style=style,
                                inner=value, rows=int(rows) if str(rows).isdigit() else 4)

    def _c_checkbox(self, comp, path, ctx, env):
        bind = self._bind_var(comp)
        checked = _truthy(ctx.st.get(bind)) if bind else self._flag(comp, "value", ctx, env)
        label = self._get(comp, "label", ctx, env, self._get(comp, "placeholder", ctx, env, ""))
        disabled = " disabled" if self._flag(comp, "disabled", ctx, env) else ""
        attrs = f'type="checkbox"{" checked" if checked else ""}{disabled}'
        if bind:
            attrs += f' data-weave-bind="{esc(bind)}"'
            self.bindings[path] = bind
        for attr in comp.attrs.values():
            if attr.handler is not None and EVENT_DOM.get(attr.name) in ("change", "input", "click"):
                attrs += f' data-weave-{EVENT_DOM[attr.name]}="1"'
        inner = f'<input class="weave-checkbox-input" {attrs}><span>{esc(label)}</span>'
        style = {"display": "inline-flex", "align-items": "center", "gap": "9px", "cursor": "pointer"}
        self._box(comp, ctx, env, style)
        return self._element(comp, path, ctx, env, "label", inner=inner, style=style, classes=("weave-checkbox",))

    def _c_toggle(self, comp, path, ctx, env):
        bind = self._bind_var(comp)
        checked = _truthy(ctx.st.get(bind)) if bind else self._flag(comp, "value", ctx, env)
        label = self._get(comp, "label", ctx, env, "")
        disabled = " disabled" if self._flag(comp, "disabled", ctx, env) else ""
        attrs = f'type="checkbox"{" checked" if checked else ""}{disabled}'
        if bind:
            attrs += f' data-weave-bind="{esc(bind)}"'
            self.bindings[path] = bind
        for attr in comp.attrs.values():
            if attr.handler is not None and EVENT_DOM.get(attr.name) in ("change", "input", "click"):
                attrs += f' data-weave-{EVENT_DOM[attr.name]}="1"'
        inner = f'<input class="weave-toggle-input" {attrs}><span class="weave-toggle-track"></span>'
        if label:
            inner += f'<span class="weave-toggle-label">{esc(label)}</span>'
        style = {"display": "inline-flex", "align-items": "center", "gap": "10px", "cursor": "pointer"}
        self._box(comp, ctx, env, style)
        return self._element(comp, path, ctx, env, "label", inner=inner, style=style, classes=("weave-toggle",))

    def _c_select(self, comp, path, ctx, env):
        bind = self._bind_var(comp)
        options = self._get(comp, "options", ctx, env, [])
        current = ctx.st.get(bind) if bind else self._get(comp, "value", ctx, env)
        placeholder = self._get(comp, "placeholder", ctx, env)
        option_html: List[str] = []
        if placeholder:
            selected = " selected" if current in (None, "") else ""
            option_html.append(f'<option value="" disabled{selected}>{esc(placeholder)}</option>')
        if isinstance(options, dict):
            pairs = [(k, v) for k, v in options.items()]
        else:
            pairs = []
            for item in options or []:
                if isinstance(item, dict):
                    value = item.get("value", item.get("id", item.get("label", "")))
                    label = item.get("label", item.get("name", value))
                    pairs.append((value, label))
                elif isinstance(item, (tuple, list)) and len(item) >= 2:
                    pairs.append((item[0], item[1]))
                else:
                    pairs.append((item, item))
        for value, label in pairs:
            selected = " selected" if str(value) == str(current) else ""
            option_html.append(f'<option value="{esc(value)}"{selected}>{esc(label)}</option>')
        attrs = ['class="weave-select-input"']
        if self._flag(comp, "disabled", ctx, env):
            attrs.append("disabled")
        if self._flag(comp, "required", ctx, env):
            attrs.append("required")
        if bind:
            attrs.append(f'data-weave-bind="{esc(bind)}"')
            self.bindings[path] = bind
        for attr in comp.attrs.values():
            if attr.handler is not None and EVENT_DOM.get(attr.name) in ("change", "input"):
                attrs.append(f'data-weave-{EVENT_DOM[attr.name]}="1"')
        select = f'<select {" ".join(attrs)}>{"".join(option_html)}</select>'
        label = self._get(comp, "label", ctx, env)
        inner = ""
        if label:
            inner += f'<label class="weave-field-label">{esc(label)}</label>'
        inner += select
        style = {"display": "flex", "flex-direction": "column", "gap": "6px", "width": "100%"}
        self._box(comp, ctx, env, style)
        return self._element(comp, path, ctx, env, "div", inner=inner, style=style, classes=("weave-field",))

    def _c_slider(self, comp, path, ctx, env):
        bind = self._bind_var(comp)
        value = ctx.st.get(bind) if bind else self._get(comp, "value", ctx, env, 0)
        minimum = self._get(comp, "min", ctx, env, 0)
        maximum = self._get(comp, "max", ctx, env, 100)
        step = self._get(comp, "step", ctx, env, 1)
        attrs = ['type="range"', f'value="{esc(value)}"', f'min="{esc(minimum)}"',
                 f'max="{esc(maximum)}"', f'step="{esc(step)}"', 'class="weave-slider-input"']
        if bind:
            attrs.append(f'data-weave-bind="{esc(bind)}"')
            self.bindings[path] = bind
        for attr in comp.attrs.values():
            if attr.handler is not None and EVENT_DOM.get(attr.name) in ("change", "input"):
                attrs.append(f'data-weave-{EVENT_DOM[attr.name]}="1"')
        label = self._get(comp, "label", ctx, env)
        inner = ""
        if label:
            inner += f'<label class="weave-field-label">{esc(label)}</label>'
        inner += f'<div class="weave-slider-row"><input {" ".join(attrs)}><span class="weave-slider-value">{esc(value)}</span></div>'
        style = {"display": "flex", "flex-direction": "column", "gap": "6px", "width": "100%"}
        self._box(comp, ctx, env, style)
        return self._element(comp, path, ctx, env, "div", inner=inner, style=style, classes=("weave-field",))

    def _button_classes(self, comp, ctx, env) -> Tuple[List[str], Dict[str, str]]:
        variant = str(self._get(comp, "variant", ctx, env, "primary"))
        size = str(self._get(comp, "size", ctx, env, "md"))
        classes = ["weave-btn", f"weave-btn-{variant}", f"weave-btn-{size}"]
        style: Dict[str, str] = {}
        if self._flag(comp, "full", ctx, env):
            style["width"] = "100%"
        if self._has(comp, "color"):
            style["background"] = _color(self._get(comp, "color", ctx, env))
            style["color"] = "#fff"
            classes.append("weave-btn-solid")
        return classes, style

    def _c_button(self, comp, path, ctx, env):
        label = self._arg(comp, 0, ctx, env, "")
        classes, style = self._button_classes(comp, ctx, env)
        disabled = self._flag(comp, "disabled", ctx, env)
        if disabled:
            classes.append("weave-btn-disabled")
        icon = self._get(comp, "icon", ctx, env)
        icon_right = self._get(comp, "icon_right", ctx, env)
        inner = ""
        if icon:
            inner += f'<span class="weave-btn-icon">{esc(icon)}</span>'
        inner += f"<span>{esc(label)}</span>"
        if icon_right:
            inner += f'<span class="weave-btn-icon">{esc(icon_right)}</span>'
        href = self._get(comp, "href", ctx, env)
        button_type = str(self._get(comp, "type", ctx, env, "button"))
        if self._flag(comp, "submit", ctx, env):
            button_type = "submit"
        if href is not None:
            extra = f'href="{esc(href)}"'
            if str(href).startswith("/"):
                extra += f' data-weave-nav="{esc(href)}"'
            if disabled:
                extra += ' aria-disabled="true" tabindex="-1"'
            style["text-decoration"] = "none"
            classes.append("weave-btn-anchor")
            if str(self._get(comp, "variant", ctx, env, "primary")) == "link":
                classes.append("weave-btn-link")
            return self._element(comp, path, ctx, env, "a", inner=inner, style=style, classes=classes, extra=extra)
        extra = f'type="{esc(button_type)}"'
        if disabled:
            extra += " disabled"
        return self._element(comp, path, ctx, env, "button", inner=inner, style=style, classes=classes, extra=extra)

    def _c_icon_button(self, comp, path, ctx, env):
        icon = self._arg(comp, 0, ctx, env, "")
        classes, style = self._button_classes(comp, ctx, env)
        classes.append("weave-btn-square")
        disabled = self._flag(comp, "disabled", ctx, env)
        if disabled:
            classes.append("weave-btn-disabled")
        extra = f'type="{esc(str(self._get(comp, "type", ctx, env, "button")))}" aria-label="{esc(icon)}"'
        if disabled:
            extra += " disabled"
        return self._element(comp, path, ctx, env, "button", inner=f"<span>{esc(icon)}</span>",
                             style=style, classes=classes, extra=extra)

    # -- data ---------------------------------------------------------
    def _c_table(self, comp, path, ctx, env):
        rows = self._arg(comp, 0, ctx, env, []) or []
        columns = self._get(comp, "columns", ctx, env)
        columns = list(columns) if columns else None
        if not columns:
            if rows and isinstance(rows[0], dict):
                columns = list(rows[0].keys())
            elif rows:
                columns = [str(i) for i in range(len(rows[0]))]
            else:
                columns = []
        if self._flag(comp, "header", ctx, env) or columns:
            header = "".join(f"<th>{esc(c.replace('_', ' ').title() if isinstance(c, str) else c)}</th>" for c in columns)
            head_html = f"<thead><tr>{header}</tr></thead>"
        else:
            head_html = ""
        body_rows = []
        for row in rows:
            cells = []
            values = row.values() if isinstance(row, dict) else row
            if isinstance(row, dict):
                values = [row.get(c) for c in columns]
            for value in values:
                if isinstance(value, bool):
                    rendered = "✓" if value else "—"
                elif value is None:
                    rendered = "—"
                else:
                    rendered = esc(value)
                cells.append(f"<td>{rendered}</td>")
            body_rows.append(f"<tr>{''.join(cells)}</tr>")
        classes = ["weave-table"]
        if self._flag(comp, "striped", ctx, env):
            classes.append("weave-table-striped")
        if self._flag(comp, "hover", ctx, env):
            classes.append("weave-table-hover")
        if self._flag(comp, "compact", ctx, env):
            classes.append("weave-table-compact")
        inner = f"{head_html}<tbody>{''.join(body_rows)}</tbody>"
        style: Dict[str, str] = {"border-collapse": "collapse", "width": "100%"}
        self._box(comp, ctx, env, style, default_radius="12px")
        return self._element(comp, path, ctx, env, "table", inner=inner, style=style, classes=classes)

    def _c_html(self, comp, path, ctx, env):
        inner = str(self._arg(comp, 0, ctx, env, ""))
        style: Dict[str, str] = {}
        self._box(comp, ctx, env, style)
        return self._element(comp, path, ctx, env, "div", inner=inner, style=style, classes=("weave-html",))
