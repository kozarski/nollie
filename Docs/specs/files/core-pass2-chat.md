# Core chat engine, second pass

Behaviour is unchanged; only the shape of the code moved. Notes per file.

- ChatSession: the pending card keeps the same fields and rules (named by its id, or for an approval by its
  request id, bare or as the queue's `queue-<id>`). Opening a chat, resuming and re-attaching read as small
  steps: a failed re-attach is sorted into "ignore", "try once more" and "explain" in that order. The call
  timeout is one named constant. The chat can now be made with no stored id or title.
- Snapshots: a snapshot's rows are one named pair (as the gateway numbered them, under the ids on screen).
  Opening the turn surface after a snapshot is its own step.
- Cards: the removal ledger, the approval wait and the twin check say the same things in other words. The
  snapshot's card step takes the answer time first.
- Streaming: the opening of a reply uses the same row maker as later redraws; the "already shown as a
  preview" check is its own small function.
- Sending, commands, events: same wire calls and notices; settings changes share one helper, the quiet
  completion and queue steps are plain loops.
- TranscriptItem and friends: initialisers assign field by field; history rows are built with one pass
  and a shared "thinking that is not just the answer" helper.
- StreamAssembler: same text, reasoning and count; the end-of-answer search reads the non-blank letters
  once instead of walking back from the end.
- SubagentActivity: header facts (goal, model, counts) are taken in one step before the event's own news.
- AutomatedReply: prompt and reply tests are named helpers, so the quiet-completion rule reads top down.
- BotMessages: the message tool is its own step; text unescaping is a small table.
