import Foundation

/// What a chat remembers about its cards to keep lists of open questions honest.
///
/// A list (a snapshot, the pending approvals) is read by the gateway at some moment before its
/// reply reaches us, and meanwhile this device may have answered a card or been asked a new one.
/// The ledger holds the times needed to tell a stale list from a true one.
struct CardLedger {
    /// Time each card was first seen on this device.
    var shownAt: [String: Date] = [:]
    /// Newest time the gateway vouched for the card's question, either by sending the card or by
    /// returning a list that held it. Should a later list leave it out, the gateway checked after the
    /// question had closed, which means the question is finished.
    var asOf: [String: Date] = [:]
    /// Time this device removed each card (answered here, or found answered elsewhere), under both the
    /// card id and the request id. A list requested earlier can still contain the card. Restoring it
    /// would raise attention again, and tapping once more answered a request that was already closed.
    private var removedAt: [String: Date] = [:]
    /// Request time of every list reply still outstanding. Lists can overlap, so a removal stays on
    /// record until the oldest of them is done. Dropping it sooner let an older list that landed last
    /// bring the card back.
    private var pendingLists: [UUID: Date] = [:]

    mutating func beginList(at date: Date) -> UUID {
        let token = UUID()
        pendingLists[token] = date
        return token
    }

    /// Called when a list has been applied or has failed. Once every list still in flight was requested
    /// after a removal, no list can contradict it, so the record can go.
    mutating func endList(_ token: UUID) {
        pendingLists.removeValue(forKey: token)
        let cutoff = pendingLists.values.min() ?? Date()
        removedAt = removedAt.filter { _, when in when >= cutoff }
    }

    mutating func noteRemoved(_ card: PendingCard) {
        let stamp = Date()
        var names = [card.id]
        if let request = card.params.text("request_id") { names.append(request) }
        for name in names { removedAt[name] = stamp }
    }

    /// Was this card (or request) `key` taken down here no earlier than `date`?
    func wasRemoved(_ key: String?, since date: Date) -> Bool {
        key.flatMap { removedAt[$0] }.map { $0 >= date } ?? false
    }

    mutating func forget(_ id: String) {
        shownAt.removeValue(forKey: id)
    }

    /// Keeps only entries for cards that are still up.
    mutating func prune(keeping cards: [PendingCard]) {
        let live = Set(cards.map(\.id))
        shownAt = shownAt.filter { live.contains($0.key) }
        asOf = asOf.filter { live.contains($0.key) }
    }
}

extension ChatSession {
    /// Cards younger than this are not treated as answered somewhere else.
    static let cardGrace: TimeInterval = 2

    private var approvalCards: [PendingCard] { cards.filter { $0.method == "approval" } }

    // MARK: Asking about approvals

    /// Finds the approval that an outside Approve or Deny (from a notification) refers to, using the
    /// card ids in `keys`. Returns nil when that request has gone or no id was given, and never
    /// substitutes a different card. Picking the first approval on screen once let a leftover banner
    /// approve a newer request that nobody had looked at.
    public func approvalCard(named keys: [String]) -> PendingCard? {
        approvalCards.first { card in keys.contains { card.isNamed(by: $0) } }
    }

    /// Finds the approval an outside Approve or Deny should answer. With no usable card id (a push
    /// that lacks one) it falls back to the chat's only approval. When two or more are open there is
    /// no telling which was meant, so nothing is answered.
    public func approvalToAnswer(named keys: [String]) -> PendingCard? {
        if keys.isEmpty {
            let only = approvalCards
            return only.count == 1 ? only.first : nil
        }
        return approvalCard(named: keys)
    }

    /// `approvalToAnswer(named:)`, waiting up to `wait` seconds for the card to show while the chat opens.
    public func approvalToAnswer(named keys: [String], waitingUpTo wait: TimeInterval) async -> PendingCard? {
        let deadline = Date.now + wait
        while true {
            if let found = approvalToAnswer(named: keys) { return found }
            if Date() >= deadline { return nil }
            try? await Task.sleep(for: .milliseconds(250))
        }
    }

    // MARK: Cards from snapshots

    /// Replaces the cards with what a snapshot says is open, plus any that arrived after the snapshot
    /// was requested. A card already on screen keeps its state and is announced only once. One the
    /// snapshot has dropped is removed, together with whatever was posted for it.
    func applyCards(answeredAt: Date, of snapshot: JSONValue, listedAt: Date) {
        let listed = cardsListed(in: snapshot, since: listedAt)
        let sameAsListed = { (card: PendingCard) in listed.contains { Self.sameQuestion($0, card) } }

        let before = cards
        // Keep a question that arrived after the snapshot was requested, since it may postdate the list.
        // The gateway collects its open questions while building the reply, so something asked just after
        // that point lands before the reply yet is missing from it. Clearing it would leave the bot
        // waiting with nothing visible to answer. A question from before the request that the list omits
        // has ended.
        let kept = before.filter { (ledger.asOf[$0.id] ?? .distantPast) >= listedAt || sameAsListed($0) }
        let keptIDs = Set(kept.map(\.id))
        let dropped = before.filter { !keptIDs.contains($0.id) }
        let fresh = listed.filter { new in !before.contains { Self.sameQuestion(new, $0) } }

        let shown = foldingTwins(kept)
        cards = shown + fresh

        for card in shown where sameAsListed(card) {
            ledger.asOf[card.id] = max(ledger.asOf[card.id] ?? .distantPast, answeredAt)
        }
        let now = Date()
        for card in fresh { (ledger.shownAt[card.id], ledger.asOf[card.id]) = (now, answeredAt) }
        ledger.prune(keeping: cards)

        // These cards stay up although the snapshot omits them, because they were raised before its reply
        // arrived. If the turn finished first and its ending was held back while rows were built,
        // `handleShownBySnapshot` clears them. Otherwise the chat would claim to need you once the turn
        // was already done.
        book.leftUp = Set(cards.lazy.filter { (self.ledger.asOf[$0.id] ?? .distantPast) < answeredAt && !sameAsListed($0) }.map(\.id))

        for card in dropped { release(dropped: card) }
        let attentionLingers = cards.isEmpty && runtime.needsAttention.contains(storedID)
        if !dropped.isEmpty || attentionLingers { cardWent() }
        fresh.forEach(announce)
    }

    /// Questions listed by a snapshot, minus any removed on this device since it was requested. The
    /// gateway read its list before replying, so something answered here in the meantime can still
    /// appear on it.
    private func cardsListed(in snapshot: JSONValue, since asked: Date) -> [PendingCard] {
        var found: [PendingCard] = []
        for entry in snapshot["open_requests"]?.arrayValue ?? [] {
            guard let id = entry.text("id"), let method = entry.text("method") else { continue }
            let params = entry["params"] ?? .object([:])
            let seen = found.contains { $0.id == id }
            if seen || ledger.wasRemoved(id, since: asked) || ledger.wasRemoved(params.text("request_id"), since: asked) { continue }
            found.append(PendingCard(id: id, method: method, params: params))
        }
        if let queued = snapshot["pending_approval"], !queued.isNull, let request = queued.text("request_id"),
           !found.contains(where: { $0.approval?.requestId == request }), !ledger.wasRemoved(request, since: asked) {
            found.append(queueCard(for: request, from: queued))
        }
        return found
    }

    /// An approval listed under two ids collapses into one card: the request's own, sitting in the
    /// earlier one's slot. The question remains open, so the leftover id needs no further handling.
    private func foldingTwins(_ list: [PendingCard]) -> [PendingCard] {
        var out: [PendingCard] = []
        for card in list {
            guard let at = out.firstIndex(where: { Self.areTwins($0, card) }) else {
                out.append(card)
                continue
            }
            let earlier = out[at]
            let own = card.viaApprovalRPC ? earlier : card
            let queued = card.viaApprovalRPC ? card : earlier
            out[at] = own
            merge(queued: queued, into: own)
        }
        return out
    }

    /// Takes down a card absent from the latest snapshot, because the gateway has stopped waiting for
    /// it (answered elsewhere, withdrawn, or its turn is done). Left in place, the chat list and tab
    /// would keep saying you are needed with no question to answer, and Approve would stay in the notification.
    private func release(dropped card: PendingCard) {
        // Anything here still awaiting this card is released without sending a value (nil). Replying
        // with `.null` would reach the gateway as a decision: clarify cancelled, password skipped,
        // approval denied.
        let waiter = inlineAnswers.removeValue(forKey: card.id)
        ledger.noteRemoved(card)
        runtime.cardNotifier?.cardSettled(card, chat: self)
        waiter?.resume(returning: nil)
    }

    /// A card built from an approval the gateway's queue holds, answered through `approval.respond`.
    private func queueCard(for request: String, from entry: JSONValue) -> PendingCard {
        let params = (entry.objectValue ?? [:]).merging(["session_id": .string(runtimeID)]) { $1 }
        return PendingCard(id: "queue-" + request, method: "approval", params: .object(params), viaApprovalRPC: true)
    }

    /// Same question, whichever id it came in under (its own or the approval queue's).
    private static func sameQuestion(_ a: PendingCard, _ b: PendingCard) -> Bool {
        a.id == b.id || (a.approval?.requestId).map { $0 == b.approval?.requestId } ?? false
    }

    /// Two cards for a single approval: one under the approval queue's id, one under the request's.
    /// Hermes puts an approval in its queue a beat before sending the request itself, so a list fetched
    /// in that window showed the queue's card. Result: duplicate cards, and answering either left the
    /// other still asking.
    private static func areTwins(_ a: PendingCard, _ b: PendingCard) -> Bool {
        if a.viaApprovalRPC == b.viaApprovalRPC { return false }
        guard let mine = a.approval?.requestId, let theirs = b.approval?.requestId else { return false }
        return mine == theirs
    }

    /// The request's own card inherits the history of its queue twin: the earlier first-seen time, and
    /// the fact that it was already announced.
    private func merge(queued: PendingCard, into own: PendingCard, asOf: Date? = nil) {
        let shown = [ledger.shownAt[own.id], ledger.shownAt.removeValue(forKey: queued.id)].compactMap { $0 }
        ledger.shownAt[own.id] = shown.min() ?? Date()
        ledger.asOf[own.id] = [ledger.asOf[own.id], ledger.asOf.removeValue(forKey: queued.id), asOf].compactMap { $0 }.max()
    }

    // MARK: Pending approvals

    /// Safety net for an approval frame that never arrived. Queries the gateway for everything pending
    /// on this session and makes a card from each entry; replies still use `approval.respond`.
    public func pollPendingApprovals() async {
        let asked = Date()
        lastApprovalCheck = asked
        let listing = ledger.beginList(at: asked)
        defer { ledger.endList(listing) }
        guard let reply = try? await ask("approval.pending", timeout: 10) else { return }

        // Full list of open items from the gateway, if present. Older gateways give back a lone approval,
        // and that says nothing regarding any others.
        let waiting = reply["approvals"]?.arrayValue ?? reply["pending"]?.arrayValue
        if let waiting { retireAnsweredElsewhere(gatewayList: waiting, asked: asked) }

        let entries = waiting ?? (reply["request_id"] == nil ? [] : [reply])
        for entry in entries {
            guard let request = entry.text("request_id"),
                  !cards.contains(where: { $0.approval?.requestId == request }),
                  !ledger.wasRemoved(request, since: asked) else { continue }
            addCard(queueCard(for: request, from: entry))
        }
    }

    /// An approval on screen but missing from the gateway's list has been answered elsewhere (another
    /// device, the dashboard or a terminal), and nobody informed this client. Keep cards that are
    /// newer than the request, as the gateway may have compiled its list before they came in.
    private func retireAnsweredElsewhere(gatewayList: [JSONValue], asked: Date) {
        let open = Set(gatewayList.compactMap { $0.text("request_id") })
        let held = approvalCards.compactMap { $0.approval?.requestId }
        log.notice("approval.pending: gateway has open \(open.sorted().joined(separator: ","), privacy: .public); this chat holds \(held.joined(separator: ","), privacy: .public)")
        for card in approvalCards {
            guard let request = card.approval?.requestId, !open.contains(request),
                  let since = ledger.shownAt[card.id], since + Self.cardGrace < asked else { continue }
            settleElsewhere(card)
        }
    }

    /// When the turn keeps going while an approval card is open, the bot was probably unblocked
    /// elsewhere. Check immediately rather than waiting for the next poll.
    func checkApprovalsIfTurnMovedOn() {
        let sinceLast = Date().timeIntervalSince(lastApprovalCheck)
        guard sinceLast > 1.5, !approvalCards.isEmpty else { return }
        lastApprovalCheck = Date()
        Task { [self] in await pollPendingApprovals() }
    }

    // MARK: Cards arriving and leaving

    /// A server request that becomes a card, and waits here for the person's answer.
    public func answer(serverRequest req: ServerRequest) async -> JSONValue? {
        guard PendingCard.askingMethods.contains(req.method) else { return nil }
        addCard(PendingCard(id: req.id, method: req.method, params: req.params))
        // A repeated request id (the gateway retrying) frees the earlier waiter instead of leaving it
        // stuck behind the new one.
        inlineAnswers.removeValue(forKey: req.id)?.resume(returning: nil)
        return await withCheckedContinuation { inlineAnswers[req.id] = $0 }
    }

    /// `asOf` is the last time the gateway vouched that the question was open. Use the current time for
    /// a brand new question or for a list reply that has just landed.
    func addCard(_ card: PendingCard, asOf: Date = Date()) {
        if cards.contains(where: { $0.id == card.id }) { return }
        // With System control on, the app answers approvals itself. One learned of from a list
        // goes through the approval queue with no card; a request's own card was answered earlier.
        if card.viaApprovalRPC, let ask = card.approval, let choice = runtime.approvalAutoAnswer?(ask, profileName) {
            Task { await respond(card: card, result: ["choice": .string(choice)]) }
            return
        }
        if let twin = cards.firstIndex(where: { Self.areTwins($0, card) }) {
            // Already showing under its other id. The queue's version adds nothing, whereas the request's own
            // card takes the queue's place, because the waiter lives with it (`answer(serverRequest:)`).
            if card.viaApprovalRPC { return }
            let queued = cards[twin]
            cards[twin] = card
            merge(queued: queued, into: card, asOf: asOf)
            acknowledge(card)
        } else {
            ledger.shownAt[card.id] = Date()
            ledger.asOf[card.id] = asOf
            cards.append(card)
            announce(card)
        }
    }

    /// Runs the first time this device sees a card. The chat marks itself as needing you, the platform
    /// reacts (a haptic or a notification), and the gateway learns that a client received the approval.
    private func announce(_ card: PendingCard) {
        runtime.setAttention(storedID: storedID, needed: true)
        acknowledge(card)
        activity.update(for: self, attention: true)
        defer { runtime.cardNotifier?.cardArrived(card, chat: self) }
    }

    /// Lets the gateway know this client received the approval request. If only the queue listed the
    /// approval, no request was ever sent, so there is nothing to acknowledge.
    private func acknowledge(_ card: PendingCard) {
        guard card.method == "approval", !card.viaApprovalRPC, let request = card.approval?.requestId else { return }
        Task { _ = try? await ask("approval.received", ["request_id": .string(request)]) }
    }

    /// Takes a card off the screen and out of the ledger.
    private func takeDown(_ card: PendingCard) {
        ledger.noteRemoved(card)
        cards.removeAll { $0.id == card.id }
        ledger.forget(card.id)
    }

    /// This card was answered on a different device, or its turn finished without it. Remove it and
    /// stop asking for attention.
    func settleElsewhere(_ card: PendingCard) {
        if !cards.map(\.id).contains(card.id) { return }
        takeDown(card)
        // Don't touch the gateway's reply slot. Sending nothing through it counted as a denial in cases
        // where the card was simply missing from the gateway's list. If an answer already exists there,
        // a late one gets ignored, and finishing the turn releases whatever remains.
        cardWent()
        runtime.cardNotifier?.cardSettled(card, chat: self)
        addNote(card.method == "approval" ? String(localized: "Answered on another device", table: "Core", comment: "Safety: an approval was answered elsewhere")
                : String(localized: "The question was closed", table: "Core"), symbol: "checkmark.shield")
    }

    /// Answers a card, using whichever card is currently up for that question. The approval queue's
    /// card yields to the request's own when it appears; a caller still holding the queue's would
    /// clear nothing and reply through the queue while the request stayed open.
    ///
    /// A yes to an approval first passes the app's owner check (`approvalOwnerCheck`). False means
    /// nothing was sent: the check said no, or the card went while it was asking. `checkedOnPhone`
    /// is for an answer that came through iCloud: the phone asked for Face ID before sending it.
    @discardableResult
    public func respond(card given: PendingCard, result: JSONValue, checkedOnPhone: Bool = false) async -> Bool {
        if !checkedOnPhone, let approval = given.approval, given.method == "approval", let choice = result.text("choice"), choice != "deny",
           let check = runtime.approvalOwnerCheck {
            let names = [given.id, approval.requestId].filter { !$0.isEmpty }
            let wasUp = approvalCard(named: names) != nil
            guard await check(approval, profileName) else { return false }
            // Answered on another device or withdrawn while the person was checked: leave it be.
            if wasUp, approvalCard(named: names) == nil { return false }
        }
        let card = approvalCard(named: [given.id]) ?? given
        takeDown(card)
        cardWent()
        let isApproval = card.method == "approval"
        if isApproval {
            let requestKey = card.approval?.requestId ?? card.id
            runtime.pushRegistrar?.noteAnswer(requestID: requestKey, session: storedID, runtime: runtime)
        }
        if card.viaApprovalRPC, let request = card.approval?.requestId {
            _ = try? await ask("approval.respond", ["request_id": .string(request), "choice": result["choice"] ?? "deny"])
            return true
        }
        switch inlineAnswers.removeValue(forKey: card.id) {
        case .some(let waiter):
            waiter.resume(returning: result)
        case .none:
            let socket: GatewaySocket = runtime.socket
            await socket.respond(to: card.id, result: result)
        }
        if isApproval { addNote(Self.approvalNote(result.text("choice")), symbol: "checkmark.shield") }
        return true
    }

    /// The gateway withdrew a request.
    func cancelCard(id: String, reason: String) {
        let waiter = inlineAnswers.removeValue(forKey: id)
        guard let card = cards.first(where: { $0.id == id }) else {
            // Its card already went (taken for answered elsewhere) and left its waiter open;
            // the request is over now, so the waiter is let go.
            waiter?.resume(returning: .null)
            return
        }
        takeDown(card)
        // Whatever was posted for the card is cleared as well. Otherwise a withdrawn approval's
        // notification kept offering Approve and the activity kept saying "Approval needed".
        cardWent()
        runtime.cardNotifier?.cardSettled(card, chat: self)
        waiter?.resume(returning: .null)
        addNote(String(localized: "Request withdrawn (\(reason)).", table: "Core", comment: "The value is the gateway's own reason word, such as timeout"),
                symbol: "xmark.circle")
    }

    /// The note after the person answered an approval here: "Approval: once". The choice is the gateway's own word.
    static func approvalNote(_ choice: String?) -> String {
        let word = choice ?? "?"
        return switch choice {
        case "once": String(localized: "Approval: once", table: "Core", comment: "Safety: the person allowed this one action")
        case "session": String(localized: "Approval: session", table: "Core", comment: "Safety: the person allowed this for the rest of the chat")
        case "always": String(localized: "Approval: always", table: "Core", comment: "Safety: the person always allows this")
        case "deny": String(localized: "Approval: deny", table: "Core", comment: "Safety: the person said no")
        default: String(localized: "Approval: \(word)", table: "Core", comment: "Safety: the person's answer, in the gateway's own word")
        }
    }

    /// Follow-up once a card is gone. With none left, we stop requesting attention and the activity
    /// reports that the turn carries on. With some left, the activity moves to the first remaining one
    /// (its wording, plus the request its Approve button answers), since keeping the old one named a
    /// request that no longer waits.
    func cardWent() {
        guard cards.isEmpty else { return activity.showCards(for: self) }
        runtime.setAttention(storedID: storedID, needed: false)
        activity.update(for: self, attention: false)
    }
}
