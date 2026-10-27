# How Nollie keeps you safe

[← Nollie](../README.md) · [Nollie Link](nollie-link.md) · [Nollie Computer](nollie-computer.md)

Nollie runs AI helpers on your Mac that can read the web, work with files and, if you let them, use apps on
your Mac. That is real power, so this page says plainly what Nollie protects you from, what it can't, and
what is still being built.

## What is built today

**Every risky action asks you first.** Approvals are always on. The card shows the whole command, never a
summary, so what runs is exactly what you read. You can allow it once, allow it for one chat, always allow it (Nollie asks once more), or deny it.

**Sending, buying, posting and deleting ask first.** Nollie checks every action a helper takes against fixed
rules before it runs, not the helper's own judgement. Anything that sends a message or email, pays or buys,
posts publicly or deletes files or accounts waits for your yes, on a card that says the whole action in plain
words. A click on a button such as Send or Pay adds "You're about to press “Send”", read from the screen itself.
Scheduled work never gets these: they are held, and Night shift lists them in the morning when it is on. When the rules
can't tell what something does, they ask too. They can't read everything a page's code means, and they run in every
helper Nollie sets up, Private ones included; [Ask first](ask-first.md) lists what they miss.

**Saved sign-ins keep pictures away from your password.** Nollie types a saved sign-in into a helper's computer
after your yes. The helper is never told the password, and while it is typed every new screenshot, recording and
preview of a computer pauses. If a site shows the password in plain text afterwards, a later screenshot could
still catch it.

**Saved cards never reach a helper.** A helper you've allowed to pay ("Can pay with my cards" in its settings,
off to start) can ask to pay at a checkout. Your card number and expiry date stay in your Mac's Keychain,
behind Touch ID or your Mac's password for every read, on this Mac only and never in iCloud. The helper, its
chat, the logs and Papertrail only ever see "Visa ending 4242". Fixed rules decide when you are asked, not
the helper: the first payment on each site always asks, on the buy card with Face ID. Every payment asks
unless you turn on "Skip the card on sites I've paid" with a limit you choose, and even then a site's first
payment asks. A total in a currency you don't pay in is refused, and private helpers can never pay. Each
time, you type the security code on your Mac (it is never kept), Nollie reads the checkout itself to check
the total you said yes to is on screen, then fills the card in and presses Return. Pictures of every computer
pause from the moment it types until Nollie sees the number has gone from the screen. If the checkout keeps
showing the number (a declined card, say), pictures stay paused until it's gone. Once typed, the number is
in a page on a computer the helper controls; a helper that set out to could read it back from there. A
look-alike page that shows the same total would get the card too: before you say yes, look at the helper's
screen when you can.

**Your phone talks only to your Mac.** Nollie Link is a TLS 1.3 connection from your iPhone straight to your
Mac, with no Nollie server in between. The phone trusts your Mac's own key, which it learns from the QR code
you scan, so nobody else on the Wi-Fi can pretend to be your Mac or read the traffic. The link code works
once and expires after two minutes. A linked phone can chat, approve and manage the Board, but can't reach
your keys, settings, files or anything that changes how Nollie itself runs. Removing a phone on the Mac cuts
it off within a second.

**Away from home is off until you turn it on.** Without it, your Mac answers your phone only on your home
network, and turns away anything that comes in through Tailscale. With it on, your phone reaches your Mac
through Tailscale, your own private network, with the same key check and the same limits as at home. Turning
it off cuts those connections at once. Watch's Take over works from a linked phone after Face ID; it only
pauses the helper, and private bots are never offered it.

**Using your Mac is off until you turn it on.** Nollie Computer is in beta. When a helper wants to use apps on
your Mac, a card names the helper, the chat it came from and every app it wants, and you answer with Touch ID.
Sending, buying, deleting, uploading, signing in, installing and opening links ask again, each with Touch ID.
Terminals, password managers, System Settings and Nollie itself are never touched, and browsers are view
only. Stop ends a task at once.

**Your helpers' computers use your Mac's connection, including your VPN.** Nollie passes their web traffic
through your Mac, so with a VPN or Tailscale exit node on, it leaves through that like everything else. Only those
computers can use it, only websites on the internet are reachable (never your Mac, your home network or your
other devices), and nothing that passes through is read or kept.

**Nollie has no analytics.** Its logs stay on your Mac.

## Planned, not built yet

- **Local models for your Mac.** When a job needs your Mac, Nollie hands it to a helper on a local model, so
  screenshots of your screen never leave it, even if Nollie itself uses your ChatGPT or Claude plan.
- **A sealed computer for every helper.** Each helper gets its own small Linux computer inside your Mac, with
  its own browser, files and logins. It can go online, but it can't see your files, your home network or the
  other helpers. Files come in through its Inbox and go out through its Outbox.
- **Throwaway computers.** Risky jobs get a fresh computer that is deleted afterwards. Downloads and
  attachments open in one with the internet switched off, so nothing in them can phone home.
- **Stop from anywhere.** Today Stop works from your iPhone when it can reach your Mac, at home or through
  Tailscale: it ends the job on your Mac, stops replies and pauses schedules until you resume them. It is
  in Siri and Shortcuts, on the Lock Screen while your iPhone can see a helper using a computer, and on
  the "started using your Mac" alert when notification details are shown. Your iPhone asks to be
  unlocked first. Next: send and Stop while you're away without Tailscale, through your own iCloud.

## What Nollie can't protect you from

- **A clever page talking a helper into asking you for something harmful.** Web pages, emails and documents
  can contain instructions aimed at the AI. Nollie never lets a page approve anything, but if a helper asks you
  for something odd, the approval card is your last check. Read it.
- **Malware already on your Mac or phone,** or someone using your unlocked Mac. Nollie runs as you, so it is
  only as safe as the account it runs in.
- **A fake link code.** If you scan a code from someone else's computer, your phone links to theirs. Only
  scan a code shown on a Mac you own.
- **What online models see.** When you use a ChatGPT or Claude plan, or an API key, what you send goes to that
  company under its own terms. Local models keep it on your Mac.

## Found a problem?

Email hello@nollie.app. Please don't post security issues in public before we've had a chance to fix them.
