# Apple's on-device model: quick answers

[← Architecture](../architecture.md) · [Papertrail](papertrail.md)

Status: feasibility written 26 Oct 2026 for 1.2 "In your pocket", then built as quick answers. Measured on Xcode 27.2
(macOS 27.2 SDK, iOS 27.0 simulator) on Corey's Mac.

## Purpose

A new person should get an answer the moment Nollie opens, with nothing to download, and the iPhone should do small
things when the Mac can't be reached. Apple's FoundationModels framework gives every app a model on the device. Nollie
already uses it for chat titles, previews and the working line (`ChatSummaries.swift`, `ChatSummaryParts.swift`,
`ChatGoalWriting.swift`). This page says what else it can honestly do.

## What the model can and can't do

| Question | Answer |
| :--- | :--- |
| Context | 4,096 tokens on the 26 releases (input and output together). The 27 SDK reports the real size: 8,192 on this Mac. `contextSize` is back-deployed and returns 4,096 before 27. |
| Speed and size | A small model (about 3B parameters) on the Neural Engine. Fine for a few sentences; weak at long reasoning, maths and facts. Its knowledge stops at its training date and it has no internet. |
| Tool calling | Supported (`Tool` protocol), but every tool's schema and every result share that small window. Good for one or two narrow tools, not an agent loop. |
| Streaming | Yes (`streamResponse`), so words appear as they come. |
| Availability | Needs a device that runs Apple Intelligence (iPhone 15 Pro and later, M1 and later iPad and Mac), Apple Intelligence switched on, and its model downloaded. Otherwise `availability` is `.unavailable(.deviceNotEligible / .appleIntelligenceNotEnabled / .modelNotReady)`. |
| Languages | 24 on this Mac: da, de, en (AU, GB, IN, US), es (ES, 419, US), fr (FR, CA), it, ja, ko, nb, nl, pt (BR, PT), sv, tr, vi, zh (Hans, HK, TW). Anything else throws `unsupportedLanguageOrLocale`; `supportsLocale()` checks first. |
| Guardrails | Apple checks both the prompt and the reply. A hit throws `guardrailViolation` (or `refusal`); false positives on harmless text are known. `permissiveContentTransformations` relaxes it only for rewriting text the person supplies. |
| Other errors | `rateLimited` in the background, `concurrentRequests` if one session is asked twice, `contextSizeExceeded`, and on 27 a new `LanguageModelError` type with `timeout` (the 26 `GenerationError` is deprecated). |
| Leaves the device? | No. The 27 SDK also adds a Private Cloud Compute model; that one goes to Apple's servers, so it is not used here. Using it later would need Corey's decision and a Papertrail entry. |
| Simulator | Uses the host Mac's model. |

**Observed on this Mac today:** `availability` says `.available`, yet every request fails with
`FoundationModels.LanguageModelError -1` wrapping `com.apple.SensitiveContentAnalysisML error 15` (Apple's safety
check failing on the Neural Engine, code 53). Same from a command-line probe, from the Mac app and from the iOS
simulator, with both guardrail settings. The Osaurus teardown hit the same error. So "available" does not prove it
answers: the app must treat a failed first answer as "not working here" and step aside quietly. Real answers have
therefore not been seen on this machine; they need a check on Corey's iPhone or another Mac.

## Can it drive Hermes's main agent? No.

- Size: a static read of only 22 of Hermes's ~60 tool schemas is about 26,600 characters (about 6,600 tokens), before
  the system prompt, memory, skills index and the chat. That is more than the whole 26 window and most of 8,192.
- Shape: Hermes talks to models over an OpenAI-style HTTP API from a launchd service. Apple's model lives inside an
  app process; Nollie would have to run a bridge server whenever Hermes runs, including with Nollie closed.
- Quality: multi-step tool use, planning and long results are beyond a model this size. Worse answers from the main
  helper would cost more trust than the download saves.
- Safety: Ask first is enforced by Hermes and Nollie's rules, not the model, so nothing is gained there either.

Also not chosen: Hermes's helper tasks (titles, compression) for the same bridge reason, and deciding what needs Ask
first, which stays fixed rules.

## The roles that work: quick answers

Talk only, on this device, clearly labelled, with fixed rules around it.

1. **Mac first setup.** From the connection step until the model is ready, the setup header has a "Quick question"
   pill. The sheet answers simple things while Hermes installs or the model downloads.
2. **iPhone and iPad, Mac out of reach.** After six seconds without the Mac (at once if the connection failed), the
   Chats list shows "Can't reach your Mac" with "Quick answer". A sign-in problem keeps its own banner instead.
   Each answer has Copy and "Ask Nollie on your Mac". One tap sends the question into Nollie's main chat now, or,
   with the Mac away, keeps it on the phone ("Goes when your Mac is back", with an x to take it back) and sends it
   the moment the Mac returns, with a short "Your question went to your Mac" note and Open.
3. **iPhone setup before pairing.** The same sheet from the pairing step, without hand-off.

Good for: explaining, ideas, drafting and rewording text to copy, simple how-tos.

### Rules (`QuickAnswerRules` in NollieCore, never the model's judgement)

- The model gets no tools, so it cannot act. Its instructions also say it has none and must never claim to act.
- Before the model sees anything, the request is routed. Drafting and rewording stay on the device even when they
  mention sending ("Write a text to Mum saying..."). Anything that would act (send, text, book, buy, pay, post,
  delete, remind me, add to my calendar, open, set an alarm), read the person's things (my calendar, inbox, files,
  "on my Mac") or need fresh facts (weather, news, look up, open now) gets a fixed line instead and the hand-off
  button. Mixed requests ("write it and send it") go to the helper.
- A reply that says it acted ("I've sent", "I'll book", "it's been scheduled") is never shown; the fixed line
  replaces it.
- Handed-off questions are plain messages to the helper, so Ask first applies to anything it then does. A leading
  slash is removed so a question can never run a gateway command. Each waiting question leaves the queue before it
  is sent, so a lost answer is never sent twice; one that could not reach the chat goes back in the queue.
- Nothing is saved except questions waiting for the Mac (UserDefaults, `quickAnswers.forMac`). The conversation
  lasts as long as the sheet. Memory is the latest exchanges that fit the window; a full window gets one more try
  without them.

### When it can't run

- Device not eligible, Apple Intelligence off, model not ready, language not supported, or switched off in Settings:
  the pill and bar are simply not there. Never an error.
- A failure reads plainly ("Quick answers aren't working on this iPhone right now.", "Quick answers are busy. Try
  again in a moment.", "That's not one I can answer here."). After a hard failure the way in goes until the next
  launch, as on this Mac. The error kind is logged to the chat channel without any words.
- Settings › Appearance › Summaries › Advanced has a "Quick answers" switch (on by default).

### What leaves the device, and Papertrail

Nothing leaves for a quick answer: no network call is made, which the sheet says ("Stays on this iPhone",
"Talk only"). Papertrail records calls Hermes makes on the Mac, per bot, from Hermes hooks; quick answers never reach
Hermes, so there is no line to mark. A question handed to the Mac becomes an ordinary message, and Papertrail records
its route like any other turn.

## Files

New: `Packages/NollieCore/Sources/NollieCore/Chat/QuickAnswerRules.swift`, `Apps/Nollie/QuickAnswer/` (`QuickAnswers`,
`QuickAnswerSheet`, `QuickAnswerEntry`, `QuickAnswerHandoff`), tests `Tests/Unit/QuickAnswerRulesTests.swift` and
`Tests/Unit/QuickAnswersTests.swift`. Hooks: `ChatListView+Bots.swift` (the bar), `OnboardingView.swift` (two
pills), `SummariesSettingsView.swift` (the switch).

Debug flags: `-nollie-test-quick-answers` gives stand-in replies where the model can't run;
`-nollie-demo-quick-ask "first|second"` opens the sheet and asks; `-nollie-demo-quick-hand-off` hands scripted
helper questions to the Mac.

## Later

- Check real answers on a device where Apple's safety check works; tune the instructions and the routing words.
- Languages other than English for the routing rules (they match English words; the app is English only today).
- A Siri or Shortcuts path for quick answers, if the 1.2 Siri work wants one; it must use the same rules.
