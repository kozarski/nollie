import Foundation

extension ChatSession {
    // MARK: Small helpers

    /// Events go out to all devices viewing the chat, yet they carry the answer without the question.
    /// When another device begins a turn, one snapshot is fetched. Because it includes what was sent
    /// while the turn runs, the text typed over there turns up here with its reply streaming below.
    private func adoptTurnStartedElsewhere() {
        adoptingTurn = true
        Task { [weak self] in
            try? await self?.resumeFromGateway()
            self?.adoptingTurn = false
        }
    }

    private func setStatus(_ line: String) {
        guard statusLine != line else { return }
        statusLine = line
    }

    private func announceStreamed(_ chunk: String) {
        if chunk.isEmpty { return }
        let info: [String: Any] = ["storedID": storedID, "count": chunk.count, "text": chunk]
        NotificationCenter.default.post(name: .hermesStreamDelta, object: nil, userInfo: info)
    }

    private func announceReply(_ text: String?, payload: JSONValue, quiet: Bool) {
        guard !quiet, let spoken = text, spoken.contains(where: { !$0.isWhitespace }),
              payload.text("status") != "interrupted" else { return }
        let note: [String: String] = ["text": spoken, "storedID": storedID]
        NotificationCenter.default.post(name: .hermesReplyCompleted, object: nil, userInfo: note)
    }

    private func completionIsQuiet(_ payload: JSONValue, text: String?) -> Bool {
        AutomatedReply.suppressesCompletion(text: text, status: payload.text("status"), error: payload.text("error"),
                                            items: items, intentionalSilence: payload.flag("intentional_silence"))
    }

    /// The turn failed to complete cleanly according to the payload.
    private func endedInError(_ payload: JSONValue) -> Bool {
        payload.text("status") == "error" || payload.text("error")?.isEmpty == false
    }

    private func withTool(_ toolID: String, _ change: (inout ToolActivity) -> Void) -> ToolActivity? {
        // Events belong to the newest rows, so search backwards. Starting at the top made a long turn
        // with hundreds of tool calls scan the entire thread each time.
        guard let rowID = toolRows[toolID], let at = items.lastIndex(where: { $0.id == rowID }),
              case .tool(var call) = items[at].kind else { return nil }
        change(&call)
        items[at].kind = .tool(call)
        return call
    }

    private func closeTurnSurface(phase: String) {
        activityEndTask?.cancel()
        activityEndTask = nil
        activity.end(for: self, phase: phase)
    }

    // MARK: Dispatch

    /// Applies one event from the gateway to the chat.
    public func handle(event ev: GatewayEvent) {
        // A snapshot is mid-build; this event is replayed once it lands (see `apply(snapshot:)`).
        guard book.building == 0 else {
            book.held.append(HeldEvent(event: ev, at: Date()))
            return
        }
        let payload = ev.payload
        if ev.type.hasPrefix("subagent.") {
            updateSubagent(ev.type, payload)
            return
        }
        guard let kind = ChatEventKind(rawValue: ev.type) else {
            log.debug("unhandled event \(ev.type, privacy: .public)")
            return
        }
        if kind.opensTurn, !startedHere, !isRunning, !adoptingTurn, !isResuming { adoptTurnStartedElsewhere() }
        if kind == .messageComplete || kind == .error { startedHere = false }
        if kind.movesTurn { checkApprovalsIfTurnMovedOn() }

        switch kind {
        case .messageStart:
            beginStreaming()
        case .messageDelta:
            replyGrew(payload)
        case .reasoningDelta:
            reasoningGrew(payload)
        case .thinkingDelta:
            // These are the gateway's own waiting and spinner notices, not the model thinking. They go to
            // the status line and leave the reasoning card alone.
            if reply.rowID == nil { beginStreaming() }
            setStatus("Thinking…")
        case .messageInterim:
            interimReply(payload)
        case .messageComplete:
            turnCompleted(payload)
        case .sessionUsage:
            guard let fresh = try? payload["usage"]?.decode(Usage.self) else { break }
            usage = fresh
            activity.update(for: self, attention: !cards.isEmpty)
        case .sessionInfo:
            sessionInfoChanged(payload)
        case .sessionTitle:
            if let name = payload.text("title") { title = name }
        case .statusUpdate:
            statusChanged(payload)
        case .toolStart:
            toolStarted(payload)
        case .toolGenerating:
            statusLine = "Preparing \(payload.text("name") ?? "tool")…"
        case .toolComplete:
            toolFinished(payload)
        case .toolOutputRisk:
            _ = withTool(payload.text("tool_id") ?? "") { $0.risk = payload.text("risk") }
        case .error:
            appendError(payload.text("message") ?? "Unknown error")
            endPhase = "error"
            isRunning = false
            closeTurnSurface(phase: "error")
        case .notice:
            addNote(payload.text("message") ?? "", symbol: "info.circle")
        case .notificationShow:
            guard let text = payload.text("text"), !text.trimmingCharacters(in: .whitespaces).isEmpty else { break }
            (banner, bannerIsReconnect) = (text, false)
        case .notificationClear:
            banner = nil
        case .requestCancel:
            cancelCard(id: payload.text("id") ?? "", reason: payload.text("reason") ?? "cancelled")
        case .sessionReclaimed:
            stale = true
            isRunning = false
            banner = "The gateway let this session go (\(payload.text("reason") ?? "idle")). Your next message starts it again."
        case .sessionResumeProgress:
            statusLine = payload.text("message")
        case .reasoningAvailable:
            // Misleading name: this is the start of the reply again (first 500 characters), sent after every
            // model response. Treated as reasoning it filled the card with half a table.
            break
        case .reviewSummary, .todoUpdated, .voiceStatus, .voiceTranscript, .reaction, .messageReaction, .skinChanged:
            break
        }
    }

    // MARK: Reply text

    private func replyGrew(_ payload: JSONValue) {
        if reply.rowID == nil { beginStreaming() }
        setStatus("Writing…")   // the turn surface follows this
        let chunk = payload.text("text") ?? ""
        clock.characters += chunk.count
        reply.assembler.appendDelta(chunk)
        scheduleStreamingUpdate()
        announceStreamed(chunk)
    }

    private func reasoningGrew(_ payload: JSONValue) {
        if reply.rowID == nil { beginStreaming() }
        setStatus("Thinking…")
        reply.assembler.appendReasoning(payload.text("text") ?? "")
        scheduleStreamingUpdate()
    }

    private func interimReply(_ payload: JSONValue) {
        let text = payload.text("text") ?? ""
        if payload.flag("already_streamed") {
            finishStreaming(finalText: text.isEmpty ? nil : text)
            return
        }
        if text.isEmpty { return }
        finishStreaming()
        addRow(.assistant(text: text, reasoning: nil, streaming: false))
    }

    /// The gateway's receipt that a turn was stored gives the final bubble its durable row number.
    /// Only an explicit, complete receipt counts.
    public nonisolated static func completedAssistantRowID(_ payload: JSONValue) -> Int? {
        guard payload.text("status") == "complete", payload.text("error")?.isEmpty != false,
              let receipt = payload["persisted_turn"], receipt.flag("complete"),
              let last = receipt["final_assistant_row_id"]?.doubleValue,
              let rowID = Int(exactly: last), rowID > 0,
              receipt["row_ids"]?.arrayValue?.contains(where: { $0.doubleValue == last }) == true else { return nil }
        return rowID
    }

    private func turnCompleted(_ payload: JSONValue) {
        let text = payload.text("text")
        let status = payload.text("status")
        let error = payload.text("error")
        let lastReply = finishStreaming(finalText: text, gatewayReasoning: payload.text("reasoning"),
                                        previewed: payload.flag("response_previewed"))
        let quiet = completionIsQuiet(payload, text: text)
        if quiet, payload.flag("intentional_silence") { items = AutomatedReply.completingSilently(items) }

        if let at = lastReply {
            if let stored = Self.completedAssistantRowID(payload) { items[at].rowID = stored }
            if text?.isEmpty == false {
                items[at].finishReason = endedInError(payload) ? "error" : (status == "interrupted" ? "interrupted" : "stop")
            }
        }
        announceReply(text, payload: payload, quiet: quiet)
        if let fresh = try? payload["usage"]?.decode(Usage.self) { usage = fresh }
        if let at = lastReply {
            items[at].stats = clock.stats(outputTokens: usage?.output, extra: text?.count ?? 0) ?? items[at].stats
        }
        clock.stop()

        if let error, !error.isEmpty {
            appendError(error)
        } else if status == "interrupted", InterruptedTurn.parse(text ?? "") == nil {
            // The gateway's "Operation interrupted." text becomes a card that says the same thing.
            addNote("Interrupted", symbol: "stop.circle")
        }
        noteWarning(payload)
        summarizedRowShown = false
        // Nothing waits on a finished turn, so any card still up was answered on another device.
        cards.forEach(settleElsewhere)

        endPhase = endedInError(payload) ? "error" : "done"
        let phase = endPhase
        isRunning = false
        statusLine = nil
        closeTurnSurface(phase: phase)

        if quiet {
            NotificationCenter.default.post(name: .hermesSessionsChanged, object: nil)
        } else {
            runtime.cardNotifier?.turnFinished(chat: self, error: error)
        }
        saveTranscriptCache()
        drainQueue()
    }

    private func noteWarning(_ payload: JSONValue) {
        guard let warning = payload.text("warning"), !warning.isEmpty,
              CompressionNotice.read(kind: "warning", text: warning) == nil else { return }
        banner = warning
    }

    // MARK: Session facts

    private func sessionInfoChanged(_ payload: JSONValue) {
        guard let fresh = try? payload.decode(SessionLiveInfo.self) else { return }
        info = fresh
        if let name = fresh.title, !name.isEmpty { title = name }
        if let running = fresh.running { isRunning = running }
        if let stored = fresh.storedSessionId { follow(storedID: stored) }
    }

    private func statusChanged(_ payload: JSONValue) {
        let text = payload.text("text") ?? ""
        switch CompressionNotice.read(kind: payload.text("kind") ?? "", text: text) {
        case .summarizing:
            statusLine = CompressionNotice.summarizingLine
            guard !summarizedRowShown else { return }
            summarizedRowShown = true
            let row = TranscriptItem(id: UUID().uuidString, kind: .system(text: CompressionNotice.summarizedRow, symbol: "text.append"))
            // Ahead of a reply that has not said anything yet, so it reads in the order it happened.
            let before = clock.characters == 0 ? reply.rowID.flatMap { live in items.lastIndex { $0.id == live } } : nil
            items.insert(row, at: before ?? items.endIndex)
        case .finished:
            statusLine = isRunning ? "Thinking…" : nil
        case .hidden:
            break
        case nil:
            statusLine = text.isEmpty ? nil : text
        }
    }

    // MARK: Tools and helpers

    private func toolStarted(_ payload: JSONValue) {
        let toolID = payload.text("tool_id") ?? UUID().uuidString
        let call = ToolActivity(id: toolID, name: payload.text("name") ?? "tool",
                                context: payload.text("context") ?? payload.text("preview"),
                                argsText: payload.text("args_text") ?? payload["args"]?.prettyPrinted)
        let rowID = "tool-" + toolID
        toolRows[toolID] = rowID
        sealStreamingForTool()
        items.append(TranscriptItem(id: rowID, kind: .tool(call)))
        statusLine = "Running \(call.displayName)…"
        activity.update(for: self, attention: false, detail: "Running \(call.displayName)")
    }

    private func toolFinished(_ payload: JSONValue) {
        let finished = withTool(payload.text("tool_id") ?? "") { call in
            call.status = .done
            call.summary = payload.text("summary")
            call.durationSeconds = payload["duration_s"]?.doubleValue
            call.resultText = payload.text("result_text") ?? payload.text("result")
                ?? payload["result"].map { $0.isNull ? "" : $0.prettyPrinted }
        }
        // Nollie added or retired a crew member: the bot list follows.
        if let change = finished?.crewNote?.status, ["added", "removed", "restored", "retired"].contains(change) {
            Task { [runtime] in await runtime.loadProfiles() }
        }
        statusLine = "Thinking…"
    }

    /// One row per helper. The first `subagent.*` event creates it and later ones update it.
    private func updateSubagent(_ type: String, _ payload: JSONValue) {
        let rowID = SubagentActivity.rowID(for: payload) ?? "sub-" + UUID().uuidString
        let at = items.lastIndex { $0.id == rowID }
        var known: SubagentActivity?
        if let at, case .subagent(let current) = items[at].kind { known = current }
        let row = SubagentActivity.applying(type, payload, to: known)
        if let at {
            items[at].kind = .subagent(row)
            return
        }
        // Same as a tool call: whatever the bot says once its helpers are done starts a fresh bubble.
        sealStreamingForTool()
        items.append(TranscriptItem(id: rowID, kind: .subagent(row)))
    }

    /// The same failure arrives at agent start, at the turn and at completion. One row is plenty.
    private func appendError(_ text: String) {
        if case .error(let last)? = items.last?.kind, last == text { return }
        addFailure(text)
    }

    // MARK: Events a snapshot already showed

    /// Replays an event that came in while a snapshot was being built but happened before the applied
    /// reply. What it changed in the thread, cards and running state is already in the snapshot; the
    /// remaining side work is still owed. Discarding it altogether meant a finished turn never released
    /// the message queued behind it, a withdrawn question kept its waiter forever, and a card left up by
    /// the snapshot outlasted its turn. `arrivedAt` is the time the event reached this device.
    func handleShownBySnapshot(_ ev: GatewayEvent, arrivedAt: Date) {
        let payload = ev.payload
        switch ev.type {
        case "message.delta":
            announceStreamed(payload.text("text") ?? "")   // the typing haptics follow the reply
        case "message.complete":
            let text = payload.text("text")
            let quiet = completionIsQuiet(payload, text: text)
            announceReply(text, payload: payload, quiet: quiet)
            if let fresh = try? payload["usage"]?.decode(Usage.self) { usage = fresh }
            noteWarning(payload)
            summarizedRowShown = false
            // Timing and sealed text from this turn must not leak into the next.
            clock.stop()
            reply.sealed = ""
            // If the snapshot already shows the next turn running, leave it; otherwise this turn is over.
            if !isRunning {
                startedHere = false
                statusLine = nil
                settleLeftUpBySnapshot(upBefore: arrivedAt)
                closeTurnSurface(phase: endedInError(payload) ? "error" : "done")
            }
            if quiet {
                NotificationCenter.default.post(name: .hermesSessionsChanged, object: nil)
            } else {
                runtime.cardNotifier?.turnFinished(chat: self, error: payload.text("error"))
            }
            drainQueue()
        case "error":
            guard !isRunning else { return }
            startedHere = false
            settleLeftUpBySnapshot(upBefore: arrivedAt)
            closeTurnSurface(phase: "error")
        case "request.cancel":
            // A withdrawn request does not return. The snapshot may not list it, which means its card is
            // gone and anyone waiting is let go. Or the snapshot predates the withdrawal and the card is
            // still up, so it is taken down now.
            cancelCard(id: payload.text("id") ?? "", reason: payload.text("reason") ?? "cancelled")
        case "session.reclaimed":
            // Only when the snapshot belongs to the session that ended; a later resume is a new session.
            let named = payload.text("session_id") ?? ev.sessionID
            if named == runtimeID { handle(event: ev) }
        default:
            // Usage and notices act at once. Everything else only changes what the snapshot already shows.
            if ["session.usage", "notification.show", "notification.clear"].contains(ev.type) { handle(event: ev) }
        }
    }

    /// The turn finished ahead of the applied snapshot's reply, and the snapshot shows nothing
    /// running. A card that survived only because it was raised after the snapshot was requested,
    /// yet before this end, belonged to this turn and goes like any card at turn end. A card raised
    /// since belongs to the next turn; removing it too left the bot waiting on nothing anyone could see.
    private func settleLeftUpBySnapshot(upBefore end: Date) {
        for card in cards where book.leftUp.contains(card.id) {
            if (ledger.shownAt[card.id] ?? .distantPast) < end { settleElsewhere(card) }
        }
    }

    func drainQueue() {
        guard !isRunning, !isSubmitting, let next = queue.first else { return }
        queue.removeFirst()
        // Marked now, not when the task starts, so a send in between queues behind this one.
        isSubmitting = true
        Task { [self] in await submit(text: next.text, attachments: next.attachments, queued: true) }
    }
}
