"""Compile the runtime fixtures in Direct and Store modes without an app install."""
import json
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[2]
OUTPUT = ROOT / "build" / "nollie-runtime-supervisor"
OUTPUT.mkdir(parents=True, exist_ok=True)
DEVELOPER = Path(subprocess.check_output(["xcode-select", "-p"], text=True).strip())
FRAMEWORKS = DEVELOPER / "Platforms/MacOSX.platform/Developer/Library/Frameworks"
MACROS = DEVELOPER / "Toolchains/XcodeDefault.xctoolchain/usr/lib/swift/host/plugins/testing/libTestingMacros.dylib"
sources = ["Apps/Nollie/Connect/ConfigurationBackup.swift", "Apps/Nollie/Connect/ScopedHermesImport.swift",
           "Apps/Nollie/Connect/StarterAssistantDefaults.swift",
           "Apps/Nollie/Connect/NativeDependencyInstaller.swift", "Apps/Nollie/Connect/NativeSetupKit.swift", "Services/Runtime/RuntimeContract.swift",
           "Services/Runtime/RuntimeSupervisor.swift", "Services/Runtime/NativeRuntimeBackend.swift",
           "Services/Runtime/RuntimeIPC.swift", "Services/Runtime/RuntimeService.swift",
           "Services/Runtime/LinkDoorHTTP.swift", "Services/Runtime/LinkDoorPolicy.swift", "Services/Runtime/LinkDoorDevices.swift",
           "Services/Runtime/LinkDoorIdentity.swift", "Services/Runtime/LinkDoor.swift", "Services/Runtime/LinkDoorWebSocket.swift", "Services/Runtime/LinkDoorLive.swift",
           "Services/Runtime/LinkDoorFamily.swift", "Services/Runtime/LinkDoorFamilyHermes.swift", "Services/Runtime/LinkDoorFamilyDoor.swift",
           "Services/Runtime/LiveRelayIPC.swift", "Services/Runtime/LiveRelay.swift", "Services/Runtime/RuntimeLink.swift",
           "Services/Runtime/CuaInstaller.swift", "Services/Runtime/AppPresence.swift",
           "Services/Runtime/ExitRelayPolicy.swift", "Services/Runtime/ExitRelayWire.swift", "Services/Runtime/ExitRelay.swift",
           "Services/Runtime/RuntimeExitRelay.swift", "Services/Runtime/RuntimeKeyStore.swift", "Services/Runtime/RuntimeKeyMigration.swift",
           "Packages/NollieCore/Sources/NollieCore/Storage/NolliePaths.swift",
           "Packages/NollieCore/Sources/NollieCore/Link/NollieLinkAway.swift",
           "Packages/NollieCore/Sources/NollieCore/Logging/NollieLog.swift", "Packages/NollieCore/Sources/NollieCore/Logging/LogFileWriter.swift",
           "Packages/NollieCore/Sources/NollieCore/Logging/NollieLogFiles.swift", "Packages/NollieCore/Sources/NollieCore/Logging/HermesLogLink.swift"]
fixture = OUTPUT / "RuntimeSupervisorTests.swift"
fixture.write_text((ROOT / "Services/Runtime/Tests/RuntimeSupervisorTests.swift").read_text())
main = OUTPUT / "TestMain.swift"
main.write_text("import Testing\nimport Darwin\n@main struct TestMain { static func main() async { let status: CInt = await Testing.__swiftPMEntryPoint(); exit(status) } }\n")
results = {}
for mode, defines in [("direct", ["-D", "NOLLIE_DIRECT"]), ("store", [])]:
    binary = OUTPUT / (mode + "-tests")
    command = ["xcrun", "swiftc", "-swift-version", "6", *defines, "-parse-as-library", "-F", str(FRAMEWORKS),
               "-Xlinker", "-rpath", "-Xlinker", str(FRAMEWORKS), "-load-plugin-library", str(MACROS),
               *sources, str(fixture), "Services/Runtime/Tests/RuntimeServiceTests.swift",
               "Services/Runtime/Tests/CuaInstallerTests.swift", "Services/Runtime/Tests/LiveRelayHelperTests.swift",
               "Services/Runtime/Tests/RuntimeExitRelayTests.swift",
               "Services/Runtime/Tests/RuntimeKeysTests.swift", str(main), "-o", str(binary)]
    with (OUTPUT / (mode + "-compile.log")).open("w") as log:
        subprocess.run(command, cwd=ROOT, stdout=log, stderr=subprocess.STDOUT, check=True)
    with (OUTPUT / (mode + "-tests.log")).open("w") as log:
        subprocess.run([str(binary)], cwd=ROOT, stdout=log, stderr=subprocess.STDOUT, check=True)
    with (OUTPUT / (mode + "-helper-typecheck.log")).open("w") as log:
        subprocess.run(["xcrun", "swiftc", "-swift-version", "6", *defines, "-parse-as-library", "-typecheck",
                        *sources, "Services/Runtime/RuntimeHelperMain.swift"], cwd=ROOT,
                       stdout=log, stderr=subprocess.STDOUT, check=True)
    results[mode] = "passed"
with (OUTPUT / "entry-tests.log").open("w") as log:
    subprocess.run([sys.executable, "-m", "unittest", "discover", "-s", str(ROOT / "Tools/runtime-helper"), "-p", "test_*.py"],
                   stdout=log, stderr=subprocess.STDOUT, check=True)
results["entrypoint"] = "passed"
results["helper_entrypoints"] = "Direct and Store typechecks passed"
results["scope"] = "Swift lifecycle fixtures and temporary Python stub modules only. No Hermes service launched or registered."
(OUTPUT / "validation.json").write_text(json.dumps(results, indent=2) + "\n")
print(json.dumps(results, indent=2))
