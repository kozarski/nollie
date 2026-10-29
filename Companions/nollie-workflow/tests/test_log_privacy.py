import ast
import importlib.util
import io
import logging
import os
from pathlib import Path
import re
import sys
from types import SimpleNamespace
import unittest

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("log_privacy_under_test", ROOT / "log_privacy.py")
log_privacy = importlib.util.module_from_spec(spec)
spec.loader.exec_module(log_privacy)

# The pinned Hermes source, when this Mac has a copy: the templates are checked against it.
SOURCES = [Path(os.environ["NOLLIE_HERMES_SOURCE"])] if os.environ.get("NOLLIE_HERMES_SOURCE") else [
    Path.home() / "code/nollie-worktrees/hermes-v0.22.2", Path.home() / ".hermes" / "hermes-agent"]
HERMES = next((path for path in SOURCES if (path / "agent" / "turn_context.py").is_file()), None)
WORDY = re.compile(r"(^|_)(text|message|msg|prompt|content|response|reply|query|caption|body|preview|snippet|steer)(_|$)",
                   re.I)


def record(template, *args, name="agent.turn_context"):
    return logging.LogRecord(name, logging.INFO, __file__, 1, template, args, None)


def word_calls(root):
    """Every Hermes log call that passes a slice of something named like words: (file, line, template, args)."""
    def name_of(node):
        if isinstance(node, ast.Name):
            return node.id
        if isinstance(node, ast.Attribute):
            return node.attr
        if isinstance(node, ast.Call):
            return name_of(node.func)
        return ""

    def base(node):
        if isinstance(node, ast.BoolOp):
            return any(base(value) for value in node.values)
        if isinstance(node, ast.Call):
            if isinstance(node.func, ast.Attribute) and node.func.attr in ("replace", "strip"):
                return base(node.func.value)
            return any(base(arg) for arg in node.args)
        return bool(WORDY.search(name_of(node) or "-"))

    def wordy(node):
        if isinstance(node, ast.Subscript) and isinstance(node.slice, ast.Slice):
            return base(node.value)
        if isinstance(node, ast.Call) and isinstance(node.func, ast.Attribute) and node.func.attr in ("replace", "strip"):
            return wordy(node.func.value)
        if isinstance(node, ast.IfExp):
            return wordy(node.body) or wordy(node.orelse)
        if isinstance(node, ast.BinOp):
            return wordy(node.left)
        return False

    for path in sorted(root.rglob("*.py")):
        if {"tests", "node_modules", "website"} & set(path.relative_to(root).parts):
            continue
        try:
            tree = ast.parse(path.read_text())
        except (SyntaxError, UnicodeDecodeError, ValueError):
            continue
        for node in ast.walk(tree):
            if not (isinstance(node, ast.Call) and isinstance(node.func, ast.Attribute)
                    and node.func.attr in ("info", "warning", "error", "exception", "critical")
                    and name_of(node.func.value) in ("logger", "log", "_logger", "LOGGER", "logging", "_log")
                    and node.args and isinstance(node.args[0], ast.Constant) and isinstance(node.args[0].value, str)):
                continue
            words = tuple(index for index, arg in enumerate(node.args[1:]) if wordy(arg))
            if words:
                yield path.relative_to(root), node.lineno, node.args[0].value, words


class LogPrivacyTests(unittest.TestCase):
    def setUp(self):
        self.factory = logging.getLogRecordFactory()
        self.addCleanup(logging.setLogRecordFactory, self.factory)
        log_privacy._recent.clear()
        self.addCleanup(log_privacy._recent.clear)

    def test_the_turn_line_keeps_everything_but_the_words(self):
        template = "conversation turn: session=%s model=%s provider=%s platform=%s history=%d msg=%r"
        line = log_privacy.scrub(record(template, "s-1", "m", "p", "api", 3, "Book me a table at Rosa's for six"))
        self.assertEqual(line.getMessage(),
                         "conversation turn: session=s-1 model=m provider=p platform=api history=3 msg='[left out]'")
        line = log_privacy.scrub(record(template + " origin=%s", "s", "m", "p", "x", 0, "private words", "fork"))
        self.assertNotIn("private words", line.getMessage())
        self.assertTrue(line.getMessage().endswith("origin=fork"))

    def test_chat_app_lines_and_prompts_leave_their_words_out(self):
        cases = [
            ("inbound message: platform=%s user=%s chat=%s msg=%r reply_to_id=%s reply_to_text=%r",
             ("telegram", "corey", "42", "my words", "7", "their words")),
            ("Prompt: %s", ("every morning check the news",)),
            ("User prompt: %s", ("what is in this photo",)),
            ("Generating image with %s (%s) — prompt: %s", ("svc", "model", "a cat on my sofa")),
            ("[sms] inbound from %s -> %s: %s", ("+44***", "+44***", "see you at six")),
        ]
        for template, args in cases:
            message = log_privacy.scrub(record(template, *args)).getMessage()
            for word in ("my words", "their words", "news", "photo", "sofa", "six"):
                self.assertNotIn(word, message, template)
            self.assertIn("[left out]", message)

    def test_any_other_msg_field_is_left_out_too(self):
        message = log_privacy.scrub(record("relay got msg=%r from %s", "hello there", "peer")).getMessage()
        self.assertEqual(message, "relay got msg='[left out]' from peer")
        self.assertEqual(log_privacy.word_arguments("a %d%% b msg=%s c=%s"), (1,))
        self.assertEqual(log_privacy.word_arguments("nothing here %s"), ())

    def test_a_message_quoted_anywhere_later_is_left_out(self):
        log_privacy.remember("Please draft a polite note to the landlord about the boiler")
        log_privacy.remember("short")
        message = log_privacy.scrub(record("Delivery failed for %s: %r", "chat-9",
                                           "Please draft a polite note to the landlord about the boiler",
                                           name="gateway.delivery")).getMessage()
        self.assertEqual(message, "Delivery failed for chat-9: '[left out]'")
        quoted = log_privacy.scrub(record("x %s", "head Please draft a polite note to the land tail")).getMessage()
        self.assertEqual(quoted, "x head [left out] tail")
        untouched = log_privacy.scrub(record("tool %s ran in %dms", "web_search", 12)).getMessage()
        self.assertEqual(untouched, "tool web_search ran in 12ms")

    def test_a_record_it_cannot_read_is_left_alone(self):
        odd = record("broken %s %s", "only one")
        self.assertIs(log_privacy.scrub(odd), odd)
        self.assertEqual(odd.args, ("only one",))

    def test_install_wraps_the_factory_once_and_every_handler_gets_the_cleaned_line(self):
        def hermes_factory(*args, **kwargs):
            line = self.factory(*args, **kwargs)
            line.session_tag = " [s-1]"
            return line
        hermes_factory._hermes_session_injector = True
        logging.setLogRecordFactory(hermes_factory)
        self.assertTrue(log_privacy.install())
        self.assertFalse(log_privacy.install())
        self.assertTrue(getattr(logging.getLogRecordFactory(), "_hermes_session_injector", False))
        stream = io.StringIO()
        handler = logging.StreamHandler(stream)
        handler.setFormatter(logging.Formatter("%(session_tag)s %(message)s"))
        logger = logging.getLogger("nollie.tests.log_privacy")
        logger.addHandler(handler)
        logger.propagate = False
        self.addCleanup(logger.removeHandler, handler)
        logger.warning("Prompt: %s", "remind me to call mum")
        self.assertEqual(stream.getvalue(), " [s-1] Prompt: [left out]\n")

    def test_the_hooks_remember_messages_and_replies(self):
        hooks = {}
        log_privacy.register(SimpleNamespace(register_hook=lambda name, fn: hooks.update({name: fn})))
        self.assertEqual(sorted(hooks), ["post_llm_call", "pre_llm_call"])
        hooks["pre_llm_call"](user_message="What time does the chemist close today?")
        hooks["post_llm_call"](user_message=None, assistant_response=["not text"])
        hooks["post_llm_call"](assistant_response="The chemist on the high street closes at six.")
        message = log_privacy.scrub(record("%s | %s", "What time does the chemist close today?",
                                           "The chemist on the high street closes at six.")).getMessage()
        self.assertEqual(message, "[left out] | [left out]")

    @unittest.skipUnless(HERMES, "the pinned Hermes source is not on this Mac")
    def test_every_log_line_in_the_pinned_hermes_that_carries_words_is_covered(self):
        found = list(word_calls(HERMES))
        self.assertGreater(len(found), 30)
        for path, line, template, words in found:
            self.assertTrue(set(words) <= set(log_privacy.word_arguments(template)),
                            f"{path}:{line} {template!r} passes words at {words}")
        turn = (HERMES / "agent" / "turn_context.py").read_text()
        self.assertIn('"conversation turn: session=%s model=%s provider=%s platform=%s history=%d msg=%r"', turn)
        self.assertIn('_turn_fmt += " origin=%s"', turn)


if __name__ == "__main__":
    unittest.main()
