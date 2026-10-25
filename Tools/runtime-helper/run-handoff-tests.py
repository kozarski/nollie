"""Exercise connection handoff with fixtures, without a service or Keychain access."""
from pathlib import Path
import shutil
import subprocess

ROOT = Path(__file__).resolve().parents[2]
OUTPUT = ROOT / "build" / "nollie-runtime-handoff"
PACKAGE = OUTPUT / "swift-fixtures"
TESTS = PACKAGE / "Tests" / "HandoffTests"
TESTS.mkdir(parents=True, exist_ok=True)
(PACKAGE / "Package.swift").write_text('''// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "HandoffFixtures", platforms: [.macOS("26.0")],
    dependencies: [.package(path: "../../../Packages/NollieCore")],
    targets: [.testTarget(name: "HandoffTests", dependencies: [.product(name: "NollieCore", package: "NollieCore")])])
''')
for path in ["Apps/Nollie/Connect/ManagedRuntimeHandoff.swift", "Services/Runtime/RuntimeIPC.swift",
             "Apps/Nollie/App/InterruptedRuntimeRecovery.swift"]:
    shutil.copyfile(ROOT / path, TESTS / Path(path).name)
for name in ["ManagedRuntimeHandoffTests.swift", "InterruptedRuntimeRecoveryTests.swift"]:
    (TESTS / name).write_text((ROOT / "Tests/Unit" / name).read_text().replace("@testable import Nollie\n", ""))
with (OUTPUT / "tests.log").open("w") as log:
    subprocess.run(["swift", "test", "--package-path", str(PACKAGE), "--scratch-path", str(OUTPUT / "swift-build")],
                   cwd=ROOT, stdout=log, stderr=subprocess.STDOUT, check=True)
print("Managed handoff fixtures passed. Log:", OUTPUT / "tests.log")
