# Papertrail's network filter

[← Papertrail](papertrail.md)

Status: built and tested as code, **off and not shipped** (27 Oct 2026). It needs the Network Extensions capability,
which only Corey can add in the developer portal. Until then the filter has no Xcode target and nothing installs it.

## Why

Papertrail's door sees every connection Hermes and its children make **when they use the proxy they are given**.
Some programs ignore proxy settings: SSH (and `git` over SSH), raw sockets, mail sent with `smtplib`, UDP and QUIC,
older Node. The filter is the second net: a content filter that sees every new flow on the Mac, picks out the ones
from Hermes's process tree that did not go to loopback (so did not come through the door), writes them into the bot's
Papertrail, and, with Refuse on, drops them.

## What is built

| File | What it does | Compiled in |
| :--- | :--- | :--- |
| `Services/NetworkFilter/NetworkFilterPolicy.swift` | The rules: the switch, the verdict, loopback, reading `KERN_PROCARGS2`, the bot from a process's door label, the report | Nollie Runtime, NollieMacTests |
| `Services/NetworkFilter/NetworkFilterXPC.swift` | The Mach service protocol both sides speak, and the code-signing requirements each side demands of the other | Nollie Runtime, NollieMacTests |
| `Services/NetworkFilter/PapertrailFilterProvider.swift` | The `NEFilterDataProvider`, the process tree walk, the Mach service that sends reports | No target yet; typechecked by `Tools/runtime-helper/run-tests.py` |
| `Services/NetworkFilter/Info.plist`, `NollieNetworkFilter.entitlements` | The future target's bundle and entitlements | No target yet |
| `Services/Runtime/RuntimeNetworkFilter.swift` | Nollie Runtime's side: subscribes while Hermes runs and the switch is on, writes each report as a `direct` line | Nollie Runtime |

**The switch.** `~/Library/Application Support/Nollie/RuntimeService/network-filter.json`:
`{"version": 1, "on": true, "refuse": false}`. Missing, unreadable or any other version is off; Refuse means nothing
without On. Nollie Runtime reads it at each Hermes start. Nothing in the app writes it yet.

**How a flow is judged.** The filter takes the flow's audit token, walks the process's parents (at most 32) by
`sysctl`, and checks each against Nollie Runtime's signature (identifier `com.coreykozarski.nollie.runtime`, team
`5985LRZFZS`). A flow from a process below Nollie Runtime, to anywhere but loopback, went around the door. Nollie
Runtime's own flows (the door's upstream connections among them) are not below it, so they pass. With nobody
subscribed the filter allows everything without a look: turning Nollie off turns it off.

**Whose it was.** The process's start-time environment (`KERN_PROCARGS2`) carries its door label in its proxy
variables; the nearest labelled parent's is used when its own has none. No label, no line (it is counted).

**What is sent.** Time, process id, the program's file name, host (the name the program asked for when the system
knows it, else the address), port, `tcp` or `udp`, the bot, and whether it was refused. Never an argument, a path
beyond the file name, or a byte. A refused flow never left, so it is counted, not written.

**With Refuse on**, the door also turns away programs it cannot place with a bot (403), so nothing Hermes starts
leaves without a line.

## What Corey needs to do in the developer portal

1. Certificates, Identifiers & Profiles › Identifiers › `com.coreykozarski.nollie` (the Direct app): turn on
   **Network Extensions** and **System Extension**.
2. Register a new App ID, `com.coreykozarski.nollie.network-filter`, with **Network Extensions** on.
3. Make two **Developer ID** provisioning profiles, one for each App ID above (Network Extension entitlements in a
   Developer ID build need explicit profiles), and install them.
4. The app group `5985LRZFZS.com.coreykozarski.nollie.network-filter` is team-prefixed, so macOS needs no
   registration for it; if the portal asks, register it and add it to the extension's App ID.

Then, in the project (a lead or helper can do this once the profiles exist):

5. Add a target, macOS › System Extension › Network Extension, named `NollieNetworkFilter`, bundle id
   `com.coreykozarski.nollie.network-filter`, Info.plist and entitlements from `Services/NetworkFilter/`, sources
   `PapertrailFilterProvider.swift`, `NetworkFilterPolicy.swift`, `NetworkFilterXPC.swift`,
   `PapertrailDoorBook.swift`, `ExitRelayWire.swift`, `LinkDoorHTTP.swift`, with `NOLLIE_DIRECT NOLLIE_NETWORK_FILTER`
   in its Swift conditions. Embed it in NollieMacDirect only, in `Contents/Library/SystemExtensions`.
6. Give NollieMacDirect `com.apple.developer.system-extension.install` and
   `com.apple.developer.networking.networkextension` = `content-filter-provider-systemextension`.
7. Build the app side, still to do: a Papertrail switch (Direct edition, off by default) that asks to install the
   extension (`OSSystemExtensionRequest`), turns the filter on (`NEFilterManager`, `filterSockets` on), writes the
   switch file, and restarts Hermes. macOS then asks the person to allow it in System Settings; Nollie never clicks
   that for them.
8. Prove it on a signed, notarized build: `ssh`, `git` over SSH, `nc`, a Python socket and old Node from a bot's
   terminal each show as `direct` lines, and are dropped with Refuse on; the door's own traffic is not reported.

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
- `Tests/Unit/PapertrailDoorTests.swift`: with Refuse on, the door refuses an unplaced program.
- `Tools/runtime-helper/run-tests.py` typechecks the provider with `NOLLIE_NETWORK_FILTER`.
