import json
import unittest

from night_support import Checks, load

receipts = load("receipts")


class ClassificationTests(unittest.TestCase):
    def command(self, command, **answers):
        return receipts.classify("terminal", {"command": command}, Checks(**answers))

    def test_every_kind(self):
        self.assertEqual(receipts.classify("write_file", {"path": "/tmp/a"}, Checks()), {"kind": "tool"})
        self.assertEqual(self.command("df -h"), {"kind": "safe"})
        self.assertEqual(self.command("podman ps", allowlist_entry="podman *"),
                         {"kind": "allowlist", "detail": "podman *"})
        self.assertEqual(self.command("git push origin main", dangerous=(True, "git push", "git push"),
                                      permanently_approved=True),
                         {"kind": "always", "detail": "git push", "key": "git push"})
        # A stop keeps the words of the rule that decided it, for the card's Why.
        self.assertEqual(self.command("rm -rf build", dangerous=(True, "recursive delete", "recursive delete")),
                         {"kind": "blocked", "detail": "risky", "rule": "recursive delete"})
        self.assertEqual(self.command("rm -rf /", hardline=(True, "delete root")),
                         {"kind": "blocked", "detail": "hardline", "rule": "delete root"})
        self.assertEqual(self.command("hermes config set x", deny_rule="hermes config*"),
                         {"kind": "blocked", "detail": "deny_rule", "rule": "hermes config*"})
        self.assertEqual(self.command("echo x | sudo -S ls", sudo_guard=(True, "sudo guess")),
                         {"kind": "blocked", "detail": "other"})
        self.assertEqual(receipts.classify("send_message", {}, Checks(), guard="held"), {"kind": "held"})
        self.assertEqual(receipts.classify("send_message", {}, Checks(), guard="ask_first"),
                         {"kind": "held", "detail": "ask_first"})
        self.assertEqual(receipts.classify("computer_use", {}, Checks(), guard="mac"),
                         {"kind": "blocked", "detail": "mac"})
        self.assertEqual(self.command("ls", dangerous=RuntimeError("Hermes changed")), {"kind": "unknown"})

    def test_hermes_order_floors_before_allowlist_and_risk(self):
        # A hardline command stays a hardline stop even when a hand-written allowlist entry matches.
        checks = Checks(hardline=(True, "x"), deny_rule="rm*", allowlist_entry="rm *",
                        dangerous=(True, "k", "d"), permanently_approved=True)
        self.assertEqual(receipts.classify("terminal", {"command": "rm -rf /"}, checks),
                         {"kind": "blocked", "detail": "hardline", "rule": "x"})
        self.assertNotIn("allowlist_entry", checks.asked)
        # The allowlist wins over pattern detection, as in check_all_command_guards.
        checks = Checks(allowlist_entry="git push *", dangerous=(True, "git push", "git push"))
        self.assertEqual(receipts.classify("terminal", {"command": "git push x"}, checks)["kind"], "allowlist")
        self.assertNotIn("dangerous", checks.asked)

    def test_permanent_approval_is_asked_with_the_pattern_key(self):
        seen = []
        checks = Checks(dangerous=(True, "recursive delete", "recursive delete"),
                        permanently_approved=lambda key: seen.append(key) or True)
        receipts.classify("terminal", {"command": "rm -r old"}, checks)
        self.assertEqual(seen, ["recursive delete"])

    def test_hermes_checks_never_use_the_dry_run_or_reload(self):
        from pathlib import Path
        text = Path(load("receipts").__file__).read_text()
        self.assertNotIn("evaluate_command(", text)
        self.assertNotIn("load_permanent_allowlist(", text)


class SettleTests(unittest.TestCase):
    def test_a_block_replaces_the_prediction(self):
        self.assertEqual(receipts.settle({"kind": "safe"}, "blocked", "risky"), {"kind": "blocked", "detail": "risky"})
        self.assertEqual(receipts.settle({"kind": "tool"}, "blocked", "held"), {"kind": "held"})
        self.assertEqual(receipts.settle({"kind": "tool"}, "blocked", "weird"), {"kind": "blocked", "detail": "other"})

    def test_a_hold_for_the_persons_yes_keeps_its_reason(self):
        self.assertEqual(receipts.settle({"kind": "held", "detail": "ask_first"}, "blocked", "ask_first"),
                         {"kind": "held", "detail": "ask_first"})
        self.assertEqual(receipts.settle({"kind": "tool"}, "blocked", "ask_first"),
                         {"kind": "held", "detail": "ask_first"})
        # Allowed after all (Hermes let it through): not claimed as held.
        self.assertEqual(receipts.settle({"kind": "held", "detail": "ask_first"}, "done"), {"kind": "unknown"})

    def test_ask_firsts_hold_is_told_apart_from_a_rehearsal(self):
        ask_first = load("ask_first")
        held = ask_first.HELD_MESSAGE.format(summary="Run this command:\nrm -rf build")
        self.assertEqual(receipts.block_detail(json.dumps({"error": held})), "ask_first")
        self.assertEqual(receipts.block_detail(held), "ask_first")
        self.assertEqual(receipts.block_detail("anything", "ask_first"), "ask_first")
        self.assertEqual(receipts.block_detail(json.dumps({"error": receipts.REHEARSAL})), "held")
        # Approvals switched off is a stop, not a hold.
        bypassed = ask_first.BYPASSED_MESSAGE.format(summary="Send: send message")
        self.assertNotEqual(receipts.block_detail(json.dumps({"error": bypassed})), "ask_first")

    def test_a_stop_keeps_its_rules_words_only_when_that_rule_stopped_it(self):
        risky = {"kind": "blocked", "detail": "risky", "rule": "recursive delete"}
        self.assertEqual(receipts.settle(risky, "blocked", "risky"), risky)
        # Something else stopped it: those words would explain the wrong stop.
        self.assertEqual(receipts.settle(risky, "blocked", "deny_rule"), {"kind": "blocked", "detail": "deny_rule"})
        held = {"kind": "held", "detail": "ask_first", "ask": "send"}
        self.assertEqual(receipts.settle(held, "blocked", "ask_first"), held)
        self.assertEqual(receipts.settle(held, "blocked", "held"), {"kind": "held"})
        # A rule's words are scrubbed and kept short.
        found = receipts.classify("terminal", {"command": "x"}, Checks(deny_rule="curl *sk-abcdefghijklmnop123* " + "y" * 200))
        self.assertNotIn("sk-abcdefghijklmnop", found["rule"])
        self.assertLessEqual(len(found["rule"]), receipts.RULE_LIMIT)
        # An empty description adds nothing.
        self.assertEqual(self.command_receipt(dangerous=(True, "k", "")), {"kind": "blocked", "detail": "risky"})

    def command_receipt(self, **answers):
        return receipts.classify("terminal", {"command": "rm -r x"}, Checks(**answers))

    def test_a_predicted_stop_that_ran_is_not_claimed(self):
        self.assertEqual(receipts.settle({"kind": "blocked", "detail": "risky"}, "done"), {"kind": "unknown"})
        self.assertEqual(receipts.settle({"kind": "held"}, "failed"), {"kind": "unknown"})
        self.assertEqual(receipts.settle({"kind": "always", "detail": "git push", "key": "k"}, "done"),
                         {"kind": "always", "detail": "git push"})

    def test_result_status_and_cause(self):
        blocked = json.dumps({"error": "BLOCKED: Command flagged as dangerous (x) but cron jobs run without a user present"})
        self.assertEqual(receipts.result_status("ok", blocked), "blocked")
        self.assertEqual(receipts.block_detail(blocked), "risky")
        self.assertEqual(receipts.block_detail("BLOCKED (hardline): no"), "hardline")
        self.assertEqual(receipts.block_detail(json.dumps({"error": "BLOCKED: this command matches the user-defined deny rule 'x'"})),
                         "deny_rule")
        self.assertEqual(receipts.block_detail(json.dumps({"error": receipts.REHEARSAL})), "held")
        self.assertEqual(receipts.block_detail("anything", "mac"), "mac")
        self.assertEqual(receipts.result_status("blocked", ""), "blocked")
        self.assertEqual(receipts.result_status("error", "{\"error\": \"boom\"}"), "failed")
        self.assertEqual(receipts.result_status("ok", "{\"output\": \"fine\"}"), "done")


class ScrubTests(unittest.TestCase):
    def test_tokens_and_passwords(self):
        text = ("curl -H 'Authorization: Bearer abc.def' https://user:hunter2@api.example.com/v1?key=zzz#frag "
                "sk-live1234567890abcd ghp_ABCDEFGHIJKLMNOP1234 password=pa55word mysql -u root -pS3cret! "
                "deadbeefdeadbeefdeadbeefdeadbeef0011 QWxhZGRpbjpvcGVuIHNlc2FtZQ1234567890ABCDEFGHIJ")
        clean = receipts.scrub(text)
        for secret in ("abc.def", "hunter2", "zzz", "frag", "sk-live", "ghp_", "pa55word", "S3cret",
                       "deadbeefdeadbeef", "QWxhZGRpbjpvcGVu"):
            self.assertNotIn(secret, clean, secret)
        self.assertIn("api.example.com/v1", clean)
        self.assertIn("-u root", clean)

    def test_ordinary_words_and_paths_stay(self):
        text = "find /Users/someone/Vault/Projects2026/LongFolderName/Report -print -path x"
        self.assertEqual(receipts.scrub(text), text)

    def test_vault_secret_through_the_redactor(self):
        redactor = lambda text: text.replace("vault-value-42", "<redacted>")
        self.assertEqual(receipts.scrub("echo vault-value-42", redactor), "echo <redacted>")

    def test_a_key_shortened_to_its_ends_is_hidden(self):
        shorten = lambda text: text.replace("sk-abcdefghij1234", "sk-abc...1234")
        for text in ("export KEY=sk-abcdefghij1234", "token sk-abc...1234 ghp_ab\u2026yz"):
            clean = receipts.scrub(text, shorten)
            for part in ("sk-abc", "1234", "ghp_ab", "yz"):
                self.assertNotIn(part, clean, (text, clean))

    def test_a_raising_redactor_hides_the_whole_string(self):
        def broken(text):
            raise RuntimeError("no")
        self.assertEqual(receipts.scrub("echo secret", broken), "[hidden]")
        self.assertEqual(receipts.scrub("echo secret", lambda text: None), "[hidden]")

    def test_targets_are_short(self):
        self.assertEqual(len(receipts.target("terminal", {"command": "x" * 1000})), 300)
        self.assertEqual(receipts.target("web_extract", {"urls": ["https://shop.example.com/ssd?ref=mail"]}),
                         "shop.example.com/ssd")
        self.assertEqual(receipts.target("web_search", {"query": "2TB NVMe price"}), "2TB NVMe price")
        self.assertEqual(receipts.target("computer_use", {"action": "click", "x": 3}), "click")
        self.assertEqual(receipts.target("write_file", {"path": "/tmp/notes.md", "content": "x"}), "/tmp/notes.md")


class LookOnlyTests(unittest.TestCase):
    def test_the_list(self):
        for tool in ("read_file", "search_files", "session_search", "skill_view", "skills_list", "web_search",
                     "todo", "browser_snapshot", "browser_get_images"):
            self.assertTrue(receipts.look_only(tool, {}), tool)
        for tool in ("write_file", "terminal", "send_message", "execute_code", "delegate_task", "cronjob_manage",
                     "memory", "mcp__cua__space_bash"):
            self.assertFalse(receipts.look_only(tool, {}), tool)

    def test_urls_need_no_query_or_fragment(self):
        self.assertTrue(receipts.look_only("web_extract", {"urls": ["https://a.example/b"]}))
        self.assertFalse(receipts.look_only("web_extract", {"urls": ["https://a.example/b?x=1"]}))
        self.assertFalse(receipts.look_only("web_extract", {"urls": ["https://a.example/b#top"]}))
        self.assertFalse(receipts.look_only("web_extract", {"urls": ["https://a.example/b", "ftp://x/y"]}))
        self.assertFalse(receipts.look_only("web_extract", {}))
        self.assertTrue(receipts.look_only("vision_analyze", {"image_url": "http://a.example/i.png"}))
        self.assertFalse(receipts.look_only("vision_analyze", {"image_url": "/Users/someone/i.png"}))

    def test_browser_console_only_without_an_expression(self):
        self.assertTrue(receipts.look_only("browser_console", {}))
        self.assertFalse(receipts.look_only("browser_console", {"expression": "document.cookie"}))


class BlockTests(unittest.TestCase):
    def test_the_mac(self):
        none = lambda name: None
        self.assertTrue(receipts.mac_block("computer_use", {}, none))
        self.assertTrue(receipts.mac_block("mcp__cua_recorder__start", {}, none))
        self.assertTrue(receipts.mac_block("mcp__nollie_mac__click", {}, none))
        self.assertTrue(receipts.mac_block("odd_name", {}, lambda name: "mcp-cua-recorder"))
        for command in ("open https://example.com", "/usr/bin/osascript -e 'x'", "ls && screencapture a.png",
                        "shortcuts run Lights", "cliclick c:1,1", "automator flow"):
            self.assertTrue(receipts.mac_block("terminal", {"command": command}, none), command)
        self.assertFalse(receipts.mac_block("terminal", {"command": "git log --oneline"}, none))
        self.assertFalse(receipts.mac_block("mcp__cua__space_bash", {}, lambda name: "mcp-cua"))

    def test_add_on_folder(self):
        self.assertTrue(receipts.plugin_block("write_file", {"path": "~/.hermes/plugins/nollie-workflow/x.py"}))
        self.assertTrue(receipts.plugin_block("patch", {"patch": "*** ~/.hermes/plugins/nollie-workflow/a"}))
        self.assertTrue(receipts.plugin_block("terminal", {"command": "rm ~/.hermes/nollie-workflow/posts.json"}))
        self.assertFalse(receipts.plugin_block("read_file", {"path": "~/.hermes/plugins/nollie-workflow/x.py"}))
        self.assertFalse(receipts.plugin_block("write_file", {"path": "/tmp/x"}))

    def test_words_are_plain_and_have_no_long_dash(self):
        for text in (receipts.REHEARSAL, receipts.MAC, receipts.PLUGIN):
            self.assertNotIn(chr(0x2014), text)


if __name__ == "__main__":
    unittest.main()
