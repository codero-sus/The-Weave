"""Recursive-descent parser for Weave.

Grammar (informal)::

    program    := "app" NAME [ "(" config ")" ] ":" INDENT section+ DEDENT EOF
    section    := state | view | styles | theme | routes | function
    state      := "state" ":" INDENT decl+ DEDENT
    decl       := NAME [":" type] "=" expression NEWLINE
    view       := "view" ":" block
    block      := INDENT view_item+ DEDENT
    view_item  := component | for | if
    component  := NAME [ "(" args ")" ] [ ":" block ]
    for        := "for" NAME ("," NAME)* "in" expression ":" block
    if         := "if" expression ":" block [ "else" ":" block ]
    args       := (attr | expression) ("," (attr | expression))*
    attr       := NAME ":" (expression | handler_block)
    handler    := "{" python_lines "}"

Everything that is not a view construct is ordinary Python expression /
statement syntax, which keeps the implementation honest: Weave re-uses
CPython's own parser for the logic half of the language.
"""

from __future__ import annotations

import ast as py_ast
import difflib
import io
import tokenize as py_tokenize
from typing import Dict, List, Optional, Sequence, Set, Tuple

from . import nodes as N
from .errors import WeaveCompileError, WeaveSyntaxError
from .source import (
    COLON, COMMA, DEDENT, EOF, INDENT, LBRACK, LBRACE, LPAREN,
    NAME, NEWLINE, OP, RPAREN, RBRACK, RBRACE, STRING, Source,
    Token, tokenize, tokens_to_source,
)

#: Attribute names that denote an event handler rather than a value.
EVENT_ATTRIBUTES: Set[str] = {
    "click", "on_click", "on_enter", "on_change", "on_input", "on_submit",
    "on_blur", "on_focus", "on_keydown", "on_keyup", "on_dblclick",
    "on_press", "change", "submit", "enter",
    "on_remove", "on_toggle", "on_select", "on_open", "on_close",
}

#: Attribute names whose value is a state variable name rather than an expression.
BINDING_ATTRIBUTES: Set[str] = {"bind", "bind_value", "bind_checked"}

_KEYWORD_LITERALS = {
    "true": "True",
    "false": "False",
    "null": "None",
    "nil": "None",
    "none": "None",
}

#: Names that are always available inside Weave code (see runtime.py).
BUILTIN_NAMES: Set[str] = {
    "len", "str", "int", "float", "bool", "list", "dict", "set", "tuple",
    "range", "enumerate", "zip", "sorted", "reversed", "min", "max", "sum",
    "abs", "round", "any", "all", "print", "log", "toast", "navigate",
    "now", "today", "uuid", "random", "math", "json", "datetime", "time",
    "re", "itertools", "hashlib", "base64", "collections", "statistics",
    "parse_date", "format_date", "lower", "upper", "slugify", "capitalize",
    "debounce", "ctx", "state",
}


class Parser:
    def __init__(self, source: Source):
        self.source = source
        self.tokens: List[Token] = tokenize(source)
        self.pos = 0
        self._handler_counter = 0
        self._captures: List[List[str]] = []  # stack of loop-scope names

    # ------------------------------------------------------------------
    # token helpers
    # ------------------------------------------------------------------
    def advance(self) -> Token:
        tok = self.tokens[self.pos]
        self.pos = min(self.pos + 1, len(self.tokens) - 1)
        return tok

    def at(self, kind: str, text: Optional[str] = None) -> bool:
        tok = self.peek()
        return tok.kind == kind and (text is None or tok.text == text)

    def at_name(self, name: str) -> bool:
        return self.at(NAME, name)

    def expect(self, kind: str, what: str) -> Token:
        tok = self.peek()
        if tok.kind != kind:
            raise self._error(f"expected {what}, found {self._describe(tok)}", tok)
        return self.advance()

    def expect_name(self, what: str) -> Token:
        return self.expect(NAME, what)

    def expect_op(self, text: str) -> Token:
        tok = self.peek()
        if not (tok.kind == OP and tok.text == text):
            raise self._error(f"expected '{text}', found {self._describe(tok)}", tok)
        return self.advance()

    def skip_newlines(self) -> None:
        while self.peek().kind == NEWLINE:
            self.advance()

    def _describe(self, tok: Token) -> str:
        if tok.kind == EOF:
            return "end of file"
        if tok.kind == NEWLINE:
            return "end of line"
        if tok.kind == INDENT:
            return "an indented block"
        if tok.kind == DEDENT:
            return "the end of a block"
        return repr(tok.text)

    def _error(self, message: str, tok: Optional[Token] = None, *, hint: str = "") -> WeaveSyntaxError:
        tok = tok or self.peek()
        return WeaveSyntaxError(
            message,
            line=tok.line,
            col=tok.col,
            hint=hint,
            filename=self.source.filename,
        )

    # ------------------------------------------------------------------
    # program
    # ------------------------------------------------------------------
    def parse_program(self) -> N.App:
        self.skip_newlines()
        tok = self.peek()
        if not (tok.kind == NAME and tok.text == "app"):
            raise self._error(
                "a Weave file must begin with an app declaration, e.g. 'app MyApp:'",
                tok,
                hint="app <Name>:\n    state:\n    view:",
            )
        self.advance()
        name_tok = self.expect_name("an app name")
        app = N.App(line=name_tok.line, col=name_tok.col, name=name_tok.text)

        if self.at(LPAREN):
            self._parse_app_config(app)

        self.expect(COLON, "':' after the app name")
        self._expect_line_end()
        self.expect(INDENT, "an indented app body")

        seen_view = False
        while not self.at(DEDENT) and not self.at(EOF):
            self.skip_newlines()
            if self.at(DEDENT) or self.at(EOF):
                break
            tok = self.peek()
            if tok.kind != NAME:
                raise self._error(f"expected a section name, found {self._describe(tok)}", tok)
            section = tok.text
            if section == "state":
                self.advance()
                self.expect(COLON, "':' after 'state'")
                self._expect_line_end()
                self.expect(INDENT, "an indented state block")
                app.state.extend(self._parse_state_block())
            elif section == "view":
                self.advance()
                self.expect(COLON, "':' after 'view'")
                self._expect_line_end()
                self.expect(INDENT, "an indented view block")
                app.view.extend(self._parse_view_block())
                seen_view = True
            elif section == "routes":
                self.advance()
                self.expect(COLON, "':' after 'routes'")
                self._expect_line_end()
                self.expect(INDENT, "an indented routes block")
                app.routes.extend(self._parse_routes_block())
            elif section == "styles":
                self.advance()
                self.expect(COLON, "':' after 'styles'")
                self._expect_line_end()
                self.expect(INDENT, "an indented styles block")
                app.styles.update(self._parse_styles_block())
            elif section == "theme":
                self.advance()
                self.expect(COLON, "':' after 'theme'")
                self._expect_line_end()
                self.expect(INDENT, "an indented theme block")
                app.theme.update(self._parse_key_value_block())
            elif section in ("function", "def", "fn", "computed", "action"):
                app.functions.append(self._parse_function())
            else:
                raise self._error(
                    f"unknown section '{section}'",
                    tok,
                    hint="sections are: state, view, styles, theme, routes, function",
                )

        self.expect(DEDENT, "the end of the app body")
        self.skip_newlines()
        self.expect(EOF, "end of file")
        if not seen_view and not app.routes:
            raise self._error(
                "this app has no 'view' block, so there is nothing to render",
                name_tok,
                hint="add:\n    view:\n        text(\"Hello, Weave\")",
            )
        return app

    def _parse_app_config(self, app: N.App) -> None:
        self.expect(LPAREN, "'('")
        while not self.at(RPAREN):
            key = self.expect_name("a config key")
            self.expect(COLON, "':' after the config key")
            value_start = self.pos
            depth = 0
            while not (self.peek().kind == RPAREN and depth == 0) and not self.at(EOF):
                tok = self.peek()
                if tok.kind in (LPAREN, LBRACK, LBRACE):
                    depth += 1
                elif tok.kind in (RPAREN, RBRACK, RBRACE):
                    depth -= 1
                self.advance()
            value = _expr(self.tokens[value_start:self.pos])
            if key.text == "title":
                try:
                    app.title = str(py_ast.literal_eval(value))
                except (ValueError, SyntaxError):
                    raise self._error("app title must be a string literal", key)
            else:
                app.theme[key.text] = value
            if self.at(COMMA):
                self.advance()
            elif not self.at(RPAREN):
                raise self._error("expected ',' or ')' in app config", self.peek())
        self.expect(RPAREN, "')'")

    # ------------------------------------------------------------------
    # state
    # ------------------------------------------------------------------
    def _parse_state_block(self) -> List[N.StateDecl]:
        decls: List[N.StateDecl] = []
        while not self.at(DEDENT) and not self.at(EOF):
            self.skip_newlines()
            if self.at(DEDENT) or self.at(EOF):
                break
            name_tok = self.expect_name("a state variable name")
            type_name: Optional[str] = None
            type_args: List[N.TypeRef] = []
            if self.at(COLON):
                self.advance()
                type_tokens = self._collect_until(lambda t: t.kind == OP and t.text == "=")
                type_src = tokens_to_source(type_tokens)
                type_name, type_args = _parse_type(type_src, name_tok, self.source)
                # skip the '='
                self.expect_op("=")
            else:
                self.expect_op("=")
            expr_tokens = self._collect_line()
            if not expr_tokens:
                raise self._error("expected an initial value for state variable", self.peek())
            expr = _expr(expr_tokens)
            _validate_expr(expr, expr_tokens[0], self.source, "state initializer")
            decl = N.StateDecl(
                line=name_tok.line,
                col=name_tok.col,
                name=name_tok.text,
                value=expr,
                type_name=type_name,
                type_args=type_args,
            )
            decls.append(decl)
            self._expect_line_end()
        if not decls:
            raise self._error("state blocks cannot be empty", self.peek())
        self.expect(DEDENT, "the end of the state block")
        return decls

    # ------------------------------------------------------------------
    # functions
    # ------------------------------------------------------------------
    def _parse_function(self) -> N.FunctionDecl:
        kind_tok = self.advance()
        kind = "computed" if kind_tok.text == "computed" else "function"
        name_tok = self.expect_name("a function name")
        params = ""
        return_type = None
        if self.at(LPAREN):
            open_tok = self.advance()
            start = self.pos
            depth = 0
            while not (self.peek().kind == RPAREN and depth == 0) and not self.at(EOF):
                tok = self.peek()
                if tok.kind in (LPAREN, LBRACK, LBRACE):
                    depth += 1
                elif tok.kind in (RPAREN, RBRACK, RBRACE):
                    depth -= 1
                self.advance()
            params = tokens_to_source(self.tokens[start:self.pos])
            self.expect(RPAREN, "')' after function parameters")
            if open_tok.kind != LPAREN:  # pragma: no cover - defensive
                raise self._error("malformed parameter list", open_tok)
        if self.at(OP, "->"):
            self.advance()
            rt = self._collect_until(lambda t: t.kind == COLON)
            return_type = tokens_to_source(rt)
        self.expect(COLON, "':' after the function signature")
        self._expect_line_end()
        self.expect(INDENT, "an indented function body")
        body_line = self.peek().line
        body = self._extract_block_body(self.peek(-1))
        self._skip_block()
        return N.FunctionDecl(
            line=name_tok.line,
            col=name_tok.col,
            name=name_tok.text,
            params=params,
            body=body,
            kind=kind,
            return_type=return_type,
            body_line=body_line,
        )

    # ------------------------------------------------------------------
    # styles / theme
    # ------------------------------------------------------------------
    def _parse_styles_block(self) -> Dict[str, Dict[str, str]]:
        styles: Dict[str, Dict[str, str]] = {}
        while not self.at(DEDENT) and not self.at(EOF):
            self.skip_newlines()
            if self.at(DEDENT) or self.at(EOF):
                break
            name_tok = self.expect_name("a style name")
            self.expect(COLON, "':' after the style name")
            self._expect_line_end()
            self.expect(INDENT, "an indented style block")
            props: Dict[str, str] = {}
            while not self.at(DEDENT) and not self.at(EOF):
                self.skip_newlines()
                if self.at(DEDENT) or self.at(EOF):
                    break
                key_tok = self.expect_name("a CSS property")
                self.expect(COLON, "':' after the property name")
                value_tokens = self._collect_line()
                props[_css_prop(key_tok.text)] = _expr(value_tokens)
                self._expect_line_end()
            self.expect(DEDENT, "the end of the style block")
            styles[name_tok.text] = props
        self.expect(DEDENT, "the end of the styles block")
        return styles

    def _parse_key_value_block(self) -> Dict[str, str]:
        values: Dict[str, str] = {}
        while not self.at(DEDENT) and not self.at(EOF):
            self.skip_newlines()
            if self.at(DEDENT) or self.at(EOF):
                break
            key_tok = self.expect_name("a theme key")
            self.expect(COLON, "':' after the theme key")
            value_tokens = self._collect_line()
            values[key_tok.text] = _expr(value_tokens)
            self._expect_line_end()
        self.expect(DEDENT, "the end of the theme block")
        return values

    # ------------------------------------------------------------------
    # routes
    # ------------------------------------------------------------------
    def _parse_routes_block(self) -> List[N.Route]:
        routes: List[N.Route] = []
        while not self.at(DEDENT) and not self.at(EOF):
            self.skip_newlines()
            if self.at(DEDENT) or self.at(EOF):
                break
            path_tok = self.expect(STRING, "a route path string (e.g. \"/about\")")
            title = None
            if self.at(LPAREN):
                self.advance()
                while not self.at(RPAREN):
                    key = self.expect_name("a route option")
                    self.expect(COLON, "':' after the route option")
                    value_tokens = self._collect_until(lambda t: t.kind in (COMMA, RPAREN))
                    if key.text == "title":
                        title = str(py_ast.literal_eval(_expr(value_tokens)))
                    if self.at(COMMA):
                        self.advance()
                self.expect(RPAREN, "')'")
            self.expect(COLON, "':' after the route path")
            self._expect_line_end()
            self.expect(INDENT, "an indented route block")
            body = self._parse_view_block()
            routes.append(N.Route(line=path_tok.line, col=path_tok.col, path=str(path_tok.value), body=body, title=title))
        self.expect(DEDENT, "the end of the routes block")
        return routes

    # ------------------------------------------------------------------
    # view
    # ------------------------------------------------------------------
    def _parse_view_block(self) -> List[N.Node]:
        children = self._parse_view_items()
        if self.at(DEDENT):
            self.advance()
        return children

    def _parse_view_items(self) -> List[N.Node]:
        items: List[N.Node] = []
        while not self.at(DEDENT) and not self.at(EOF):
            self.skip_newlines()
            if self.at(DEDENT) or self.at(EOF):
                break
            items.append(self._parse_view_item())
        return items

    def _capture_scope(self) -> List[str]:
        names: List[str] = []
        for frame in self._captures:
            for name in frame:
                if name not in names:
                    names.append(name)
        return names

    def _parse_view_item(self) -> N.Node:
        tok = self.peek()
        if tok.kind != NAME:
            raise self._error(
                f"expected a component name, found {self._describe(tok)}",
                tok,
                hint="view lines look like: text(\"hello\") or card():",
            )
        if tok.text == "for":
            return self._parse_for()
        if tok.text == "if":
            return self._parse_if()
        if tok.text == "else":
            raise self._error("'else' without a matching 'if'", tok)
        return self._parse_component()

    def _parse_for(self) -> N.For:
        for_tok = self.advance()
        targets: List[str] = []
        while True:
            name_tok = self.expect_name("a loop variable")
            targets.append(name_tok.text)
            if self.at(COMMA):
                self.advance()
                continue
            break
        if len(targets) > 2:
            raise self._error(
                "for loops support at most two loop variables (index, item)",
                for_tok,
                hint="for i, item in enumerate(items):",
            )
        if not self.at_name("in"):
            raise self._error("expected 'in' in for loop", self.peek())
        self.advance()
        iter_tokens = self._collect_until(lambda t: t.kind == COLON)
        iterable = _expr(iter_tokens)
        _validate_expr(iterable, iter_tokens[0] if iter_tokens else for_tok, self.source, "for loop")
        self.expect(COLON, "':' after the for loop")
        self._expect_line_end()
        self.expect(INDENT, "an indented for body")
        self._captures.append(targets)
        try:
            children = self._parse_view_block()
        finally:
            self._captures.pop()
        index = None
        if len(targets) == 2:
            index, target = targets[0], targets[1]
            return N.For(line=for_tok.line, col=for_tok.col, target=target, index=index, iterable=iterable, children=children)
        return N.For(line=for_tok.line, col=for_tok.col, target=targets[0], iterable=iterable, children=children)

    def _parse_if(self) -> N.If:
        if_tok = self.advance()
        cond_tokens = self._collect_until(lambda t: t.kind == COLON)
        condition = _expr(cond_tokens)
        _validate_expr(condition, cond_tokens[0] if cond_tokens else if_tok, self.source, "if condition")
        self.expect(COLON, "':' after the if condition")
        self._expect_line_end()
        self.expect(INDENT, "an indented if body")
        node = N.If(line=if_tok.line, col=if_tok.col, condition=condition, children=self._parse_view_block())
        nxt = self._next_significant()
        if nxt.kind == NAME and nxt.text == "else" and nxt.col == if_tok.col:
            self.advance()
            self.skip_newlines()
            if self.at_name("if"):  # 'else if' -> 'elif'
                node.orelse = [self._parse_if()]
                return node
            self.expect(COLON, "':' after 'else'")
            self._expect_line_end()
            self.expect(INDENT, "an indented else body")
            node.orelse = self._parse_view_block()
        return node

    def _parse_component(self) -> N.Component:
        name_tok = self.advance()
        component = N.Component(line=name_tok.line, col=name_tok.col, name=name_tok.text)
        if self.at(LPAREN):
            self._parse_call_args(component)
        if self.at(COLON):
            self.advance()
            self._expect_line_end()
            self.expect(INDENT, f"an indented block for '{name_tok.text}'")
            component.children = self._parse_view_block()
        return component

    # -- argument parsing ---------------------------------------------
    def _parse_call_args(self, component: N.Component) -> None:
        open_tok = self.expect(LPAREN, "'('")
        base_depth = open_tok.depth
        while True:
            self.skip_soft_newlines()
            if self.at(RPAREN):
                self.advance()
                return
            if self.at(EOF):
                raise self._error("unclosed '(' in component arguments", open_tok)
            value_tokens = self._collect_until(
                lambda t: (t.kind == COMMA and t.depth == base_depth + 1)
                or (t.kind == RPAREN and t.depth == base_depth)
            )
            value_tokens = self._strip_newlines(value_tokens)
            if not value_tokens:
                raise self._error("empty argument in component call", self.peek())
            first = value_tokens[0]
            if (
                first.kind == NAME
                and len(value_tokens) >= 2
                and value_tokens[1].kind == COLON
            ):
                attr_name = first.text
                if attr_name in component.attrs:
                    raise self._error(
                        f"duplicate attribute '{attr_name}' on '{component.name}'",
                        first,
                    )
                component.attrs[attr_name] = self._make_attribute(attr_name, value_tokens[2:], first)
            else:
                if component.attrs:
                    raise self._error(
                        "positional arguments must come before named attributes",
                        first,
                    )
                expr = _expr(value_tokens)
                _validate_expr(expr, first, self.source, f"argument to '{component.name}'")
                component.positional.append(expr)
            self.skip_soft_newlines()
            if self.at(COMMA):
                self.advance()
                continue
            if self.at(RPAREN):
                self.advance()
                return
            raise self._error("expected ',' or ')' in component arguments", self.peek())

    def _make_attribute(self, name: str, value_tokens: List[Token], name_tok: Token) -> N.Attribute:
        value_tokens = self._strip_newlines(value_tokens)
        if not value_tokens:
            raise self._error(f"attribute '{name}' is missing a value", name_tok)
        raw = tokens_to_source(value_tokens)
        is_event = name in EVENT_ATTRIBUTES or name.startswith("on_")
        if is_event and value_tokens[0].kind == LBRACE:
            close = self._matching_brace(value_tokens, value_tokens[0])
            if close is None:
                raise self._error(f"unclosed '{{' in '{name}' handler", value_tokens[0])
            body = self._extract_braced_body(value_tokens[0], close)
            handler = N.Handler(
                line=value_tokens[0].line,
                col=value_tokens[0].col,
                body=body,
                kind="event",
                captures=self._capture_scope(),
                body_line=value_tokens[0].line if close.line == value_tokens[0].line else value_tokens[0].line + 1,
            )
            return N.Attribute(line=name_tok.line, col=name_tok.col, name=name, expr="", handler=handler, raw=raw)

        if is_event:
            expr = _expr(value_tokens)
            _validate_expr(expr, value_tokens[0], self.source, f"'{name}' handler")
            handler = N.Handler(
                line=value_tokens[0].line,
                col=value_tokens[0].col,
                body=expr,
                kind="event",
                captures=self._capture_scope(),
                body_line=value_tokens[0].line,
            )
            return N.Attribute(line=name_tok.line, col=name_tok.col, name=name, expr=expr, handler=handler, raw=raw)

        expr = _expr(value_tokens)
        if name not in BINDING_ATTRIBUTES:
            _validate_expr(expr, value_tokens[0], self.source, f"attribute '{name}'")
        return N.Attribute(line=name_tok.line, col=name_tok.col, name=name, expr=expr, raw=raw)

    @staticmethod
    def _strip_newlines(tokens: Sequence[Token]) -> List[Token]:
        return [t for t in tokens if t.kind != NEWLINE]

    def skip_soft_newlines(self) -> None:
        while self.peek().kind == NEWLINE and self.peek().soft:
            self.advance()

    @staticmethod
    def _matching_brace(value_tokens: Sequence[Token], open_tok: Token) -> Optional[Token]:
        for tok in value_tokens[1:]:
            if tok.kind == RBRACE and tok.depth == open_tok.depth:
                return tok
        return None

    # ------------------------------------------------------------------
    # source slicing helpers
    # ------------------------------------------------------------------
    def _collect_line(self) -> List[Token]:
        return self._collect_until(lambda t: t.kind in (NEWLINE, EOF, DEDENT))

    def _collect_until(self, predicate) -> List[Token]:
        start = self.pos
        depth = 0
        while not self.at(EOF):
            tok = self.peek()
            if depth == 0 and predicate(tok):
                break
            if tok.kind in (LPAREN, LBRACK, LBRACE):
                depth += 1
            elif tok.kind in (RPAREN, RBRACK, RBRACE):
                depth -= 1
            self.advance()
        return self.tokens[start:self.pos]

    def _skip_block(self) -> None:
        """Advance past the current indented block, consuming its DEDENT."""
        depth = 0
        while not self.at(EOF):
            tok = self.advance()
            if tok.kind == INDENT:
                depth += 1
            elif tok.kind == DEDENT:
                if depth == 0:
                    return
                depth -= 1

    def _next_significant(self) -> Token:
        idx = self.pos
        while self.tokens[idx].kind == NEWLINE:
            idx += 1
        return self.tokens[idx]

    def _expect_line_end(self) -> None:
        tok = self.peek()
        if tok.kind == NEWLINE:
            self.advance()
            return
        if tok.kind in (EOF, DEDENT):
            return
        raise self._error(f"expected end of line, found {self._describe(tok)}", tok)

    def peek(self, offset: int = 0) -> Token:  # type: ignore[override]
        idx = self.pos + offset
        if idx < 0:
            idx = 0
        return self.tokens[min(idx, len(self.tokens) - 1)]

    def _extract_block_body(self, fake_header: Token) -> str:
        """Return the dedented source of an indented block.

        The block's first token is at ``self.pos`` and the block ends at the
        matching DEDENT.  Indentation is removed relative to the first line.
        """
        first = self.peek()
        if first.kind in (DEDENT, EOF):
            return ""
        start_line = first.line
        # find matching DEDENT without consuming
        idx = self.pos
        depth = 0
        while idx < len(self.tokens):
            tok = self.tokens[idx]
            if tok.kind == INDENT:
                depth += 1
            elif tok.kind == DEDENT:
                if depth == 0:
                    break
                depth -= 1
            idx += 1
        end_tok = self.tokens[idx] if idx < len(self.tokens) else None
        end_line = end_tok.line if end_tok is not None and end_tok.kind != EOF else len(self.source.lines) + 1
        raw_lines = self.source.lines[start_line - 1 : end_line - 1]
        if not raw_lines:
            return ""
        return normalize_code(_dedent_lines(raw_lines))

    def _extract_braced_body(self, open_tok: Token, close_tok: Token) -> str:
        open_line = self.source.line(open_tok.line)
        if open_tok.line == close_tok.line:
            return normalize_code(open_line[open_tok.col : close_tok.col - 1].strip())

        close_line = self.source.line(close_tok.line)
        head = open_line[open_tok.col :].strip()
        middle = self.source.lines[open_tok.line : close_tok.line - 1]
        tail_raw = close_line[: close_tok.col - 1]
        tail = tail_raw.strip()

        if not head and not tail:
            return normalize_code(_dedent_lines(middle))

        # Mixed inline/block style, e.g. ``{ first()`` … ``last() }``.
        non_blank = [line for line in middle if line.strip()]
        if non_blank:
            base = min(len(line) - len(line.lstrip(" ")) for line in non_blank)
        else:
            base = len(tail_raw) - len(tail_raw.lstrip(" "))
        rebuilt: List[str] = []
        if head:
            rebuilt.append(head)
        for line in middle:
            rebuilt.append(line[base:] if line.strip() else "")
        if tail:
            relative = max(0, len(tail_raw) - len(tail_raw.lstrip(" ")) - base)
            rebuilt.append(" " * relative + tail)
        return normalize_code("\n".join(rebuilt).strip("\n"))


def _dedent_lines(lines: Sequence[str]) -> str:
    non_blank = [ln for ln in lines if ln.strip()]
    if not non_blank:
        return ""
    indent = min(len(ln) - len(ln.lstrip(" ")) for ln in non_blank)
    return "\n".join(ln[indent:].rstrip() if ln.strip() else "" for ln in lines).strip("\n")


def _expr(tokens: Sequence[Token]) -> str:
    """Reconstruct an expression, translating keyword literals safely."""
    rewritten: List[Token] = []
    for tok in tokens:
        if tok.kind == NAME and tok.text in _KEYWORD_LITERALS:
            rewritten.append(Token(NAME, _KEYWORD_LITERALS[tok.text], tok.line, tok.col, tok.depth))
        else:
            rewritten.append(tok)
    return tokens_to_source(rewritten)


def normalize_code(src: str) -> str:
    """Rewrite ``true``/``false``/``null`` in a Python code block.

    Uses CPython's tokenizer so string literals and comments are untouched,
    and all replacements have the same width, so formatting is preserved.
    """
    if not src.strip():
        return src
    try:
        tokens = list(py_tokenize.generate_tokens(io.StringIO(src).readline))
    except (py_tokenize.TokenError, IndentationError):
        return src
    out = []
    for tok in tokens:
        if tok.type == py_tokenize.NAME and tok.string in _KEYWORD_LITERALS:
            out.append(tok._replace(string=_KEYWORD_LITERALS[tok.string]))
        else:
            out.append(tok)
    try:
        return py_tokenize.untokenize(out)
    except (ValueError, IndexError):  # pragma: no cover - defensive
        return src


def _validate_expr(src: str, tok: Token, source: Source, what: str) -> None:
    if not src.strip():
        raise WeaveSyntaxError(
            f"expected an expression for {what}",
            line=tok.line,
            col=tok.col,
            filename=source.filename,
        )
    try:
        py_ast.parse(src, mode="eval")
    except SyntaxError as exc:
        raise WeaveSyntaxError(
            f"invalid expression in {what}: {exc.msg}",
            line=tok.line,
            col=tok.col,
            hint=src.strip(),
            filename=source.filename,
        ) from None


def _parse_type(src: str, tok: Token, source: Source) -> Tuple[str, List[N.TypeRef]]:
    try:
        parsed = py_ast.parse(src, mode="eval").body
    except SyntaxError:
        raise WeaveSyntaxError(
            f"invalid type annotation '{src}'",
            line=tok.line,
            col=tok.col,
            filename=source.filename,
        ) from None

    def convert(node) -> N.TypeRef:
        if isinstance(node, py_ast.Name):
            return N.TypeRef(node.id)
        if isinstance(node, py_ast.Attribute):
            return N.TypeRef(convert(node.value).name + "." + node.attr)
        if isinstance(node, py_ast.Subscript):
            base = convert(node.value)
            elems = node.slice.elts if isinstance(node.slice, py_ast.Tuple) else [node.slice]
            base.args = [convert(e) for e in elems]
            return base
        if isinstance(node, py_ast.Constant) and isinstance(node.value, str):
            return N.TypeRef(node.value)
        raise WeaveSyntaxError(
            f"unsupported type annotation '{src}'",
            line=tok.line,
            col=tok.col,
            filename=source.filename,
        )

    ref = convert(parsed)
    return ref.name, ref.args


def _css_prop(name: str) -> str:
    return name.replace("_", "-")


def parse(source: Source) -> N.App:
    return Parser(source).parse_program()


def parse_file(path: str) -> N.App:
    with open(path, "r", encoding="utf-8") as fh:
        text = fh.read()
    return parse(Source(text, filename=path))


def validate_component_names(app: N.App, source: Source) -> None:
    """Check component names and attributes against the component registry."""
    from .components import COMPONENTS, UNIVERSAL_ATTRS, UNIVERSAL_EVENTS

    def walk(nodes: Sequence[N.Node]) -> None:
        for node in nodes:
            if isinstance(node, N.Component):
                spec = COMPONENTS.get(node.name)
                if spec is None:
                    close = difflib.get_close_matches(node.name, list(COMPONENTS), n=1)
                    hint = f"did you mean '{close[0]}'?" if close else "see 'weave components' for the full list"
                    raise WeaveCompileError(
                        f"unknown component '{node.name}'",
                        line=node.line,
                        col=node.col,
                        hint=hint,
                        filename=source.filename,
                    )
                for attr_name, attr in node.attrs.items():
                    if (
                        attr_name in spec.attrs
                        or attr_name in spec.events
                        or attr_name in UNIVERSAL_ATTRS
                        or attr_name in UNIVERSAL_EVENTS
                        or attr_name in EVENT_ATTRIBUTES
                        or attr_name in BINDING_ATTRIBUTES
                    ):
                        continue
                    if attr_name.startswith("style_") or attr_name.startswith("data_"):
                        continue
                    close = difflib.get_close_matches(attr_name, list(spec.attrs) + list(spec.events), n=1)
                    hint = f"did you mean '{close[0]}'?" if close else f"'{node.name}' supports: {', '.join(sorted(spec.attrs | spec.events))}"
                    raise WeaveCompileError(
                        f"unknown attribute '{attr_name}' on '{node.name}'",
                        line=attr.line,
                        col=attr.col,
                        hint=hint,
                        filename=source.filename,
                    )
                min_args, max_args = spec.positional
                if len(node.positional) < min_args:
                    raise WeaveCompileError(
                        f"'{node.name}' expects at least {min_args} argument(s), got {len(node.positional)}",
                        line=node.line,
                        col=node.col,
                        filename=source.filename,
                    )
                if max_args is not None and len(node.positional) > max_args:
                    raise WeaveCompileError(
                        f"'{node.name}' accepts at most {max_args} argument(s), got {len(node.positional)}",
                        line=node.line,
                        col=node.col,
                        filename=source.filename,
                    )
                walk(node.children)
            elif isinstance(node, N.For):
                walk(node.children)
            elif isinstance(node, N.If):
                walk(node.children)
                walk(node.orelse)

    walk(app.view)
    for route in app.routes:
        walk(route.body)
