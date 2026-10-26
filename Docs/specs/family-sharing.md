# Sharing a helper at home

[← Architecture](../architecture.md) · [Nollie Link](../nollie-link.md) · [Ask first](../ask-first.md) · [Papertrail](papertrail.md)

Status: written before the code (26 Oct 2026) for 1.3, "For your home". The Mac side is enforced at the Nollie Link
door; nothing here relies on the phone behaving.

## Purpose

Someone at home (a partner, a parent, a teenager) asks one of your helpers things from their own iPhone. You stay
in charge: anything that needs a yes comes to you, they never see your other helpers, your Private helpers, your
memory, saved cards, saved sign-ins or Papertrail, and you can take it away in one tap.

The test: the person who owns the Mac feels more in charge after sharing, not less. The person it is shared with
knows plainly what they have: one helper, their own chats, and that the owner says yes to anything that matters.

## Words

| Word | Meaning |
| :--- | :--- |
| Owner | The person whose Mac runs Nollie, and every iPhone they linked themselves. Today's linked phones are all owners. |
| Member | Someone at home a helper was shared with: one linked iPhone with the member role, a name the owner typed ("Sam"), and the helpers shared with them. |
| Shared helper | A helper a member may reach. Sharing makes a household copy (below), so in practice it is "Scout for Sam". |
| Ask | An approval card raised in a member's chat. It goes to the owner. |

## What each role can do

Enforced by the door on the Mac. The phone's screens only follow what the door allows.

| | Owner | Member |
| :--- | :--- | :--- |
| Helpers seen | All, as today | Only the ones shared with them, never a Private one |
| Chats | All | Only chats they started, with a shared helper |
| Start a chat, send, attach a photo, stop a reply | Yes | Yes, in their own chats |
| Answer an approval | Yes | No. It goes to the owner. They may say "Never mind" (deny) to their own ask. With the owner's switch "Small yeses" on (off by default), they may also say Allow once to an ask that is not one of Ask first's fixed kinds |
| Memory, cards, sign-ins, Papertrail, Board, schedules, settings, bot settings, files, the live picture, Take over, Stop on the Mac, Away from home | As today | No |
| Share a helper, see members, remove a member, answer a member's ask | Yes | No |
| Reach the Mac through Tailscale | With Away from home on | No: home network only |

Ask first stays absolute. Sending, buying, posting, deleting, and adding or changing calendar events, reminders or
contacts always wait for the owner's yes, whatever the switch says. "Small yeses" never covers them, never offers
Session or Always, and an ask the door cannot classify counts as not small.

## The household copy

What a helper knows comes with it into every chat. Hermes puts a helper's memory into its instructions and gives it
search over its past chats, and there is no per-chat switch for either. So a member chatting with your own Scout
could ask "What do you remember about Corey?" and the door could not stop the answer.

So Share never hands over your helper itself. It makes a household copy for that person, with Hermes's own profile
copy (`POST /api/profiles` with `clone_from`): the same look, instructions, skills and model, with **none of its
memory and none of its chats**. In a setup Nollie manages, Ask first is added to every new bot before Hermes
publishes it, so the copy holds sends, buys, posts and deletes like the original. One copy per person, so two
people at home never see each other's chats through a helper's search either. The copy's name is the helper's name
with the person's (`career-sam`); it still introduces itself as Scout.

What still comes along, and the share screen says so in one line: the instructions you wrote for the helper. If they
hold something personal, edit the copy's instructions after sharing.

What does not change, and is listed for Corey below: the copy runs on your Mac as you, with the helper's tools. A
member could ask it to read a file it can reach. Anything that changes something waits for your yes; reading does not.

## Joining

Decided: **in person, by QR code**. Simplest and safe.

1. The owner opens a helper and taps Share. The share screen shows who already has it and one button, Add someone.
2. They type the person's name ("Sam"). Nollie makes Sam's copy of the helper, then shows a code. On the Mac the
   code comes from Nollie Runtime over its signed XPC; on a linked owner phone, from the door
   (`POST /nollie/family/invite`, owners only).
3. Sam opens Nollie on their iPhone, taps Scan QR code, and sees "Corey shares Scout with you" with one line:
   "Corey says yes to anything that matters. Your chats are kept on Corey's Mac." Join or Not now.
4. Joining claims the code exactly as linking does (pinned TLS 1.3, single-use secret, two minutes). The Mac creates
   a member device instead of an owner one. The owner's screen says "Sam joined".

The code is the usual Nollie Link code with version 2 and one more key, `f`: `{"o": owner's first name, "b": [the
helpers' shown names]}`. A phone that does not know version 2 refuses the code rather than linking as an owner.
The role is decided on the Mac by the offer that was claimed, never by anything the phone says.

Why not Apple Family Sharing: it gives apps no way to share their own data with family members (it covers purchases
and Screen Time), and an invite link sent in Messages would be a two-minute secret travelling to wherever it is
forwarded. Scanning in person proves the person is at home, which is also the only place a member's phone can
reach the Mac.

## What the member's phone shows

One quiet screen instead of the usual app: "Shared with you", the helpers shared with them (character and name), and
under each its chats. A chat looks like any Nollie chat. There is no Board, no Settings beyond Appearance and the
link itself, no Papertrail, no bot settings and no memory.

When a helper needs a yes, the member's card says "Waiting for Corey" with what the helper wants to do and one
button, Never mind. With Small yeses on and an ask that qualifies, it offers Allow once as well.

## Approvals from a member

The door reads every frame Hermes sends to a member's phone. When Hermes asks a member's chat for an approval
(a server request with method `approval`), the door:

1. records an ask: the request id, the member's name, the helper, the chat, what Hermes said about it
   (description, the command as Hermes already redacted it, the Ask first rule key) and the time;
2. still passes the request to the member's phone, which shows the waiting card;
3. refuses any answer from the member, by response frame or `approval.respond`, other than Never mind, and Allow
   once when Small yeses allows it.

The owner sees the ask on the Mac (Nollie Runtime's link status, polled while a phone is linked) and on their own
linked phone (`GET /nollie/family`, owners only), as a card that says "Sam asked Scout", the action and Allow once /
Deny. A yes asks for Face ID first where a yes in a chat would. The answer goes to the door
(`POST /nollie/family/asks/<id>`, owners only, `once` or `deny`), which delivers it to Hermes as the answer to that
request on the member's own connection, or, when that connection has closed, as `request.answer` over the door's
own loopback socket. Hermes then carries on in Sam's chat.

An ask leaves the list when it is answered by anyone, when Hermes withdraws it (`request.cancel`), or when the
member is removed (their open asks are answered Deny). Asks are kept in memory: a helper restart forgets them and
Hermes's own approval timeout denies them.

Known gap: the door only sees an ask while the member's phone is connected. If Sam closes Nollie before the helper
asks, Hermes holds the question until Sam opens the chat again (the snapshot carries it, and the door records it
then) or until its timeout.

## Threat model

What is worth protecting from a member: the owner's other helpers and their chats, Private helpers, memory, saved
cards and sign-ins, Papertrail, the Mac's settings and files, and the owner's yes.

| Who | What they might try | What stops them |
| :--- | :--- | :--- |
| A curious member | Ask a shared helper about the owner | The household copy has no memory of the owner and none of the owner's chats |
| | List helpers, open another helper's chat, guess a chat id | The door filters `/api/profiles` to shared helpers; every chat route and socket call needs a chat this member started, with a shared helper. Unknown ids are refused before Hermes sees them |
| | Read memory, cards, sign-ins, Papertrail, schedules, the Board, settings | Not on the member allowlist: 403 from the door |
| | Answer their own approval with Allow | Only Never mind passes, or Allow once for a small ask with the switch on. Session and Always never pass |
| | Send hand-made socket messages | Members get their own JSON-RPC allowlist: chat methods only, each tied to a profile they were given and a chat they own. Everything Hermes sends them is filtered too: only answers to their own calls and events for their own chats |
| | Stop the owner's work, watch a helper's computer, Take over | `/nollie/stop`, `/nollie/live`, Take over and Away from home are owner routes |
| A child | All of the above, plus pressing every button | The same, and nothing a member can press sends, buys, posts or deletes without the owner. Screen Time stays the parent's tool for the phone itself |
| A lost member phone | Whoever has it keeps asking | Only at home (no Tailscale for members). The owner removes Sam in one tap: the credential's hash is deleted, every open connection closes at once, open asks are denied |
| A member who left the household | Keep using the link | Same as a lost phone |
| A helper marked Private after it was shared | Keep being reached | The door reads the Private list (cached five seconds) on every member request and refuses Private helpers. If the list can't be read, members are refused (fail closed). `private` and `moss` are always Private and can never be shared |
| A forged invite code | Make a member's phone join an attacker's Mac | As for linking: pinned key, private addresses only, "Corey shares Scout with you" names who. A member who joins the wrong Mac gives it nothing of the owner's |

Out of scope: someone using the owner's unlocked Mac or phone, malware on either, and what a household copy can do
with its own tools on the Mac (see the copy, above).

## Papertrail: who asked

Each household copy is its own Hermes profile, so its Papertrail is exactly that person's requests: the owner opens
"Scout for Sam" and sees what left the Mac for Sam. The add-on records the copy like any non-private bot. The door
keeps nothing of what was said.

Members see no Papertrail in this version. Their own copy's Papertrail would be safe to show them; it is left out to
keep the member's screen small.

The door also keeps, per member, the chat ids they started (at most 500), so it can prove a chat is theirs.

## Removal

The owner's share screen lists each person with one Remove button. Remove deletes the member's credential hash,
closes their connections (phone and Hermes side) at once, answers their open asks Deny, and forgets their chats on
the door. The household copy stays on the Mac with its chats, as a bot the owner can delete like any other.
Stopping sharing one helper with a person who has others only takes that helper off their list; their
connections close so the next request is checked against the new list.

## Door contract

New routes, all answered by the door itself, never Hermes:

| Route | Who | What |
| :--- | :--- | :--- |
| `GET /nollie/family/me` | Anyone linked | `{"role": "owner"}` or `{"role": "member", "owner", "person", "helpers": [names], "small": Bool}` |
| `GET /nollie/family` | Owners | `{"members": [{id, person, device, helpers, small, linkedAt, lastActive}], "asks": [...]}` |
| `POST /nollie/family/invite` | Owners | `{"person", "helpers": [names]}`: a version 2 code's fields, as the Mac's XPC offer gives them |
| `PUT /nollie/family/members/<id>` | Owners | `{"helpers"?, "small"?}` |
| `DELETE /nollie/family/members/<id>` | Owners | Remove, as above |
| `POST /nollie/family/asks/<id>` | Owners | `{"choice": "once" \| "deny"}` |

Member allowlist, everything else 403:

| Route | Rule |
| :--- | :--- |
| `GET /api/status`, `/api/health`, `/nollie/link/hosts` | Passed (hosts: home only) |
| `GET /api/profiles` | The door asks Hermes and answers with shared, non-private helpers only, a few fields each |
| `GET /api/sessions?profile=P` | The door answers from its own record of the member's chats, each row read from Hermes |
| `GET`, `PATCH`, `DELETE /api/sessions/<id>`, `GET /api/sessions/<id>/messages` | `profile=P` once in the query, P shared and not Private, `<id>` a chat this member started with P |
| `/api/ws` | Member JSON-RPC rules below |

Member JSON-RPC, phone to Hermes: `ping`, `client.capabilities`; `session.create` with a shared profile and only
`profile`, `cols`, `title`, `idempotency_key`, `close_on_disconnect` (no folder, no seed messages, no branch, no
model); `session.resume` of a chat they started; `prompt.submit` with plain text, `image.attach_bytes`,
`session.interrupt`, `session.steer`, `session.title`, `session.usage`, `session.events.since`, `session.close`,
`approval.pending`, `approval.received` on a live chat this connection opened; `approval.respond` and answers to
Hermes's requests as above; answers to `clarify`. Everything else gets the door's 4403 reply.

Hermes to a member's phone: answers to calls this connection made; events and requests for chats this connection
opened (`approval` and `clarify` requests only); `gateway.ready`. Everything else is dropped.

The door learns a chat's runtime and stored ids from Hermes's answers to `session.create` and `session.resume`, and
a new stored id from any later frame for that chat that names one (compression moves a chat).

## Test plan

Mac unit tests (`LinkDoorFamilyTests`, Direct run), with the door's sources compiled in:

- Roles and state: older `link.json` files read as owners; member fields survive a save; a member invite's claim
  makes a member with the invite's person and helpers; an owner offer makes an owner.
- Private: `private`, `moss` and listed names can't be invited or added; a helper made Private after sharing is
  refused at once; an unreadable list refuses members.
- Route allowlists per role, with the owner's unchanged and a corpus of member refusals.
- Member RPC up and down: unshared profiles, other chats and unknown ids refused; folders, seeds, branches, models,
  slash commands, config refused; Hermes frames for other chats dropped.
- Asks: a member's approval is recorded for the owner; the member's Allow is refused, Never mind passes; Small yeses
  passes Allow once only for a small ask; the owner's answer reaches Hermes on the member's connection.
- End to end on loopback: a member gets 403 for an unshared helper's chat and for Papertrail and never reaches
  Hermes; a member's socket is cut within a second of Remove; the owner's routes are refused to a member.

Phone: `FamilySharingTests` for the code's version 2, the member screen's helper list and the ask card's words.
Pictures, light and dark, against the mock gateway: the owner's share screen, the member's app, and an ask from a
member on the owner's phone.

## What needs Corey

- A real two-phone test at home: link Corey's phone as owner, share a helper, scan with a second iPhone, chat, raise
  an approval (ask the copy to send an email), answer it on Corey's phone, remove the second phone mid-chat.
- Whether household copies should also lose terminal and file tools by default. Today they keep the original's
  tools, so a member could ask one to read a file it can reach on the Mac.
- Whether members should see their own copy's Papertrail.
- Away from home for members (through the iCloud transport once it exists, never Tailscale).
- No Apple capability or entitlement is needed: Apple Family Sharing is not used.
