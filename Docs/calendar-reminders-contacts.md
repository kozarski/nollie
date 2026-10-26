# Calendar, Reminders and Contacts

[← Nollie](../README.md) · [Ask first](ask-first.md) · [Permissions](permissions.md) · [Saved sign-ins](saved-sign-ins.md)

A helper can look at the calendar, reminders and contacts on the person's Mac, and add or change them
only after the person says yes. Each helper has three switches, all off to start: Bot settings › Apps,
"Calendar", "Reminders", "Contacts". The data stays in the Mac's own apps. The iPhone shows the same
switches and the same cards; it never touches the phone's own calendar.

## How it works

1. **Switch on.** On the Mac that runs Hermes, turning a switch on shows the macOS prompt at that
   moment (it names Nollie, since Nollie reads the apps itself). A no leaves the switch off. Turned on
   from the iPhone, the switch saves and, until the Mac allows it, says "Allow Calendar in Nollie on your Mac."
2. **A helper calls a tool.** The workflow add-on gives every bot that is not private these tools, each
   area in its own toolset (`nollie_calendar`, `nollie_reminders`, `nollie_contacts`), shown to the
   model only while that switch is on:

   | Look | Change (always asks) |
   | :--- | :--- |
   | `calendar_events` (a range, default the next 7 days), `calendar_search` | `calendar_add_event`, `calendar_change_event`, `calendar_delete_event` |
   | `reminder_lists`, `reminders_open` | `reminder_add`, `reminder_complete`, `reminder_delete` |
   | `contacts_search` (name, phones, emails, birthday only) | `contact_add`, `contact_change` |

3. **The Mac answers.** The call becomes a request file in the main bot's home. Nollie on the Mac
   looks for open requests (each second while any switch is on, every 10 seconds otherwise) and, for a
   helper whose switch is on and an area macOS allows:
   - a look is answered from the apps and the file is deleted once the tool has it;
   - a change is **worded, not made**: "Add “Dentist” on Tue 3 Nov, 10:00 to Home calendar?" The Mac
     remembers exactly what it worded.
4. **The person says yes or no.** The tool asks through Hermes's own approval gate with those words.
   The card is Ask first's (`plugin_rule:nollie-ask-first:<calendar|reminders|contacts>:<id>`), with a
   fresh key per call and only Allow once or Deny, on the Mac, the iPhone and in a notification.
5. **Only after a yes** the request is marked approved and the Mac makes the change it worded, if what
   it changes still looks as it did when the card was shown. Otherwise nothing changes and the helper
   is told to look again.

## Fixed rules, not judgement

- Every add, change, delete and complete asks, every time, whatever the Ask first switch says.
  Ask first's own rules leave these tools to the tool (`APPLE_DATA` in `ask_first.py`), so nothing is
  asked twice.
- In a schedule, Board work or any run nobody can answer, a change is held, never made, in Ask first's
  words, and Night shift lists it as held. Looks still work there.
- With approvals switched off for a bot (YOLO), a change is refused rather than waved through.
- The Mac refuses a change that comes back approved without a plan this copy of Nollie worded (after a
  restart, say), and makes each plan once.
- The card's words come from the change itself (`AppleDataCards`): one line, then what else is saved
  ("Until 11:00", "At 12 High Street", "Only this time, not the whole series."). What a helper wrote is
  flattened to one line and cut at 80 characters, so it can't add lines or pass as Nollie's.
- A repeating event changes or is deleted for that one time only.
- Contacts give only name, phone numbers, email addresses and birthday. Nothing is taken out of a
  contact; a change adds a number or address, sets the birthday or fixes the name.

## Private bots

The tools are never registered for a private bot, the add-on checks the Private list again on every
call, the routes refuse private bots and never list their requests, and the Mac refuses them too.

## What leaves the Mac

Nothing new. A look's answer goes to the helper, and from there only in the model request that
Papertrail already lists. Papertrail records each look as a local read (route `mac`, no arguments) and
a turn that went online says what it read: "18k tokens · read your calendar".

## Where things are kept

| What | Where |
| :--- | :--- |
| Switches | `<main home>/nollie-workflow/apple-data/bots.json` (0600) |
| What the Mac allows | `…/apple-data/mac.json`: allowed, denied or not asked, nothing from the apps |
| Open calls | `…/apple-data/requests/<id>.json`, deleted when the tool has its answer, pruned after 10 minutes |

## Routes

Default profile only, `Cache-Control: no-store`. The Link door lets a phone use only the first two.

- `GET /api/plugins/nollie-workflow/apple-data/bots?bot=<name>` and `PUT …/bots {"bot", "on": [...]}`:
  `{"bot", "on", "mac"}`. Private bots get 403.
- `PUT …/apple-data/mac {"access": {...}}`: the Mac's permissions.
- `GET …/apple-data/requests`: open requests and every helper's switches.
- `POST …/requests/{id}/prepare {"card"}` (changes only) and `POST …/requests/{id}/answer {"result"}` or
  `{"error"}`. A result for a change that was never approved is refused (409).

## Threat model, in short

The boundary is the person's yes on the card. A process running as the person could write a request
file or approve one by hand, as it could answer any Hermes card; Nollie can't tell it apart from the
add-on. What stops a helper is that it has no tool that approves: only the tool, after Hermes's gate
answers, marks a request approved, and the Mac makes only what it worded itself.

## Pieces

| Piece | Where |
| :--- | :--- |
| Tools, request files, the ask | `Companions/nollie-workflow/apple_data.py` |
| Routes | `Companions/nollie-workflow/dashboard/plugin_api.py` |
| Gate, wording, reads and changes (no UI) | `Packages/NollieCore/Sources/NollieCore/AppleData/` |
| EventKit and Contacts, the Mac's poll | `Apps/Mac/AppleData/` |
| Switches | `Apps/Nollie/Chat/AppleDataSection.swift`, `Apps/Nollie/App/AppleDataModel.swift` |
| Card title and icon | `Apps/Nollie/Chat/AskFirstCard.swift` |
| Tests | `Companions/nollie-workflow/tests/test_apple_data.py`, `Tools/mock-gateway/test_apple_data.py`, `Tests/Unit/AppleDataTests.swift` |

The mock gateway serves the switches (`POST /api/_mock/apple-data` sets them) and "ask first calendar"
shows a calendar card.

## Not done yet

- Not tried against a real Hermes and real Calendar data: the macOS prompts need Corey.
- The Mac answers only for a gateway on this Mac; a Mac connected to a Hermes elsewhere shows the
  switches but the data comes from the Mac that runs Hermes, which needs Nollie open.
- After a switch is turned on, Hermes may take up to 30 seconds to show the tools to the model (it
  caches tool checks).
