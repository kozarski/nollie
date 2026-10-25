# Development

[← Nollie](../README.md) · [Contributing](contributing.md)

Use Xcode with the iOS 27 SDK and Swift 6 support.
The project targets macOS and iOS 26 or later.
All commands below run from the repository root.

## Build

| Scheme | Configuration | Purpose |
| :--- | :--- | :--- |
| `NollieMacDirect` | `DirectDebug` / `DirectRelease` | Full Mac app with owned runtime and notification helpers, and Sparkle for updates (this edition only) |
| `NollieMac` | `Debug` / `Release` | Sandboxed Mac client |
| `Nollie` | `Debug` / `Release` | iPhone and iPad |

```sh
xcodebuild -project Nollie.xcodeproj -scheme NollieMacDirect \
  -configuration DirectDebug -destination 'platform=macOS' \
  -derivedDataPath build/mac build
```

Mac builds require signing for Keychain access and helper validation.
This checkout uses team `5985LRZFZS` and bundle identifier `com.coreykozarski.nollie`.
Use valid profiles for the app and extensions. Add `-allowProvisioningUpdates` only when account provisioning
is intended; do not replace shared signing certificates to resolve a project-specific failure.

For an unsigned simulator build, replace `SIMULATOR_ID` with an available simulator's identifier:

```sh
xcodebuild -project Nollie.xcodeproj -scheme Nollie -configuration Debug \
  -destination 'platform=iOS Simulator,id=SIMULATOR_ID' \
  -derivedDataPath build/ios CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY= build
```

Physical-device installation needs a signed build and explicit device selection.
Publishing is covered separately in [Releasing](releasing.md).

## Test the changed behavior

Use `test` in place of `build`, with `-only-testing:TARGET/SUITE`.
The Mac unit-test target is `NollieMacTests`; phone tests use `NollieTests`, with UI tests in `NollieUITests`.
Target names have not changed with the move into `Tests/`.

Choose the suites for the behavior you changed. Preserve the result bundle and inspect failures before widening the run.
Tests run in parallel, so notification names, identifiers and fixtures must be unique to each case.
Coordinate any shared simulator or Derived Data directory before running another build.

UI tests use an installed demo app. Rebuild and reinstall it after changing source.
A passing fixture or simulator test does not establish device, signing, background-service or network behavior.

## Preview without personal data

The mock gateway needs Python with `websockets` available. Use a prepared development environment.

```sh
python3 Tools/mock-gateway/mock_gateway.py \
  --port 9139 --token mock-token --neutral-models
```

Use an unused loopback port. The mock serves scripted data and does not require a model account.
Its `/nollie/live` socket replays `Tools/mock-gateway/fixtures/live-desktop.hevclive`, a synthetic desktop
encoded by NollieCore's own encoder, and follows the computer fixture's state and take-over.
`GET /api/_mock/computer-preview` counts its sockets (`live_open`, `live_connections`), frames and keyframe
requests, and keeps the viewer's last report.
Do not replace a running personal gateway or reuse real credentials.

| Tool | Purpose |
| :--- | :--- |
| [make-demo-app.sh](../Tools/dev/make-demo-app.sh) | Make a separate Mac demo copy from a Debug app |
| [make-demo-app-sim.sh](../Tools/dev/make-demo-app-sim.sh) | Make and install a separate simulator demo |
| [mock_gateway.py](../Tools/mock-gateway/mock_gateway.py) | Read the available fixtures and launch flags |
| [make-live-fixture.sh](../Tools/mock-gateway/make-live-fixture.sh) | Remake the mock's live picture after a change to `LiveWire` or `LiveEncoder` (run it outside any sandbox; check the fixture in) |
| [check-latest.py](../Tools/dev/check-latest.py) | Report pins behind upstream, and check every place agrees with `Tools/pins.json` (read-only) |
| [managed-setup-dry-run.py](../Tools/dev/managed-setup-dry-run.py) | Rehearse the managed setup with the current pins in a throwaway folder (`--smoke` starts and stops both roles) |
| [hermes-overlay.py](../Tools/dev/hermes-overlay.py) | Rebuild Nollie's reviewed Hermes changes for the pinned Hermes |

Demo copies use `com.coreykozarski.nollie.demo` and the display name Nollie Demo.
Launch with `-nollie-demo-gateway http://127.0.0.1:9139 mock-token Studio -companionPromptShown YES`.
The scripts document their exact arguments. Demo-only behavior is excluded from release builds.
On the Mac demo copy, `-nollie-show-welcome -nollie-demo-install-step` opens the setup step as it is, and
`-nollie-demo-install-working` shows it part way through, without installing anything.

Capture the changed screen, including relevant loading, error and accessibility states.
Inspect the image, not only the screenshot command's exit status.
Stop only the mock and demo processes created for your task; retain the evidence you need under ignored `build/`.

## Update pinned versions

`Tools/pins.json` lists every third-party component the Mac setup installs or builds, with its version,
checksum and source. `python3 Tools/dev/check-latest.py` shows which are behind upstream; it changes nothing.

To move a pin: read the release notes, change `Tools/pins.json`, then run
`python3 Tools/dev/check-latest.py --local` and fix each place it names (the Swift plan in
`NativeDependencyInstaller.swift`, `Tools/computer-helper/pin.env`, the notices). For Hermes, also run
`python3 Tools/dev/hermes-overlay.py` (the patches must still apply), update `hermesOverlayDigest`, recheck the
source hashes in `Services/Runtime/runtime_entry.py` and run `Tools/runtime-helper/run-model-inventory-smoke.py`.
Use `--source /path/to/pinned-hermes` to rebuild the overlay without downloading. Revisit the
[remaining extension gaps](../Companions/hermes-patches/README.md) and run their Python suites when the pin changes.
For the page reader, regenerate `Companions/nollie-reader/requirements.txt` as `requirements.in` describes.
For Sparkle, change `Tools/sparkle/pin.env` and `NOLLIE_SPARKLE_VERSION` in each Direct configuration of the Mac
targets together with the pin; `check-latest.py --local` names what is left. It is linked by build settings, not as a
package product, so that only the Direct configurations get it (the next build fetches it into the cache).
Finish with `python3 -I Tools/dev/managed-setup-dry-run.py --folder <empty folder> --smoke` and `Tools/dev/verify.py`.
