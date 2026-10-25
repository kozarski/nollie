# Core: TranscriptItem.swift and ChatSession.swift (behaviour spec)

## TranscriptItem.swift
Row types of a conversation, plus helpers that read gateway text.
- ToolActivity (public, Identifiable): id, name, context, argsText, status (running/done/failed), summary,
  resultText, durationSeconds, risk, delivery (set at init from BotDelivery.parse). displayName replaces
  underscores with spaces. deliveryReply: for a delivery, the result without `session_id:` lines, unwrapped
  from a JSON `{"output": ...}` when the text starts with `{`, with a leading "Message from X:" removed.
- BotDelivery (target, message?): `parse(name:context:argsText:)` finds a message to another bot in a tool
  call: the full command from the args JSON `"command"` (unescaped) beats the short context; `peer dm
  <peer>/<bot>`; the `--run-delivery` runner with `-p <bot>`; a quiet CLI run (-q/-Q/--quiet/--query-file or
  `-c "Bot Chat"` or "Message from" text) that has `chat` and `-p/--profile <bot>`, message taken from the text
  quoted after `-q `; tools named message_agent / send_message_to_agent with a "target" in args (message from
  args) or, failing that, the context. `key(_:)` makes a routing alias: trim, drop leading @, drop `@host`
  suffix, last `/` part, lowercased.
- AgentMessage (sender, handle?, body): `parse` reads "Message from [robot] Sender (@handle): body" and
  "[Message from agent 'Sender'] body"; `key` = BotDelivery.key(handle ?? sender).
- AttachmentPreview (id, name, serverPath, kind image/pdf/audio/video/file, localURL, byteCount).
- SubagentActivity: helper row (id, goal, status, step, model, toolCount, durationSeconds, summary, taskIndex,
  taskCount). isRunning, failed (failed or error), detailLine ("2 of 3 · step" while running; "Done in 5s · 3
  tool calls" after, seconds under 60 else minutes). rowID(for:) = "sub-" + subagent_id | child_session_id |
  delegation_id, nil if none. applying(type, payload, to:) creates ("Subagent" goal) or updates: goal, model,
  tool_count, task_index, task_count; subagent.tool sets step "name: preview(120)"; thinking/progress set step to
  last 160 chars of one-lined text; complete sets status (default completed), summary, duration_seconds, clears step.
- TranscriptItem (Identifiable): id, kind (user/assistant/tool/system/error/subagent/steer), timestamp, rowID,
  stats, finishReason, displayKind, controlMarker, notificationCategory; full init. `fromHistory(_ [msgs],
  running:, settled:)` builds rows in order; an empty assistant row whose answer was promoted (api_content, or
  reasoning when no tool calls, clean stop, and followed by a user message or being last in a finished chat or
  settled) becomes the reply. `withPromotedAnswers` does the same on messages. `fromHistory(_ msg, index:)`: ids
  "h-<rowId|index>-<index>"; hidden rows dropped unless an assistant control marker; user, assistant (reasoning
  dropped when equal to the text), tool/tool_call (failed when finishReason is error), system, error, other
  roles as assistant; empty text rows dropped. `isEmptyAssistant` and `promotedAnswer` are internal (tests).
- StreamAssembler: text, reasoning, deltaCount, isStreaming; start/appendDelta/appendReasoning/complete/reset;
  `normalized` strips think/reasoning tags and collapses whitespace; `settledReasoning(...)`; `suffixStart`;
  `tail(ofFinalText:alreadySealed:)` (prefix drop, else whitespace-insensitive match, else full).
- TurnStats (outputTokens, seconds, exact): tokensPerSecond when seconds > 0.5; label "412 tokens · 38 tok/s ·
  10.8s" (~ when estimated, minutes when 60+); `make` exact when after > before else max(1, chars/4).
- InjectedNote.parse: bracketed notices -> title/body (background process finished/failed, cronjob, async
  delegation, generic note).
- StartFailure.parse: provider and reason for "could not start the assistant" / missing CLI.
Tests: ConversationReducerTests, TranscriptTests, StreamAssembler tests, DeliveryTests etc. in Tests/Unit.

## ChatSession.swift
One live conversation (MainActor, Observable): transcript, streaming assembly, cards, send queue, attachments.
- QueuedMessage, PendingCard (+approval/clarify/valuePrompt/isSecret/isNamed(by:)).
- Public surface kept as-is: runtime, runtimeID, storedID, formerStoredIDs, title, info, items, usage,
  isRunning (starts a 6 s approval poll while running; stops it and ends the activity 2 s later), turnStartedHere,
  statusLine, banner, interruptCause, cards, queue, staged, composerHistory, lastSubmitStatus, stale,
  isResuming, resumeError, profile, profileName, modelName, subtitle, firstCard, needsAttention, approvalCard(named:),
  approvalToAnswer(named:) and the waiting variant, create(cwd:), resume(), reattachAfterReconnect, beginResume,
  awaitResume, send, stageAttachment, removeStaged, stop, steer, removeQueued, updateQueued, pollPendingApprovals,
  loadUsage, contextBreakdown, setModel/setReasoning/setFast/setYolo, rename, answer(serverRequest:), respond(card:result:),
  handle(event:), static helpers (inflightPromptIsListed, keepingIDs, completedAssistantRowID, imageTranscoder,
  renamedByPerson, markRenamedByPerson), internal ones tests reach (gatewayStandIn, beforeSnapshotRows, apply(snapshot:),
  attachmentFailure, streamingInterval, cardGrace, cameBack, follow, isBuildingSnapshot, snapshotRows).
- Snapshots: events arriving while rows are built off-actor are held, then replayed; those that came before the
  reply is applied only do their side effects. Newer snapshots win. Rows added here meanwhile are kept.
- Cards: shown once, twins (queue id and request id) merged, list-vs-removed bookkeeping so an answered card does not
  return, cards dropped when a list no longer has them, settled at turn end.
- Events: message.* streaming (throttled redraw, longer when the reply is long, not at all while away), reasoning,
  tools, subagents, status, errors, notices, usage, info, title, reclaim, request.cancel.
- Slash commands: local ones (approve, deny, stop, title, model, reasoning, new, help) else slash.exec with fallback
  to command.dispatch; desktop-only commands are refused with a reason; alias loops are capped.
Tests: ConversationEngineTests, ChatSession*Tests, ApprovalTests, SnapshotTests, etc.
