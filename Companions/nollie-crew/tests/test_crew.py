import copy
import shutil
import unittest

from support import NOLLIE, PERSON_ASKED, Home, policy, store


def add_args(**changes):
    return dict(copy.deepcopy(PERSON_ASKED), **changes)


class AddTests(unittest.TestCase):
    def setUp(self):
        self.home = Home()
        self.addCleanup(self.home.cleanup)

    def test_person_asked_adds_member_with_note_meet_and_undo(self):
        result = self.home.call("crew_add", add_args())
        self.assertTrue(result["ok"], result)
        self.assertEqual(result["status"], "added")
        self.assertEqual(result["note"], "I've added Rover to check new roles each morning.")
        self.assertEqual([a["id"] for a in result["actions"]], ["meet", "undo"])
        self.assertEqual(result["actions"][0]["profile"], "rover")
        self.assertEqual(result["actions"][1]["token"], result["undo"])
        home = self.home.root / "profiles" / "rover"
        self.assertIn("Come to me for: New job listings and what changed since yesterday.",
                      (home / "SOUL.md").read_text())
        meta = store.read_yaml(home / "profile.yaml")
        self.assertEqual(meta["display_name"], "Rover")
        self.assertEqual(meta["description"], "New job listings and what changed since yesterday.")
        self.assertEqual(store.read_json(home / "nollie-crew.json")["owner"], "nollie-crew")
        self.assertTrue(self.home.private_untouched())

    def test_member_config_never_reaches_past_nollie(self):
        self.home.call("crew_add", add_args())
        cfg = self.home.member_config("rover")
        self.assertEqual(policy.exceeds(cfg, NOLLIE), [])
        self.assertEqual(cfg["platform_toolsets"]["cli"],
                         ["clarify", "file", "memory", "session_search", "skills", "todo", "vision", "web"])
        self.assertEqual(cfg["platform_toolsets"]["cron"], ["clarify", "file", "memory", "web"])
        self.assertEqual(cfg["platform_toolsets"]["telegram"],
                         ["clarify", "file", "memory", "session_search", "skills", "todo", "vision", "web"])
        for platform in policy.CORE_PLATFORMS:
            self.assertIn(platform, cfg["platform_toolsets"])
        self.assertEqual(cfg["command_allowlist"], [])
        self.assertEqual(cfg["approvals"]["deny"], NOLLIE["approvals"]["deny"])
        self.assertEqual(cfg["approvals"]["mode"], "smart")
        self.assertEqual(cfg["approvals"]["unattended_mode"], "deny")
        self.assertEqual(cfg["mcp_servers"], {})
        for key in ("platforms", "nous", "secrets", "auxiliary", "gateway"):
            self.assertNotIn(key, cfg)
        self.assertEqual(cfg["model"], {"provider": "llamacpp"})
        self.assertEqual(cfg["fallback_providers"], [])
        self.assertNotIn("nollie-crew", cfg["plugins"]["enabled"])
        self.assertIn("nollie-crew", cfg["plugins"]["disabled"])
        self.assertIn("nollie_crew", cfg["agent"]["disabled_toolsets"])
        self.assertFalse(cfg["auth"]["adopt_external_logins"])
        self.assertEqual(cfg["agent"]["max_turns"], 60)
        self.assertEqual(cfg["timezone"], "Europe/London")

    def test_every_member_gets_ask_first_without_more_tools(self):
        for plugins in ({}, {"enabled": ["nollie-guard", "nollie-crew"],
                            "disabled": ["nollie-workflow", "user/nollie-workflow", "other-addon"]},
                        {"enabled": ["user/nollie-workflow", "user/nollie-crew", "nollie-guard"]}):
            with self.subTest(plugins=plugins):
                nollie = copy.deepcopy(NOLLIE)
                nollie["plugins"] = plugins
                home = Home(nollie)
                self.addCleanup(home.cleanup)
                result = home.call("crew_add", add_args())
                self.assertEqual(result["status"], "added", result)
                config = home.member_config("rover")
                enabled = {p.rsplit("/", 1)[-1] for p in config["plugins"]["enabled"]}
                inherited = {p.rsplit("/", 1)[-1] for p in plugins.get("enabled", [])} - {"nollie-crew"}
                self.assertEqual(enabled, inherited | {"nollie-workflow"})
                self.assertFalse({"nollie-workflow", "user/nollie-workflow"} & set(config["plugins"]["disabled"]))
                self.assertIn("nollie_sign_in", config["agent"]["disabled_toolsets"])
                for tools in config["platform_toolsets"].values():
                    self.assertLessEqual(set(tools), policy.nollie_toolsets(nollie))
                self.assertEqual(policy.exceeds(config, nollie), [])
                installed = home.root / "profiles/rover/plugins/nollie-workflow"
                source = home.root / "plugins/nollie-workflow"
                self.assertEqual((installed / "ask_first.py").read_bytes(), (source / "ask_first.py").read_bytes())
                self.assertFalse((installed / "recorder-only").exists(), "every crew bot keeps a Papertrail")
                marker = home.root / "profiles/rover/nollie-workflow/ask-first-initialized"
                self.assertEqual(marker.read_text(), "1\n")
                self.assertEqual(marker.stat().st_mode & 0o777, 0o600)
                self.assertTrue(home.private_untouched())

    def test_member_keeps_main_safety_and_cannot_drop_ask_first(self):
        self.home.call("crew_add", add_args())
        config = self.home.member_config("rover")
        self.assertEqual(config["approvals"]["deny"], NOLLIE["approvals"]["deny"])
        for key in ("cron_mode", "single_query_mode", "unattended_mode"):
            self.assertEqual(config["approvals"][key], "deny")
        self.assertEqual(config["plugins"]["enabled"], ["nollie-guard", "nollie-workflow"])
        config["plugins"]["disabled"].append("user/nollie-workflow")
        self.assertIn("Ask first", policy.exceeds(config, NOLLIE))
        config["plugins"]["disabled"] = []
        config["plugins"]["enabled"].remove("nollie-workflow")
        self.assertIn("Ask first", policy.exceeds(config, NOLLIE))

    def test_workflow_tools_need_main_to_have_them_and_an_explicit_grant(self):
        refused = self.home.call("crew_add", add_args(toolsets=["nollie_sign_in"]))
        self.assertFalse(refused["ok"])
        nollie = copy.deepcopy(NOLLIE)
        nollie["platform_toolsets"]["cli"].append("nollie_sign_in")
        home = Home(nollie)
        self.addCleanup(home.cleanup)
        self.assertEqual(home.call("crew_add", add_args(toolsets=["nollie_sign_in"]))["status"], "added")
        config = home.member_config("rover")
        self.assertNotIn("nollie_sign_in", config["agent"]["disabled_toolsets"])
        self.assertEqual(config["platform_toolsets"]["cli"], ["nollie_sign_in"])

    def test_missing_workflow_refuses_before_creating_a_profile(self):
        shutil.rmtree(self.home.root / "plugins/nollie-workflow")
        result = self.home.call("crew_add", add_args())
        self.assertFalse(result["ok"])
        self.assertIn("Ask first", result["error"])
        self.assertFalse((self.home.root / "profiles/rover").exists())
        self.assertTrue(self.home.private_untouched())

    def test_a_name_marked_private_is_not_created(self):
        store.write_json(self.home.root / "nollie-private-bots.json", {"version": 1, "profiles": ["rover"]})
        result = self.home.call("crew_add", add_args())
        self.assertFalse(result["ok"])
        self.assertIn("private", result["error"])
        self.assertFalse((self.home.root / "profiles/rover").exists())
        self.assertNotIn("rover", self.home.profiles.touched)

    def test_damaged_private_list_refuses_before_creating_a_profile(self):
        (self.home.root / "nollie-private-bots.json").write_text("broken")
        result = self.home.call("crew_add", add_args())
        self.assertFalse(result["ok"])
        self.assertIn("Private list", result["error"])
        self.assertFalse((self.home.root / "profiles/rover").exists())

    def test_local_model_comes_from_settings(self):
        store.write_json(self.home.root / "nollie-crew" / "settings.json",
                         {"local_model": {"provider": "llamacpp", "default": "fixture-small"}})
        self.home.call("crew_add", add_args())
        self.assertEqual(self.home.member_config("rover")["model"], {"provider": "llamacpp", "default": "fixture-small"})

    def test_toolsets_nollie_lacks_are_refused(self):
        for toolsets, words in ((["discord"], "Nollie doesn't have discord"),
                                (["nollie_crew"], "can't have nollie_crew"),
                                (["image_gen"], "Nollie doesn't have image_gen"),
                                ("web", "must be a list")):
            result = self.home.call("crew_add", add_args(toolsets=toolsets))
            self.assertFalse(result["ok"], toolsets)
            self.assertIn(words, result["error"])
        self.assertFalse((self.home.root / "profiles" / "rover").exists())

    def test_disabled_toolsets_are_refused(self):
        nollie = copy.deepcopy(NOLLIE)
        nollie["agent"]["disabled_toolsets"] = ["terminal"]
        home = Home(nollie)
        self.addCleanup(home.cleanup)
        result = home.call("crew_add", add_args(toolsets=["terminal"]))
        self.assertFalse(result["ok"])
        self.assertIn("terminal", result["error"])

    def test_plan_route_needs_nollie_to_have_a_plan(self):
        nollie = copy.deepcopy(NOLLIE)
        nollie["model"] = {"provider": "custom", "base_url": "http://127.0.0.1:18434/v1", "default": "fixture-small"}
        home = Home(nollie)
        self.addCleanup(home.cleanup)
        result = home.call("crew_add", add_args(model_route="plan"))
        self.assertEqual(result, {"ok": False, "error": "Nollie isn't using an online plan, so a crew member can't either."})
        result = home.call("crew_add", add_args())
        self.assertEqual(home.member_config("rover")["model"], nollie["model"])

    def test_names_must_be_free(self):
        for name in ("Scout", "career", "Nollie", "Moss", "private", "Default"):
            result = self.home.call("crew_add", add_args(name=name))
            self.assertFalse(result["ok"], name)
        self.assertTrue(self.home.private_untouched())

    def test_come_to_me_for_is_one_or_two_sentences(self):
        result = self.home.call("crew_add", add_args(come_to_me_for="One. Two. Three."))
        self.assertFalse(result["ok"])
        result = self.home.call("crew_add", add_args(come_to_me_for="Job listings"))
        self.assertTrue(result["ok"])
        self.assertEqual(store.read_yaml(self.home.root / "profiles/rover/profile.yaml")["description"], "Job listings.")

    def test_schedule_the_person_gave_is_created(self):
        result = self.home.call("crew_add", add_args(schedule={"when": "0 8 * * *", "task": "Check new roles.",
                                                               "asked_by_person": True}))
        self.assertEqual(result["status"], "added")
        jobs = self.home.profiles.schedules("rover")
        self.assertEqual([(j["schedule"], j["prompt"], j["enabled"]) for j in jobs], [("0 8 * * *", "Check new roles.", True)])
        self.assertIn("Schedule: 0 8 * * *", result["changes"])


class ApprovalTests(unittest.TestCase):
    def setUp(self):
        self.home = Home()
        self.addCleanup(self.home.cleanup)

    def test_each_sensitive_kind_needs_the_person(self):
        cases = {
            "mac": add_args(toolsets=["web", "computer_use"]),
            "plan": add_args(model_route="plan"),
            "connections": add_args(toolsets=["notes"]),
            "schedule": add_args(schedule={"when": "0 7 * * *", "task": "Look.", "asked_by_person": False}),
        }
        for need, args in cases.items():
            result = self.home.call("crew_add", args)
            self.assertEqual((result["status"], result["needs"]), ("needs_approval", [need]), need)
        result = self.home.call("crew_add", add_args(toolsets=["cua", "cronjob"]))
        self.assertEqual(result["needs"], ["mac", "schedule"])
        self.assertEqual(result["message"], "Nollie wants to add Rover and let them use the Mac and run on a schedule I picked.")
        self.assertFalse((self.home.root / "profiles" / "rover").exists())

    def test_messaging_toolsets_need_the_person(self):
        nollie = copy.deepcopy(NOLLIE)
        nollie["platform_toolsets"]["cli"].append("send_message")
        home = Home(nollie)
        self.addCleanup(home.cleanup)
        result = home.call("crew_add", add_args(toolsets=["send_message"]))
        self.assertEqual(result["needs"], ["messages"])

    def test_only_the_persons_yes_in_the_prompt_lets_it_through(self):
        args = add_args(toolsets=["web", "computer_use"])
        directive = self.home.tools.pre_tool_call(tool_name="crew_add", args=args)
        self.assertEqual(directive["action"], "approve")
        self.assertTrue(directive["rule_key"].startswith("nollie-crew:"))
        self.assertIn("use the Mac", directive["message"])
        # The hook asked, but nobody answered yet.
        self.assertEqual(self.home.call("crew_add", args)["status"], "needs_approval")
        self.home.tools.post_approval_response(pattern_key="plugin_rule:" + directive["rule_key"], choice="deny")
        self.assertEqual(self.home.call("crew_add", args)["status"], "needs_approval")
        self.home.approve("crew_add", args, choice="timeout")
        self.assertEqual(self.home.call("crew_add", args)["status"], "needs_approval")
        self.home.approve("crew_add", args, choice="once")
        result = self.home.call("crew_add", args)
        self.assertEqual(result["status"], "added", result)
        self.assertIn("computer_use", self.home.member_config("rover")["platform_toolsets"]["cli"])
        self.assertEqual(policy.exceeds(self.home.member_config("rover"), NOLLIE), [])
        # The yes was for one request only.
        self.assertFalse(self.home.tools.approvals.granted(policy.request_digest("crew_add", args)))

    def test_an_answer_for_other_details_does_not_count(self):
        self.home.approve("crew_add", add_args(toolsets=["computer_use"]))
        result = self.home.call("crew_add", add_args(toolsets=["computer_use", "web"]))
        self.assertEqual(result["status"], "needs_approval")

    def test_an_answer_nobody_asked_for_is_ignored(self):
        args = add_args(toolsets=["computer_use"])
        digest = policy.request_digest("crew_add", args)
        self.home.tools.post_approval_response(pattern_key="plugin_rule:nollie-crew:" + digest, choice="always")
        self.assertEqual(self.home.call("crew_add", args)["status"], "needs_approval")

    def test_answers_expire(self):
        args = add_args(toolsets=["computer_use"])
        approvals = self.home.tools.approvals
        approvals._clock = lambda: self.home.clock[0]
        self.home.approve("crew_add", args)
        self.home.clock[0] += 21 * 60
        self.assertEqual(self.home.call("crew_add", args)["status"], "needs_approval")

    def test_hook_stays_quiet_for_safe_requests_and_other_tools(self):
        self.assertIsNone(self.home.tools.pre_tool_call(tool_name="crew_add", args=add_args()))
        self.assertIsNone(self.home.tools.pre_tool_call(tool_name="terminal", args={"command": "ls"}))
        own_idea = add_args(asked_by_person=False, toolsets=["computer_use"])
        self.assertIsNone(self.home.tools.pre_tool_call(tool_name="crew_add", args=own_idea))
        self.home.who["profile"] = "career"
        self.assertIsNone(self.home.tools.pre_tool_call(tool_name="crew_add", args=add_args(toolsets=["computer_use"])))


class CapTests(unittest.TestCase):
    def test_cap_of_eight_counts_paused_but_not_retired(self):
        home = Home()
        self.addCleanup(home.cleanup)
        names = ["Ada", "Bea", "Cal", "Dot", "Eli", "Fay", "Gus", "Hal"]
        for name in names:
            self.assertEqual(home.call("crew_add", add_args(name=name))["status"], "added", name)
        home.call("crew_pause", {"name": "Ada"})
        result = home.call("crew_add", add_args(name="Ivy"))
        self.assertEqual(result, {"ok": False, "error": "The crew is full (8). Retire someone first.", "status": "full"})
        own_idea = home.call("crew_add", add_args(name="Ivy", asked_by_person=False))
        self.assertEqual(own_idea["status"], "full")
        self.assertEqual(home.call("crew_list", {})["room"], 0)
        home.call("crew_retire", {"name": "Bea", "confirm": True})
        self.assertEqual(home.call("crew_add", add_args(name="Ivy"))["status"], "added")
        self.assertEqual(len(home.call("crew_list", {})["members"]), 8)

    def test_bringing_back_a_retired_member_respects_the_cap(self):
        home = Home()
        self.addCleanup(home.cleanup)
        for name in ["Ada", "Bea", "Cal", "Dot", "Eli", "Fay", "Gus", "Hal"]:
            home.call("crew_add", add_args(name=name))
        token = home.call("crew_retire", {"name": "Ada", "confirm": True})["undo"]
        home.call("crew_add", add_args(name="Ivy"))
        result = home.call("crew_undo", {"token": token})
        self.assertFalse(result["ok"])
        self.assertIn("full", result["error"])


class RetireAndUndoTests(unittest.TestCase):
    def setUp(self):
        self.home = Home()
        self.addCleanup(self.home.cleanup)
        self.added = self.home.call("crew_add", add_args(schedule={"when": "0 8 * * *", "task": "Check.",
                                                                   "asked_by_person": True}))
        self.member_home = self.home.root / "profiles" / "rover"

    def test_retire_asks_first(self):
        for args in ({"name": "Rover"}, {"name": "Rover", "confirm": False}, {"name": "Rover", "confirm": "yes"}):
            result = self.home.call("crew_retire", args)
            self.assertEqual(result["status"], "needs_confirmation")
            self.assertEqual(result["question"], "Retire Rover? I'll keep a copy of their chats, and you can undo it.")
            self.assertTrue(self.member_home.exists())
        result = self.home.call("crew_retire", {"name": "rover", "confirm": True})
        self.assertEqual(result["status"], "retired")
        self.assertFalse(self.member_home.exists())
        self.assertEqual(len(list((self.home.root / "nollie-crew" / "archives").glob("rover-*.tar.gz"))), 1)

    def test_undo_add_removes_the_member_cleanly_once(self):
        (self.member_home / "sessions" / "chat.json").write_text("{}")
        result = self.home.call("crew_undo", {"token": self.added["undo"]})
        self.assertEqual(result, {"ok": True, "status": "removed", "profile": "rover", "note": "I've removed Rover."})
        self.assertFalse(self.member_home.exists())
        self.assertEqual(self.home.call("crew_list", {})["members"], [])
        self.assertFalse(self.home.call("crew_undo", {"token": self.added["undo"]})["ok"])
        self.assertFalse(self.home.call("crew_undo", {"token": "made-up"})["ok"])
        # The name is free again.
        self.assertEqual(self.home.call("crew_add", add_args())["status"], "added")

    def test_undo_retire_brings_the_member_back_with_their_chats(self):
        (self.member_home / "sessions" / "chat.json").write_text('{"fixture": true}')
        (self.member_home / ".env").write_text("FIXTURE=1\n")
        token = self.home.call("crew_retire", {"name": "Rover", "confirm": True})["undo"]
        result = self.home.call("crew_undo", {"token": token})
        self.assertEqual((result["status"], result["note"]), ("active", "Rover is back."))
        self.assertEqual((self.member_home / "sessions" / "chat.json").read_text(), '{"fixture": true}')
        self.assertFalse((self.member_home / ".env").exists())  # credentials never go into the copy
        self.assertEqual(self.home.call("crew_list", {})["members"][0]["name"], "Rover")
        self.assertEqual(self.home.call("crew_pause", {"name": "Rover"})["status"], "paused")

    def test_undo_after_a_later_retire_does_nothing(self):
        self.home.call("crew_retire", {"name": "Rover", "confirm": True})
        result = self.home.call("crew_undo", {"token": self.added["undo"]})
        self.assertFalse(result["ok"])

    def test_pause_resume_and_their_undo(self):
        paused = self.home.call("crew_pause", {"name": "Rover"})
        self.assertEqual(paused["status"], "paused")
        self.assertTrue((self.member_home / "gateway.parked").exists())
        self.assertFalse(self.home.profiles.schedules("rover")[0]["enabled"])
        self.assertEqual(self.home.call("crew_pause", {"name": "Rover"})["note"], "Rover is already paused.")
        undone = self.home.call("crew_undo", {"token": paused["undo"]})
        self.assertEqual(undone["status"], "active")
        self.assertFalse((self.member_home / "gateway.parked").exists())
        self.assertTrue(self.home.profiles.schedules("rover")[0]["enabled"])
        self.home.call("crew_pause", {"name": "Rover"})
        resumed = self.home.call("crew_resume", {"name": "Rover"})
        self.assertEqual(resumed["note"], "Rover is back at work.")

    def test_update_and_its_undo(self):
        before = (self.member_home / "SOUL.md").read_text()
        result = self.home.call("crew_update", {"name": "Rover", "new_name": "Rex", "role": "watch app reviews",
                                                "schedule": {"when": "0 9 * * 1", "task": "Read reviews.",
                                                             "asked_by_person": True}})
        self.assertEqual(result["status"], "updated", result)
        self.assertIn("You are Rex", (self.member_home / "SOUL.md").read_text())
        self.assertEqual(store.read_yaml(self.member_home / "profile.yaml")["display_name"], "Rex")
        self.assertEqual([j["schedule"] for j in self.home.profiles.schedules("rover")], ["0 9 * * 1"])
        self.home.call("crew_undo", {"token": result["undo"]})
        self.assertEqual((self.member_home / "SOUL.md").read_text(), before)
        self.assertEqual(store.read_yaml(self.member_home / "profile.yaml")["display_name"], "Rover")
        self.assertEqual([j["schedule"] for j in self.home.profiles.schedules("rover")], ["0 8 * * *"])
        self.assertEqual(self.home.call("crew_list", {})["members"][0]["role"], "check new roles each morning")

    def test_update_that_adds_reach_needs_the_person(self):
        args = {"name": "Rover", "toolsets": ["web", "computer_use"]}
        self.assertEqual(self.home.call("crew_update", args)["needs"], ["mac"])
        self.home.approve("crew_update", args)
        self.assertEqual(self.home.call("crew_update", args)["status"], "updated")
        # Keeping what was already agreed does not ask again.
        self.assertEqual(self.home.call("crew_update", {"name": "Rover", "toolsets": ["computer_use"]})["status"], "updated")
        self.assertEqual(self.home.call("crew_update", {"name": "Rover", "model_route": "plan"})["needs"], ["plan"])

    def test_update_refuses_taken_names_and_empty_changes(self):
        self.assertFalse(self.home.call("crew_update", {"name": "Rover", "new_name": "Scout"})["ok"])
        self.assertEqual(self.home.call("crew_update", {"name": "Rover"})["error"], "Nothing to change.")


class GuardTests(unittest.TestCase):
    def setUp(self):
        self.home = Home()
        self.addCleanup(self.home.cleanup)
        self.home.call("crew_add", add_args())

    def test_other_profiles_are_refused_for_every_tool(self):
        for profile in ("career", "private", "rover", "custom", None):
            self.home.who = {"profile": profile}
            for tool in tools_names():
                result = self.home.call(tool, {"name": "Rover", "token": "x", "suggestion": "x"})
                self.assertEqual(result, {"ok": False, "error": "Only Nollie can manage the crew."}, (profile, tool))
        self.assertTrue((self.home.root / "profiles" / "rover").exists())

    def test_caller_failure_is_a_refusal(self):
        def broken():
            raise RuntimeError("fixture")
        self.home.tools.caller = broken
        self.assertFalse(self.home.call("crew_list", {})["ok"])

    def test_helpers_and_schedules_cannot_change_the_crew(self):
        self.home.who = {"profile": "default", "helper": True}
        self.assertTrue(self.home.call("crew_list", {})["ok"])
        self.assertFalse(self.home.call("crew_pause", {"name": "Rover"})["ok"])
        self.assertFalse(self.home.call("crew_add", add_args(name="Ivy", asked_by_person=False))["ok"])
        self.home.who = {"profile": "default", "scheduled": True}
        self.assertFalse(self.home.call("crew_add", add_args(name="Ivy"))["ok"])
        self.assertFalse(self.home.call("crew_retire", {"name": "Rover", "confirm": True})["ok"])
        self.assertEqual(self.home.call("crew_add", add_args(name="Ivy", asked_by_person=False))["status"], "suggestion")

    def test_private_and_unowned_profiles_are_never_touched(self):
        for name in ("private", "Moss", "career", "Scout", "default", "Nollie", "nobody"):
            for tool, args in (("crew_update", {"name": name, "role": "x y"}), ("crew_pause", {"name": name}),
                               ("crew_resume", {"name": name}), ("crew_retire", {"name": name, "confirm": True})):
                result = self.home.call(tool, args)
                self.assertFalse(result["ok"], (tool, name))
        self.assertTrue(self.home.private_untouched())
        from support import tree_digest
        self.assertEqual(tree_digest(self.home.root / "profiles" / "career"), self.home.career_digest)
        listed = self.home.call("crew_list", {})
        self.assertEqual(listed["other_bots"], ["career"])

    def test_member_marked_private_is_never_read_or_changed(self):
        from support import tree_digest
        private = self.home.root / "profiles/rover"
        before = tree_digest(private)
        undo = next(iter(self.home.crew.read_state()["undo"]))
        store.write_json(self.home.root / "nollie-private-bots.json", {"version": 1, "profiles": ["rover", "career"]})
        self.home.profiles.touched.clear()
        for tool, args in (("crew_update", {"name": "Rover", "toolsets": ["web"]}),
                           ("crew_retire", {"name": "Rover", "confirm": True}),
                           ("crew_pause", {"name": "Rover"}), ("crew_resume", {"name": "Rover"}),
                           ("crew_undo", {"token": undo})):
            self.assertFalse(self.home.call(tool, args)["ok"])
        listed = self.home.call("crew_list", {})
        self.assertEqual((listed["members"], listed["other_bots"]), ([], []))
        self.assertEqual(tree_digest(private), before)
        self.assertNotIn("rover", self.home.profiles.touched)
        self.assertNotIn("career", self.home.profiles.touched)

    def test_a_changed_ownership_marker_stops_changes(self):
        store.write_json(self.home.root / "profiles" / "rover" / "nollie-crew.json", {"owner": "nollie-crew", "id": "other"})
        result = self.home.call("crew_retire", {"name": "Rover", "confirm": True})
        self.assertFalse(result["ok"])
        self.assertIn("changed outside the crew", result["error"])
        self.assertTrue((self.home.root / "profiles" / "rover").exists())

    def test_a_profile_recreated_by_hand_is_not_retired(self):
        token = self.home.call("crew_retire", {"name": "Rover", "confirm": True})["undo"]
        (self.home.root / "profiles" / "rover").mkdir()
        store.write_yaml(self.home.root / "profiles" / "rover" / "config.yaml", {"model": "x"})
        result = self.home.call("crew_undo", {"token": token})
        self.assertFalse(result["ok"])
        self.assertIn("taken", result["error"])

    def test_a_failed_create_leaves_nothing_behind(self):
        def broken(*args, **kwargs):
            raise OSError("fixture")
        self.home.profiles.add_schedule = broken
        result = self.home.call("crew_add", add_args(name="Ivy", schedule={"when": "0 8 * * *", "task": "Look.",
                                                                         "asked_by_person": True}))
        self.assertEqual(result["error"], "The crew change could not be confirmed. Check crew_list before retrying.")
        self.assertFalse((self.home.root / "profiles" / "ivy").exists())
        self.assertEqual([m["name"] for m in self.home.call("crew_list", {})["members"]], ["Rover"])

    def test_damaged_state_is_kept_for_repair(self):
        (self.home.root / "nollie-crew" / "state.json").write_text('{"version": 99}')
        result = self.home.call("crew_add", add_args(name="Ivy"))
        self.assertFalse(result["ok"])
        self.assertEqual((self.home.root / "nollie-crew" / "state.json").read_text(), '{"version": 99}')


class SuggestionTests(unittest.TestCase):
    def setUp(self):
        self.home = Home()
        self.addCleanup(self.home.cleanup)
        self.idea = add_args(asked_by_person=False, name="Rover", role="keep an eye on app reviews",
                             toolsets=["web", "computer_use"])

    def test_own_idea_is_a_suggestion_not_a_member(self):
        result = self.home.call("crew_add", self.idea)
        self.assertEqual(result["status"], "suggestion")
        self.assertEqual(result["note"], "Want me to add Rover to keep an eye on app reviews? They would use the Mac.")
        self.assertEqual([a["id"] for a in result["actions"]], ["add", "not_now"])
        self.assertFalse((self.home.root / "profiles" / "rover").exists())
        self.assertEqual(self.home.call("crew_list", {})["suggestion"]["id"], result["suggestion"])
        self.assertFalse((self.home.root / "profiles" / "rover").exists())

    def test_missing_origin_counts_as_own_idea(self):
        args = add_args()
        args.pop("asked_by_person")
        self.assertEqual(self.home.call("crew_add", args)["status"], "suggestion")

    def test_one_suggestion_at_a_time(self):
        first = self.home.call("crew_add", self.idea)
        other = self.home.call("crew_add", add_args(asked_by_person=False, name="Ivy", role="tidy the downloads folder"))
        self.assertEqual((other["status"], other["suggestion"]), ("suggestion_waiting", first["suggestion"]))

    def test_not_now_sticks(self):
        key = self.home.call("crew_add", self.idea)["suggestion"]
        self.assertEqual(self.home.crew.answer_suggestion(key, "not_now")["note"], "Okay, I won't suggest that again.")
        self.assertEqual(self.home.call("crew_add", self.idea)["status"], "declined_before")
        reworded = add_args(asked_by_person=False, name="Ivy", role="keep an eye on the app reviews")
        self.assertEqual(self.home.call("crew_add", reworded)["status"], "declined_before")
        different = add_args(asked_by_person=False, name="Ivy", role="tidy the downloads folder")
        self.assertEqual(self.home.call("crew_add", different)["status"], "suggestion")
        self.assertFalse(self.home.crew.answer_suggestion(key, "add")["ok"])
        # The person can still ask for it themselves.
        self.assertEqual(self.home.call("crew_add", dict(self.idea, asked_by_person=True, toolsets=["web"]))["status"], "added")

    def test_not_now_from_the_chat(self):
        key = self.home.call("crew_add", self.idea)["suggestion"]
        self.assertEqual(self.home.call("crew_not_now", {"suggestion": key})["status"], "not_now")
        self.assertEqual(self.home.call("crew_add", self.idea)["status"], "declined_before")

    def test_add_tap_creates_the_member_it_described(self):
        key = self.home.call("crew_add", self.idea)["suggestion"]
        result = self.home.crew.answer_suggestion(key, "add")
        self.assertEqual(result["status"], "added", result)
        self.assertEqual(result["note"], "I've added Rover to keep an eye on app reviews.")
        self.assertIn("computer_use", self.home.member_config("rover")["platform_toolsets"]["cli"])
        self.assertFalse(self.home.crew.answer_suggestion(key, "add")["ok"])
        self.assertIsNone(self.home.call("crew_list", {})["suggestion"])


def tools_names():
    from support import tools_module
    return list(tools_module.SCHEMAS)


if __name__ == "__main__":
    unittest.main()
