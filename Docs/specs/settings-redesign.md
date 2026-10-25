# Settings, answer first

[← Architecture](../architecture.md) · [Contributing](../contributing.md)

Status: plan for the `settings-redesign` branch, 21 Oct 2026. Every Settings page on the iPhone and the Mac
follows Settings › Away from home, the page Corey approved.

## The pattern

Each page answers "what's true right now?" before anything else.

1. **Hero.** One very large SF Symbol (72 pt, hierarchical) and a big state title in the state's colour. One short
   line under it at most. `PageHero`.
2. **Facts.** A few big symbols with a word or two each. Side by side tiles only when two things are compared
   (`FactTiles`, as Without and With Tailscale), else a strip (`FactStrip`).
3. **One clear switch** on a Liquid Glass capsule (`GlassSwitch`). A page with a few switches stacks capsules
   (`GlassStack`). A choice of a few is a capsule with a menu (`GlassChoice`).
4. **Extra steps only when needed**, as Away from home shows Tailscale's steps only once the switch is on.
5. **Advanced.** Everything technical waits behind one "Advanced" row per area (`AdvancedLink`), in plain words.

Never: stacks of grey cards, a separator under every row, small grey text, BETA chips in the default view, words
like gateway, token, provider, registration, callback or API in the default view.

The pieces live in `Apps/Nollie/Settings/SettingsPage.swift`. Pages are a `SettingsPage` (a centred 560 pt column
that scrolls, on `Ink.canvas`) on both the iPhone and the Mac, in place of the grouped list and form. Glass falls
back to solid with Reduce Transparency through `nollieGlass`; symbol changes use `.contentTransition`, which
Reduce Motion already tones down; text uses Dynamic Type styles throughout.

## Models, in this order

1. **On this Mac.** Local models. Recommended, preselected and gently encouraged: "Private and free."
2. **Sign in with ChatGPT or Claude**, for plans people already pay for.
3. **Use an API key**, under Advanced.

## Bringing Papertrail and Night shift forward

The top of Settings answers two questions in two tiles, each the way to the whole story:

- **What left your Mac**: today's Papertrail across every bot that keeps one (private bots are never read).
  "Nothing today" with a green shield, or "Went online 3 times", counted as each bot's own Papertrail counts it.
  Opens a page with the same answer as its hero and one row per bot, each opening that bot's Papertrail.
- **Night shift**: the newest morning card from the last day and a half. "A quiet night", "2 jobs overnight", or
  "1 thing waits for you" in orange. Opens a page with the card itself and its Share button.

The chat list carries it too: a small Papertrail glyph inside the search field at its right edge, on the Mac and the
iPhone, with the same symbol as the tile, opening the same page; a tap anywhere else in the field searches, and Clear
takes its place while there is text. Above it, the Board is a sideways glass capsule and New Bot a round glass button
beside it, on both; the iPhone's clock is gone (Schedules is in each bot's menu).

Each bot's settings say the same for that bot under its face ("Nothing left your Mac today", "Went online 3 times
today").

Every Advanced page also leads with what's true in that layer ("Siri won't answer", "How bots move", "Version 0.1
(1)"), never a bare "Advanced" title.

## Pages

Identifiers that UI tests use stay as they are unless a page's own test is updated with it.

| Page | Hero: what's true now | Default view | Advanced |
| :--- | :--- | :--- | :--- |
| **Settings** (root) | The two summary tiles above | Category rows as glass capsules in three groups, no separators; Connection shows "Connected" as a word | Developer Mode moves from the root to About › Advanced; the Advanced category still appears only with it on |
| **Bots** | The default bot's face, "3 bots", "Nollie answers first." | Your bots as capsules, New bot, Which bot opens first, Motion (iPhone) or Animate bots (Mac) | Motion style, Tilt with your iPhone, Preview motion, "Same as your Mac" default |
| **Appearance** | Theme symbol, "Light", "Dark" or "Matches your iPhone"; "Liquid Glass on." | Theme choice, accent swatches, Liquid Glass switch, Chat summaries row | Glass strength, text size and bubbles, More chat options (today's Advanced chat display), Start over |
| **Summaries** | "Up to date", "Summaries off" or "Needs Apple Intelligence" | One switch for summaries | Titles, Previews, Status line, Forget every summary |
| **Notifications** | From permission and iCloud alerts: "You'll hear back" (green), "Alerts while Nollie is open", "Alerts are off" (red, with Open Settings), "Nollie can tell you" (with Allow), "Sign in to iCloud" | Allow or Open Settings when needed; switches for Alerts when Nollie is closed (iCloud alerts), Hide details, Haptics (iPhone), Keep checking while closed (Mac) | Check alerts (test and diagnostics), What iPhone allows, Taps while typing, Stay quiet when I'm at my Mac, Companion |
| **Notifications › Advanced › Check alerts** (today's iCloud alerts details) | "Alerts arrive", "Send a test to be sure", "Test on its way" | Send a test, Did it arrive?, Check again | Details disclosure, in plain words: "Signed up with Apple", "iCloud is watching", "Same iCloud on both", "Set up doesn't mean delivered. A test shows they arrive.", "Alerts since Nollie opened: 3 arrived, 1 opened" |
| **Privacy** | "Locked with Face ID" (green) or "No lock" (blue, calm): "Anyone holding your iPhone can open Nollie." | The lock switch; "Ask again for approvals" choice (Risky ones, Every one, Never) | None needed |
| **Sign-ins** (Mac) | "No sign-ins yet" or "3 sign-ins": "Nollie types it in. Helpers are never told the password." | Add sign-in, each saved sign-in as a capsule, last use as one line | Recent uses (the 30-day history) |
| **Siri & Shortcuts** | "Ask Siri", "Chats show in Spotlight too." | Spotlight switch; what to say as a few phrases | Answer approvals by voice |
| **Connection** | "Connected": "Studio is ready." / "Linked to your Mac" / "Connecting" / "Sign in again" / "Can't reach your Mac" / "Let's set up Nollie" | Models row with the plain choice ("On this Mac"), Review setup, Use Nollie on your iPhone or Scan QR code, Reconnect when needed | Your assistants (switch, remove), Add one by address, Edit, Connection details, Saved sign-ins with Forget |
| **Connection › Models** | "On this Mac", "ChatGPT plan", "Getting your model 1.4 of 3.5 GB", "Choose how Nollie thinks" | Choices in order: On this Mac (Recommended, preselected), Sign in with ChatGPT or Claude | Use an API key, Use both, Other models, model details, Test a reply |
| **Linked devices** (Mac sheet) | "Use Nollie on your iPhone" / "Linked to Corey's iPhone" | The code, linked iPhones | Last active times, background service wording |
| **Away from home** | Unchanged (the model); the floating back button no longer covers the tiles when scrolled | | |
| **About** | Nollie's wordmark, "Your own crew of helpers, on your Mac and iPhone." | Acknowledgements, Remove | Version and build, Developer Mode |
| **Acknowledgements** | "Thanks", "Nollie is built on open work by others." | The notices, unchanged in substance (licence obligation) | |
| **Remove** | "Remove Nollie" (red trash), "See what goes before anything happens." | The one Remove button | |
| **Remove sheet** | Review: "Remove Nollie from this Mac", "This can't be undone." Working: "Removing Nollie". Finished: "Nollie is in the Trash" (green) | What goes, what stays, the iCloud switch, Cancel and Remove | The long details of each part stay in the list |
| **Advanced** (Developer Mode) | The worst Status light: "All good", "Needs a look", "Something is off" | Hermes dashboard, Companion, Status, Troubleshooting | It is the Advanced area |
| **Status** | Worst light wins, same words | One capsule per area with its light | Details per row, versions |
| **Troubleshooting** | "What's wrong?" | One capsule per topic | Server specifics stay in each topic |
| **What left your Mac** (new) | "Nothing left your Mac today" | One capsule per bot with today's count | |
| **Night shift** (new) | "A quiet night" / "2 jobs overnight" | The morning card with Share | |
| **Bot settings** | The bot's face and name, then the Papertrail line for today | Tabs as today | Raw model ids, home path |
| **Bot settings › Papertrail** | "Stayed on your Mac" (green), "Went online 3 times today" (blue), "Not recording yet", "Couldn't check" | Totals and today's rows, route and time only | Token counts, models, hosts (today's Developer Mode details) |
| **Bot settings › Computer** | "Hands off your Mac", "Can use your Mac", "Using your Mac", "Has its own computer" | Allow Mac control, its own computer | Nollie Computer beta, Mac permissions, reset and remove its computer |
| **Bot settings › Model** | "On this Mac", "Claude plan", "Uses an API key" | The plain choices | The full model menu with raw ids |

Pages that stay as they are in this pass, because they are flows or tools rather than settings: the Companion
setup wizard (already behind Advanced), Connect by address (`GatewayFormView`), the pairing scanner, Schedules,
Apps & access's tool lists, History and What it knows, the Computer sheet and the Mac's permissions window (already
close to the pattern). Each is a candidate for its own pass.

## Fixes in this pass

- iPhone, Away from home: the floating back button covered the "Without Tailscale" tile's title when scrolled. Every
  `SettingsPage` (and Away from home) now uses the hard top scroll edge, so words under the button fade out.
- Remove Nollie: the finished sheet ("Nollie is in the Trash") kept the review sheet's height. It now fits its
  content on the Mac and the iPhone.

## Proof

`Tools/dev/verify.py` on one simulator (`NOLLIE_MOCK_PORT=9207`), and before and after pictures of each page on the
iPhone simulator and in Mac window captures of the demo copy, light and dark.
