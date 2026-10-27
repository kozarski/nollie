# In your pocket: what works where

[← Specs](README.md) · [Nollie Link](../nollie-link.md)

Status: audit of 26 Oct 2026 (branch `v12-pocket`, from 1.1), with the gaps closed on that branch marked.
The question for each row: can a non-technical person do this day to day from the device, without the Mac in front of them?

The iPhone and iPad reach the assistant in one of two ways. Directly (the store Mac's Hermes over the pairing
companion, or a gateway with its token): every route the app uses is there. Through **Nollie Link** (the Direct Mac
edition): the door allows only the routes in `LinkDoorPolicy`, so anything that touches files, configuration,
scheduled-task scripts, shell or slash commands stays on the Mac by design. The Watch has no connection of its own; it
asks the iPhone (`WatchWire`).

Key: **Yes** works fully. **Partly** works with a gap named in the note. **Mac only** is refused away from the Mac on
purpose. **Not for the wrist** is out of the Watch's glanceable scope. ✚ marks a gap closed on this branch.

## The table

| Everyday thing | Mac (`Apps/Mac`) | iPhone (`Apps/Nollie`) | iPad (`Apps/Nollie`) | Watch (`Apps/Watch`) |
| :--- | :--- | :--- | :--- | :--- |
| Start a job for a helper | Yes: a chat, a Board task, a schedule | Yes: a chat, a Board task. A new schedule: direct yes, over Link Mac only | As iPhone | Not for the wrist (typing) |
| See the Board and move a card | Yes: drag, card menu, inspector's status | ✚ Yes. Before: long press › Move to only; the task sheet had no way to move, and the swipe actions never showed (they only work in a `List`) | ✚ Yes, as iPhone | Not for the wrist |
| Read Papertrail | Yes: Settings tile, sidebar button, Bot settings tab | Yes: Settings tile, the search field's glyph, Bot settings tab | Yes, and beside the chat in the side panel | Not for the wrist |
| Read Night shift with its Why? | Yes: Settings › Night shift, each entry's Why | Yes, the same page | Yes, the same page | ✚ The last note: counts, the first runs, held or stopped in orange. Before: nothing. The Why stays on the phone |
| Answer approvals | Yes: cards, menu bar | Yes: cards, notifications (Face ID before a send) | Yes | Yes: Allow once where the wrist may; paying, sending, posting, sign-ins, using the Mac and private bots are Deny only |
| Stop | Yes: a chat's stop, Stop using your Mac, the computer's Stop | ✚ Yes. Before: a chat's own stop in the app; Stop for everything only from the Lock Screen card (while a helper used a computer), a notification or Siri | ✚ Yes, as iPhone | Yes: Stop on the crew page |
| See what each helper is doing | Yes: the menu bar lists each turn with its step | ✚ Yes. Before: each bot's row line only, no one place for who is at work | ✚ Yes, at the foot of the sidebar | ✚ Yes. Before: only chats open on the phone; a Board worker or work started elsewhere was missing |
| Add a ready-made helper | Yes: New bot › gallery | ✚ Yes. Before: direct yes, over Link no (the door refused the crew add-on, so the gallery stayed hidden) | ✚ Yes, as iPhone | Not for the wrist |
| Change a helper's simple settings | Yes | Yes: name, look, instructions, model, memory, Calendar, Reminders and Contacts, Can pay, Ask first. Apps & access switches (toolsets, skills, MCP): direct yes, over Link Mac only (configuration) | As iPhone | Not for the wrist |
| Memory | Yes, a private bot's too on its own Mac | Yes (never a private bot's) | Yes | Not for the wrist |

## What changed on this branch

**Who is working, with Stop (iPhone, iPad).** `CrewAtWorkBar` sits at the foot of the chat list while any helper
works: up to three faces, "Scout is working" or "3 helpers working", the step under one name, and on a phone linked to
a Mac one red Stop. It is the same Stop as the Lock Screen, the Watch and Siri (`MacStop.press`), so it ends the task
on the Mac, stops replies and pauses schedules. Tapping the faces opens the helper's chat; with several, a menu names
each with its step. Without a link there is no Stop: there is nowhere for it to go. Who counts as working is
`CrewAtWork.members`, the same rule as the bot rows (`BotPresence`), and the Watch now uses it too.

**Moving a card from its sheet (iPhone, iPad).** The task sheet has Move next to Edit, listing the statuses a hand
can set. Done, Block and Archive ask first, with the same questions as the Board (`BoardQuestions`, now shared). The
move rules (`KanbanAsk.gate`, `KanbanStore.carryOut`) moved from the Mac's folder into `Apps/Nollie/Kanban` so the
Mac, the Board and the sheet share one copy.

**Ready-made helpers over Nollie Link.** The door now passes `GET /api/plugins/nollie-crew/crew`,
`POST .../members` and `POST .../undo`, exact paths only. Why this is safe from a phone: the crew add-on gives a
ready-made helper the local model, no schedule and only tools of Nollie's own that need no further yes; it answers
only for Nollie's profile; Undo archives rather than deletes and needs the token the add returned. It is no more than
creating a bot, which a phone can already do. A crew suggestion's Add can bring a schedule, so `suggestions/*` stays
on the Mac; on a linked phone that card now says "Answer this on your Mac." instead of "Try again".

**The last Night shift note (Watch).** The phone reads the newest card (at most every 15 minutes, and when the Watch
asks) and sends it in the Watch's picture as `WatchWire.NightNote`, worded with the card's own words. The Watch shows it
as a page after the crew. An older phone sends no note and an older Watch ignores it, so the version stays 1.

## Still open

- Over Nollie Link a phone cannot make a new schedule or flip Apps & access switches, by design. Both screens still
  offer the control and show the door's refusal; they should say "On your Mac" up front instead.
- Night shift cards in Nollie's chat show only in the new chat view (Debug); Release builds on every device show them
  in Settings › Night shift.
- The Board's swipe actions in `KanbanView` never appear (they need a `List`); Move in the sheet and the long press
  cover what they offered.
- The Watch does not show Board tasks waiting for help, only approvals.
- Who is working is what the phone can see: chats open on it, the Board's workers, and a bot's main chat the gateway's
  record shows mid-turn. A schedule's run, or another chat started on the Mac, does not show until the phone opens it.
