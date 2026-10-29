# Use Nollie away from home

[← Nollie](../../README.md) · [Help](README.md) · [Nollie Link](../nollie-link.md)

At home, everything works. Your iPhone or iPad talks to your Mac over your own network.

Away from home there are two ways to keep going: your own iCloud, with nothing to set up, or Tailscale, which
does more.

| | At home | Away, nothing on | Away, through iCloud | Away, with Tailscale |
| :--- | :---: | :---: | :---: | :---: |
| Alerts, if they're on | Yes | Yes | Yes | Yes |
| Chat with your helpers | Yes | No | Yes, words only | Yes |
| Approve what they ask | Yes | No | Yes | Yes |
| Stop | Yes | No | Yes | Yes |
| Photos and files, Watch, Take over, the Board | Yes | No | No | Yes |

Both need the Mac you download from nollie.app (not the Mac App Store edition), with your iPhone or iPad
linked to it once at home.

## Through your own iCloud

Nollie passes your messages through your own iCloud, sealed so only your Mac and your iPhone can open them. No
servers of ours are involved.

### Set it up

1. Sign in to iCloud with the same Apple Account on your Mac and your iPhone.
2. Link your iPhone at home, or open Nollie on it once at home if it's already linked. That's when the two swap
   the keys they need.
3. That's all. It's on by itself once it can be.

To check, open **Settings › Away from home**. When it's ready it says **Works away from home** and **Through your
own iCloud.** The switch is **Use iCloud away from home** on your iPhone and **Answer through iCloud** on your
Mac.

If the switch can't be turned on yet, the words under it say why:

- **Link at home once.**
- **Sign in to iCloud on both.**
- **Not available yet.**

### When you're away

The top of your bots list says **Away · through iCloud**.

- **Chat.** Type in a chat as usual. Under your message you'll see **Sent through iCloud**, then **Your Mac has
  it**. The reply comes when your helper has finished, not word by word. Photos, files and slash commands wait
  until you're home.
- **Approve.** A helper's question comes to your iPhone as a card with **Allow once** and **Deny**. Nollie asks
  for Face ID first where it would at home. A card lasts ten minutes; after that, answer on your Mac.
- **Stop.** Stop goes straight through iCloud and says **Sent to your Mac through iCloud. It stops as soon as it
  hears.**

Your Mac answers while it's awake and Nollie is running on it. If it's asleep, your message says **Your Mac seems
to be asleep. It gets this when it wakes.** A message that hasn't reached your Mac after fifteen minutes says
**Didn't reach your Mac. It may be asleep.**

Private helpers stay on your Mac and can't be reached this way.

### Turn it off

Turn off **Use iCloud away from home** on your iPhone, or **Answer through iCloud** on your Mac. It stays off
until you turn it on again.

## With Tailscale

Tailscale is a free app that links your Mac and iPhone privately. Nollie uses it only to find your Mac. Your Mac
still only talks to your linked iPhone, with the same key check as at home. With it, everything works away from
home, as it does at home.

When iCloud is ready, Tailscale is under **Advanced** on the same page.

### Set it up

1. On your Mac, open Nollie, then **Settings › Away from home**.
2. Turn on **Use Tailscale**.
3. If it says **Ready**, you're done. Otherwise follow the four steps on the screen:
   1. **Get Tailscale on this Mac.** Press **Download**.
   2. **Get it on your iPhone.** Search the App Store for Tailscale, or press **Copy link** and open it on your
      iPhone.
   3. **Sign in with the same account on both.**
   4. **Come back here.** Nollie checks by itself and shows **Ready**.
4. Open Nollie on your iPhone once at home, so it learns where to find your Mac.

You can also turn on **Use Tailscale** from your iPhone, at home, in **Settings › Away from home**.

### If Nollie can't find Tailscale's name

On your Mac, under the steps, open **Enter it yourself**. Copy your Mac's name from the Tailscale app (it looks
like `your-mac.tail1234.ts.net`), press **Paste**, then **Save**.

### Turn it off

Turn off **Use Tailscale** on your Mac or your iPhone. Your Mac stops giving out its Tailscale address and refuses
anything that comes in through Tailscale, straight away. At home, everything keeps working.

### Tailscale exit nodes

Your helpers' computers use your Mac's connection, including your VPN.

With an exit node on, even one you turn on mid-task, there's nothing to do. If Nollie ever can't connect them, a
card shows on the helper's **Computer** tab and in **Away from home**. Turning off the exit node in Tailscale on
your Mac fixes it. **Open Tailscale** only opens the app; Nollie never changes Tailscale's settings. An exit node
on your iPhone is fine.

## What the top of the list says

- **At home**
- **Connected through Tailscale**
- **Away · through iCloud**: chat, approvals and Stop go through iCloud. If you tap something that needs home,
  Nollie says **This one works at home.**
- **Away · alerts only**, or **Away from home** with alerts off: neither way is on. If you tap Send, Allow, Deny,
  Stop, Watch or Take over, Nollie tells you, keeps what you typed, and offers the Tailscale steps.

If your Mac was ready and still doesn't answer, check that it's awake, and that Tailscale is on, on both.

## Shared helpers

Someone a helper is shared with uses it at home only, never through iCloud or Tailscale.
[Share a helper](share-a-helper.md)
