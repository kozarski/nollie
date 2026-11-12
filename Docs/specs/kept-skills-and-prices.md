# Kept skills and prices

[← Specs](README.md) · [Weekly note](weekly-note.md) · [Ask first](../ask-first.md)

Status: built on Hermes 0.23.1 (10 Nov 2026). What Hermes offers, and what Nollie shows of it.

## Keep skills as they are

One switch per helper, in Bot settings › Apps. On, the helper can't change its skills; it can still use them.

- Hermes 0.23 locks one skill at a time (`PUT /api/skills/lock?profile=` with `{name, locked}`, the same record as
  `hermes curator lock`; `GET /api/skills` rows carry `locked`). A locked skill is refused to every agent write path:
  `skill_manage`, `write_file`/`patch` inside its folder, and terminal commands that write there
  (`tools/skill_manager_guards.py`, `tools/skill_lock.py`). The person's own edits are not gated.
- Hermes has no switch for all skills at once, and `create` is exempt from the lock, so a new skill is never locked by
  Hermes. `skills.write_approval` stages every skill change for a yes instead, but only through `/skills` commands, with
  no route an app could answer, so Nollie doesn't use it.
- So the switch is the workflow add-on's (`GET/PUT /api/plugins/nollie-workflow/keep-skills`, kept in
  `<main home>/nollie-workflow/keep-skills/bots.json`). Its `on_skill_lifecycle` hook locks a skill the moment Hermes
  says the helper made or installed one, in that helper's own process. The app locks every skill the helper has when
  the switch goes on, and unlocks every locked one when it goes off (a lock made by hand with `hermes curator lock` is
  unlocked too). A skill written as plain files, past the skill tool, is locked the next time the Mac opens the switch.
- The skills list shows a small lock beside each locked skill.
- A linked iPhone reads the switch (the door allows `GET` with one `bot`) and says "Change these on your Mac." The locks
  and the switch change only on the Mac. Private bots are refused by the add-on and never asked about.

## A tool's price on the approval card

- A connected app (MCP server) may declare prices in its config: `mcp_servers.<name>.tool_costs`, `spend_limit` and
  `cost_unit` (`tools/mcp_tool_costs.py`). Hermes asks first for a priced call on a server marked `trust: untrusted`,
  and for any call that would take the chat past its limit. The price and the chat's running total are only in the
  words of that approval (`tools/mcp_tool_handlers.py`); no event carries them, and `GET /api/mcp/servers` leaves
  `tool_costs` out.
- Nollie reads those fixed sentences from the approval's first paragraph only (`ToolPrice`), never from the tool's
  arguments, and shows "About 5 credits" small on the card, with "About 10 credits used in this chat · Limit 50" or
  "Goes past this chat's limit" under it. The unit is the app's own label.
- A priced call on a trusted server within its limit runs without asking, so there is no card to show it on.

## A cap per helper

Not built: Hermes 0.23.1 has none. Its only cap is `spend_limit`, per chat and per connected app, in that app's own
unit, kept in memory. There is no limit on model spending for a helper, a day or a week. Setting `spend_limit` from
Nollie would mean rewriting the whole `mcp_servers` map through `PUT /api/mcp/servers`, which carries each server's
raw settings, so it stays in the config file for now.

## Mock gateway and demo

The mock serves skills per bot with their locks, `PUT /api/skills/lock`, the Keep skills switch, and model spending per
bot (`work` is a local model with no cost). `POST /api/_mock/skills {"bot": "work", "made": "name"}` plays the helper
making a skill. A chat that starts with "paid tool" gets Hermes's priced approval word for word. The in-app demo has
the same routes. `-nollie-demo-linked` makes the demo copy act as a phone linked to a Mac, and `-nollie-demo-settings
skills` opens the main bot's skills.
