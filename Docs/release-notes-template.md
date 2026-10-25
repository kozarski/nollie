<!--
Template for a release's notes. Copy it, fill in every {braces}, and delete this comment and any
section that has nothing to say. The release workflow starts a draft release from this file and fills
in {version} for you. The tone is Nollie's: plain, warm, short, no em-dashes.
-->
Nollie {version} {one sentence on what is better, said the way you would say it to a friend}.

**One version number for the Mac and iPhone apps.** Nollie for Mac and Nollie for iPhone and iPad share
one version number: this is {version} for both. {Say whether the two apps need each other, for example
"Use the Mac app and the phone app from the same release."}

**New in {version}**
- **{Name of the thing}.** {What a person can do now, in a sentence.}
- **{Name of the thing}.** {What a person can do now, in a sentence.}
- **Fixed.** {What was wrong, and what happens now.}

**Requirements.** A Mac with Apple silicon on macOS 26 or later, and for the phone app an iPhone or iPad on
iOS or iPadOS 26 or later. {Anything new, such as a larger download during setup.}

**Good to know.** {Anything someone would be surprised by. For example: Nollie downloads Hermes Agent
{hermes version} on first setup, about 180 MB. Using your Mac is off until you turn it on. The phone app is
on TestFlight: {link}.} {If something changes for people who already use Nollie, say what to do.}

**Checksums.** Compare `shasum -a 256 Nollie.dmg` with the number in Nollie.dmg.sha256 beside it. They
should match exactly.

Website https://nollie.app · Issues https://github.com/kozarski/nollie/issues · Security
https://github.com/kozarski/nollie/security/policy

Nollie for Mac {version} ({build}), signed with Developer ID and notarized by Apple.
SHA-256 of Nollie.dmg: {dmg sha256} · of Nollie.zip: {zip sha256}.
