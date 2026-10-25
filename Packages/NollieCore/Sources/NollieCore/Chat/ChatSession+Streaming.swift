import Foundation

extension ChatSession {
    private func finishedReplyRow(_ row: TranscriptItem) -> Bool {
        guard case .assistant(let words, _, false) = row.kind else { return false }
        return !words.isEmpty
    }

    private func replyKind(streaming: Bool, text: String? = nil) -> TranscriptItem.Kind {
        let thoughts = reply.assembler.reasoning
        return .assistant(text: text ?? reply.assembler.text, reasoning: thoughts.isEmpty ? nil : thoughts, streaming: streaming)
    }

    /// A new reply row opens, and with it the turn's clock if it is not running yet.
    func beginStreaming() {
        if reply.rowID == nil, !isRunning { reply.sealed = "" }
        let rowID = "stream-\(UUID().uuidString)"
        reply.rowID = rowID
        clock.begin(outputTokens: usage?.output)
        reply.assembler.start()
        isRunning = true
        items.append(TranscriptItem(id: rowID, kind: replyKind(streaming: true, text: "")))
        activity.start(for: self)
        statusLine = "Thinking…"
    }

    /// Pause between redraws of the streaming row.
    ///
    /// Drawing the reply means parsing and laying out all of it each time. By the close of a long
    /// turn that is tens of kilobytes, and redrawing every 40 ms swallowed the main thread so taps
    /// stopped responding. The interval therefore stretches as the reply grows, holding the work per
    /// second steady. A short reply still redraws roughly 25 times each second.
    nonisolated static func streamingInterval(utf8Count size: Int) -> Duration {
        let scaled = size >> 7
        return Duration.milliseconds(Swift.min(Swift.max(scaled, 40), 250))
    }

    /// Asks for the streaming row to be redrawn soon, gathering whatever arrives before then.
    func scheduleStreamingUpdate() {
        guard reply.flush == nil else { return }
        // In the background nobody can see the thread, yet each redraw still parsed the whole reply.
        // Parsed copies are released there, which kept the main thread too busy to answer the system's
        // "time is up" call, and the app was terminated. So text gathers unseen and is drawn once on
        // return (`cameBack`). The Live Activity stays visible, so it still hears about the turn each second.
        if runtime.isAway {
            nudgeActivity(attention: !cards.isEmpty)
            return
        }
        let size = reply.assembler.text.utf8.count + reply.assembler.reasoning.utf8.count
        reply.flush = Delay.run(after: Self.streamingInterval(utf8Count: size)) { [weak self] in
            self?.reply.flush = nil
            self?.updateStreamingItem()
        }
    }

    /// Lets the turn surface know how the turn is going, no more than once per second.
    private func nudgeActivity(attention: Bool) {
        let now = Date()
        guard now.timeIntervalSince(lastActivityUpdate) > 1 else { return }
        lastActivityUpdate = now
        activity.update(for: self, attention: attention)
    }

    /// Returns to the foreground and paints the reply that arrived during the absence.
    func cameBack() {
        if reply.rowID != nil, reply.flush == nil { updateStreamingItem() }
    }

    private func updateStreamingItem() {
        reply.flush?.cancel()
        reply.flush = nil
        guard let live = reply.rowID, let at = items.lastIndex(where: { $0.id == live }) else { return }
        items[at].kind = replyKind(streaming: true)
        if Date().timeIntervalSince(lastStatsUpdate) > 0.5, let running = clock.estimate() {
            lastStatsUpdate = Date()
            items[at].stats = running
        }
        // Keeps the token count and clock on the turn surface current, about once per second.
        nudgeActivity(attention: false)
    }

    /// A tool call (or helper) starts: what the bot has said so far is closed off as a bubble so
    /// whatever it says next goes below the call.
    func sealStreamingForTool() {
        guard let live = reply.rowID, let at = items.lastIndex(where: { $0.id == live }) else { return }
        reply.sealed += reply.assembler.text
        if reply.assembler.text.isEmpty {
            items.remove(at: at)
        } else {
            items[at].kind = replyKind(streaming: false)
        }
        reply.rowID = nil
        reply.assembler.reset()
    }

    /// True when nothing has streamed since and the last finished bubble says `finalText` already.
    private func alreadyShown(_ finalText: String) -> Bool {
        guard reply.assembler.text.allSatisfy(\.isWhitespace),
              let at = items.lastIndex(where: finishedReplyRow),
              case .assistant(let bubble, _, _) = items[at].kind else { return false }
        let trim = { (text: String) in text.trimmingCharacters(in: .whitespacesAndNewlines) }
        return trim(bubble) == trim(finalText)
    }

    /// Ends the reply. Gives the index of the turn's last assistant bubble when one is showing.
    @discardableResult
    func finishStreaming(finalText: String? = nil, gatewayReasoning: String? = nil, previewed: Bool = false) -> Int? {
        let live = reply.rowID
        let sealed = reply.sealed
        defer {
            reply.rowID = nil
            reply.sealed = ""
            reply.assembler.reset()
        }

        // A runtime may deliver each completed message as an interim one, leaving the final reply
        // already displayed with nothing streamed after it. The gateway signals this with
        // `response_previewed`. The bubble showing is the reply, so adding it again showed it twice.
        if previewed, let finalText, alreadyShown(finalText) {
            if let live { items.removeAll { $0.id == live } }
            return items.lastIndex(where: finishedReplyRow)
        }

        // `finalText` covers the whole turn. When tool calls cut the stream, the early part already sits
        // in earlier bubbles, so the last bubble only gets what comes after.
        let remainder = finalText.map { StreamAssembler.tail(ofFinalText: $0, alreadySealed: sealed) }
        var settled: Int?

        if let live, let at = items.lastIndex(where: { $0.id == live }) {
            let streamed = reply.assembler.text
            let text = reply.assembler.complete(finalText: remainder)
            if text.allSatisfy(\.isWhitespace) {
                items.remove(at: at)
            } else {
                // Reasoning that is really the answer (promoted by the gateway) becomes the reply, not a card.
                let thoughts = StreamAssembler.settledReasoning(streamedText: streamed, reasoning: reply.assembler.reasoning,
                                                                finalText: text, gatewayReasoning: gatewayReasoning)
                items[at].kind = .assistant(text: text, reasoning: thoughts, streaming: false)
                settled = at
            }
        } else if let remainder, remainder.contains(where: { !$0.isWhitespace }) {
            addRow(.assistant(text: remainder, reasoning: nil, streaming: false))
            settled = items.count - 1
        }
        return settled ?? items.lastIndex { if case .assistant = $0.kind { true } else { false } }
    }
}
