"""Build core-only pairing fixtures in a private scratch directory; no app launch."""
from pathlib import Path
import shutil
import subprocess

ROOT = Path(__file__).resolve().parents[3]
OUTPUT = ROOT / "build" / "nollie-pairing"
PACKAGE = OUTPUT / "swift-fixtures"
TESTS = PACKAGE / "Tests" / "PairingTests"
TESTS.mkdir(parents=True, exist_ok=True)
(PACKAGE / "Package.swift").write_text('''// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "PairingFixtures", platforms: [.macOS("26.0")],
    dependencies: [.package(path: "../../../Packages/NollieCore")],
    targets: [.testTarget(name: "PairingTests", dependencies: [.product(name: "NollieCore", package: "NollieCore")])])
''')
shutil.copyfile(ROOT / "Tests/Unit" / "DevicePairingTests.swift", TESTS / "DevicePairingTests.swift")
shutil.copyfile(ROOT / "Apps/Nollie" / "Connect" / "PairingCompanionPackage.swift", TESTS / "PairingCompanionPackage.swift")
(TESTS / "PairingCompanionPackageTests.swift").write_text(
    (ROOT / "Tests/Unit" / "PairingCompanionPackageTests.swift").read_text().replace("@testable import Nollie\n", ""))
with (OUTPUT / "swift-tests.log").open("w") as log:
    subprocess.run(["swift", "test", "--package-path", str(PACKAGE), "--scratch-path", str(OUTPUT / "swift-build")],
                   cwd=ROOT, stdout=log, stderr=subprocess.STDOUT, check=True)
print("Pairing core tests passed. Log:", OUTPUT / "swift-tests.log")
