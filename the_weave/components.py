"""The Weave component registry.

Each entry describes one declarative UI primitive: how many positional
arguments it takes, which attributes and events it understands, and whether
it can contain children.  ``renderer.py`` provides the actual HTML for every
name registered here.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import Dict, FrozenSet, Optional, Sequence, Tuple


@dataclass(frozen=True)
class ComponentSpec:
    name: str
    tag: str
    positional: Tuple[int, Optional[int]]
    attrs: FrozenSet[str] = field(default_factory=frozenset)
    events: FrozenSet[str] = field(default_factory=frozenset)
    container: bool = False
    void: bool = False
    summary: str = ""
    example: str = ""


#: Attributes accepted by every component.
UNIVERSAL_ATTRS: FrozenSet[str] = frozenset({
    "style", "class", "id", "visible", "width", "height", "margin",
    "padding", "align_self", "grow", "tooltip", "animate", "transition",
    "opacity", "z",
})

#: Events accepted by every component (where it makes sense).
UNIVERSAL_EVENTS: FrozenSet[str] = frozenset({"click", "on_click"})

_BOX_ATTRS = frozenset({
    "padding", "gap", "background", "radius", "border", "shadow", "align",
    "justify", "width", "height", "margin", "wrap", "grow", "max_width",
    "min_width", "max_height", "direction", "overflow", "position",
})

_TEXT_ATTRS = frozenset({
    "font", "bold", "italic", "color", "align", "muted", "mono", "weight",
    "max_width", "line_height", "truncate", "selectable", "font_family",
    "letter_spacing", "uppercase",
})

_INPUT_ATTRS = frozenset({
    "bind", "placeholder", "type", "label", "value", "disabled", "required",
    "autofocus", "min", "max", "step", "error", "help", "icon", "mono",
    "rows", "autocomplete", "name", "mask", "clearable",
})

_INPUT_EVENTS = frozenset({
    "on_enter", "on_change", "on_input", "on_blur", "on_focus", "enter",
    "change", "submit",
})

_BUTTON_ATTRS = frozenset({
    "variant", "size", "color", "disabled", "icon", "icon_right", "type",
    "full", "loading", "href", "title", "submit",
})


def _spec(name: str, tag: str, positional: Tuple[int, Optional[int]], *, attrs: Sequence[str] = (),
          events: Sequence[str] = (), container: bool = False, void: bool = False,
          summary: str = "", example: str = "") -> ComponentSpec:
    return ComponentSpec(
        name=name,
        tag=tag,
        positional=positional,
        attrs=frozenset(attrs),
        events=frozenset(events),
        container=container,
        void=void,
        summary=summary,
        example=example,
    )


COMPONENT_LIST = [
    # ---- layout -----------------------------------------------------
    _spec("stack", "div", (0, 0), container=True,
          attrs=_BOX_ATTRS | {"spacing", "divider"},
          events=("click",),
          summary="vertical flex container",
          example='stack(padding: 24, gap: 12):\n    text("hi")'),
    _spec("row", "div", (0, 0), container=True,
          attrs=_BOX_ATTRS | {"spacing", "justify"},
          events=("click",),
          summary="horizontal flex container",
          example='row(gap: 8, justify: between):\n    text("a")\n    text("b")'),
    _spec("grid", "div", (0, 0), container=True,
          attrs=_BOX_ATTRS | {"columns", "min_column", "gap"},
          events=("click",),
          summary="CSS grid container (columns: 3)",
          example='grid(columns: 2, gap: 16):\n    card():\n        text("a")'),
    _spec("center", "div", (0, 0), container=True, attrs=_BOX_ATTRS,
          events=("click",),
          summary="centres its children on both axes"),
    _spec("card", "div", (0, 0), container=True,
          attrs=_BOX_ATTRS | {"hover", "title", "collapsible"},
          events=("click", "on_click"),
          summary="surface container with padding, radius and shadow",
          example='card(shadow: sm):\n    text("hello")'),
    _spec("section", "section", (0, 0), container=True, attrs=_BOX_ATTRS | {"title"},
          events=("click",), summary="labelled page section"),
    _spec("hero", "header", (0, 0), container=True, attrs=_BOX_ATTRS | {"title", "subtitle"},
          events=("click",), summary="page hero / banner"),
    _spec("scroll", "div", (0, 0), container=True, attrs=_BOX_ATTRS | {"max_height"},
          events=("click",), summary="scrollable container"),
    _spec("form", "form", (0, 0), container=True, attrs=_BOX_ATTRS | {"prevent"},
          events=("submit", "on_submit", "click"),
          summary="form wrapper (fires on_submit)"),
    _spec("tabs", "div", (0, 0), container=True,
          attrs=frozenset({"bind", "variant", "full", "padding", "gap", "margin", "style", "class", "id", "visible"}),
          events=frozenset(),
          summary="segmented control; `bind` holds the selected tab label",
          example='tabs(bind: tab):\n    tab("All")\n    tab("Done")'),
    _spec("tab", "div", (1, 1), attrs=frozenset({"icon", "count"}),
          summary="a single tab inside tabs()"),
    _spec("divider", "hr", (0, 0), void=True,
          attrs=frozenset({"color", "margin", "padding", "style", "class", "id", "visible"}),
          summary="horizontal rule"),
    _spec("spacer", "div", (0, 0), void=True,
          attrs=frozenset({"height", "width", "grow", "style", "class", "id", "visible"}),
          summary="flexible empty space"),

    # ---- content ----------------------------------------------------
    _spec("text", "p", (1, 1), attrs=_TEXT_ATTRS,
          events=("click",),
          summary="paragraph of text; first argument is the content",
          example='text("Hello", font: 28, bold: true)'),
    _spec("title", "h1", (1, 1), attrs=_TEXT_ATTRS,
          events=("click",), summary="page heading"),
    _spec("label", "span", (1, 1), attrs=_TEXT_ATTRS, summary="small inline label"),
    _spec("code", "pre", (1, 1),
          attrs=frozenset({"color", "background", "padding", "radius", "font", "width", "margin", "style", "class", "id", "visible", "wrap"}),
          summary="monospace code block"),
    _spec("badge", "span", (1, 1),
          attrs=frozenset({"color", "background", "variant", "size", "radius", "style", "class", "id", "visible"}),
          summary="small pill label"),
    _spec("link", "a", (1, 1),
          attrs=frozenset({"href", "external", "color", "underline", "bold", "size", "style", "class", "id", "visible"}),
          events=("click",), summary="hyperlink"),
    _spec("image", "img", (1, 1),
          attrs=frozenset({"alt", "width", "height", "radius", "fit", "shadow", "border", "margin", "padding", "style", "class", "id", "visible", "zoom", "bg"}),
          events=("click", "on_click"), summary="image by URL or local path"),
    _spec("avatar", "img", (1, 1),
          attrs=frozenset({"alt", "size", "radius", "border", "style", "class", "id", "visible"}),
          summary="round profile image"),
    _spec("icon", "span", (1, 1),
          attrs=frozenset({"size", "color", "background", "radius", "padding", "style", "class", "id", "visible"}),
          events=("click",), summary="emoji or single glyph icon"),
    _spec("metric", "div", (1, 2),
          attrs=frozenset({"label", "color", "background", "padding", "radius", "border", "shadow", "width", "align", "icon", "trend", "style", "class", "id", "visible"}),
          summary="big number with a caption: metric(value, label)"),
    _spec("progress", "div", (1, 2),
          attrs=frozenset({"max", "color", "background", "height", "radius", "label", "width", "style", "class", "id", "visible", "show_value"}),
          summary="progress bar: progress(0.7) or progress(done, total)"),

    # ---- forms ------------------------------------------------------
    _spec("input", "input", (0, 0), attrs=_INPUT_ATTRS, events=_INPUT_EVENTS,
          summary="single-line text input, usually with bind:",
          example='input(bind: new_task, placeholder: "What next?", on_enter: {\n    tasks.append(new_task)\n})'),
    _spec("textarea", "textarea", (0, 0), attrs=_INPUT_ATTRS, events=_INPUT_EVENTS,
          summary="multi-line text input"),
    _spec("checkbox", "label", (0, 0), attrs=_INPUT_ATTRS, events=_INPUT_EVENTS,
          summary="checkbox bound to a boolean state"),
    _spec("toggle", "label", (0, 0), attrs=_INPUT_ATTRS, events=_INPUT_EVENTS,
          summary="switch bound to a boolean state"),
    _spec("select", "select", (0, 0),
          attrs=_INPUT_ATTRS | {"options", "placeholder"},
          events=_INPUT_EVENTS, summary="dropdown bound to a state value"),
    _spec("slider", "input", (0, 0), attrs=_INPUT_ATTRS, events=_INPUT_EVENTS,
          summary="range slider bound to a number"),
    _spec("button", "button", (1, 1), attrs=_BUTTON_ATTRS,
          events=("click", "on_click", "on_press"),
          summary="button with a click handler",
          example='button("Add", click: add_task())'),
    _spec("icon_button", "button", (1, 1), attrs=_BUTTON_ATTRS,
          events=("click", "on_click"), summary="square icon-only button"),

    # ---- data -------------------------------------------------------
    _spec("table", "table", (1, 1),
          attrs=frozenset({"columns", "header", "striped", "hover", "compact", "width", "margin", "padding", "radius", "border", "shadow", "background", "style", "class", "id", "visible"}),
          summary="table from a list of dicts: table(rows, columns: [...])"),
    _spec("html", "div", (1, 1),
          attrs=frozenset({"style", "class", "id", "visible", "width", "margin", "padding"}),
          summary="raw HTML escape hatch"),
]

COMPONENTS: Dict[str, ComponentSpec] = {spec.name: spec for spec in COMPONENT_LIST}

#: Components that exist in the registry but are not top-level renderable
#: (they are only meaningful as children of another component).
CHILD_ONLY = {"tab"}


def find(name: str) -> Optional[ComponentSpec]:
    return COMPONENTS.get(name)


def component_names() -> Sequence[str]:
    return sorted(COMPONENTS)
