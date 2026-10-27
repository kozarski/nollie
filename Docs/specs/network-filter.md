# Papertrail's network filter

[← Papertrail](papertrail.md)

Status: built, embedded behind one project switch, and **off** (27 Oct 2026). The only step left is Corey's in the
developer portal, then flipping `NOLLIE_NETWORK_FILTER_READY` to `YES`.

## Why

Papertrail's door sees every connection Hermes and its children make **when they use the proxy they are given**.
Some programs ignore proxy settings: SSH (and `git` over SSH), raw sockets, mail sent with `smtplib`, UDP and QUIC,
older Node. The filter is the second net: a content filter that sees every new flow on the Mac, picks out the ones
from Hermes's process tree that did not go to loopback (so did not come through the door), writes them into the bot's
Papertrail, and, with Refuse on, drops them.

## What is built

| File | What it does | Compiled in |
| :--- | :--- | :--- |
| `Services/NetworkFilter/NetworkFilterPolicy.swift` | The rules: the switch, the verdict, loopback, reading `KERN_PROCARGS2`, the bot from a process's door label, the report | Nollie Runtime, the filter, NollieMacTests |
| `Services/NetworkFilter/NetworkFilterXPC.swift` | The Mach service protocol both sides speak, and the code-signing requirements each side demands of the other | Nollie Runtime, the filter, NollieMacTests |
| `Services/NetworkFilter/PapertrailFilterProvider.swift` | The `NEFilterDataProvider`, the process tree walk, the Mach service that sends reports | Target `NollieNetworkFilter` |
| `Services/NetworkFilter/Info.plist`, `NollieNetworkFilter.entitlements` | The extension's bundle and its entitlements | Target `NollieNetworkFilter` |
| `Services/Runtime/RuntimeNetworkFilter.swift` | Nollie Runtime's side: subscribes while Hermes runs and the switch is on, writes each report as a `direct` line | Nollie Runtime |
| `Tools/network-filter/embed-network-filter.sh` | Puts the extension in `Contents/Library/SystemExtensions` of the Direct app, only when the project switch is `YES` | NollieMac's "Embed Network Filter" phase |
| `Apps/Mac/PapertrailFilterSwitch.swift` | The switch on Settings › What left your Mac, the install and approval flow, the switch file | NollieMac, Direct configurations only |
| `Apps/Mac/NollieMacDirectFilter.entitlements` | The Direct app's entitlements plus `system-extension.install` and the content filter | Used only when the project switch is `YES` |

**The target.** `NollieNetworkFilter` (macOS system extension, bundle id `com.coreykozarski.nollie.network-filter`,
product `com.coreykozarski.nollie.network-filter.systemextension`, links `libbsm`). NollieMac depends on it in every
configuration, the way it depends on Nollie Runtime, but only the Direct configurations can embed it, and the embed
script fails a client (store) build that somehow carries one. In Debug and Release (store) it is always signed ad hoc
and never leaves the build folder.

**The project switch.** `NOLLIE_NETWORK_FILTER_READY` in the project's DirectDebug and DirectRelease settings, `NO`
today. While `NO`: the extension is signed ad hoc (no profile is asked for, nothing in the portal changes), it is not
embedded, and the Direct app keeps its usual entitlements (`NollieMacDirect.entitlements`). At `YES`: the extension is
signed automatically with `NollieNetworkFilter.entitlements`, embedded, and the app signs with
`NollieMacDirectFilter.entitlements`. Unsigned builds (`CODE_SIGNING_ALLOWED=NO`) build either way.

**The switch people see.** One toggle, "Stop what Papertrail can't see", on Settings › What left your Mac, Direct
edition only. Off until the extension is approved, and disabled with "Not in this version of Nollie yet." while this
copy of Nollie doesn't carry it. Turning it on:

1. asks macOS to install the extension (`OSSystemExtensionRequest`). macOS shows its own notice; the page says
   "Allow Nollie Papertrail in System Settings › Login Items & Extensions." with an Open System Settings button;
2. once installed, turns the filter on (`NEFilterManager`, sockets only). macOS asks "Allow" or "Don't Allow"; the
   page says "Choose Allow when your Mac asks about filtering.";
3. once allowed, writes `RuntimeService/network-filter.json` as `{"version": 1, "on": true, "refuse": true}`.

On always means Refuse (Corey, 27 Oct): with it on, nothing Hermes starts leaves without a line. Nollie Runtime rereads
the file every 5 seconds while Hermes runs, so it applies without a restart: the door starts refusing programs it
can't place with a bot, and the filter link subscribes. Turning it off writes `on: false` and turns the filter off;
the extension stays installed. Saying Don't Allow leaves everything off. Nollie never answers a macOS prompt for the
person. The demo copy never asks macOS for anything; `-nollie-demo-filter on|waiting|asking` shows a state for pictures.

**How a flow is judged.** The filter takes the flow's audit token, walks the process's parents (at most 32) by
`sysctl`, and checks each against Nollie Runtime's signature (identifier `com.coreykozarski.nollie.runtime`, team
`5985LRZFZS`). A flow from a process below Nollie Runtime, to anywhere but loopback, went around the door. Nollie
Runtime's own flows (the door's upstream connections among them) are not below it, so they pass. With nobody
subscribed the filter allows everything without a look.

**Whose it was.** The process's start-time environment (`KERN_PROCARGS2`) carries its door label in its proxy
variables; the nearest labelled parent's is used when its own has none. No label, no line (it is counted).

**What is sent.** Time, process id, the program's file name, host (the name the program asked for when the system
knows it, else the address), port, `tcp` or `udp`, the bot, and whether it was refused. Never an argument, a path
beyond the file name, or a byte. A refused flow never left, so it is counted, not written.

## What Corey needs to do

In the developer portal (Certificates, Identifiers & Profiles):

1. Identifiers › `com.coreykozarski.nollie`: turn on **Network Extensions** and **System Extension**.
2. Register a new App ID, `com.coreykozarski.nollie.network-filter`, with **Network Extensions** on.
3. Make a **Developer ID** provisioning profile for each of those two App IDs (for `direct-release.sh`), and install
   them. Development builds can let Xcode make development profiles once 1 and 2 are done.

Then in the project:

4. Set `NOLLIE_NETWORK_FILTER_READY = YES` in the project's DirectDebug and DirectRelease build settings (one line
   each in `Nollie.xcodeproj`), and point `direct-release.sh`'s export options at the two new profiles if it names
   profiles explicitly.
5. Build, notarize and install a Direct copy, turn on "Stop what Papertrail can't see", and allow it twice in macOS.
   Check: `ssh`, `git` over SSH, `nc`, a Python socket and old Node from a bot's terminal are refused; a program a
   helper starts through `os.system` is refused by the door; ordinary chats, searches and pages still work; the door's
   own traffic is not reported.

## What "exactly" still misses, even with the filter on

- **Name lookups.** A program's lookups are made by the system resolver (`mDNSResponder`), whose flows are not
  Hermes's. The names Hermes's programs look up leave the Mac unrecorded (only the name, not what follows).
- **Programs that leave the tree.** A process that detaches and is re-parented to `launchd` (a double fork, a
  `launchctl` job, an app opened through Launch Services such as a browser) no longer has Nollie Runtime above it.
- **Work done for Hermes by something else.** Another app told to act (Mail asked to send by AppleScript), system
  services (background downloads, iCloud) and helpers' own computers (Cua's virtual machines) show as theirs.
- **Not Hermes:** Nollie.app's own connections (update checks, iCloud alerts).
- **Not proven:** that a sandboxed filter may read other processes' start-time environment and check their
  signatures (if not, the bot falls back to none and the flow is counted, not written), and the filter's cost on a
  busy Mac.

## Tests

- `Tests/Unit/NetworkFilterPolicyTests.swift` (NollieMacTests): the verdict for every place a process can be, the
  switch, loopback, `KERN_PROCARGS2` parsing, labels.
- `Services/Runtime/Tests/RuntimeNetworkFilterTests.swift` (run-tests.py): reports become `direct` lines; refused,
  unplaced and malformed ones are only counted; the switch file.
- `Tests/Unit/PapertrailDoorTests.swift`: with Refuse on, the door refuses an unplaced program, and lets it pass
  again when the switch goes off while Hermes runs.
- `Tests/Unit/PapertrailFilterSwitchTests.swift` (NollieMacTests): On always writes Refuse, the words for each state,
  and that this build carries no extension.
- `Tools/runtime-helper/run-tests.py` also typechecks the provider; the `NollieNetworkFilter` target builds it.
