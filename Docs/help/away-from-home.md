# Use Nollie away from home

[← Nollie](../../README.md) · [Nollie Link](../nollie-link.md)

At home, everything works. Your iPhone talks to your Mac over your own network.

| | At home | Away, without Tailscale | Away, with Tailscale |
| :--- | :---: | :---: | :---: |
| Alerts, if they're on | Yes | Yes | Yes |
| Chat with your bots | Yes | No | Yes |
| Approve what they ask | Yes | No | Yes |
| Stop, Watch and Take over | Yes | No | Yes |

Tailscale is a free app that links your Mac and iPhone privately. Nollie uses it only to find your
Mac. Your Mac still only talks to your linked iPhone, with the same key check as at home.

## Set it up

1. On your Mac, open Nollie, then **Settings › Away from home**.
2. Turn on **Use Nollie away from home**.
3. If it says **Ready**, you're done. Otherwise follow the four steps on the screen:
   1. **Get Tailscale on this Mac.** Press **Download**.
   2. **Get it on your iPhone.** Search the App Store for Tailscale, or press **Copy link** and open
      it on your iPhone.
   3. **Sign in with the same account on both.**
   4. **Come back here.** Nollie checks by itself and shows **Ready**.
4. Open Nollie on your iPhone once at home, so it learns where to find your Mac.

You can also turn the switch on from your iPhone, at home, in **Settings › Away from home**.

## If Nollie can't find Tailscale's name

Under the steps, open **Enter it yourself**. Copy your Mac's name from the Tailscale app (it looks
like `your-mac.tail1234.ts.net`), press **Paste**, then **Save**.

## When you're away

The top of your bots list says how your iPhone reaches your Mac:

- **At home**
- **Connected through Tailscale**
- **Away · alerts only**: Tailscale isn't on, on one of them. If you tap Send, Allow, Deny, Stop,
  Watch or Take over, Nollie tells you, keeps what you typed, and shows the steps.

If your Mac was ready and still doesn't answer, check that it's awake and that Tailscale is on, on
both.

## Turn it off

Turn off **Use Nollie away from home** on your Mac or your iPhone. Your Mac stops giving out its
Tailscale address and refuses anything that comes in through Tailscale, straight away. At home,
everything keeps working.

## Tailscale exit nodes

Your helpers' computers use your Mac's connection, including your VPN.

With an exit node on, even one you turn on mid-task, there's nothing to do. If Nollie ever can't connect them, a card shows on the
helper's **Computer** tab and in **Away from home**. Turning off the exit node in Tailscale on your
Mac fixes it. **Open Tailscale** only opens the app; Nollie never changes Tailscale's settings. An
exit node on your iPhone is fine.
