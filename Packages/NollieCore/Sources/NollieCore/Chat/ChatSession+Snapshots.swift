import Foundation

/// Rows built from a snapshot using the gateway's numbering, next to the same rows wearing the ids already shown.
typealias SnapshotRows = (built: [TranscriptItem], paired: [TranscriptItem])

/// An event that showed up mid-snapshot, stored with its arrival time.
struct HeldEvent {
    let event: GatewayEvent
    let at: Date
}

extension ChatSession {
    var isBuildingSnapshot: Bool { book.building > 0 }

    // MARK: Pairing rows

    /// Checks if the snapshot's pending prompt already sits as the final user row. With a known start
    /// time, that row has to belong to this very turn; otherwise we compare the text.
    public nonisolated static func inflightPromptIsListed(prompt: String, lastUserText: String? = nil, lastUserAt: Double? = nil, turnStart: Double) -> Bool {
        if lastUserText != prompt { return false }
        guard turnStart > 0, let stamp = lastUserAt else { return true }
        return stamp >= turnStart - 1
    }

    /// What a row says, for matching it with a row in another list; nil for rows that never match.
    private nonisolated static func gist(_ row: TranscriptItem) -> String? {
        switch row.kind {
        case .user(let text, _): return "u" + text.trimmingCharacters(in: .whitespacesAndNewlines)
        case .assistant(let text, _, let streaming): return streaming ? nil : "a" + text.trimmingCharacters(in: .whitespacesAndNewlines)
        case .tool(let call): return "t" + call.name
        default: return nil
        }
    }

    /// Snapshot rows that reuse the ids of on-screen rows saying the same thing.
    ///
    /// The gateway only numbers a turn's rows once they are stored. A turn we watched streaming used
    /// to come back under fresh ids, so the thread dropped every row and re-added it. We now match rows
    /// in order, peeking a few ahead to step over notes that only this device displays.
    public nonisolated static func keepingIDs(_ built: [TranscriptItem], from shown: [TranscriptItem] = []) -> [TranscriptItem] {
        var paired = built
        var taken = Set<String>()
        var from = 0
        for (position, row) in built.enumerated() {
            let match = gist(row).flatMap { words in
                shown[from...].prefix(6).firstIndex { gist($0) == words }
            }
            if let match, !taken.contains(shown[match].id) {
                paired[position].id = shown[match].id
                from = match + 1
            } else if taken.contains(row.id) {
                // Its id already went to an earlier row after a shift, so make it unique: no id appears twice.
                paired[position].id = row.id + "-\(position)"
            }
            taken.insert(paired[position].id)
        }
        return paired
    }

    /// Turns a snapshot's history into rows, reusing ids from rows already shown.
    /// Decoding and assembling a long history once blocked the main thread for seconds (the app hung
    /// on returning to a long turn, with every open chat refreshing together). This touches no chat
    /// state, so it can run away from the main actor.
    nonisolated static func snapshotRows(_ r: JSONValue, running: Bool = false, shown: [TranscriptItem] = [], streamingID: String? = nil) -> SnapshotRows {
        let history: [TranscriptMessage] = r["messages"].flatMap { try? $0.decode([TranscriptMessage].self) } ?? []

        // Transcripts from the gateway carry no attachments, so those sent from here are restored.
        var attachmentsByText: [String: [AttachmentPreview]] = [:]
        var finishedReplies = Set<String>()
        for row in shown {
            if case .user(let text, let files) = row.kind, !files.isEmpty { attachmentsByText[text] = files }
            if case .assistant(let text, _, false) = row.kind, !text.isEmpty { finishedReplies.insert(StreamAssembler.normalized(text)) }
        }
        let built = TranscriptItem.fromHistory(history, running: running, settled: finishedReplies).map { row -> TranscriptItem in
            guard case .user(let text, let files) = row.kind, files.isEmpty, let kept = attachmentsByText[text] else { return row }
            var row = row
            row.kind = .user(text: text, attachments: kept)
            return row
        }
        // Today's streaming reply holds on to its id; it is not part of history.
        let others = shown.filter { $0.id != streamingID }
        return (built, keepingIDs(built, from: others))
    }

    // MARK: Applying a snapshot

    /// Applies a session snapshot. Building its rows happens off the main actor. Events that land in
    /// the meantime are parked, then replayed in arrival order afterwards, as though the snapshot had
    /// been applied the instant it came in. `listedAt` is when it was requested; nil means we treat
    /// it as read when the reply arrived.
    func apply(snapshot r: JSONValue, listedAt: Date? = nil) async {
        // Record the reply's ids on the chat immediately. Events look chats up by runtime id; had we
        // waited for the rows, every event from a turn in progress would be lost in that window (a freshly
        // opened chat has no id yet), and a reply that finished meanwhile would never close here.
        if let live = r.text("session_id"), !live.isEmpty { runtimeID = live }
        if let stored = r.text("stored_session_id") { follow(storedID: stored) }

        book.answered += 1
        let myTurn = book.answered
        // Anything held up to now predates this reply, which therefore already includes it.
        let heldAlready = book.held.count
        let repliedAt = Date()
        let askedAt = listedAt ?? repliedAt
        let listing = ledger.beginList(at: askedAt)
        defer { ledger.endList(listing) }

        let liveInfo: SessionLiveInfo? = r["info"].flatMap { try? $0.decode(SessionLiveInfo.self) }
        let running = r["running"]?.boolValue ?? liveInfo?.running ?? false
        let rowsBefore = items
        let streamingBefore = reply.rowID
        let hold = beforeSnapshotRows
        let mark = GatewayRuntime.signposter.beginInterval("snapshot")

        book.building += 1
        let made = await Task.detached(priority: .userInitiated) {
            await hold?(r)
            return Self.snapshotRows(r, running: running, shown: rowsBefore, streamingID: streamingBefore)
        }.value
        book.building -= 1

        // Another snapshot may have been applied while this one built its rows. That one covers
        // everything here and more, so we skip ours.
        if myTurn > book.newestApplied {
            book.newestApplied = myTurn
            book.heldShown = heldAlready
            let (rows, added) = reconcile(made, against: rowsBefore, streamingBefore: streamingBefore)
            install(snapshot: r, info: liveInfo, rows: rows, listedAt: askedAt, answeredAt: repliedAt, added: added)
        }
        GatewayRuntime.signposter.endInterval("snapshot", mark)

        if book.building == 0 { replayHeldEvents() }
    }

    /// The snapshot's rows as they should be shown, and the rows added here while they were made.
    ///
    /// Rows added here meanwhile (a message sent, its error) stay after the snapshot's, since it was
    /// taken before them. Rows put in by another snapshot or a page are the gateway's, not this
    /// device's. When the thread changed, the rows are paired against it as it is now.
    private func reconcile(_ made: SnapshotRows, against before: [TranscriptItem],
                           streamingBefore: String?) -> (rows: [TranscriptItem], added: [TranscriptItem]) {
        if items == before, reply.rowID == streamingBefore { return (made.paired, []) }
        let seenBefore = Set(before.map(\.id))
        let added = items.filter { !seenBefore.contains($0.id) && !book.fetched.contains($0.id) }
        let addedIDs = Set(added.map(\.id))
        let current = items.filter { $0.id != reply.rowID && !addedIDs.contains($0.id) }
        let rows = Self.keepingIDs(made.built, from: current)
        return (rows, items == before ? [] : added)
    }

    /// Plays back events parked during a snapshot. Ones the snapshot already covers only do what it
    /// cannot (`handleShownBySnapshot`); the others go through the normal path.
    private func replayHeldEvents() {
        let (waiting, shownAlready) = (book.held, book.heldShown)
        book.held = []
        book.heldShown = 0
        waiting.prefix(shownAlready).forEach { handleShownBySnapshot($0.event, arrivedAt: $0.at) }
        book.leftUp = []
        waiting.dropFirst(shownAlready).forEach { handle(event: $0.event) }
    }

    private static func isUser(_ row: TranscriptItem) -> Bool {
        if case .user = row.kind { true } else { false }
    }

    private static func isAssistant(_ row: TranscriptItem) -> Bool {
        if case .assistant = row.kind { true } else { false }
    }

    private func install(snapshot r: JSONValue, info liveInfo: SessionLiveInfo?, rows: [TranscriptItem],
                         listedAt: Date, answeredAt: Date, added: [TranscriptItem]) {
        info = liveInfo
        if let name = liveInfo?.title, name.isEmpty == false { title = name }

        var sentWith: [String: [AttachmentPreview]] = [:]
        for case .user(let text, let files) in items.map(\.kind) where !files.isEmpty { sentWith[text] = files }
        items = rows
        toolRows = [:]

        // Something sent from here after the snapshot began is a turn the snapshot knows nothing about.
        let sentSince = startedHere && added.contains(where: Self.isUser)
        isRunning = (r["running"]?.boolValue ?? liveInfo?.running ?? false) || sentSince

        if let inflight = r["inflight"], !inflight.isNull {
            restoreInflightTurn(from: r, inflight: inflight, sentWith: sentWith)
        }
        // With no streaming reply in the snapshot, the reply we were drawing is now an ordinary history
        // row. Holding on to its id would route the following turn's text to a row that is gone.
        if let live = reply.rowID, !items.contains(where: { $0.id == live }) {
            reply.rowID = nil
            reply.assembler.reset()
        }
        book.fetched = Set(items.map(\.id))
        items += added
        if let waiting = r["queued"]?.text("user"), !waiting.isEmpty { queue = [QueuedMessage(text: waiting)] }

        applyCards(answeredAt: answeredAt, of: r, listedAt: listedAt)
        startTurnSurface()
        saveTranscriptCache()
        Task { [self] in await pollPendingApprovals() }
    }

    /// Opens the surface for a turn that is running. A card already showing before the surface existed
    /// would be announced as "Thinking…" while the bot was really blocked on it, so cards are shown
    /// immediately and quietly (they made their noise when they arrived).
    private func startTurnSurface() {
        guard isRunning else { return }
        activity.start(for: self)
        if cards.count > 0 { activity.showCards(for: self) }
    }

    /// Where the running turn begins among the rows: before the first row stamped after it started
    /// (partway through a turn the gateway has already written the tool and assistant rows although
    /// the prompt still reads "inflight"), else after the final reply.
    private func turnStartIndex(startedAt: Double) -> Int {
        if startedAt > 0, let first = items.firstIndex(where: { $0.timestamp.timeIntervalSince1970 >= startedAt - 1 }) { return first }
        return items.lastIndex(where: Self.isAssistant).map { $0 + 1 } ?? items.count
    }

    /// The part of a snapshot about the turn that is running: the prompt not yet stored, a partial
    /// reply, or the error that stopped it.
    private func restoreInflightTurn(from r: JSONValue, inflight: JSONValue, sentWith: [String: [AttachmentPreview]]) {
        let prompt = inflight.text("user") ?? ""
        let startedAt = r["turn_started_at"]?.doubleValue ?? 0
        let turnAt = turnStartIndex(startedAt: startedAt)

        // The prompt counts as listed only if the newest user row belongs to this turn. Sending the same
        // words twice in a row makes two prompts.
        let lastUser = items.last(where: Self.isUser)
        var lastText: String?
        if case .user(let text, _)? = lastUser?.kind { lastText = text }
        let listed = Self.inflightPromptIsListed(prompt: prompt, lastUserText: lastText,
                                                 lastUserAt: lastUser?.timestamp.timeIntervalSince1970, turnStart: startedAt)
        if !prompt.isEmpty && !listed {
            let base = "inflight-user-\(Int(startedAt))"
            let rowID = items.contains(where: { $0.id == base }) ? "\(base)-\(items.count)" : base
            var row = TranscriptItem(id: rowID, kind: .user(text: prompt, attachments: sentWith[prompt] ?? []))
            if startedAt > 0 { row.timestamp = Date(timeIntervalSince1970: startedAt) }
            items.insert(row, at: turnAt)
        }

        if let failure = inflight.text("error"), !failure.isEmpty {
            items.append(TranscriptItem(id: "inflight-error", kind: .error(text: failure)))
            return
        }
        let partial = inflight.text("assistant") ?? ""
        let streaming = inflight.flag("streaming")
        guard streaming || !partial.isEmpty else { return }

        // The partial text can already sit in the messages as a flushed prefix. If so, the streaming
        // bubble replaces that row instead of duplicating it.
        if let last = items.indices.last(where: { Self.isAssistant(items[$0]) }), last > turnAt,
           case .assistant(let stored, _, _) = items[last].kind, !stored.isEmpty,
           partial.hasPrefix(stored) || stored.hasPrefix(partial) {
            items.remove(at: last)
        }
        reply.assembler.start()
        reply.assembler.appendDelta(partial)
        // A reply that is already streaming here (a turn picked up from another device) keeps its row.
        // With a new id, the final row would be removed and re-added while the thread is pinned to it.
        let rowID = reply.rowID ?? "stream-" + UUID().uuidString
        reply.rowID = rowID
        items.append(TranscriptItem(id: rowID, kind: .assistant(text: partial, reasoning: nil, streaming: streaming)))
        guard !streaming else { return }
        finishStreaming(finalText: nil)
    }
}
