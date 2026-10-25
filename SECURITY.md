# Security

Nollie lets AI helpers work on your Mac, and lets your iPhone check in on them and approve what they ask
to do. A flaw in it matters, so please report one privately.

## Reporting a problem

Use **Report a vulnerability** on this repository's
[Security tab](https://github.com/kozarski/nollie/security/advisories/new). Only you and Corey can see it.

Say what you found, how to make it happen, and which version of Nollie you used (Settings › About shows it
at the top). Please don't open a public issue or pull request about it, and give a fix time to ship before
you write about it. Never include your own keys, tokens or chats.

Nollie is made by one person. You can expect a first reply within a week, and a fix, or a plain
explanation of why not, as soon as it is understood. Fixes ship in the newest release, and the release
notes say so.

## What is in scope

- The Nollie app on Mac, iPhone and iPad.
- Nollie Runtime, the helper that sets up and runs Hermes for you, and the checks it makes on what it
  downloads.
- Nollie Link, the connection from your iPhone to your Mac, and pairing with the QR code.
  [Nollie Link](Docs/nollie-link.md) has the threat model.
- Nollie Computer, a helper using apps on your Mac with your approval, and the helpers' own computers.
  [Nollie Computer](Docs/nollie-computer.md) says what keeps a helper in check.
- Ask first, saved sign-ins and Stop. [Ask first](Docs/ask-first.md) and
  [Saved sign-ins](Docs/saved-sign-ins.md) say what they hold back and what they can't see.
- The companions in `Companions/`, Nollie's add-ons for Hermes.
- The release files on GitHub and their checksums.

[How Nollie keeps you safe](Docs/security-note.md) says what is built today and what is only planned.

## What is not in scope

- **Hermes Agent** by Nous Research. Nollie downloads it unchanged apart from the small, reviewed changes
  listed in [Notices](Docs/legal/notices.md). A flaw in Hermes itself is for
  [Nous Research](https://github.com/NousResearch/hermes-agent/security).
- **Cua** and the tools around it. A flaw in Cua itself is for
  [Cua](https://github.com/trycua/cua/security).
- Model providers, Tailscale, Apple's own services, and anything that needs someone to already control
  your Mac or your unlocked phone.

If you aren't sure which side a problem is on, report it here and Corey will pass it on.

## Known, and by design

A linked iPhone can do what Nollie on the phone does, including approving what a helper asks to do. Treat a
linked phone like a key to your helpers, and remove it on the Mac if it is lost. The Direct edition of
Nollie for Mac has no sandbox, so a process already running as you can change Nollie's settings. The two
guides linked above list the rest.
