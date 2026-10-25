# Third-party notices

What Nollie ships or downloads, and the notice each needs. The in-app Acknowledgements screen and the
release DMG carry this list. Check it against every bundled or downloaded binary before each release.

## Inside the app
- **Cua Driver by Cua AI, Inc., as "Nollie Computer"** (Direct Mac edition only), tag
  `cua-driver-rs-v0.36.0`, unmodified, MIT. Credit: "Nollie includes Cua Driver by Cua AI, Inc., used
  under the MIT License." It links 332 Rust crates under permissive licences plus six unmodified
  MPL-2.0 UniFFI crates (source at https://github.com/mozilla/uniffi-rs). The build writes every
  licence text; the app carries them in `Contents/Resources/Notices/Nollie Computer/` (`NOTICE.txt`,
  `Cua-Driver-LICENSE.txt`, `Cua-Driver-THIRD_PARTY_NOTICES.md`, `THIRD_PARTY_NOTICES.txt`). Never
  Cua's perception add-on (AGPL models), its Node runtime or Cua Spaces. Cua and Cua Driver are Cua
  AI's trademarks: never the name of a Nollie feature. Where Nollie fetches Cua Spaces for a helper's computer, the
  interface names Cua plainly as the separate free tool it is. See
  [Nollie Computer](../nollie-computer.md).
- **Nollie's changes to Hermes Agent** (Direct Mac edition only), in `Contents/Resources/Setup Kit/hermes-overlay/`:
  nine Hermes source files as changed by Nollie's reviewed patches, one file those patches add, and two
  small Nollie helpers.
  Hermes Agent is MIT licensed by Nous Research; its licence travels with them as `LICENSE-hermes-agent.txt`.

## Linked into the Direct Mac edition
| Component | Version | Licence | Notice shown |
|---|---|---|---|
| Sparkle by the Sparkle Project | 2.10.0 | MIT, with BSD-style and zlib-style notices for a few bundled parts | `LICENSE`, Acknowledgements, and `Contents/Resources/Notices/Sparkle/LICENSE` inside the app. Code as released; its sandbox-only helper services are left out and it is signed by Nollie's Developer ID. Not in the App Store edition |

## Downloaded during setup, never bundled
Every version here is pinned, with its checksum, in `Tools/pins.json`.

| Component | Version | Licence | Notice shown |
|---|---|---|---|
| Hermes Agent by Nous Research | 0.22.2 (pinned commit) | MIT | Acknowledgements; "Built on Hermes Agent by Nous Research. Not affiliated." |
| uv by Astral | 0.13.4 | MIT or Apache-2.0 | Acknowledgements |
| Python (python-build-standalone) | 3.14.8 | PSF-2.0 and bundled licences | Acknowledgements |
| Hermes's Python packages | locked by hash | Mostly MIT, BSD, Apache-2.0 (listed from the lockfile at release) | Acknowledgements |
| Trafilatura, pypdf and their dependencies | locked by hash | Apache-2.0, BSD, MIT, MPL | Acknowledgements; only in the page reader's own environment |
| Local models | per model | Shown before download (for example Apache-2.0) | The download screen |
| hermes-cua-spaces by Cua AI, Inc. | 0.2.0 (commit `fcf30603`) | MIT | `LICENSE` and Acknowledgements. Installed by Hermes's own plugin installer into a helper's Hermes when its own computer is turned on |
| Cua Spaces by Cua AI, Inc. | 0.12.0 (CLI 0.5.0) | Cua's own terms (FSL-1.1) | Not redistributed: after the person's yes, Nollie Runtime fetches Cua's signed, notarized release from Cua's GitHub releases, checks its published SHA-256, team ID `YCK386LBJ7`, designated requirement and Gatekeeper, and copies Cua's app unmodified into Nollie's own folder (`~/Library/Application Support/Nollie/Cua`), never into Applications. A copy the person installed is used as it is and never moved or deleted. Nollie only runs its command-line tool, headless; it never opens the app. None of its code is read, copied or bundled |

## Planned for v1 (not shipped yet)
| Component | Licence | Notes |
|---|---|---|
| Lima, Colima, Docker CLI, gVisor | Apache-2.0 or MIT | For the crew's computers |
| llama.cpp | MIT | The local model engine |

Not ours to use: other projects' names, icons and bot artwork, even when their code is MIT licensed.
