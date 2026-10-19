"""Source handling and the Weave tokenizer.

Weave is indentation sensitive.  The tokenizer emits ``INDENT`` / ``DEDENT``
tokens exactly like Python's own tokenizer, but it also records the bracket
depth of every token.  That lets the parser tell a block-opening colon
(``stack(...):``) apart from a colon inside a dict literal or a slice
(``{ "a": 1 }``, ``xs[1:3]``).
"""

from __future__ import annotations

import ast
from dataclasses import dataclass
from typing import Iterable, List, Optional, Tuple

from .errors import WeaveSyntaxError

# Token kinds
NAME = "NAME"
NUMBER = "NUMBER"
STRING = "STRING"
OP = "OP"
NEWLINE = "NEWLINE"
INDENT = "INDENT"
DEDENT = "DEDENT"
EOF = "EOF"

# Brackets / punctuation get their own kind for readability in the parser.
LPAREN = "LPAREN"
RPAREN = "RPAREN"
LBRACK = "LBRACK"
RBRACK = "RBRACK"
LBRACE = "LBRACE"
RBRACE = "RBRACE"
COLON = "COLON"
COMMA = "COMMA"
DOT = "DOT"

_SINGLE = {
    "(": LPAREN,
    ")": RPAREN,
    "[": LBRACK,
    "]": RBRACK,
    "{": LBRACE,
    "}": RBRACE,
    ":": COLON,
    ",": COMMA,
    ".": DOT,
}

# Longest first so that ``**`` wins over ``*``.
_OPERATORS = [
    "==", "!=", "<=", ">=", "//", "**", "+=", "-=", "*=", "/=",
    "->", "+", "-", "*", "/", "%", "<", ">", "=", "|", "&", "~",
]

_OPENERS = {LPAREN, LBRACK, LBRACE}
_CLOSERS = {RPAREN, RBRACK, RBRACE}
_MATCH = {RPAREN: LPAREN, RBRACK: LBRACK, RBRACE: LBRACE}


@dataclass
class Token:
    kind: str
    text: str
    line: int
    col: int
    depth: int = 0
    #: decoded value for STRING / NUMBER tokens
    value: object = None
    #: True for newlines emitted inside brackets (insignificant whitespace)
    soft: bool = False

    def is_op(self, *ops: str) -> bool:
        return self.kind == OP and self.text in ops

    def __repr__(self) -> str:  # pragma: no cover - debugging aid
        return f"Token({self.kind}, {self.text!r}, {self.line}:{self.col}, d={self.depth})"


class Source:
    """A ``.weave`` file (or in-memory source string)."""

    def __init__(self, text: str, filename: str = "<weave>"):
        self.text = text
        self.filename = filename
        self.lines = text.splitlines()

    def line(self, number: int) -> str:
        if 1 <= number <= len(self.lines):
            return self.lines[number - 1]
        return ""

    def __str__(self) -> str:  # pragma: no cover
        return self.text


_STRING_PREFIXES = {"f", "r", "b", "u", "fr", "rf", "br", "rb"}


def decode_string(raw: str, line: int, col: int, filename: str = "") -> str:
    """Decode a Weave string literal (which follows Python escaping rules)."""
    prefix = ""
    body = raw
    for length in (2, 1):
        if len(raw) > length and raw[:length].lower() in _STRING_PREFIXES:
            prefix = raw[:length].lower()
            body = raw[length:]
            break
    if "f" in prefix:
        # f-strings are compiled by Python later; their value is not needed.
        return body[1:-1] if len(body) >= 2 else body
    try:
        value = ast.literal_eval(raw)
    except (SyntaxError, ValueError) as exc:  # pragma: no cover - defensive
        raise WeaveSyntaxError(
            f"invalid string literal: {exc}",
            line=line,
            col=col,
            filename=filename,
        )
    if not isinstance(value, str):  # pragma: no cover - defensive
        raise WeaveSyntaxError("invalid string literal", line=line, col=col, filename=filename)
    return value


class Tokenizer:
    def __init__(self, source: Source):
        self.source = source
        self.filename = source.filename

    def tokenize(self) -> List[Token]:
        source = self.source
        text = source.text.replace("\r\n", "\n").replace("\r", "\n")
        lines = text.split("\n")

        tokens: List[Token] = []
        indents: List[int] = [0]
        depth = 0
        bracket_stack: List[Token] = []

        for lineno, raw_line in enumerate(lines, start=1):
            stripped = raw_line.lstrip(" \t")
            indent_text = raw_line[: len(raw_line) - len(stripped)]
            if "\t" in indent_text:
                raise WeaveSyntaxError(
                    "tabs are not allowed for indentation; use spaces",
                    line=lineno,
                    col=1,
                    filename=self.filename,
                )
            indent = len(indent_text)

            if depth > 0:
                # Inside brackets newlines are insignificant, but we still
                # record them (soft) so multi-line handler blocks can be
                # reconstructed with their original line structure.
                if stripped and not stripped.startswith("#"):
                    before = len(tokens)
                    depth, bracket_stack = self._scan_line(stripped, lineno, indent, depth, bracket_stack, tokens)
                    if len(tokens) > before:
                        tokens.append(Token(NEWLINE, "", lineno, indent + len(stripped) + 1, depth, soft=True))
                continue

            if not stripped or stripped.startswith("#"):
                continue  # blank line or whole-line comment

            # ---- indentation bookkeeping --------------------------------
            if indent > indents[-1]:
                indents.append(indent)
                tokens.append(Token(INDENT, "", lineno, indent + 1))
            else:
                while indent < indents[-1]:
                    indents.pop()
                    tokens.append(Token(DEDENT, "", lineno, indent + 1))
                if indent != indents[-1]:
                    raise WeaveSyntaxError(
                        "unindent does not match any outer indentation level",
                        line=lineno,
                        col=indent + 1,
                        hint="keep block indentation consistent",
                        filename=self.filename,
                    )

            before = len(tokens)
            depth, bracket_stack = self._scan_line(stripped, lineno, indent, depth, bracket_stack, tokens)
            if depth == 0 and len(tokens) > before:
                tokens.append(Token(NEWLINE, "", lineno, indent + len(stripped) + 1))

        if depth != 0:
            opener = bracket_stack[-1]
            raise WeaveSyntaxError(
                f"unclosed '{opener.text}'",
                line=opener.line,
                col=opener.col,
                filename=self.filename,
            )

        while len(indents) > 1:
            indents.pop()
            tokens.append(Token(DEDENT, "", len(lines), 1))
        tokens.append(Token(EOF, "", len(lines), 1))
        return tokens

    # ------------------------------------------------------------------
    def _scan_line(
        self,
        line: str,
        lineno: int,
        base: int,
        depth: int,
        bracket_stack: List[Token],
        tokens: List[Token],
    ) -> Tuple[int, List[Token]]:
        i = 0
        n = len(line)
        while i < n:
            ch = line[i]
            if ch in " \t":
                i += 1
                continue
            if ch == "#":
                break
            col = base + i + 1

            if ch in ("'", '"'):
                raw, i2 = self._scan_string(line, i, lineno, col)
                tokens.append(Token(STRING, raw, lineno, col, depth, decode_string(raw, lineno, col, self.filename)))
                i = i2
                continue

            if ch.isdigit():
                j = i
                while j < n:
                    if line[j].isdigit():
                        j += 1
                    elif line[j] == "." and j + 1 < n and line[j + 1].isdigit():
                        j += 1
                    elif line[j] == "_" and j + 1 < n and line[j + 1].isdigit():
                        j += 1
                    else:
                        break
                raw = line[i:j]
                clean = raw.replace("_", "")
                value: object = float(clean) if "." in clean else int(clean)
                tokens.append(Token(NUMBER, raw, lineno, col, depth, value))
                i = j
                continue

            if ch.isalpha() or ch == "_":
                j = i + 1
                while j < n and (line[j].isalnum() or line[j] == "_"):
                    j += 1
                word = line[i:j]
                if j < n and line[j] in ("'", '"') and word.lower() in _STRING_PREFIXES:
                    raw, i2 = self._scan_string(line, j, lineno, base + j + 1)
                    raw = word + raw
                    tokens.append(Token(STRING, raw, lineno, col, depth,
                                        decode_string(raw, lineno, col, self.filename)))
                    i = i2
                    continue
                tokens.append(Token(NAME, word, lineno, col, depth))
                i = j
                continue

            found = None
            for op in _OPERATORS:
                if line.startswith(op, i):
                    found = op
                    break
            if found is not None:
                tokens.append(Token(OP, found, lineno, col, depth))
                i += len(found)
                continue

            kind = _SINGLE.get(ch)
            if kind is not None:
                tok = Token(kind, ch, lineno, col, depth)
                tokens.append(tok)
                if kind in _OPENERS:
                    bracket_stack.append(tok)
                    depth += 1
                elif kind in _CLOSERS:
                    if not bracket_stack:
                        raise WeaveSyntaxError(
                            f"unmatched '{ch}'",
                            line=lineno,
                            col=col,
                            filename=self.filename,
                        )
                    opener = bracket_stack.pop()
                    if _MATCH[kind] != opener.kind:
                        raise WeaveSyntaxError(
                            f"mismatched '{ch}'; '{opener.text}' is still open",
                            line=lineno,
                            col=col,
                            filename=self.filename,
                        )
                    depth -= 1
                    tok.depth = depth
                i += 1
                continue

            raise WeaveSyntaxError(
                f"unexpected character {ch!r}",
                line=lineno,
                col=col,
                filename=self.filename,
            )
        return depth, bracket_stack

    def _scan_string(self, line: str, start: int, lineno: int, col: int) -> Tuple[str, int]:
        quote = line[start]
        i = start + 1
        n = len(line)
        while i < n:
            ch = line[i]
            if ch == "\\":
                i += 2
                continue
            if ch == quote:
                return line[start : i + 1], i + 1
            i += 1
        raise WeaveSyntaxError(
            "unterminated string literal",
            line=lineno,
            col=col,
            hint="strings cannot span multiple lines in Weave",
            filename=self.filename,
        )


def tokenize(source: Source) -> List[Token]:
    return Tokenizer(source).tokenize()


# ---------------------------------------------------------------------------
# Small helpers used by the parser and code generator
# ---------------------------------------------------------------------------

_NO_SPACE_BEFORE = {RPAREN, RBRACK, RBRACE, COMMA, DOT, COLON}
_NO_SPACE_AFTER = {LPAREN, LBRACK, DOT, LBRACE}


def tokens_to_source(tokens: Iterable[Token]) -> str:
    """Reconstruct a canonical single-line code fragment from tokens."""
    out: List[str] = []
    prev: Optional[Token] = None
    for tok in tokens:
        if tok.kind in (NEWLINE, INDENT, DEDENT, EOF):
            continue
        if prev is not None and _needs_space(prev, tok):
            out.append(" ")
        out.append(tok.text)
        prev = tok
    return "".join(out)


def _needs_space(prev: Token, cur: Token) -> bool:
    if cur.kind in _NO_SPACE_BEFORE or prev.kind in _NO_SPACE_AFTER:
        return False
    if prev.kind in (COMMA, COLON, OP):
        return True
    if cur.kind in (OP,):
        return True
    if prev.kind in (NAME, NUMBER, STRING) and cur.kind in (NAME, NUMBER, STRING):
        return True
    return False
