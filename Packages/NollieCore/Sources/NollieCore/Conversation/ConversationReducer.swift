import Foundation

/// The conversation as plain values: the live tail of the transcript, the questions waiting, what the bot is doing
/// and what the person has typed. Only `ConversationReducer` changes it.
public struct ConversationState: Hashable, Sendable {
    public internal(set) var lineage: ConversationLineage
    /// The live session this device is attached to (`session_id` in events and calls).
    public internal(set) var runtimeSession: String?
    /// The live tail, oldest first. Stored history before it lives in `ConversationWindow`.
    public internal(set) var rows: [ConversationRow] = []
    public internal(set) var cards: [ConversationCard] = []
    public internal(set) var activity: ConversationActivity = .idle
    public internal(set) var running = false
    public internal(set) var title: String?
    /// A warning from Hermes worth showing once (never its advice to start a new chat).
    public internal(set) var notice: String?
    public internal(set) var outbox = ConversationOutbox()

    /// Moves by one on every input.
    public internal(set) var clock = 0
    /// The current (or last) turn; 0 before the first.
    public internal(set) var turn = 0
    /// Turns Hermes has said are stored in full.
    public internal(set) var settledTurns: Set<Int> = []
    /// A turn began that this device did not send: a snapshot would show its prompt.
    public internal(set) var turnNeedsPrompt = false
    /// The chat needs attaching again before it can be trusted (reclaimed, or Hermes said reload).
    public internal(set) var needsAttach = false
    /// The highest seq applied per runtime session.
    public internal(set) var watermarks: [String: Int] = [:]

    var streamingRowId: String?
    /// The latest reply row of the current turn.
    var replyRowId: String?
    /// The `summarized` note of the compression under way, if one is.
    var openSummaryId: String?
    var nextLocal = 1

    public init(lineage: ConversationLineage, outbox: ConversationOutbox = ConversationOutbox()) {
        self.lineage = lineage
        self.outbox = outbox
    }

    /// Whether a turn is over (so its rows will not change again).
    public func hasEnded(turn number: Int) -> Bool { number < turn || !running }

    public func row(_ id: String) -> ConversationRow? { rows.first { $0.id == id } }
}

/// Everything that can change a conversation.
public enum ConversationInput: Hashable, Sendable {
    case event(GatewayEventEnvelope)
    case question(GatewayIncomingQuestion)
    case questionWithdrawn(id: String)
    /// A `session.resume` answer. `held`: events that arrived while it was in flight, in order. `requestedAt`: the
    /// clock when it was asked for. `full`: after a reload, the snapshot replaces the ended turns.
    case attached(ConversationSnapshot, held: [GatewayEventEnvelope], requestedAt: Int, full: Bool)
    case compose(text: String)
    case sendStarted(id: String)
    case sendFinished(id: String, ConversationSendOutcome)
    /// Something other than the send's answer shows Hermes has the message (stored at `at`, when known).
    case sendLanded(id: String, at: ConversationRowAddress?)
    case discard(id: String)
    /// The person chose to send a message again whose first send failed or may not have landed.
    case resend(id: String)
    case answered(cardId: String, choice: String?)
    case setAside(cardId: String)
    /// The history window now holds these stored rows.
    case absorbed(Set<ConversationRowAddress>)
    /// The client said this session's events cannot be trusted from where they were; its numbering starts over.
    case reset(session: String)
}

/// Gateway inputs in, the next state out. Pure: the same inputs in the same order always give the same state.
/// See `Docs/specs/conversation-engine.md`.
public enum ConversationReducer {
    public static func reduce(_ state: ConversationState, _ input: ConversationInput) -> ConversationState {
        var next = state
        next.clock += 1
        next.apply(input)
        return next
    }

    public static func reduce(_ state: ConversationState, _ inputs: [ConversationInput]) -> ConversationState {
        inputs.reduce(state, reduce)
    }

    /// How Hermes's words about compression read.
    enum CompressionSign: Equatable {
        case summarizing
        case finished
        /// Advice to start a new chat: never shown, Nollie keeps one endless chat.
        case startOverAdvice
    }

    static func compressionSign(kind: String, text: String) -> CompressionSign? {
        let words = text.lowercased()
        if kind == "compacting" || words.contains("compacting context") { return .summarizing }
        if kind == "compacted" || words.contains("compaction complete") { return .finished }
        if words.contains("session compressed") || (words.contains("compress") && words.contains("/new")) { return .startOverAdvice }
        return nil
    }
}

// MARK: - Applying inputs

extension ConversationState {
    fileprivate mutating func apply(_ input: ConversationInput) {
        switch input {
        case .event(let event): receive(event)
        case .question(let question): show(question)
        case .questionWithdrawn(let id): withdraw(card: id)
        case .attached(let snapshot, let held, let requestedAt, let full): attach(snapshot, held: held, requestedAt: requestedAt, full: full)
        case .compose(let text):
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            outbox.add(.init(id: makeId("out"), text: trimmed))
        case .sendStarted(let id): startSending(id)
        case .sendFinished(let id, let outcome): finishSending(id, outcome)
        case .sendLanded(let id, let address): landed(id, at: address)
        case .discard(let id):
            guard let state = outbox[id]?.state, state != .sending else { return }
            outbox.remove(id)
            let rowId = userRowId(for: id)
            rows.removeAll { $0.id == rowId }
        case .resend(let id):
            guard let entry = outbox[id] else { return }
            switch entry.state {
            case .uncertain, .failed: break
            default: return
            }
            outbox.remove(id)
            let rowId = userRowId(for: id)
            rows.removeAll { $0.id == rowId }
            outbox.add(.init(id: makeId("out"), text: entry.text))
        case .answered(let id, let choice):
            guard cards.contains(where: { $0.id == id }) else { return }
            cards.removeAll { $0.id == id }
            append(.note(.answered(choice: choice)))
        case .setAside(let id):
            cards.removeAll { $0.id == id }
        case .absorbed(let stored): absorb(stored)
        case .reset(let session):
            watermarks[session] = nil
            if session == runtimeSession { needsAttach = true }
        }
    }

    // MARK: Events

    private mutating func receive(_ event: GatewayEventEnvelope) {
        guard !event.sessionId.isEmpty, event.sessionId == runtimeSession else { return }
        if let seq = event.seq {
            if seq <= watermarks[event.sessionId] ?? 0 { return }
            watermarks[event.sessionId] = seq
        }
        let payload = event.payload ?? [:]
        switch event.type {
        case GatewayWire.Events.messageStart.name:
            joinTurn()
            activity = .thinking
        case GatewayWire.Events.messageDelta.name:
            joinTurn()
            let text = payload["text"]?.stringValue ?? ""
            updateStreaming { $0.text += text }
            activity = .writing
        case GatewayWire.Events.reasoningDelta.name:
            joinTurn()
            let text = payload["text"]?.stringValue ?? ""
            updateStreaming { $0.reasoning += text }
            activity = .thinking
        case GatewayWire.Events.thinkingDelta.name:
            joinTurn()
            activity = .thinking
        case GatewayWire.Events.messageInterim.name:
            interim(text: payload["text"]?.stringValue ?? "", alreadyStreamed: payload["already_streamed"]?.boolValue ?? false)
        case GatewayWire.Events.toolStart.name:
            joinTurn()
            startTool(payload)
        case GatewayWire.Events.toolGenerating.name:
            activity = .preparingTool(payload["name"]?.stringValue ?? "tool")
        case GatewayWire.Events.toolComplete.name:
            finishTool(payload)
            if running { activity = .thinking }
        case GatewayWire.Events.toolOutputRisk.name:
            if let index = toolIndex(payload["tool_id"]?.stringValue ?? ""), case .tool(var step) = rows[index].kind {
                step.risk = payload["risk"]?.stringValue
                rows[index].kind = .tool(step)
            }
        case GatewayWire.Events.statusUpdate.name:
            status(kind: payload["kind"]?.stringValue ?? "", text: payload["text"]?.stringValue ?? "")
        case GatewayWire.Events.sessionInfo.name:
            if let title = payload["title"]?.stringValue, !title.isEmpty { self.title = title }
            if let stored = payload["stored_session_id"]?.stringValue { moveTip(to: stored) }
            if let flag = payload["running"]?.boolValue {
                if flag { joinTurn() } else if running { endTurn() }
            }
        case GatewayWire.Events.sessionTitle.name:
            if let title = payload["title"]?.stringValue { self.title = title }
        case GatewayWire.Events.messageComplete.name:
            complete(payload)
        case GatewayWire.Events.error.name:
            sealStreaming(ending: .error)
            append(.error(payload["message"]?.stringValue ?? ""))
            endTurn()
        case GatewayWire.Events.notice.name:
            if let text = payload["message"]?.stringValue, !text.isEmpty { append(.note(.notice(text))) }
        case GatewayWire.Events.requestCancel.name:
            withdraw(card: payload["id"]?.stringValue ?? "")
        case GatewayWire.Events.sessionReclaimed.name:
            sealStreaming(ending: nil)
            endTurn()
            needsAttach = true
        default:
            break
        }
    }

    /// A turn's event arrived: it belongs to the turn under way, or starts one this device did not send.
    private mutating func joinTurn() {
        guard !running else { return }
        beginTurn()
        turnNeedsPrompt = true
    }

    private mutating func beginTurn() {
        turn += 1
        running = true
        streamingRowId = nil
        replyRowId = nil
        openSummaryId = nil
        turnNeedsPrompt = false
        activity = .thinking
    }

    private mutating func endTurn() {
        sealStreaming(ending: nil)
        running = false
        activity = .idle
        openSummaryId = nil
        turnNeedsPrompt = false
        outbox.forgetSent()
    }

    /// Changes the streaming reply, opening one first if none is.
    private mutating func updateStreaming(_ change: (inout ConversationReply) -> Void) {
        let index: Int
        if let id = streamingRowId, let found = rows.lastIndex(where: { $0.id == id }) {
            index = found
        } else {
            let row = ConversationRow(id: makeId("reply"), kind: .assistant(ConversationReply(streaming: true)), turn: turn)
            rows.append(row)
            streamingRowId = row.id
            replyRowId = row.id
            index = rows.count - 1
        }
        guard case .assistant(var reply) = rows[index].kind else { return }
        change(&reply)
        rows[index].kind = .assistant(reply)
    }

    /// The streaming reply stops taking text: a tool came between, or the turn ended. An empty one goes.
    private mutating func sealStreaming(ending: ConversationReply.Ending?) {
        guard let id = streamingRowId else { return }
        streamingRowId = nil
        guard let index = rows.lastIndex(where: { $0.id == id }), case .assistant(var reply) = rows[index].kind else { return }
        if reply.isEmpty {
            rows.remove(at: index)
            if replyRowId == id { replyRowId = nil }
            return
        }
        reply.streaming = false
        if let ending { reply.ending = ending }
        rows[index].kind = .assistant(reply)
    }

    private mutating func interim(text: String, alreadyStreamed: Bool) {
        joinTurn()
        if alreadyStreamed {
            if !text.isEmpty { updateStreaming { $0.text = text } }
            sealStreaming(ending: nil)
        } else if !text.isEmpty {
            sealStreaming(ending: nil)
            let row = ConversationRow(id: makeId("reply"), kind: .assistant(ConversationReply(text: text)), turn: turn)
            rows.append(row)
            replyRowId = row.id
        }
    }

    private mutating func startTool(_ payload: GatewayJSON) {
        sealStreaming(ending: nil)
        let toolId = payload["tool_id"]?.stringValue ?? makeId("tool")
        let step = ConversationToolStep(
            toolId: toolId, name: payload["name"]?.stringValue ?? "tool",
            context: payload["context"]?.stringValue ?? payload["preview"]?.stringValue,
            argumentsText: payload["args_text"]?.stringValue ?? payload["args"].flatMap { args in
                (try? args.encoded()).map { String(decoding: $0, as: UTF8.self) }
            })
        if let index = toolIndex(toolId), rows[index].turn == turn {
            rows[index].kind = .tool(step)
        } else {
            let id = toolIndex(toolId) == nil ? "tool:\(toolId)" : "tool:\(toolId):\(turn)"
            rows.append(ConversationRow(id: id, kind: .tool(step), turn: turn))
        }
        activity = .runningTool(step.name)
    }

    private mutating func finishTool(_ payload: GatewayJSON) {
        guard let index = toolIndex(payload["tool_id"]?.stringValue ?? ""), case .tool(var step) = rows[index].kind else { return }
        step.done = true
        step.summary = payload["summary"]?.stringValue
        step.resultText = payload["result_text"]?.stringValue ?? ConversationText.plain(payload["result"])
        step.seconds = payload["duration_s"]?.doubleValue
        rows[index].kind = .tool(step)
    }

    private func toolIndex(_ toolId: String) -> Int? {
        rows.lastIndex { if case .tool(let step) = $0.kind { step.toolId == toolId } else { false } }
    }

    // MARK: Compression

    private mutating func status(kind: String, text: String) {
        if let change = BackupSwitch.read(kind: kind, text: text) {
            append(.note(.notice(change.line(here: BackupSwitch.here))))
            return
        }
        switch ConversationReducer.compressionSign(kind: kind, text: text) {
        case .summarizing:
            joinTurn()
            // No compression open, or the open one already moved the tip: this is a new one.
            if openSummaryNote() != .summarized(into: nil) { addSummaryNote(into: nil) }
            activity = .summarizing
        case .finished:
            activity = running ? .thinking : .idle
        case .startOverAdvice:
            break
        case nil:
            if !text.isEmpty { activity = .status(text) }
        }
    }

    private func openSummaryNote() -> ConversationNote? {
        guard let id = openSummaryId else { return nil }
        return row(id)?.note
    }

    /// The tip moved: one `summarized` note per move, however Hermes ordered its signs.
    private mutating func moveTip(to stored: String) {
        guard lineage.advance(to: stored) else { return }
        if let id = openSummaryId, let index = rows.firstIndex(where: { $0.id == id }), rows[index].note == .summarized(into: nil) {
            rows[index].kind = .note(.summarized(into: stored))
        } else {
            addSummaryNote(into: stored)
        }
    }

    private mutating func addSummaryNote(into stored: String?) {
        let row = ConversationRow(id: makeId("summary"), kind: .note(.summarized(into: stored)), turn: turn)
        // Ahead of a reply that has not said anything yet, so it reads in the order it happened.
        if let id = streamingRowId, let index = rows.lastIndex(where: { $0.id == id }), rows[index].reply?.text.isEmpty == true {
            rows.insert(row, at: index)
        } else {
            rows.append(row)
        }
        openSummaryId = row.id
    }

    // MARK: Completion

    private mutating func complete(_ payload: GatewayJSON) {
        let text = ConversationText.plain(payload["text"]) ?? ""
        let error = payload["error"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
        let status = payload["status"]?.stringValue
        let ending: ConversationReply.Ending = error != nil || status == "error" ? .error
            : status == "interrupted" ? .interrupted : .complete
        // The reply this completes: the one streaming, or the turn's latest one not yet finished.
        var replyIndex: Int?
        if let id = streamingRowId ?? replyRowId, let index = rows.lastIndex(where: { $0.id == id }),
           rows[index].turn == turn, rows[index].reply?.ending == nil {
            replyIndex = index
        }
        streamingRowId = nil
        if let index = replyIndex, case .assistant(var reply) = rows[index].kind {
            if !text.isEmpty { reply.text = text }
            if reply.reasoning.isEmpty, let reasoning = payload["reasoning"]?.stringValue { reply.reasoning = reasoning }
            reply.streaming = false
            reply.ending = ending
            if reply.isEmpty {
                rows.remove(at: index)
                replyIndex = nil
            } else {
                rows[index].kind = .assistant(reply)
            }
        } else if !text.isEmpty {
            rows.append(ConversationRow(id: makeId("reply"), kind: .assistant(ConversationReply(text: text, ending: ending)), turn: turn))
            replyIndex = rows.count - 1
        }
        if let error {
            append(.error(error))
        } else if ending == .interrupted {
            append(.note(.interrupted))
        }
        if let warning = payload["warning"]?.stringValue, !warning.isEmpty,
           ConversationReducer.compressionSign(kind: "warning", text: warning) == nil {
            notice = warning
        }
        stampStored(payload["persisted_turn"], replyIndex: replyIndex, complete: ending == .complete)
        // A finished turn waits on nothing: a card still up was settled somewhere else.
        for _ in cards { append(.note(.answeredElsewhere)) }
        cards.removeAll()
        endTurn()
    }

    /// Hermes stored the turn: its user row and final reply learn their addresses.
    private mutating func stampStored(_ receipt: GatewayJSON?, replyIndex: Int?, complete: Bool) {
        guard complete, let receipt, receipt["complete"]?.boolValue == true else { return }
        let stored = Set(receipt["row_ids"]?.arrayValue?.compactMap(\.intValue) ?? [])
        if let user = receipt["user_row_id"]?.intValue,
           let index = rows.firstIndex(where: { $0.turn == turn && $0.userText != nil }) {
            rows[index].address = ConversationRowAddress(segment: lineage.tip, rowId: user)
        }
        if let final = receipt["final_assistant_row_id"]?.intValue, stored.isEmpty || stored.contains(final), let index = replyIndex {
            rows[index].address = ConversationRowAddress(segment: lineage.tip, rowId: final)
        }
        if rows.contains(where: { $0.turn == turn && $0.address != nil }) { settledTurns.insert(turn) }
    }

    // MARK: Questions

    private mutating func show(_ question: GatewayIncomingQuestion) {
        guard !cards.contains(where: { $0.id == question.id }) else { return }
        let params = question.params
        let kind: ConversationCard.Kind
        switch question.method {
        case GatewayWire.Questions.approval.name:
            kind = .approval(requestId: params["request_id"]?.stringValue, command: params["command"]?.stringValue,
                             description: params["description"]?.stringValue,
                             choices: params["choices"]?.arrayValue?.compactMap(\.stringValue) ?? [])
        case GatewayWire.Questions.clarify.name:
            let questions = (params["questions"]?.arrayValue ?? []).compactMap { entry -> ConversationCard.Question? in
                guard let id = entry["qid"]?.stringValue else { return nil }
                return ConversationCard.Question(id: id, text: entry["question"]?.stringValue ?? "",
                                                 choices: entry["choices"]?.arrayValue?.compactMap(\.stringValue) ?? [],
                                                 multipleChoice: entry["multi_select"]?.boolValue ?? false)
            }
            kind = .clarify(questions: questions)
        default:
            let prompt = params["prompt"]?.stringValue ?? params["description"]?.stringValue ?? params["message"]?.stringValue ?? ""
            kind = .value(prompt: prompt, secret: true)
        }
        let card = ConversationCard(id: question.id, method: question.method, kind: kind, shownAt: clock)
        // The request's own card takes the place of the approval queue's card for the same request.
        if let requestId = card.approvalRequestId,
           let index = cards.firstIndex(where: { $0.viaApprovalQueue && $0.approvalRequestId == requestId }) {
            cards[index] = card
        } else {
            cards.append(card)
        }
    }

    private mutating func withdraw(card id: String) {
        guard cards.contains(where: { $0.id == id }) else { return }
        cards.removeAll { $0.id == id }
        append(.note(.withdrawn))
    }

    // MARK: Snapshots

    private mutating func attach(_ snapshot: ConversationSnapshot, held: [GatewayEventEnvelope], requestedAt: Int, full: Bool) {
        if let previous = runtimeSession, previous != snapshot.runtimeSession { watermarks[previous] = nil }
        runtimeSession = snapshot.runtimeSession
        needsAttach = false
        if let stored = snapshot.storedSession { lineage.resolve(to: stored) }
        if let title = snapshot.title, !title.isEmpty { self.title = title }
        if full { dropEndedTurns() }

        if snapshot.running {
            if !running { beginTurn() }
            turnNeedsPrompt = false
            if let prompt = snapshot.inflightUser, !prompt.isEmpty, !rows.contains(where: { $0.turn == turn && $0.userText != nil }) {
                let at = rows.firstIndex { $0.turn == turn } ?? rows.count
                rows.insert(ConversationRow(id: makeId("user"), kind: .user(text: prompt, delivery: .sent), turn: turn), at: at)
            }
            if let reply = snapshot.inflightReply, !reply.isEmpty {
                updateStreaming { shown in
                    if shown.text.isEmpty || reply.hasPrefix(shown.text) { shown.text = reply }
                }
            }
        } else if running {
            endTurn()
        }

        settleCards(snapshot, requestedAt: requestedAt)

        for entry in outbox.uncertain where [snapshot.inflightUser, snapshot.queuedUser, snapshot.lastUserText].contains(entry.text) {
            landed(entry.id, at: nil)
        }

        let skipped = Self.deltasAlreadyShown(held, in: snapshot.running ? snapshot.inflightReply ?? "" : "")
        var deltasSeen = 0
        for event in held {
            if event.type == GatewayWire.Events.messageDelta.name {
                deltasSeen += 1
                if deltasSeen <= skipped {
                    if let seq = event.seq { watermarks[event.sessionId] = max(watermarks[event.sessionId] ?? 0, seq) }
                    continue
                }
            }
            receive(event)
        }
    }

    /// How many of the held deltas, from the first, the snapshot's reply already ends with.
    static func deltasAlreadyShown(_ held: [GatewayEventEnvelope], in reply: String) -> Int {
        guard !reply.isEmpty else { return 0 }
        let texts = held.filter { $0.type == GatewayWire.Events.messageDelta.name }.map { $0.payload?["text"]?.stringValue ?? "" }
        for count in stride(from: texts.count, to: 0, by: -1) where reply.hasSuffix(texts.prefix(count).joined()) {
            return count
        }
        return 0
    }

    private mutating func settleCards(_ snapshot: ConversationSnapshot, requestedAt: Int) {
        let listed = Set(snapshot.openRequests.map(\.id))
        let queued = snapshot.pendingApproval?.requestId
        let gone = cards.filter { card in
            guard card.shownAt <= requestedAt else { return false }
            return card.viaApprovalQueue ? card.approvalRequestId != queued : !listed.contains(card.id)
        }
        for card in gone {
            cards.removeAll { $0.id == card.id }
            append(.note(.answeredElsewhere))
        }
        for question in snapshot.openRequests { show(question) }
        if let pending = snapshot.pendingApproval, !cards.contains(where: { $0.approvalRequestId == pending.requestId }) {
            cards.append(ConversationCard(id: "queue-\(pending.requestId)", method: GatewayWire.Questions.approval.name,
                                          kind: .approval(requestId: pending.requestId, command: pending.command,
                                                          description: pending.description, choices: pending.choices),
                                          shownAt: clock, viaApprovalQueue: true))
        }
    }

    /// After a reload the stored history has the ended turns; only rows the person still has to act on stay.
    private mutating func dropEndedTurns() {
        let current = turn, live = running
        rows.removeAll { row in
            guard row.turn < current || !live else { return false }
            switch row.kind {
            case .user(_, .uncertain), .user(_, .notSent): return false
            default: return true
            }
        }
        if let id = openSummaryId, row(id) == nil { openSummaryId = nil }
    }

    // MARK: Sending

    func userRowId(for outboxId: String) -> String { "user:\(outboxId)" }

    private mutating func startSending(_ id: String) {
        guard outbox[id]?.state == .waiting, let entry = outbox[id] else { return }
        outbox.set(id, .sending)
        beginTurn()
        rows.append(ConversationRow(id: userRowId(for: id), kind: .user(text: entry.text, delivery: .sending), turn: turn))
        activity = .sending
    }

    private mutating func finishSending(_ id: String, _ outcome: ConversationSendOutcome) {
        guard outbox[id]?.state == .sending else { return }
        let rowId = userRowId(for: id)
        switch outcome {
        case .accepted(let stored):
            outbox.set(id, .sent)
            setDelivery(rowId, .sent)
            if let stored, let index = rows.firstIndex(where: { $0.id == rowId }) {
                rows[index].address = ConversationRowAddress(segment: lineage.tip, rowId: stored)
            }
            if activity == .sending { activity = .thinking }
        case .refused(let reason, let retryable):
            if retryable {
                outbox.set(id, .waiting)
                rows.removeAll { $0.id == rowId }
            } else {
                outbox.set(id, .failed(reason))
                setDelivery(rowId, .notSent(reason))
            }
            endTurn()
        case .notSent:
            outbox.set(id, .waiting)
            rows.removeAll { $0.id == rowId }
            endTurn()
        case .uncertain:
            // The turn is left as it is: if Hermes has the message its events carry on, and the next snapshot
            // says whether anything runs.
            outbox.set(id, .uncertain)
            setDelivery(rowId, .uncertain)
            if activity == .sending { activity = .idle }
        }
    }

    private mutating func landed(_ id: String, at address: ConversationRowAddress?) {
        guard outbox[id]?.state == .uncertain else { return }
        outbox.set(id, .sent)
        let rowId = userRowId(for: id)
        setDelivery(rowId, .sent)
        if let address, let index = rows.firstIndex(where: { $0.id == rowId }) { rows[index].address = address }
        if !running { outbox.forgetSent() }
    }

    private mutating func setDelivery(_ rowId: String, _ delivery: ConversationDelivery) {
        guard let index = rows.firstIndex(where: { $0.id == rowId }), case .user(let text, _) = rows[index].kind else { return }
        rows[index].kind = .user(text: text, delivery: delivery)
    }

    // MARK: Absorbing stored rows

    /// Settled turns whose stored rows the history window now holds leave the live tail. Rows match on Hermes's
    /// row id alone: ids are unique in a profile's store, and which segment a compressing turn lands in is not
    /// known for sure.
    private mutating func absorb(_ stored: Set<ConversationRowAddress>) {
        let ids = Set(stored.map(\.rowId))
        let covered = settledTurns.filter { turn in
            guard hasEnded(turn: turn) else { return false }
            let addresses = rows.filter { $0.turn == turn }.compactMap(\.address)
            return !addresses.isEmpty && addresses.allSatisfy { ids.contains($0.rowId) }
        }
        guard !covered.isEmpty else { return }
        rows.removeAll { covered.contains($0.turn) }
        settledTurns.subtract(covered)
        if let id = openSummaryId, row(id) == nil { openSummaryId = nil }
    }

    // MARK: Helpers

    private mutating func append(_ kind: ConversationRow.Kind) {
        rows.append(ConversationRow(id: makeId(Self.prefix(for: kind)), kind: kind, turn: turn))
    }

    private static func prefix(for kind: ConversationRow.Kind) -> String {
        switch kind {
        case .user: "user"
        case .assistant: "reply"
        case .tool: "tool"
        case .note: "note"
        case .error: "error"
        case .post: "post"
        }
    }

    private mutating func makeId(_ prefix: String) -> String {
        defer { nextLocal += 1 }
        return "\(prefix)-\(nextLocal)"
    }
}
