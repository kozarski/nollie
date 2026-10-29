# Releasing

[← Nollie](../README.md) · [Development](development.md)

Nollie for Mac is a notarized download on GitHub Releases. The iPhone and iPad app goes out through
TestFlight now and the App Store later. Corey makes every release by hand, on his own Mac, because the
Developer ID certificate and the notary login never leave it.
A successful development build is not distribution approval or clean-machine acceptance.

## Distribution paths

| Build | Path | Boundary |
| :--- | :--- | :--- |
| Direct Mac | GitHub Releases: Developer ID signed, notarized DMG and zip | Includes the owned runtime and optional background helpers, and updates itself with Sparkle |
| iPhone / iPad | TestFlight now, App Store later | Remote client; no downloaded Hermes runtime |
| Sandboxed Mac client | Mac TestFlight / App Store evaluation | Connects to an existing setup |
| Homebrew cask `kozarski/nollie/nollie` | Coming soon: points at the same DMG | Nothing extra to sign |

Keep runtime installation compiled behind `NOLLIE_DIRECT`.
Do not weaken sandboxing, signature checks, download verification or Gatekeeper to make packaging pass.

The project-wide identity is `com.coreykozarski.nollie`, with child bundle identifiers for extensions.
Signing profiles, entitlements, App Store Connect records and CloudKit environments must agree.
Retain the exact root [LICENSE](../LICENSE) in distributed bundles.

## One version number

The Mac app and the iPhone app share one version number, `MARKETING_VERSION`, the same in every target.
The build number, `CURRENT_PROJECT_VERSION`, goes up with every upload. A release is tagged `v` plus the
version, such as `v1.0`. The release workflow refuses a tag that does not match.

## One command: ship.sh

`Tools/release/ship.sh <version>` makes a whole release, one step at a time, and stops for Corey's yes
before anything leaves this Mac. Run it from the repository root, on the branch the release comes from.

```sh
Tools/release/ship.sh 1.3 --dry-run     # rehearse it: every local step, nothing sent
Tools/release/ship.sh 1.3               # the real thing
Tools/release/ship.sh 1.3 --status      # what is done so far
Tools/release/ship.sh 1.3 --from mac    # go again from a step
```

| Step | What it does | Sends? |
| :--- | :--- | :--- |
| `preflight` | Clean tree; every commit since the last tag is Corey's, with no attribution lines and no mention of AI tools; no secrets in the tree or in what was added since; the Developer ID signer and the gh login are Corey's; the CloudKit production schema matches `Tools/cloudkit/nollie-alerts.ckdb`; the notes are finished; every version and build number agrees; Corey's own key is set for uploads and the team key only for notarization; the site is committed | No, it only reads |
| `bump` | Sets `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` in every place and commits "Nollie 1.3: version 1.3 (7)" | No |
| `check` | The full check, `Tools/dev/verify.py` (`--check-stages build unit` for fewer) | No |
| `mac` | `direct-release.sh`, then the checksums go into the notes, the appcast is written again with them, and `Nollie.dmg`, `Nollie.zip`, their `.sha256` files and `appcast.xml` are put in `build/ship/<version>/assets` | Apple's notary service |
| `ios` | Builds and checks the iPhone, iPad and Watch app, shows the exact `.ipa`, then uploads it | TestFlight |
| `macstore` | The same for the Mac App Store `.pkg` | TestFlight |
| `draft` | Tags the release commit, checks every commit that would be pushed, pushes the branch, makes the draft release with the files and notes, then pushes the tag | GitHub |
| `appcast` | Checks the files and the appcast, then reads the draft back: every file unchanged, the notes the same as the appcast's | No, it only reads |
| `publish` | Publishes the draft, then waits until the live appcast offers the new version | GitHub |
| `site` | Deploys nollie.app with wrangler, then checks the live page is this `index.html` | Cloudflare |

**Checkpoints.** Before each send, the script shows exactly what will go and where (each file with its size
and SHA-256, and the command it will run) and asks for `yes`. Anything else stops it, and nothing is sent.
Where there is no terminal to ask in, it stops at the checkpoint; once Corey has said yes, carry on with
`--from <step> --approve <step>`. The script refuses any send that has not passed its checkpoint, so a step
cannot send by accident.

**Resuming.** Progress is kept in `build/ship/<version>/state.json`. Running the same command again carries on
from the first step not yet done. A build that is already made and checked is not made again: if the iPhone
upload stopped at its checkpoint, the next run shows the same `.ipa` and uploads that one.

**Keys.** Uploads use Corey's own App Store Connect key from `Tools/release/.env` (`ASC_KEY_KIND=individual`), so
they show his name. The Mac download is notarized with the team key `LA7B5435SG` from
`~/.asc/keys/AuthKey_LA7B5435SG.p8`; its issuer comes from `NOLLIE_NOTARY_ISSUER_ID` or the `asc` tool's
`~/.asc/config.json`. Each tool gets only its own key: the team key never reaches `testflight.sh`, and the
preflight stops if `.env` names it.

**Notes.** Write them in `Docs/releases/<version>.md` (or pass `--notes <file>`), from
[release-notes-template.md](release-notes-template.md). Leave `{build}`, `{dmg sha256}` and `{zip sha256}` as
they are: the `mac` step fills them in once the files exist, before the appcast is written, so the update
window and the release page say the same thing. Any other `{braces}` stop the preflight.

**Dry run.** `--dry-run` works on a throwaway checkout in `build/ship/<version>-dry-run/checkout`, so the branch
is not touched and no tag is made. It runs the preflight, the bump commit, the full check and all three builds;
signs the app, the DMG and the zip with Developer ID; makes the checksums; and writes an appcast signed with a
stand-in key, which installed copies would refuse. It reads the remote tags, the CloudKit production schema,
the gh login and the published appcast, and contacts nothing else: no App Store Connect, no notary service, no
push, no release, no deploy. Everything a real run would send is in `would-send.txt` beside it. A dry run
does not need `Tools/release/.env`. Afterwards, `--dry-run --clean` removes the checkout, its builds and its
Xcode caches, and keeps the reports.

Builds take the shared lock, `/tmp/nollie-xcodebuild.lock` (`NOLLIE_BUILD_LOCK` to change it), so they wait
their turn behind other checkouts.

## Making a release by hand

`ship.sh` does all of this. These are the same steps on their own, for when one needs doing by hand.
Run them from the repository root, on a clean branch that has passed CI and `Tools/dev/verify.py`.

1. **Choose the version.** Set `MARKETING_VERSION` everywhere and raise the build number. Commit it.
2. **Write the notes.** Copy [release-notes-template.md](release-notes-template.md) and fill it in. The
   shape is: a sentence on what is better, one version number for both apps, what is new, requirements,
   good to know, checksums. Keep it plain, warm and short, with no em-dashes.
3. **Build the Mac app.** `Tools/release/direct-release.sh` archives `NollieMacDirect`, signs it with
   Developer ID, has Apple notarize and staple it, checks Gatekeeper accepts it, then makes a signed
   DMG and a zip in `build/release/<date-time>/`. The DMG is notarized too when `NOTARY_PROFILE` names a
   `notarytool` keychain profile, or when the App Store Connect key settings `testflight.sh` uses
   (`ASC_KEY_ID`, `ASC_ISSUER_ID`, `ASC_KEY_PATH`) are set; without either it warns at the end, and the DMG
   must not ship until it is notarized and stapled. It then signs the DMG and the zip for Sparkle and writes
   `appcast.xml` beside them (see [Automatic updates](#automatic-updates-direct-mac)). It stops before
   building anything if the update key is still the placeholder. With `DRY_RUN=1` it sends nothing to Apple:
   it signs with Developer ID here, skips the checks that need Apple's ticket, and signs the appcast with a
   stand-in key.
4. **Name and checksum the files.** Give them the plain names the download links use, then write a checksum
   file beside each. `appcast.xml` keeps its name; it already points at `Nollie.zip`:

   ```sh
   cd build/release/<date-time>
   cp Nollie-<version>-<build>.dmg Nollie.dmg
   cp Nollie-<version>-<build>.zip Nollie.zip
   shasum -a 256 Nollie.dmg > Nollie.dmg.sha256
   shasum -a 256 Nollie.zip > Nollie.zip.sha256
   ```

5. **Try the DMG once.** Open it on a Mac that has never run Nollie and check the first screens, as the
   [acceptance table](#acceptance-still-needed) asks. Look at it, do not assume.
6. **Tag it.** `git tag v<version>` on the release commit. Pushing the tag needs Corey's yes. The
   [Release workflow](../.github/workflows/release.yml) then checks the tag against the app's version and
   starts a draft release from the notes template.
7. **Publish.** Put the final notes in the draft. Then run `Tools/release/sparkle-appcast.sh build/release/<date-time>`
   again, so `appcast.xml` carries those notes (step 3 had none to read yet). Add the files to the draft and
   press Publish. By hand:

   ```sh
   gh release create v<version> --repo kozarski/nollie --title "Nollie <version>" \
     --notes-file notes.md \
     Nollie.dmg Nollie.dmg.sha256 Nollie.zip Nollie.zip.sha256 appcast.xml
   ```

   Use `--draft` first if you want to look at it on GitHub before anyone else can. To check a draft, run
   the Release workflow with action `check` and the tag: it downloads the files, checks every checksum file,
   confirms the disk image's notarization ticket is stapled and that Gatekeeper accepts the app inside,
   checks that `appcast.xml` names this tag's `Nollie.zip` with its exact length and a signature, and puts
   the checksums in its summary for the notes. Publishing is what makes `appcast.xml` the latest one: the
   app reads `releases/latest/download/appcast.xml`, so a draft updates nobody.
8. **Phone app.** `Tools/release/testflight.sh` sends it to TestFlight (see below). Say in the notes which
   build goes with the release, and give the TestFlight link.
9. **Afterwards.** When the Homebrew cask exists, update its version and checksum to the new DMG's.
   Update the download link on nollie.app. Keep the signing log and the checksums in the release record.

Never put a signing certificate, notary key or App Store Connect key in GitHub or in this repository.

## Automatic updates (Direct Mac)

The Direct Mac app updates itself with [Sparkle](https://sparkle-project.org). The App Store edition does
not: the Mac App Store does its updates, and nothing of Sparkle is compiled into or embedded in that
build. The app asks once a day (a switch in Settings, About: "Check for updates automatically"), has
Check for Updates… in the app menu, and always asks before it installs.

How it works: the app reads `https://github.com/kozarski/nollie/releases/latest/download/appcast.xml`. The
appcast lists the newest zip on GitHub Releases with an EdDSA signature. The app only installs an update
signed by the key it carries (`SUPublicEDKey`), and checks the signature before it unpacks anything.
Apple's notarization and Developer ID signature still apply to the app inside.

### One time: make the key

```sh
Tools/release/sparkle-keys.sh --backup ~/Desktop/nollie-sparkle-key.txt
```

This runs Sparkle's `generate_keys`. The private key goes into your login keychain (macOS may ask whether to
allow it), and the public key is written to `Tools/sparkle/update-feed.env`. Commit that file. Until then it
holds a placeholder, and `direct-release.sh` refuses to build.

`--backup` also saves the private key to that file with `generate_keys -x`. Put the file in 1Password, then
delete it. The key is the only thing that lets you ship updates to apps that are already out: lose it and
nobody gets another update from the app (they would have to download a new copy by hand). To use it on another
Mac, import it there with `generate_keys -f <file>` (the tool is in `~/Library/Caches/Nollie/sparkle/<version>/bin/`,
and `Tools/sparkle/fetch-sparkle.sh` puts it there). Never change the key in `update-feed.env` once a release
is out; `sparkle-keys.sh` refuses to unless you pass `--replace`.

### Each release

`direct-release.sh` does these after the notarized zip and DMG exist; `Tools/release/sparkle-appcast.sh <folder>`
does them on its own and can be run again.

1. Checks the key in your keychain is the one inside the app. If not, nothing is signed. With
   `SPARKLE_KEY_FILE` set to the backup file, it signs from that file instead and skips the keychain. From
   the keychain, macOS asks once whether `sign_update` may use the key, and the script waits until someone
   answers (choose Always Allow).
2. Signs the zip and the DMG with `sign_update` (the signatures are saved in `sparkle-signatures.txt`), then
   checks each signature against the key inside the app with `Tools/sparkle/verify-signature.swift`, as an
   installed copy would. If one does not match, nothing is written.
3. Makes `appcast.xml` with `generate_appcast`: it starts from the latest published appcast, so earlier
   versions stay in the feed, and adds this one. The text people see in the update window is the GitHub
   release's notes, read with `gh release view`. If the release does not exist yet there are no notes to read:
   write them in the draft, then run `sparkle-appcast.sh` again.
4. Checks the result with `Tools/release/check_appcast.py` (this tag's zip, its exact length, a signature).

Upload `Nollie.dmg`, `Nollie.zip`, their `.sha256` files and `appcast.xml` to the release. Sparkle installs
from the zip. The build number (`CURRENT_PROJECT_VERSION`) must be higher than the last release's, or no one is
offered the update.

### Installing safely

Before Sparkle quits Nollie to install, the app (Apps/Mac/Update) does three things, in order:

- A bot using this Mac (Nollie Computer) is stopped.
- Turns that are running on Nollie's own background service are given up to a minute to finish. Any that
  are still going are paused, and their chats say so ("Paused for an update").
  Turns on a gateway elsewhere are not touched, since an update to this app does not affect them.
- Then Sparkle quits Nollie, swaps the app and opens the new one.

Nollie Runtime (the background service in the app) is not restarted by the app. It watches the app it lives
in, and when a new copy has replaced the old one it stops Hermes, exits, and launchd starts the new version
from the new app, which then picks the saved setup back up (see `AppPresence`). That takes up to a minute
after the update. The new app waits for it and reconnects by itself.

Pinned version: Sparkle's version is in `Tools/sparkle/pin.env` and `Tools/pins.json` (see
[Update pinned versions](development.md#update-pinned-versions)). The Direct build fetches it into
`~/Library/Caches/Nollie/sparkle/`, checks its size and SHA-256, and signs it with the build's own identity.

## TestFlight tooling

[Tools/release/testflight.sh](../Tools/release/testflight.sh) archives and exports the phone or sandboxed Mac client.
It is not the Developer ID packaging path for `NollieMacDirect`.

The script requires explicit `ASC_APP_ID`, `ASC_KEY_ID`, `ASC_ISSUER_ID` and `ASC_KEY_PATH`.
Its guard verifies the intended app record before work begins.
Keep private keys outside the repository and never include credential values in logs or documentation.

`DRY_RUN=1` prevents upload, but still performs archive/export and authenticated account checks.
Add `OFFLINE=1` and a `BUILD_NUMBER` to skip App Store Connect as well, for a rehearsal that contacts nothing.
`UPLOAD_PRODUCT=<.ipa or .pkg>` uploads an export a dry run made, after checking it again, without building it
a second time; `ship.sh` uses it so the file shown at the checkpoint is the file that goes.
Inspect the script and export options before running it.
An actual upload or external release action needs Corey's approval.

## Demo mode

App Review and curious testers have no Mac running Hermes, so every build has a demo: **Try a demo** on the
first screen, after Get started. It runs on a made-up gateway inside the app (`DemoGateway` in NollieCore).
It has four bots, a few chats, a Board, a Night shift card and an Ask first card to Allow or Deny, and a
message sent in any chat gets a short scripted reply. It never touches the Keychain, a saved gateway, the
network, push or notifications. A "Demo" pill stays at the top, and tapping it (or Settings, Leave demo)
puts everything back as it was. Quitting the app also ends the demo.

Paste this into the App Review notes:

> Nollie connects to the person's own Mac, which a reviewer does not have. Tap "Try a demo" on the first
> screen to use the whole app on sample data. No account or sign-in is needed. Tap the "Demo" pill at the
> top, or Settings, then "Leave demo", to go back to the first screen.

To check it: `Tools/dev/verify.py ui` runs `DemoModeUITests` (tap Try a demo, send a message, see the reply,
answer the Ask first card, leave). Pictures of the demo come from that test, with `TEST_RUNNER_NOLLIE_SHOTS=<folder>` set.
In a Debug Mac demo copy, `-nollie-demo-start` taps Try a demo at launch and `-nollie-demo-start-chat <bot>`
opens that bot's chat.

## Acceptance still needed

| Area | Required proof |
| :--- | :--- |
| Fresh models | Real local download, a verified local reply, and supported online account sign-in |
| Phone pairing | Secure reachable transport, owner authentication, physical enrollment and revocation |
| Managed notifications | Follow the runtime after an endpoint change |
| Detailed alerts | Physical preview policy and closed-app tap to the intended reply |
| Computer setup | Packaged adapter, native permissions and truthful control boundaries |
| Installation | Clean-machine install, interruption recovery, upgrade, Remove Nollie on a real install (Login Items and Privacy & Security afterwards) and dragging Nollie to the Trash while Nollie Runtime runs |
| Distribution | Signed archive, embedded-helper parity, notarization where applicable and production CloudKit delivery |

Existing-Hermes development use has a real closed-app alert pass.
That does not prove fresh managed setup, detailed notification routing or production delivery.
Record what was actually exercised, the build and environment, and the remaining limits.

## Release record

Keep a small checklist with the source revision, version/build, signing identities, test results and inspected screenshots.
Verify the app and each embedded helper come from the same build.
Keep required notices and the rollback path; do not publish credentials, personal transcripts or private fixtures.
