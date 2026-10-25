# A simpler Hermes setup for Nollie

Research and source review: 16 October 2026. Implementation baseline: Hermes 0.22.0, pinned revision `e06df9c2eae6901f4c88f464e0ae6e753c0428b8`.

Nollie should start with one assistant that completes one useful task. It should own installation, connection checks, recovery and understandable choices. Users should never need to know which command or configuration file makes a feature work.

## What experienced users are teaching us

Reddit is useful evidence of friction, not a benchmark or a security guarantee. The strongest threads include disagreement and specific failures. No third-party scripts, skills or plugins from these threads were installed.

| Community observation | What it means for Nollie |
| --- | --- |
| A months-long personal-assistant report praises local models and specialist helpers, but replies disagree about starting with a small model. Another user describes an installation damaged by repeated ad hoc repairs. | Recommend a tested combination for the actual computer. Do not rank models by popularity or ask the assistant to rewrite its own installation. [Discussion](https://www.reddit.com/r/hermesagent/comments/1wznwqv/what_i_learned_after_running_hermes_as_my/) |
| A long-running setup keeps general memory small and puts detailed procedures elsewhere. Replies ask for regression checks before merging skills. | Keep personal preferences, task progress and reusable procedures separate. Start with built-in memory; external memory servers and nightly self-editing are unnecessary onboarding dependencies. [Configuration report](https://www.reddit.com/r/hermesagent/comments/1x24qfp/my_hermes_configuration_that_works_for_me/) |
| Users asking for Muse-like initiative get two different answers: stronger instructions and actual scheduled/event triggers. | Supply both. Instructions define useful behavior; durable work and wake-ups make it happen. Do not promise that a personality file keeps a process alive. [Proactivity discussion](https://www.reddit.com/r/hermesagent/comments/1wvxxr0/any_way_to_make_hermes_more_proactive/) |
| A concrete calendar example uses a cheap pre-check before waking the model. Other replies warn about empty checks consuming their allowance. | Check for a meaningful change first. Wake the assistant only when work is due, new information arrived, or a decision needs attention. [Event-driven examples](https://www.reddit.com/r/hermesagent/comments/1wpidot/making_hermes_more_proactive/) |
| A local model works in ordinary chat but fails to call tools in scheduled runs. | A successful chat is only the first check. Verify tool use and background delivery separately on the same configured route. [Failure report](https://www.reddit.com/r/hermesagent/comments/1uo5lic/tool_calling_not_working_when_using_cron_gateway/) |

## What Hermes already provides

The official local-model path installs a pinned engine, selects a hardware-appropriate model download, and manages the server. Its fit calculation includes context memory and runtime overhead, not only the model file. Recommendations are predictions, so Nollie must still test a reply and a harmless tool call. This is a better normal path than requiring users to install another model app. Existing Ollama, LM Studio and MLX setups remain advanced connection options. [Local models](https://hermes-agent.nousresearch.com/docs/user-guide/local-models)

Scheduled tasks can be one-off, recurring or event-triggered. Script-only checks and `wakeAgent: false` avoid unnecessary model calls; the check itself may still use a paid external service. Durable delivery and failure visibility matter as much as scheduling. A finite task, a session heartbeat and an ongoing watch should remain separate concepts internally. [Scheduling](https://hermes-agent.nousresearch.com/docs/user-guide/features/cron), [goals](https://hermes-agent.nousresearch.com/docs/user-guide/features/goals), [heartbeats](https://hermes-agent.nousresearch.com/docs/user-guide/features/heartbeat)

Built-in memory is already available. SOUL provides standing character and behavior, memory holds small durable facts, and skills hold procedures loaded when needed. A task's latest evidence and next action belong with the task. Avoid copying every transcript into permanent memory. [Memory](https://hermes-agent.nousresearch.com/docs/user-guide/features/memory), [file roles](https://hermes-agent.nousresearch.com/docs/user-guide/which-file-does-what)

A separate installation folder protects ownership and uninstall boundaries. It is not a sandbox for terminal execution. Retain command approvals, deny unattended dangerous operations, and make computer permissions a separate explicit choice. Only reviewed capabilities should be added to the starter installation. [Security](https://hermes-agent.nousresearch.com/docs/user-guide/security)

## The product flow to finish

1. **Meet Nollie.** The character introduction, then one clear Get started button.
2. **Start new or bring your setup.** Detect an existing installation. Explain Connect versus Import before changing anything. Import previews the exact copy and offers a verified backup; it does not silently adopt credentials, schedules or permissions.
3. **How it works.** Nollie is the app; Hermes does the work on the Mac. Explain local versus online processing, optional tools and what happens when the Mac sleeps.
4. **Name your assistant.** One main contact. Add helpers later, only when their creation and model assignment actually work.
5. **Choose where it thinks.** On your Mac, Online, or Both. Show one suitable local recommendation with its download size, or a supported account connection with clear billing. Advanced contains custom addresses, model formats and routing.
6. **Set things up.** One installation card with real progress, a resumable download, plain-language recovery and no terminal. Account sign-in and macOS permission prompts remain user actions.
7. **Try something useful.** A short response check, then a user-sent task such as turning three priorities into a day plan. A failed test keeps setup incomplete with a useful recovery action.
8. **Stay on top of it.** Offer ongoing work after the first success. Explain awake/online requirements and possible usage costs. Let the user choose notification timing. Do not create a recurring briefing or monitoring job merely because onboarding finished.
9. **Pair the phone.** Mac shows a short-lived code. iPhone shows a warm greeting, explains that Mac setup comes first, scans, confirms the Mac, and opens the assistant. A fresh install must establish secure phone connectivity before displaying a usable code.

The normal settings menu should use these terms:

| User-facing control | Advanced detail |
| --- | --- |
| Where Nollie thinks | Provider, model, context, fallback routes |
| Things Nollie is watching | Cron, events, heartbeat and delivery receipts |
| What Nollie remembers | Memory files, retrieval providers and retention |
| Apps and computer access | Toolsets, MCP, adapters and leases |
| Your Mac and iPhone | Gateway, transport, pairing and device credentials |
| Remove Nollie (built: Settings › About › Remove, see [Remove Nollie](help/remove-nollie.md)) | Removal plan from ownership records, service removal, add-on removal from an existing Hermes, retained backups |

## Model accounts are different products

- **Nous Portal:** Hermes documents subscription sign-in for models and hosted tools. Explain the chosen provider and paid services; do not enable every hosted tool silently. [Portal integration](https://hermes-agent.nousresearch.com/docs/integrations/nous-portal)
- **ChatGPT:** OpenAI documents plan-based integration for open-source projects, local personal projects and selected private apps. Confirm Nollie's applicable integration route before shipping; do not substitute stored credentials for the supported authorization flow. Plan usage and API billing are distinct. [OpenAI integration guide](https://developers.openai.com/cookbook/articles/sign-in-with-chatgpt)
- **Claude:** Use the user's API key or a supported provider in Nollie's native product flow. Current Anthropic developer documentation prohibits offering Claude.ai login or routing consumer-plan credentials through a third-party app. Hosting the unmodified Claude Code binary is described separately and is not blanket permission for an arbitrary model route. [Anthropic authentication rules](https://code.claude.com/docs/en/legal-and-compliance)
- **Other providers:** Review their own product authorization, billing and data rules before presenting subscription sign-in. A Hermes connector or successful OAuth response alone does not establish permission or usable entitlement.

Local inference does not make browsing, voice services or external tools offline. An imported setup may already have auxiliary model routes or fallbacks. A Local/Online/Both preference must not claim to change those routes or guarantee privacy it does not enforce. [Hermes model routing](https://hermes-agent.nousresearch.com/docs/user-guide/configuring-models)

## Background work contract

This is Nollie's proposed product behavior, not a claim about competitors' internals:

- One durable task records the desired result, owner, next action and latest evidence.
- Continue authorized research and preparation without repeated nudges. An idea awaiting a decision must not trigger paid work by itself.
- A watch records its trigger, timing, delivery destination and stop condition. Reuse it instead of creating duplicates.
- No change means no interruption. A useful finding, failure, deadline or decision can justify a concise message in the main conversation.
- Awaiting approval is visible on the Board and in chat. Explain what one action is needed to continue.
- Completion requires checking the result. Restarting should recover work without repeating purchases, messages or notifications.
- Scheduling, execution and delivery each need evidence. “Saved” is not “ran,” and “sent” is not “seen.”

## Current implementation and next acceptance gates

This research pass consolidates fresh-install instructions and conservative configuration into one bundled contract. A newly imported copy uses the same runtime defaults while retaining its reviewed instructions and inactive configuration archive. Existing homes are never rewritten. The pass also removes the nonfunctional helper-creation choice and clarifies model-location/privacy wording. It does not modify an existing Hermes installation, Board, private profile, credential or schedule.

The starter runs one Board task and one delegated child at a time. It keeps speculative triage passive, retains command approval checks, and disables shared metrics. It does not disable ordinary scheduling: the recursive scheduling guard prevents a scheduled agent from receiving the scheduling tool. Authorized chat work can still create a real follow-up. No recurring job is installed merely by creating the home.

The existing managed runtime and personal notification route have recorded successful tests. The welcome and iPhone scan flow exist. A new user still cannot complete the entire journey unaided:

| Next delivery | Required proof |
| --- | --- |
| Native local model quickstart | Explicit download consent, progress, cancellation/resume, model selection and a real reply. The pinned Hermes source exposes quickstart/jobs; Nollie's client currently only reads hardware/catalog. |
| One supported online sign-in | Correct provider authorization, clear billing, expired-session recovery and real inference. |
| Ongoing work on a fresh setup | User enables it; a bounded task survives app closure/restart; no duplicate execution; result reaches the main chat and an opted-in notification. |
| Secure phone connection | Fresh local runtime becomes safely reachable, then physical QR pairing succeeds. Current loopback-only runtime cannot satisfy the existing HTTPS pairing requirement. |
| Computer access | Packaged adapter, real permissions, harmless successful action and immediate user stop. |
| Safe import activation | Verify the copied instructions with the starter runtime settings before real inference. New-copy configuration no longer inherits `{}` defaults; the original installation remains unchanged. |
| Clean removal and release | Owned services stop, retained data is clear, unrelated tools survive, production Apple notifications work. |

Prioritize the local quickstart and first real reply, then secure QR pairing. Keep the beta private while these paths are unfinished. A successful test on an established personal setup does not prove a first-time installation.

## Validation for this pass

- Signed Mac build and 39 focused tests passed. After the final import change, the 13 starter/import tests passed again.
- iPhone simulator build and 30 focused tests passed, including three cases of the parameterized guidance test.
- Four portable-starter tests passed. Runtime fixtures passed in Direct and Store configurations, with 27 and 7 Swift tests respectively, plus 29 Python entrypoint tests. These fixtures did not start a live Hermes service.
- Inspected actual Mac captures of How Nollie works and Make it yours, and iPhone simulator captures of Mac-first pairing and Models. The visual copy checks used the isolated demo app; the model screen used the local mock gateway.
- Existing Hermes homes, Board data, schedules and credentials were not changed. No new physical-phone pairing, model inference or production-notification result is claimed.

Evidence is under `build/nollie-apple-20261016/`: `mac-starter-research-tests.xcresult`, `mac-starter-import-fixed-tests.xcresult`, `phone-starter-research-tests.xcresult`, `mac-research-how-it-works.png`, `mac-research-one-assistant.png`, `iphone-research-pairing.png`, and `iphone-research-models.png`. Standalone runtime evidence is under `build/nollie-runtime-supervisor/`.
