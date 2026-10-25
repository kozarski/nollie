"""Nollie never opens the Cua Spaces app and never makes it a login item.

The app has its own window and menu bar item; Nollie keeps one menu bar item by running only Cua's
background part (`cua daemon start`, from the command-line tool inside the app), started and stopped
by Nollie Runtime. These checks read Nollie's own source and fail on any way of launching the app.
Behaviour is covered too: Services/Runtime/Tests/CuaInstallerTests.swift records every program the
installer runs, and the computer add-on's tests only accept Cua's and Hermes's command-line tools.
"""
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[2]
FOLDERS = ["Apps", "Services", "Companions", "Shared", "Packages", "Extensions", "Tools/release", "Tools/runtime-helper"]
SUFFIXES = {".swift", ".py", ".sh", ".plist", ".template", ".js"}


def sources():
    for folder in FOLDERS:
        for path in sorted((ROOT / folder).rglob("*")):
            parts = set(path.relative_to(ROOT).parts)
            if path.suffix in SUFFIXES and path.is_file() and not parts & {"tests", "Tests", "build", ".build", "Generated"}:
                yield path


# Anything that starts an app by itself, rather than a command-line tool.
LAUNCHERS = re.compile(r"openApplication\(|launchApplication|LSOpen|NSWorkspace\.shared\.open\(\s*(app|url|cua)"
                       r"|urlForApplication\(withBundleIdentifier|/usr/bin/open\b|[\"']open[\"']\s*,\s*[\"']-[abW]")
# Registering something to run at login or under launchd.
LOGIN = re.compile(r"SMAppService|SMLoginItemSetEnabled|LaunchAgents|launchctl|loginItem")
# Files about Cua Spaces itself. Nollie Computer (Cua Driver) opens only the apps a bot may use, and
# Cua Spaces is never one of them: Tests/Unit/ComputerRulesTests.swift, cuaSpacesIsNeverOpenedOrUsed.
CUA = re.compile(r"trycua\.spaces|Cua Spaces|cua-spaces|CuaRelease|CuaSetup|CuaInstaller|cua daemon|\.cua/|own_computer")


class NeverOpensCuaSpaces(unittest.TestCase):
    def test_nothing_that_mentions_cua_launches_an_app_or_a_login_item(self):
        problems = []
        for path in sources():
            text = path.read_text(errors="replace")
            if not CUA.search(text):
                continue
            for number, line in enumerate(text.splitlines(), 1):
                if LAUNCHERS.search(line) or (LOGIN.search(line) and CUA.search(line)):
                    problems.append(f"{path.relative_to(ROOT)}:{number}: {line.strip()}")
        self.assertEqual(problems, [], "Cua Spaces must never be opened or made a login item:\n" + "\n".join(problems))

    def test_the_apps_own_program_is_never_run(self):
        # The window program is Contents/MacOS/<CFBundleExecutable>; the CLI is Contents/MacOS/cua.
        pattern = re.compile(r"Cua Spaces\.app/Contents/MacOS/(?!cua\b)")
        problems = [f"{p.relative_to(ROOT)}" for p in sources() if pattern.search(p.read_text(errors="replace"))]
        self.assertEqual(problems, [])

    def test_cuas_command_line_is_never_asked_to_install_a_login_item_or_open_its_app(self):
        pattern = re.compile(r"[\"']daemon[\"']\s*,\s*[\"'](install|enable|autostart)[\"']|cua (daemon install|open|app)\b")
        problems = []
        for path in sources():
            for number, line in enumerate(path.read_text(errors="replace").splitlines(), 1):
                if pattern.search(line):
                    problems.append(f"{path.relative_to(ROOT)}:{number}")
        self.assertEqual(problems, [])

    def test_no_visible_words_ask_people_to_open_cua(self):
        problems = []
        for path in sources():
            for number, line in enumerate(path.read_text(errors="replace").splitlines(), 1):
                if re.search(r"Open Cua|Open it to wake|Open it there|open Cua Spaces", line):
                    problems.append(f"{path.relative_to(ROOT)}:{number}")
        self.assertEqual(problems, [])

    def test_the_check_itself_catches_a_launch(self):
        self.assertTrue(LAUNCHERS.search('NSWorkspace.shared.openApplication(at: cuaApp, configuration: c)'))
        self.assertTrue(LAUNCHERS.search('subprocess.run(["/usr/bin/open", "-a", "Cua Spaces"])'))
        self.assertTrue(LAUNCHERS.search('run(["open", "-b", "com.trycua.spaces.macos"])'))
        self.assertTrue(LOGIN.search('SMAppService.loginItem(identifier: "com.trycua.spaces.macos")'))
        self.assertFalse(LAUNCHERS.search('NSWorkspace.shared.open(Self.downloadPage)'))


if __name__ == "__main__":
    unittest.main()
