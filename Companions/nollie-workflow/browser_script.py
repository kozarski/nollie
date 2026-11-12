"""What a ``browser_exec`` script does, read step by step from its code, never run.

Hermes 0.23 drives the browser with one tool, ``browser_exec``: its ``code`` is Python with browser helpers
already imported (``new_tab``, ``goto_url``, ``wait_for_load``, ``page_info``, ``js``, ``fill_input``,
``click_at_xy``, ``capture_screenshot``, ``cdp``, ``ensure_real_tab``), so one call can open a page, type, click
and submit. This reads the code with Python's own parser and lists each helper it calls, with the words, keys,
addresses and page scripts it passes where they can be worked out from the code itself.

Anything it can't follow is said plainly in ``problem`` (code that isn't Python, a helper passed around or
looked up by name, code built while it runs, a helper Nollie doesn't know), and Ask first asks for it.
Ask first judges the steps; Night shift, receipts and Papertrail use ``label`` and ``opened``.
"""
from __future__ import annotations

import ast
import builtins
from dataclasses import dataclass, field
import io
import itertools
import json
import re
import tokenize
from urllib.parse import urlsplit

TOOL = "browser_exec"
SCRIPT_LIMIT = 256 * 1024
# Values a name or an f-string may take, worked out from the code. More than this reads as unknown.
VALUE_LIMIT = 32

# The helpers, by what they do. Hermes lists the first ten; the rest are browser-harness helpers a script may
# also call, judged as plainly as their names say.
HELPERS = {
    "new_tab": "open", "goto_url": "open", "goto": "open", "navigate": "open", "open_url": "open",
    "wait_for_load": "wait", "wait": "wait", "wait_for": "wait", "wait_for_selector": "wait", "sleep": "wait",
    "page_info": "read", "capture_screenshot": "read", "screenshot": "read", "get_html": "read",
    "get_text": "read", "page_text": "read", "scroll": "read", "scroll_by": "read", "scroll_to": "read",
    "ensure_real_tab": "tab", "switch_tab": "tab", "list_tabs": "tab", "current_tab": "tab", "close_tab": "tab",
    "js": "js", "evaluate": "js", "run_js": "js",
    "fill_input": "fill", "type_text": "fill", "fill": "fill",
    "click_at_xy": "click", "click": "click", "double_click": "click",
    "press_key": "press", "press": "press", "key": "press",
    "cdp": "cdp",
}
# Plain Python the scripts use around the helpers (Python's own built-ins, less the ones that build code, below).
# Calls to other bare names need the code to define or import them.
BUILTINS = frozenset(name for name in dir(builtins) if not name.startswith("_")) - frozenset((
    "eval", "exec", "compile", "getattr", "setattr", "delattr", "globals", "locals", "vars", "breakpoint", "input",
    "help", "exit", "quit", "copyright", "credits", "license"))
# Short helper names that also name methods of ordinary objects (``time.sleep``, ``page.wait``): a helper only
# when called by its bare name.
BARE_ONLY = frozenset(("goto", "navigate", "open_url", "wait", "wait_for", "wait_for_selector", "sleep", "screenshot",
                       "get_html", "get_text", "page_text", "scroll", "scroll_by", "scroll_to", "close_tab", "evaluate",
                       "run_js", "fill", "click", "double_click", "press", "key"))
# Page actions of a browser library a script may import (Playwright, Selenium), called as methods.
PAGE_ACTIONS = {"click": "click", "dblclick": "click", "tap": "click", "check": "click", "uncheck": "click",
                "select_option": "click", "submit": "click", "dispatch_event": "click", "press": "press",
                "send_keys": "press", "type": "fill", "fill": "fill", "press_sequentially": "fill",
                "set_input_files": "fill", "evaluate": "js", "execute_script": "js", "goto": "open"}
# Code that builds or finds code while it runs: what it does can't be read from the script.
DYNAMIC = frozenset(("eval", "exec", "compile", "__import__", "getattr", "setattr", "delattr", "globals",
                     "locals", "vars", "breakpoint"))
DYNAMIC_ATTRS = frozenset(("import_module", "__builtins__", "__dict__", "__getattribute__", "__globals__",
                           "__code__", "__call__", "__class__", "__subclasses__"))
SECRET_WORDS = re.compile(r"(?i)pass(word|wd|code)?|secret|token|card|cvv|cvc|otp|pin\b|security.?code|iban|ssn")


@dataclass
class Step:
    """One helper call. ``values`` holds every string the argument may be, or None when the code doesn't say."""

    kind: str  # open, wait, read, tab, js, fill, click, press, cdp, unknown
    name: str
    line: int
    urls: list | None = None
    selector: list | None = None
    text: list | None = None
    point: tuple | None = None
    method: list | None = None
    params: dict | None = None
    params_known: bool = True


@dataclass
class Script:
    steps: list = field(default_factory=list)
    problem: str | None = None
    comments: list = field(default_factory=list)


def _cap(values):
    return values if values is not None and len(values) <= VALUE_LIMIT else None


class _Values:
    """The strings each plain name may hold, from every place the code sets it. One unknown makes it unknown."""

    def __init__(self, tree):
        self.known = {}
        self.unknown = set()
        self.defined = set()
        self.imported = set()
        for node in ast.walk(tree):
            if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef, ast.ClassDef)):
                self.defined.add(node.name)
                for arg in ast.walk(node.args) if not isinstance(node, ast.ClassDef) else ():
                    if isinstance(arg, ast.arg):
                        self.unknown.add(arg.arg)
            elif isinstance(node, ast.Lambda):
                for arg in ast.walk(node.args):
                    if isinstance(arg, ast.arg):
                        self.unknown.add(arg.arg)
            elif isinstance(node, (ast.Import, ast.ImportFrom)):
                for alias in node.names:
                    self.imported.add((alias.asname or alias.name).split(".")[0])
            elif isinstance(node, ast.Assign):
                for target in node.targets:
                    self._set(target, node.value)
            elif isinstance(node, (ast.AnnAssign,)) and node.value is not None:
                self._set(node.target, node.value)
            elif isinstance(node, (ast.AugAssign,)):
                self._forget(node.target)
            elif isinstance(node, (ast.For, ast.AsyncFor)):
                self._loop(node.target, node.iter)
            elif isinstance(node, ast.comprehension):
                self._loop(node.target, node.iter)
            elif isinstance(node, (ast.With, ast.AsyncWith)):
                for item in node.items:
                    if item.optional_vars is not None:
                        self._forget(item.optional_vars)
            elif isinstance(node, ast.ExceptHandler) and node.name:
                self.unknown.add(node.name)
            elif isinstance(node, ast.NamedExpr):
                self._set(node.target, node.value)
            elif isinstance(node, (ast.Global, ast.Nonlocal)):
                self.unknown.update(node.names)
        # A name set from a lambda or a def is something the code defined itself.
        for name in list(self.known):
            if name in self.unknown:
                self.known.pop(name)

    def _forget(self, target):
        for node in ast.walk(target):
            if isinstance(node, ast.Name):
                self.unknown.add(node.id)

    def _set(self, target, value):
        if isinstance(target, ast.Name):
            if isinstance(value, ast.Lambda):
                self.defined.add(target.id)
                return
            self.known.setdefault(target.id, []).append(value)
        else:
            self._forget(target)

    def _loop(self, target, iterable):
        if isinstance(target, ast.Name) and isinstance(iterable, (ast.List, ast.Tuple, ast.Set)):
            for item in iterable.elts:
                self.known.setdefault(target.id, []).append(item)
        else:
            self._forget(target)

    def strings(self, node, depth=0):
        """Every string ``node`` may be, or None when the code doesn't say."""
        if depth > 12 or node is None:
            return None
        if isinstance(node, ast.Constant):
            if isinstance(node.value, str):
                return [node.value]
            if isinstance(node.value, (int, float, bool)) or node.value is None:
                return [str(node.value)]
            return None
        if isinstance(node, ast.Name):
            if node.id in self.unknown or node.id not in self.known:
                return None
            found = []
            for value in self.known[node.id]:
                more = self.strings(value, depth + 1)
                if more is None:
                    return None
                found.extend(more)
            return _cap(list(dict.fromkeys(found)))
        if isinstance(node, ast.JoinedStr):
            parts = []
            for part in node.values:
                if isinstance(part, ast.FormattedValue):
                    found = self.strings(part.value, depth + 1)
                    if found is not None and part.conversion == ord("r"):
                        found = [repr(f) for f in found]
                else:
                    found = self.strings(part, depth + 1)
                if found is None:
                    return None
                parts.append(found)
            return self._product(parts)
        if isinstance(node, ast.BinOp) and isinstance(node.op, ast.Add):
            left, right = self.strings(node.left, depth + 1), self.strings(node.right, depth + 1)
            return None if left is None or right is None else self._product([left, right])
        if isinstance(node, ast.IfExp):
            body, other = self.strings(node.body, depth + 1), self.strings(node.orelse, depth + 1)
            return None if body is None or other is None else _cap(list(dict.fromkeys(body + other)))
        if isinstance(node, ast.Call) and isinstance(node.func, ast.Attribute) and node.func.attr == "dumps" \
                and isinstance(node.func.value, ast.Name) and node.func.value.id == "json" and len(node.args) == 1:
            found = self.strings(node.args[0], depth + 1)
            return None if found is None else [json.dumps(f) for f in found]
        return None

    @staticmethod
    def _product(parts):
        total = 1
        for part in parts:
            total *= max(1, len(part))
            if total > VALUE_LIMIT:
                return None
        return ["".join(p) for p in itertools.product(*parts)]

    def number(self, node):
        if isinstance(node, ast.Constant) and isinstance(node.value, (int, float)) and not isinstance(node.value, bool):
            return node.value
        if isinstance(node, ast.UnaryOp) and isinstance(node.op, ast.USub):
            found = self.number(node.operand)
            return None if found is None else -found
        return None


def _argument(call, index, names):
    for keyword in call.keywords:
        if keyword.arg in names:
            return keyword.value
    return call.args[index] if len(call.args) > index else None


def _helper_name(func):
    if isinstance(func, ast.Name):
        return func.id
    if isinstance(func, ast.Attribute):
        return func.attr
    return None


def _comments(code):
    found = []
    try:
        for token in tokenize.generate_tokens(io.StringIO(code).readline):
            if token.type == tokenize.COMMENT:
                found.append(token.string.lstrip("#").strip())
    except (tokenize.TokenError, IndentationError, SyntaxError):
        pass
    return found


class _Reader(ast.NodeVisitor):
    def __init__(self, values):
        self.values = values
        self.steps = []
        self.problems = []
        self.calls = set()

    def _bound(self, name):
        values = self.values
        return name in values.known or name in values.unknown or name in values.defined or name in values.imported

    def visit_Call(self, node):
        name = _helper_name(node.func)
        self.calls.add(id(node.func))
        bare = isinstance(node.func, ast.Name)
        if bare and name in DYNAMIC:
            self.problems.append("the script builds or looks up code while it runs")
        elif not bare and name in DYNAMIC_ATTRS:
            self.problems.append("the script builds or looks up code while it runs")
        elif name in HELPERS and (bare or name not in BARE_ONLY):
            self.steps.append(self._step(HELPERS[name], name, node))
        elif not bare and name in PAGE_ACTIONS:
            self.steps.append(self._step(PAGE_ACTIONS[name], name, node))
        elif bare and name not in BUILTINS and not self._bound(name):
            self.steps.append(Step("unknown", name, node.lineno))
        elif not isinstance(node.func, (ast.Name, ast.Attribute)):
            # f()(), (a or b)(...), helpers[0](...): what runs can't be read.
            if any(isinstance(n, ast.Name) and n.id in HELPERS for n in ast.walk(node.func)):
                self.problems.append("the script uses a browser helper in a way Nollie can't follow")
        self.generic_visit(node)

    def visit_Name(self, node):
        if id(node) not in self.calls and isinstance(node.ctx, ast.Load):
            if node.id in DYNAMIC or node.id in ("__builtins__", "builtins"):
                self.problems.append("the script builds or looks up code while it runs")
            elif node.id in HELPERS and not self._bound(node.id):
                self.problems.append("the script uses a browser helper in a way Nollie can't follow")

    def visit_Attribute(self, node):
        if id(node) not in self.calls and node.attr in DYNAMIC_ATTRS:
            self.problems.append("the script builds or looks up code while it runs")
        self.generic_visit(node)

    def _step(self, kind, name, call):
        values = self.values
        step = Step(kind, name, call.lineno)
        if kind == "open":
            step.urls = values.strings(_argument(call, 0, ("url", "href", "address")))
        elif kind == "js":
            step.text = values.strings(_argument(call, 0, ("expr", "expression", "code", "script", "js", "source")))
        elif kind == "fill":
            if name == "type_text" or (name in ("type", "press_sequentially", "fill") and len(call.args) < 2
                                       and not any(k.arg in ("selector", "sel") for k in call.keywords)):
                step.selector, step.text = [], values.strings(_argument(call, 0, ("text", "value")))
            else:
                step.selector = values.strings(_argument(call, 0, ("selector", "sel", "target")))
                step.text = values.strings(_argument(call, 1, ("text", "value")))
        elif kind == "click":
            if name == "click_at_xy" or (name in ("click", "double_click") and len(call.args) >= 2
                                         and all(isinstance(a, ast.Constant) and isinstance(a.value, (int, float))
                                                 for a in call.args[:2])):
                x, y = (_argument(call, 0, ("x",)), _argument(call, 1, ("y",)))
                step.point = (values.number(x), values.number(y))
            else:
                step.selector = values.strings(_argument(call, 0, ("selector", "sel", "target", "text")))
        elif kind == "press":
            step.text = values.strings(_argument(call, 0, ("key", "keys", "combo")))
        elif kind == "cdp":
            step.method = values.strings(_argument(call, 0, ("method",)))
            params, known = {}, True
            for keyword in call.keywords:
                if keyword.arg is None:
                    if isinstance(keyword.value, ast.Dict):
                        for key, value in zip(keyword.value.keys, keyword.value.values):
                            key_text = values.strings(key) if key is not None else None
                            if not key_text or len(key_text) != 1:
                                known = False
                                continue
                            params[key_text[0]] = _param(values, value)
                    else:
                        known = False
                elif keyword.arg != "method":
                    params[keyword.arg] = _param(values, keyword.value)
            if len(call.args) > 1:
                second = call.args[1]
                if isinstance(second, ast.Dict):
                    for key, value in zip(second.keys, second.values):
                        key_text = values.strings(key) if key is not None else None
                        if key_text and len(key_text) == 1:
                            params[key_text[0]] = _param(values, value)
                        else:
                            known = False
                else:
                    known = False
            step.params, step.params_known = params, known
        return step


def _param(values, node):
    """A CDP parameter: its strings, a number, True or False, or None when the code doesn't say."""
    if isinstance(node, ast.Constant) and isinstance(node.value, bool):
        return node.value
    number = values.number(node)
    if number is not None:
        return number
    if isinstance(node, ast.Dict):
        found = {}
        for key, value in zip(node.keys, node.values):
            key_text = values.strings(key) if key is not None else None
            if key_text and len(key_text) == 1:
                found[key_text[0]] = _param(values, value)
            else:
                return None
        return found
    return values.strings(node)


def parse(code):
    """The script's steps in the order they're written, and why it can't be read, if it can't."""
    if not isinstance(code, str):
        return Script(problem="the script isn't text")
    if len(code) > SCRIPT_LIMIT:
        return Script(problem="the script is too long to read")
    try:
        tree = ast.parse(code)
    except (SyntaxError, ValueError, MemoryError, RecursionError):
        return Script(problem="the script isn't Python Nollie can read", comments=_comments(code))
    try:
        values = _Values(tree)
        reader = _Reader(values)
        reader.visit(tree)
    except RecursionError:
        return Script(problem="the script is too deeply nested to read", comments=_comments(code))
    steps = sorted(reader.steps, key=lambda s: s.line)
    problem = reader.problems[0] if reader.problems else None
    return Script(steps=steps, problem=problem, comments=_comments(code))


LOOK_HELPERS = frozenset(name for name, kind in HELPERS.items() if kind in ("read", "wait", "tab")) - {"close_tab"}


def only_looks(code):
    """True for a script that does nothing but read the page already open, wait or pick a tab: each line one such
    helper, printed or not, given only plain values. Any other Python, however harmless, is not read as a look."""
    if not isinstance(code, str) or not code.strip() or len(code) > SCRIPT_LIMIT:
        return False
    try:
        tree = ast.parse(code)
    except (SyntaxError, ValueError, MemoryError, RecursionError):
        return False

    def look(node):
        return (isinstance(node, ast.Call) and isinstance(node.func, ast.Name) and node.func.id in LOOK_HELPERS
                and all(isinstance(a, ast.Constant) for a in node.args)
                and all(isinstance(k.value, ast.Constant) and k.arg for k in node.keywords))

    for statement in tree.body:
        if not isinstance(statement, ast.Expr):
            return False
        value = statement.value
        if isinstance(value, ast.Call) and isinstance(value.func, ast.Name) and value.func.id == "print" \
                and not value.keywords and len(value.args) == 1:
            value = value.args[0]
        if not look(value):
            return False
    return bool(tree.body)


# Plain labels ----------------------------------------------------------------------------------

def _page(url):
    """``bbc.co.uk/weather`` from ``https://www.bbc.co.uk/weather?x=1``: host and path, never the query."""
    try:
        parts = urlsplit(str(url).strip())
    except ValueError:
        return None
    if parts.scheme not in ("http", "https") or not parts.hostname:
        return None
    host = parts.hostname.removeprefix("www.")
    path = parts.path.rstrip("/")
    shown = host + (path if len(path) <= 60 else path[:59] + "…")
    return shown[:120]


def _host(url):
    try:
        host = urlsplit(str(url).strip()).hostname or ""
    except ValueError:
        return None
    return host.removeprefix("www.") or None


def opened(script):
    """Every page address the script opens, as far as the code says."""
    found = []
    for step in script.steps:
        if step.kind == "open" and step.urls:
            found.extend(step.urls)
        if step.kind == "cdp" and step.method and any(m in ("Page.navigate", "Target.createTarget") for m in step.method):
            url = (step.params or {}).get("url")
            if isinstance(url, list):
                found.extend(url)
    return found


def opens(script):
    """How many pages the script loads: each navigation it makes, at least one."""
    count = sum(1 for step in script.steps if step.kind == "open" or (
        step.kind == "cdp" and step.method and any(m in ("Page.navigate", "Target.createTarget") for m in step.method)))
    return max(1, count)


_LABEL_TEXT = re.compile(r"""(?:textContent|innerText|innerHTML|value|title|ariaLabel|label|name)\s*(?:\.\s*trim\s*\(\s*\))?\s*"""
                         r"""(?:===?|\.\s*(?:includes|startsWith|endsWith)\s*\()\s*(['"`])((?:(?!\1).){1,80})\1""")
_ATTR_LABEL = re.compile(r"""\[\s*(?:aria-label|title|value|name|alt|data-testid)\s*[\^$*~|]?=\s*(?:\\?['"])((?:(?!['"\\]).){1,80})""")
_TEXT_SELECTOR = re.compile(r"""^(?:text=|:?has-text\(|button:has-text\(|//\*?\[contains\(text\(\),\s*['"])"""
                            r"""['"]?([^'")]{1,80})""")


def click_words(text):
    """The words a page script clicks by: ``Place order`` from ``.find(b => b.textContent.trim() === 'Place order')
    .click()``, or from a ``[aria-label="Place order"]`` selector."""
    found = [m.group(2) for m in _LABEL_TEXT.finditer(text)] + [m.group(1) for m in _ATTR_LABEL.finditer(text)]
    return [f.strip() for f in found if f.strip()]


CLICKS_IN_JS = re.compile(r"\.\s*(click|dblclick|submit|requestSubmit)\s*\(|dispatchEvent\s*\(|\.focus\(\)[^;]*keydown")


def _first_host(script):
    for url in opened(script):
        host = _host(url)
        if host:
            return host
    return None


def label(code):
    """A short plain label for one ``browser_exec`` call, from what the script does: "Opened bbc.co.uk/weather",
    "Filled in a form on shop.example.com", "Clicked Place order". Never from the script's own comment."""
    script = parse(code) if not isinstance(code, Script) else code
    if script.problem and not script.steps:
        return "Used the browser"
    host = _first_host(script)
    on = f" on {host}" if host else ""
    clicked = None
    clicks = 0
    for step in script.steps:
        if step.kind == "click":
            clicks += 1
            if step.selector and len(step.selector) == 1:
                words = click_words(step.selector[0]) or _selector_words(step.selector[0])
                clicked = clicked or (words[0] if words else None)
        elif step.kind == "js" and step.text and any(CLICKS_IN_JS.search(t) for t in step.text):
            clicks += 1
            words = [w for t in step.text for w in click_words(t)]
            clicked = clicked or (words[0] if len(set(words)) == 1 else None)
        elif step.kind == "cdp" and step.method and any(m == "Input.dispatchMouseEvent" for m in step.method):
            if (step.params or {}).get("type") in (["mousePressed"], ["mouseReleased"]):
                clicks += 1
    filled = any(s.kind == "fill" for s in script.steps) or any(
        s.kind == "js" and s.text and any(re.search(r"\.value\s*=(?!=)", t) for t in s.text) for s in script.steps)
    pressed = any(s.kind == "press" or (s.kind == "cdp" and s.method and "Input.dispatchKeyEvent" in s.method)
                  for s in script.steps)
    if clicks:
        if clicked and not SECRET_WORDS.search(clicked):
            return f"Clicked {_short(clicked)}"
        return f"Filled in a form{on}" if filled else f"Clicked on a page{on}"
    if filled:
        return f"Filled in a form{on}"
    if pressed:
        return f"Pressed a key{on}"
    pages = [p for p in (_page(u) for u in opened(script)) if p]
    if pages:
        more = len(dict.fromkeys(pages)) - 1
        return f"Opened {pages[0]}" + (f" and {more} more page{'s' if more > 1 else ''}" if more else "")
    if any(s.kind == "open" for s in script.steps):
        return "Opened a page"
    if any(s.kind in ("js", "read") for s in script.steps):
        return "Read a page"
    return "Used the browser"


def _selector_words(selector):
    words = re.sub(r"[#.\[\]=\"'_:>()-]+", " ", str(selector)).split()
    words = [w for w in words if w.lower() not in ("button", "input", "a", "div", "span", "type", "submit", "btn",
                                                    "id", "class", "role", "form")]
    return [" ".join(words)] if words else []


def _short(text):
    text = re.sub(r"\s+", " ", str(text)).strip()
    return text if len(text) <= 60 else text[:59] + "…"
