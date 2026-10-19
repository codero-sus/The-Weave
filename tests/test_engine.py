"""Tests for the Weave frontend: tokenizer, parser, analyzer, codegen, renderer."""

from __future__ import annotations

import unittest

from the_weave import WeaveCompileError, WeaveRuntimeError, WeaveSyntaxError, compile_source
from the_weave.runtime import Context, to_jsonable
from the_weave.source import Source, Tokenizer

TODO = '''
app TodoApp:
    state:
        tasks = ["Learn Weave", "Build something cool"]
        new_task = ""

    view:
        stack(padding: 24, align: center):
            text("My Tasks", font: 28, bold: true)

            input(bind: new_task, placeholder: "Add a new task...", on_enter: {
                tasks.append(new_task)
                new_task = ""
            })

            for task in tasks:
                card(shadow: sm):
                    text(task)
                    button("Done", click: tasks.remove(task))
'''

KITCHEN = """
app Kitchen:
    theme:
        primary: "#5b5ef0"
        mode: auto

    styles:
        dashed:
            background: "transparent"
            border: "1px dashed var(--weave-border)"

    state:
        text_value = "hi"
        flag = true
        choice = "a"
        num = 3
        rows = [{"name": "Ada", "score": 3}]
        items = ["a", "b"]

    function double(n):
        return n * 2

    view:
        stack():
            row():
                text("r")
            grid(columns: 2):
                text("g")
            center():
                text("c")
            card(style: dashed):
                text("k")
            section(title: "S"):
                text("s")
            hero(title: "H", subtitle: "sub"):
                text("h")
            scroll():
                text("sc")
            form():
                text("f")
            tabs(bind: choice):
                tab("a")
                tab("b")
            divider()
            spacer()
            text(double(num))
            title("ti")
            label("l")
            code("c")
            badge("b")
            link("ln", href: "/x")
            image("/x.png", alt: "x")
            avatar("/a.png")
            icon("i")
            metric(num, "m")
            progress(num, 5)
            input(bind: text_value)
            textarea(bind: text_value)
            checkbox(bind: flag, label: "c")
            toggle(bind: flag, label: "t")
            select(bind: choice, options: ["a", "b"])
            slider(bind: num, min: 0, max: 5)
            button("b")
            icon_button("i")
            table(rows, columns: ["name", "score"])
            html("<b>raw</b>")
            for item in items:
                text(item)
            if flag:
                text("yes")
            else:
                text("no")
"""


def compile_ok(source: str, filename: str = "test.weave"):
    return compile_source(source, filename)


class TokenizerTests(unittest.TestCase):
    def test_indentation_tokens(self):
        tokens = Tokenizer(Source("app A:\n    view:\n        text(\"x\")\n")).tokenize()
        kinds = [t.kind for t in tokens]
        self.assertEqual(kinds.count("INDENT"), 2)
        self.assertEqual(kinds.count("DEDENT"), 2)

    def test_bracket_depth(self):
        tokens = Tokenizer(Source('text(a, (b, c), d)\n')).tokenize()
        commas = [t for t in tokens if t.kind == "COMMA"]
        self.assertEqual(len(commas), 3)
        self.assertTrue(any(t.depth == 2 for t in commas))

    def test_string_prefixes(self):
        tokens = Tokenizer(Source('x = f"hi {name}"\ny = r"raw"\n')).tokenize()
        strings = [t for t in tokens if t.kind == "STRING"]
        self.assertEqual(len(strings), 2)
        self.assertTrue(strings[0].text.startswith('f"'))
        self.assertEqual(strings[1].value, "raw")

    def test_tabs_are_rejected(self):
        with self.assertRaises(WeaveSyntaxError) as ctx:
            Tokenizer(Source("app A:\n\tview:\n")).tokenize()
        self.assertIn("tabs", ctx.exception.message)

    def test_unclosed_bracket(self):
        with self.assertRaises(WeaveSyntaxError) as ctx:
            Tokenizer(Source('text(a\n')).tokenize()
        self.assertIn("unclosed", ctx.exception.message)

    def test_unterminated_string(self):
        with self.assertRaises(WeaveSyntaxError) as ctx:
            Tokenizer(Source('text("oops)\n')).tokenize()
        self.assertIn("unterminated", ctx.exception.message)

    def test_comments_and_blank_lines(self):
        tokens = Tokenizer(Source("# hello\n\napp A:  # trailing\n")).tokenize()
        self.assertEqual([t.text for t in tokens if t.kind == "NAME"][:2], ["app", "A"])


class ParserTests(unittest.TestCase):
    def test_spec_example(self):
        program = compile_ok(TODO)
        app = program.app
        self.assertEqual(app.name, "TodoApp")
        self.assertEqual([d.name for d in app.state], ["tasks", "new_task"])
        self.assertEqual(len(app.view), 1)
        stack = app.view[0]
        self.assertEqual(stack.name, "stack")
        self.assertEqual(len(stack.children), 3)
        loop = stack.children[2]
        self.assertEqual(loop.target, "task")
        self.assertEqual(loop.iterable, "tasks")
        card = loop.children[0]
        self.assertEqual(card.name, "card")
        self.assertEqual(card.attrs["shadow"].expr, "sm")
        button = card.children[1]
        self.assertIn("click", button.attrs)
        self.assertEqual(button.attrs["click"].handler.captures, ["task"])

    def test_typed_state(self):
        program = compile_ok('''
app Typed:
    state:
        count: int = 0
        names: list[str] = ["a"]
    view:
        text(count)
''')
        self.assertEqual(program.app.state[0].type_name, "int")
        self.assertEqual(program.app.state[1].type_args[0].name, "str")

    def test_functions_routes_styles_theme(self):
        program = compile_ok('''
app Multi(title: "Multi"):
    theme:
        primary: "#111"
        radius: 20
    styles:
        panel:
            background: "var(--weave-surface)"
            padding: 12
    state:
        x = 1
    function inc(n):
        return n + 1
    view:
        text(inc(x))
    routes:
        "/about":
            text("about")
''')
        self.assertEqual(program.app.title, "Multi")
        self.assertEqual(program.app.theme["primary"], '"#111"')
        self.assertIn("panel", program.app.styles)
        self.assertEqual(program.app.functions[0].name, "inc")
        self.assertEqual([r.path for r in program.app.routes], ["/about"])

    def test_missing_app_header(self):
        with self.assertRaises(WeaveSyntaxError) as ctx:
            compile_ok('view:\n    text("x")\n')
        self.assertIn("app declaration", ctx.exception.message)

    def test_unknown_component_with_suggestion(self):
        with self.assertRaises(WeaveCompileError) as ctx:
            compile_ok('app A:\n    view:\n        txet("x")\n')
        self.assertIn("unknown component", ctx.exception.message)
        self.assertIn("text", ctx.exception.hint)

    def test_unknown_attribute_with_suggestion(self):
        with self.assertRaises(WeaveCompileError) as ctx:
            compile_ok('app A:\n    view:\n        text("x", boldd: true)\n')
        self.assertIn("unknown attribute", ctx.exception.message)
        self.assertIn("bold", ctx.exception.hint)

    def test_bind_requires_state(self):
        with self.assertRaises(WeaveCompileError) as ctx:
            compile_ok('app A:\n    state:\n        name = ""\n    view:\n        input(bind: nmae)\n')
        self.assertIn("bind", ctx.exception.message)
        self.assertIn("name", ctx.exception.hint)

    def test_unknown_name_in_view(self):
        with self.assertRaises(WeaveCompileError) as ctx:
            compile_ok('app A:\n    state:\n        tasks = []\n    view:\n        for t in taks:\n            text(t)\n')
        self.assertIn("unknown name 'taks'", ctx.exception.message)
        self.assertIn("tasks", ctx.exception.hint)

    def test_duplicate_state(self):
        with self.assertRaises(WeaveCompileError) as ctx:
            compile_ok('app A:\n    state:\n        a = 1\n        a = 2\n    view:\n        text(a)\n')
        self.assertIn("declared twice", ctx.exception.message)

    def test_duplicate_function(self):
        with self.assertRaises(WeaveCompileError):
            compile_ok('app A:\n    function f():\n        return 1\n    function f():\n        return 2\n    view:\n        text("x")\n')

    def test_handler_syntax_error(self):
        with self.assertRaises(WeaveCompileError) as ctx:
            compile_ok('''
app A:
    view:
        button("x", click: {
            x = = 1
        })
''')
        self.assertIn("invalid Python", ctx.exception.message)

    def test_empty_state_block(self):
        with self.assertRaises(WeaveSyntaxError):
            compile_ok('app A:\n    state:\n    view:\n        text("x")\n')

    def test_positional_before_named(self):
        with self.assertRaises(WeaveSyntaxError):
            compile_ok('app A:\n    view:\n        text(bold: true, "x")\n')

    def test_duplicate_attribute(self):
        with self.assertRaises(WeaveSyntaxError):
            compile_ok('app A:\n    view:\n        text("x", bold: true, bold: false)\n')

    def test_route_must_start_with_slash(self):
        with self.assertRaises(WeaveCompileError):
            compile_ok('app A:\n    view:\n        text("x")\n    routes:\n        "about":\n            text("y")\n')


class RenderTests(unittest.TestCase):
    def test_todo_markup(self):
        program = compile_ok(TODO)
        ctx = Context(program.new_state())
        result = program.render(ctx)
        self.assertIn("My Tasks", result.html)
        self.assertIn("Learn Weave", result.html)
        self.assertIn('data-weave-bind="new_task"', result.html)
        self.assertEqual(result.html.count("data-weave-click"), 2)
        self.assertEqual(result.html.count("data-weave-enter"), 2)  # wrapper + control
        self.assertEqual(len(result.bindings), 1)

    def test_html_escaping(self):
        program = compile_ok('''
app Safe:
    state:
        evil = "<script>alert('x')</script>"
    view:
        text(evil)
''')
        ctx = Context(program.new_state())
        html = program.render(ctx).html
        self.assertNotIn("<script>alert", html)
        self.assertIn("&lt;script&gt;", html)

    def test_attribute_escaping(self):
        program = compile_ok('''
app Safe:
    state:
        evil = '"><img src=x onerror=alert(1)>'
    view:
        input(placeholder: evil)
''')
        html = program.render(Context(program.new_state())).html
        self.assertNotIn('"><img', html)
        self.assertNotIn("<img src=x", html)
        self.assertIn("&quot;&gt;&lt;img", html)

    def test_conditionals_and_loops(self):
        program = compile_ok('''
app Cond:
    state:
        items = [{"name": "a", "done": true}, {"name": "b", "done": false}]
    view:
        for i, item in items:
            if item["done"]:
                badge(f"{i}:{item['name']}", variant: success)
            else:
                text(f"{i}:{item['name']}")
''')
        html = program.render(Context(program.new_state())).html
        self.assertIn("0:a", html)
        self.assertIn("1:b", html)
        self.assertIn("weave-badge", html)

    def test_every_component_renders(self):
        program = compile_ok(KITCHEN)
        result = program.render(Context(program.new_state()))
        self.assertEqual(result.status, 200)
        self.assertIn("<table", result.html)
        self.assertIn("raw", result.html)
        self.assertIn("weave-tabs", result.html)
        self.assertIn("dashed", result.html)  # named style resolved
        self.assertIn("6", result.html)  # double(3)

    def test_unknown_route_status(self):
        program = compile_ok("""
app Routed:
    view:
        text("home")
    routes:
        "/about":
            text("about")
""")
        ctx = Context(program.new_state())
        self.assertEqual(program.render(ctx, "/about").status, 200)
        missing = program.render(ctx, "/nope")
        self.assertEqual(missing.status, 404)
        self.assertIn("No page at", missing.html)

    def test_named_style(self):
        program = compile_ok('''
app Styled:
    styles:
        panel:
            background: "red"
            padding: 8
    view:
        card(style: panel)
''')
        html = program.render(Context(program.new_state())).html
        self.assertIn("background: red", html)
        self.assertIn("padding: 8px", html)

    def test_state_isolation(self):
        program = compile_ok(TODO)
        a = program.new_state()
        b = program.new_state()
        a["tasks"].append("mutated")
        self.assertNotIn("mutated", b["tasks"])

    def test_theme_defaults_and_colors(self):
        program = compile_ok('''
app Theme:
    view:
        card(background: primary):
            text("hi", color: primary)
''')
        html = program.render(Context(program.new_state())).html
        self.assertIn("var(--weave-primary)", html)

    def test_local_assets_are_rewritten(self):
        program = compile_ok("""
app Assets:
    view:
        image("logo.png")
        image("https://example.com/x.png")
        avatar("/static/me.png")
""")
        html = program.render(Context(program.new_state())).html
        self.assertIn('src="/assets/logo.png"', html)
        self.assertIn('src="https://example.com/x.png"', html)
        self.assertIn('src="/static/me.png"', html)

    def test_bareword_attribute(self):
        program = compile_ok('''
app Bare:
    view:
        input(type: email)
        text("x", align: center)
''')
        html = program.render(Context(program.new_state())).html
        self.assertIn('type="email"', html)
        self.assertIn("text-align: center", html)


class RuntimeTests(unittest.TestCase):
    def setUp(self):
        self.program = compile_ok(TODO)
        self.ctx = Context(self.program.new_state())

    def _event(self, path, event):
        result = self.program.render(self.ctx)
        binding = result.events[path][event][0]
        return binding

    def test_enter_appends_and_clears(self):
        self.ctx.st["new_task"] = "Ship it"
        binding = self._event("r.0.1", "enter")
        self.program.execute_handler(binding.func_name, self.ctx, binding.captures)
        self.assertEqual(self.ctx.st["tasks"][-1], "Ship it")
        self.assertEqual(self.ctx.st["new_task"], "")

    def test_click_removes_captured_item(self):
        binding = self._event("r.0.2$0.0.1", "click")
        self.assertEqual(binding.captures["task"], "Learn Weave")
        self.program.execute_handler(binding.func_name, self.ctx, binding.captures)
        self.assertNotIn("Learn Weave", self.ctx.st["tasks"])

    def test_augassign_and_function_calls(self):
        program = compile_ok('''
app Counter:
    state:
        count = 0
    function add(a, b):
        return a + b
    view:
        text(count)
        button("+", click: {
            count = add(count, 1)
            count += 1
        })
''')
        ctx = Context(program.new_state())
        result = program.render(ctx)
        binding = result.events["r.1"]["click"][0]
        program.execute_handler(binding.func_name, ctx, binding.captures)
        self.assertEqual(ctx.st["count"], 2)

    def test_mutating_captured_dict(self):
        program = compile_ok('''
app Dicts:
    state:
        rows = [{"done": false}]
    view:
        for row in rows:
            button("toggle", click: {
                row["done"] = not row["done"]
            })
''')
        ctx = Context(program.new_state())
        result = program.render(ctx)
        binding = result.events["r.0$0.0"]["click"][0]
        program.execute_handler(binding.func_name, ctx, binding.captures)
        self.assertTrue(ctx.st["rows"][0]["done"])

    def test_toast_and_navigate(self):
        program = compile_ok('''
app Effects:
    view:
        button("go", click: {
            toast("hello", "success")
            navigate("/next")
        })
''')
        ctx = Context(program.new_state())
        binding = program.render(ctx).events["r.0"]["click"][0]
        program.execute_handler(binding.func_name, ctx, binding.captures)
        self.assertEqual(ctx.toasts[0]["message"], "hello")
        self.assertEqual(ctx.redirect, "/next")

    def test_runtime_error_has_location(self):
        program = compile_ok('''
app Boom:
    state:
        x = 1
    view:
        button("boom", click: {
            x = x / 0
        })
''')
        ctx = Context(program.new_state())
        binding = program.render(ctx).events["r.0"]["click"][0]
        with self.assertRaises(WeaveRuntimeError) as cm:
            program.execute_handler(binding.func_name, ctx, binding.captures)
        self.assertIn("ZeroDivisionError", cm.exception.message)
        self.assertGreaterEqual(cm.exception.line, 5)
        self.assertEqual(ctx.st["x"], 1)  # untouched because assignment never ran

    def test_fstring_and_helpers(self):
        program = compile_ok('''
app Helpers:
    state:
        names = ["Ada", "Grace"]
    view:
        text(", ".join(names), bold: true)
        text(plural(len(names), "person", "people"))
''')
        html = program.render(Context(program.new_state())).html
        self.assertIn("Ada, Grace", html)
        self.assertIn("2 people", html)

    def test_mixed_inline_handler_block(self):
        program = compile_ok("""
app Mixed:
    view:
        button("x", click: { toast("one")
            toast("two") })
""")
        ctx = Context(program.new_state())
        binding = program.render(ctx).events["r.0"]["click"][0]
        program.execute_handler(binding.func_name, ctx, binding.captures)
        self.assertEqual([t["message"] for t in ctx.toasts], ["one", "two"])

    def test_jsonable_state(self):
        program = compile_ok('''
app J:
    state:
        when = datetime.date(2026, 1, 2)
        tags = {"a", "b"}
    view:
        text(str(when))
''')
        data = to_jsonable(program.new_state())
        self.assertEqual(data["when"], "2026-01-02")
        self.assertEqual(sorted(data["tags"]), ["a", "b"])

    def test_initial_state_uses_helpers(self):
        program = compile_ok('''
app Init:
    state:
        title = "  hello world  ".strip().title()
        n = len([1, 2, 3])
    view:
        text(title)
''')
        state = program.new_state()
        self.assertEqual(state["title"], "Hello World")
        self.assertEqual(state["n"], 3)

    def test_typed_state_mismatch(self):
        with self.assertRaises(WeaveCompileError) as ctx:
            compile_ok('app A:\n    state:\n        n: int = "oops"\n    view:\n        text(n)\n')
        self.assertIn("declared as int", ctx.exception.message)


if __name__ == "__main__":
    unittest.main()
