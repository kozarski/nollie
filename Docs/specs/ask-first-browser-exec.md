# Ask first and browser scripts (Hermes 0.23)

[← Specs](README.md) · [Ask first](../ask-first.md)

## What changed in Hermes

Hermes 0.22 had a browser tool for each step: `browser_navigate`, `browser_click`, `browser_type`,
`browser_press`, `browser_snapshot`, `browser_console` and the rest. Ask first judged one step at a time and
could read the page's last snapshot to see the label under a click.

Hermes 0.23 drops them for one tool, `browser_exec`. Its `code` is a Python script with browser helpers
already loaded: `new_tab` and `goto_url` (open a page), `wait_for_load`, `page_info`, `capture_screenshot`,
`ensure_real_tab`, `js` (run a page script), `fill_input` (type), `click_at_xy` (click a spot) and `cdp`
(any raw browser command). It also takes `session`, `timeout_s` and, when the person allowed it, `local`
(their own browser, signed in as them). The result is the script's printed output, plus a workspace
folder and sometimes a screenshot path. `browser_cdp`, `browser_dialog` and `browser_vault` stay.

So one call can open a shop, type a quantity and press Place order. The script is plain Python too, so it
can also run programs, send web requests or delete files.

## How a script is judged

`Companions/nollie-workflow/browser_script.py` reads the script with Python's own parser, never runs it,
and lists every helper call in order, with the words, keys and addresses it passes when the code itself
says them (plain strings, names set to strings, f-strings and simple loops over a list).
`ask_first.browser_exec_action` then judges every step as the old tools were judged. The strongest wins.

| Step | Judged as |
|---|---|
| Open a page, read it, wait, scroll, take a screenshot, pick a tab | Never asks, as before |
| Type (`fill_input`) | Asks only if the text ends in Return: the page can't be read first, so it asks as unsure |
| Press a key (`press_key`, a CDP key event) | Cmd or Ctrl+Return sends, Cmd+Delete deletes, plain Return asks as unsure |
| Click by its own words (`textContent === 'Place order'`, `[aria-label="Delete"]`, `text=Send`) | The words decide, as a snapshot label did: Place order buys, Next page passes |
| OK, Continue, Done | Asks as unsure, since the page around it can't be read. Passes on a cookie notice the selector names; buys when the script opened a checkout |
| Click a spot (`click_at_xy`) or a button Nollie can't name | Asks as unsure |
| Page script (`js`, `Runtime.evaluate`) | The same code rules as before: a POST, `fetch` that sends, `.submit()`, a delete |
| Python around the helpers | The same rules as `execute_code`: programs, web requests, deleted files |
| A page's own question (`Page.handleJavaScriptDialog` yes) | Asks as unsure, as `browser_dialog` did |

A card lists the script's steps ("Open shop.example.com/cart", "Type “2” into #qty", "Press “Place order”")
and, for a named button, ends with the usual "You're about to press" line.

## What fails closed

These ask even with the bot's Ask first switch off, since Nollie can't read them at all:

- a script that isn't Python, is nested too deep, or is over 256 KB;
- code built or looked up while it runs (`eval`, `exec`, `getattr`, a helper passed around or renamed);
- a helper or function Nollie doesn't know, such as one from the workspace's `agent_helpers.py`;
- a page script or browser command whose text is made while the script runs;
- a raw browser command Nollie doesn't know.

Clicks it can't name, and Return on a page it can't read, ask as unsure, as they did with the old tools,
so the switch covers them.

## Other places

- Night shift shows a step as "Opened bbc.co.uk/weather", "Filled in a form on shop.example.com" or
  "Clicked Place order", worked out from the steps, never from the script's own comment or code.
- Papertrail counts the pages a script opens. A rehearsal runs a script only when it does nothing but read
  the page already open.
- The reader keeps a script off a site that just asked for a person, by the addresses written in it.
- A script that starts a screenshot program is refused like `execute_code`, and one that takes a picture
  waits while a saved sign-in is typed.
- The old tool names are still judged exactly as before, for bots still on 0.22.

## Gaps

- **The page itself.** The script opens and changes the page before it presses, so Nollie can't read the
  label under a spot, the words around an OK, or where a form sends. Those ask as unsure; a button with
  harmless words ("View details") that submits a checkout form passes, as it did when the old page couldn't
  be read.
- **Words from the script.** A click by its own words is judged by those words. A page could show "Next"
  on a button that pays; that was true of snapshot labels too.
- **Values found while it runs.** Text typed from something the script read off the page is unknown, so it
  asks as unsure. A loop over values the page gives can't be followed.
- **`browser_vault`.** It fills saved logins and cards. Ask first doesn't judge the fill itself; the press
  that submits them is judged.
- **Night shift's picture to share** hides a browser step's whole label, as it hid any page.
