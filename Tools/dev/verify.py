#!/usr/bin/env python3
"""One command for the whole check: builds, unit tests, Python tests and the golden UI flows.

    Tools/dev/verify.py                 everything
    Tools/dev/verify.py build unit      only those stages (build, unit, python, ui)

NOLLIE_UI_ONLY=Group1,Group2 runs just those UI groups; NOLLIE_SIMULATOR picks the simulator and
NOLLIE_MOCK_PORT the mock gateway's port, so checkouts side by side do not share one.
It fails on any build error, failing test, or a golden UI flow that skipped: a skipped flow
proves nothing, so it counts as a failure here. Work goes under build/verify/.
"""
import json
import re
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import time
import urllib.request

ROOT = Path(__file__).resolve().parents[2]
WORK = ROOT / "build" / "verify"
PROJECT = str(ROOT / "Nollie.xcodeproj")
SIMULATOR = os.environ.get("NOLLIE_SIMULATOR", "Nollie Verify iPhone")
MOCK_PORT = int(os.environ.get("NOLLIE_MOCK_PORT", "9139"))

# Flows that must run, not skip, on the iPhone demo copy against the mock gateway.
GOLDEN_UI = [
    "NewBotCreationUITests",
    "ChatNavigationUITests",
    "FirstTaskUITests",
    "BotsSettingsUITests",
    "DevicePairingUITests",
    "AboutSourceUITests",
    "MainChatContinuityUITests",
    "PrivateBotUITests",
    "CrewNoteUITests",
    "PapertrailUITests",
    "NightShiftUITests",
    "SignInUITests",
    "AskFirstUITests",
    "HelperComputerUITests",
    "LiveStreamUITests",
    "RemoveNollieUITests",
    "AwayFromHomeUITests",
    "WholeReplyUITests",
    "DemoModeUITests",
]

PYTHON_SUITES = [
    "Companions/hermes-patches/tests",
    "Companions/hermes-push/tests",
    "Companions/nollie-computer/tests",
    "Companions/nollie-crew/tests",
    "Companions/nollie-mac/tests",
    "Companions/nollie-reader/tests",
    "Companions/nollie-workflow/tests",
    "Tools/codegen",
    "Tools/computer-helper",
    "Tools/dev",
    "Tools/mock-gateway",
    "Tools/release",
    "Tools/runtime-helper",
    "Tools/setup-plan",
    "Tools/sparkle",
]
# fastapi and httpx let the add-ons' dashboard route tests run instead of skipping.
PYTHON_PACKAGES = ["websockets", "pyjwt", "cryptography", "pyyaml", "fastapi", "httpx"]

failures = []


def say(text):
    print(f"\n== {text}", flush=True)


def run(name, command, log, env=None, cwd=ROOT):
    """Runs one step with its output in a log file; records a failure instead of stopping."""
    log.parent.mkdir(parents=True, exist_ok=True)
    started = time.time()
    with open(log, "w") as out:
        code = subprocess.run(command, cwd=cwd, stdout=out, stderr=subprocess.STDOUT,
                              env={**os.environ, **(env or {})}).returncode
    seconds = int(time.time() - started)
    if code == 0:
        print(f"   ok      {name} ({seconds}s)")
    else:
        print(f"   FAILED  {name} ({seconds}s), see {log.relative_to(ROOT)}")
        failures.append(name)
    return code == 0


def simulator_udid():
    devices = json.loads(subprocess.run(["xcrun", "simctl", "list", "devices", "available", "-j"],
                                        capture_output=True, text=True, check=True).stdout)["devices"]
    for runtime, entries in devices.items():
        for device in entries:
            if device["name"] == SIMULATOR and "iOS" in runtime:
                return device["udid"]
    runtimes = json.loads(subprocess.run(["xcrun", "simctl", "list", "runtimes", "available", "-j"],
                                         capture_output=True, text=True, check=True).stdout)["runtimes"]
    # The newest runtime that runs an ordinary Pro iPhone (a beta runtime may run fewer models).
    for candidate in reversed([r for r in runtimes if r["platform"] == "iOS"]):
        pros = [t for t in candidate["supportedDeviceTypes"] if t["productFamily"] == "iPhone" and t["name"].endswith(" Pro")]
        if pros:
            newest = max(pros, key=lambda t: [int(n) for n in re.findall(r"\d+", t["name"])] or [0])
            runtime, phone = candidate["identifier"], newest["identifier"]
            break
    else:
        sys.exit("No iOS simulator runtime with a Pro iPhone is installed.")
    return subprocess.run(["xcrun", "simctl", "create", SIMULATOR, phone, runtime],
                          capture_output=True, text=True, check=True).stdout.strip()


def ios_destination(udid):
    return f"platform=iOS Simulator,id={udid}"


UNSIGNED = ["CODE_SIGNING_ALLOWED=NO", "CODE_SIGNING_REQUIRED=NO", "CODE_SIGN_IDENTITY="]


def xcodebuild(*arguments):
    # One simulator, no clones: clones crash the simulated home screen and slow everything.
    return ["xcodebuild", "-project", PROJECT, "-parallel-testing-enabled", "NO", *arguments]


def stage_build(udid):
    say("Builds")
    run("iPhone Debug", xcodebuild("-scheme", "Nollie", "-configuration", "Debug", "-destination", ios_destination(udid),
                                   "-derivedDataPath", str(WORK / "dd-ios"), *UNSIGNED, "build"), WORK / "logs/build-ios-debug.log")
    run("iPhone Release", xcodebuild("-scheme", "Nollie", "-configuration", "Release", "-destination", "generic/platform=iOS",
                                     "-derivedDataPath", str(WORK / "dd-ios-release"), *UNSIGNED, "build"), WORK / "logs/build-ios-release.log")
    run("Mac Debug", xcodebuild("-scheme", "NollieMac", "-configuration", "Debug", "-destination", "platform=macOS",
                                "-derivedDataPath", str(WORK / "dd-mac"), "-allowProvisioningUpdates", "build"), WORK / "logs/build-mac-debug.log")
    run("Mac DirectRelease", xcodebuild("-scheme", "NollieMacDirect", "-configuration", "DirectRelease", "-destination", "platform=macOS",
                                        "-derivedDataPath", str(WORK / "dd-mac-direct-release"), "-allowProvisioningUpdates", "build"),
        WORK / "logs/build-mac-directrelease.log")


def stage_unit(udid):
    say("Unit tests")
    results = WORK / "results"
    shutil.rmtree(results / "unit-ios.xcresult", ignore_errors=True)
    shutil.rmtree(results / "unit-mac.xcresult", ignore_errors=True)
    # Signed for the simulator: an unsigned build has no keychain at all, so keychain tests would fail.
    run("iPhone unit tests", xcodebuild("-scheme", "Nollie", "-configuration", "Debug", "-destination", ios_destination(udid),
                                        "-derivedDataPath", str(WORK / "dd-ios-signed"), "-allowProvisioningUpdates",
                                        "-resultBundlePath", str(results / "unit-ios.xcresult"),
                                        "test", "-only-testing:NollieTests"), WORK / "logs/unit-ios.log")
    run("Mac unit tests (Direct)", xcodebuild("-scheme", "NollieMacDirect", "-configuration", "DirectDebug", "-destination", "platform=macOS",
                                              "-derivedDataPath", str(WORK / "dd-mac-direct"), "-allowProvisioningUpdates",
                                              "-resultBundlePath", str(results / "unit-mac.xcresult"), "test", "-only-testing:NollieMacTests"),
        WORK / "logs/unit-mac.log")
    # Nollie Runtime's own fixtures (supervisor, service, Cua installer), Direct and Store, without an install.
    run("Nollie Runtime fixtures", [sys.executable, str(ROOT / "Tools/runtime-helper/run-tests.py")], WORK / "logs/unit-runtime.log")


def tools_python():
    venv = WORK / "venv"
    python = venv / "bin" / "python"
    if not python.exists():
        subprocess.run([sys.executable, "-m", "venv", str(venv)], check=True)
        subprocess.run([str(python), "-m", "pip", "install", "-q", *PYTHON_PACKAGES], check=True)
    return python


def stage_python():
    say("Python tests")
    python = tools_python()
    for suite in PYTHON_SUITES:
        run(suite, [str(python), "-m", "unittest", "discover", "-p", "test*.py"],
            WORK / "logs" / ("python-" + suite.replace("/", "-") + ".log"), cwd=ROOT / suite)


def summary(result_bundle):
    out = subprocess.run(["xcrun", "xcresulttool", "get", "test-results", "summary", "--path", str(result_bundle)],
                         capture_output=True, text=True)
    return json.loads(out.stdout) if out.returncode == 0 else {}


def stage_ui(udid):
    say("Golden UI flows")
    python = tools_python()
    subprocess.run(["xcrun", "simctl", "boot", udid], capture_output=True)
    built = WORK / "dd-ios"
    if not run("UI build for testing", xcodebuild("-scheme", "Nollie", "-configuration", "Debug", "-destination", ios_destination(udid),
                                                  "-derivedDataPath", str(built), *UNSIGNED, "build-for-testing"), WORK / "logs/ui-build.log"):
        return
    app = built / "Build/Products/Debug-iphonesimulator/Nollie.app"
    if not run("Install the demo copy", ["/bin/bash", str(ROOT / "Tools/dev/make-demo-app-sim.sh"), str(app), udid],
               WORK / "logs/ui-demo-install.log"):
        return
    mock_log = open(WORK / "logs/ui-mock-gateway.log", "w")
    mock = subprocess.Popen([str(python), str(ROOT / "Tools/mock-gateway/mock_gateway.py"), "--port", str(MOCK_PORT),
                             "--token", "mock-token", "--neutral-models"], stdout=mock_log, stderr=subprocess.STDOUT, cwd=ROOT)
    try:
        for _ in range(50):
            try:
                urllib.request.urlopen("http://127.0.0.1:%d/api/status" % MOCK_PORT, timeout=1)
                break
            except Exception:
                time.sleep(0.2)
        time.sleep(0.5)
        if mock.poll() is not None:
            # Another checkout's mock on the same port would answer instead and test the wrong code.
            print(f"   FAILED  the mock gateway did not start on port {MOCK_PORT}, see logs/ui-mock-gateway.log")
            failures.append("Mock gateway")
            return
        env = {"TEST_RUNNER_HERMES_E2E_URL": f"http://127.0.0.1:{MOCK_PORT}", "TEST_RUNNER_HERMES_E2E_TOKEN": "mock-token",
               "TEST_RUNNER_HERMES_E2E_BUNDLE": "com.coreykozarski.nollie.demo"}
        totals = {"passedTests": 0, "failedTests": 0, "skippedTests": 0}
        # One pass per group: a long run leaves the simulator and the demo copy in states a later
        # group never expects.
        only = [n for n in os.environ.get("NOLLIE_UI_ONLY", "").split(",") if n]
        for name in only or GOLDEN_UI:
            result = WORK / f"results/ui-{name}.xcresult"
            shutil.rmtree(result, ignore_errors=True)
            run(f"UI {name}", xcodebuild("-scheme", "Nollie", "-configuration", "Debug", "-destination", ios_destination(udid),
                                         "-derivedDataPath", str(built), *UNSIGNED, "-resultBundlePath", str(result),
                                         "test-without-building", f"-only-testing:NollieUITests/{name}"),
                WORK / f"logs/ui-{name}.log", env=env)
            counts = summary(result)
            if not counts:
                failures.append(f"UI {name}: no results")
            elif not counts.get("passedTests", 0) and not counts.get("failedTests", 0):
                print(f"   FAILED  UI {name} ran no tests (is the name right?)")
                failures.append(f"UI {name}: no tests ran")
            for key in totals:
                totals[key] += counts.get(key, 0)
        print(f"   {totals['passedTests']} passed, {totals['failedTests']} failed, {totals['skippedTests']} skipped")
        if totals["skippedTests"]:
            print("   FAILED  a golden UI flow skipped, which proves nothing")
            failures.append("Golden UI flows skipped")
    finally:
        mock.send_signal(signal.SIGINT)
        try:
            mock.wait(timeout=10)
        except subprocess.TimeoutExpired:
            mock.kill()
        mock_log.close()


def main():
    stages = sys.argv[1:] or ["build", "unit", "python", "ui"]
    unknown = set(stages) - {"build", "unit", "python", "ui"}
    if unknown:
        sys.exit("Unknown stage: " + ", ".join(sorted(unknown)))
    WORK.mkdir(parents=True, exist_ok=True)
    udid = simulator_udid() if {"build", "unit", "ui"} & set(stages) else None
    for stage in stages:
        {"build": stage_build, "unit": stage_unit, "python": lambda _: stage_python(), "ui": stage_ui}[stage](udid)
    say("Result")
    if failures:
        print("Failed: " + "; ".join(failures))
        sys.exit(1)
    print("Everything passed.")


if __name__ == "__main__":
    main()
