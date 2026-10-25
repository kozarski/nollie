"""Everything Nollie writes outside its app lives in one folder: ~/Library/Application Support/Nollie.

Code asks NolliePaths (Packages/NollieCore/Sources/NollieCore/Storage/NolliePaths.swift) where to put
things. This check fails when Swift code looks up a system folder or the home folder by itself, so a new
writer can't quietly start a second place. The files below may look elsewhere, each for a stated reason
that is only ever reading, or writing where the person asked.
"""
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[2]
FOLDERS = ["Apps", "Packages", "Shared", "Services", "Extensions"]
LOOKUPS = re.compile(r"applicationSupportDirectory|cachesDirectory|libraryDirectory|documentDirectory"
                     r"|homeDirectoryForCurrentUser|NSHomeDirectory\(|\"Library/")

ALLOWED = {
    "Packages/NollieCore/Sources/NollieCore/Storage/NolliePaths.swift": "the one place that decides",
    "Services/Notifications/NollieAlertHelper.swift": "sandboxed: its own macOS container",
    "Services/Runtime/CuaInstaller.swift": "reads the person's Applications for their own Cua; Cua's ~/.cua socket",
    "Services/Runtime/RuntimeContract.swift": "finds the Cua tool in use",
    "Packages/NollieCore/Sources/NollieCore/Logging/NollieLogFiles.swift": "Console's folder, ~/Library/Logs/Nollie, for the Mac log files",
    "Apps/Nollie/Connect/MacHermesSetup.swift": "reads whether a Hermes exists in ~/.hermes, never writes there",
    "Apps/Mac/MediaSave.swift": "saves a picture to Downloads when the person asks",
    "Apps/Mac/SignIns/SignInFill.swift": "finds the person's Cua tool and Cua's socket",
    "Apps/Mac/Computer/ComputerProcess.swift": "reads which Hermes a caller belongs to",
    "Apps/Mac/Computer/ComputerChecks.swift": "looks for a separately installed Cua Driver",
    "Apps/Mac/Computer/ComputerPresence.swift": "lists the person's apps",
    "Apps/Nollie/Settings/Removal/RemovalPlaces.swift": "Remove Nollie: finds what Nollie made, to delete it",
}


def swift_sources():
    for folder in FOLDERS:
        for path in sorted((ROOT / folder).rglob("*.swift")):
            relative = path.relative_to(ROOT)
            if not set(relative.parts) & {"Tests", "build", ".build"}:
                yield relative.as_posix(), path


class OneFolder(unittest.TestCase):
    def test_no_code_looks_up_a_folder_by_itself(self):
        problems = []
        for relative, path in swift_sources():
            if relative in ALLOWED:
                continue
            for number, line in enumerate(path.read_text(errors="replace").splitlines(), 1):
                code = line.split("//", 1)[0]
                if LOOKUPS.search(code):
                    problems.append(f"{relative}:{number}: {line.strip()}")
        self.assertEqual(problems, [], "Ask NolliePaths where to write instead:\n" + "\n".join(problems))

    def test_every_allowed_file_still_exists(self):
        for relative in ALLOWED:
            self.assertTrue((ROOT / relative).exists(), relative)

    def test_the_check_catches_a_new_lookup(self):
        self.assertTrue(LOOKUPS.search('FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)'))
        self.assertTrue(LOOKUPS.search('home.appendingPathComponent("Library/Logs/Nollie")'))
        self.assertFalse(LOOKUPS.search('NolliePaths.current.logs'))


if __name__ == "__main__":
    unittest.main()
