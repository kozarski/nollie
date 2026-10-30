import Foundation
import Observation

/// One conversation, run on the gateway client: it feeds the reducer from the client's notices, attaches the chat
/// (again after each reconnect), sends the outbox one message at a time, and keeps the history window in step.
/// Screens read `transcript`, `state` and `phase`. See `Docs/specs/conversation-engine.md`.
@MainActor
@Observable
public final class ConversationEngine {
    public struct Configuration: Sendable {
        public var profile: String?
        public var window = ConversationWindow.Configuration()
        public var attachTimeout: Duration = .seconds(30)
        public var submitTimeout: Duration = .seconds(60)

        public init(profile: String? = nil, window: ConversationWindow.Configuration = ConversationWindow.Configuration()) {
            self.profile = profile
            self.window = window
        }
    }

    public private(set) var state: ConversationState
    /// The stored history in the window followed by the live tail, ready to draw.
    public private(set) var transcript: [ConversationRow] = []
    public private(set) var phase: GatewayPhase = .idle
    /// The window touches the newest end, so the live tail shows.
    public private(set) var historyAtNewestEnd = true
    public private(set) var historyAtOldestEnd = false
    /// The last thing that went wrong that the person may need to know, in Hermes's words.
    public private(set) var problem: String?
    /// The add-on's cards for this chat, oldest first, at most `postLimit`.
    public private(set) var posts: [ConversationPost] = []

    public let configuration: Configuration
    @ObservationIgnored private let link: any ConversationLink
    @ObservationIgnored private let window: ConversationWindow
    @ObservationIgnored private let postSource: (any ConversationPostSource)?
    /// Counts answers to taps. A fetch that started before a post's answer landed keeps the answer.
    @ObservationIgnored private var postEdits = 0
    @ObservationIgnored private var postEditedAt: [String: Int] = [:]
    /// Each fetch's number: one that lands after a newer one is dropped.
    @ObservationIgnored private var postFetches = 0
    @ObservationIgnored private var postFetchLanded = 0
    @ObservationIgnored private var book = ConversationRequestBook()
    /// Non-nil while an attach is in flight: events and questions that arrive meanwhile follow its snapshot.
    @ObservationIgnored private var heldEvents: [GatewayEventEnvelope]?
    @ObservationIgnored private var heldQuestions: [GatewayIncomingQuestion] = []
    @ObservationIgnored private var attachedOnThisLine = false
    @ObservationIgnored private var reloadWanted = false
    @ObservationIgnored private var promptAskedForTurn = 0
    @ObservationIgnored private var watching: String?
    @ObservationIgnored private var historyRows: [ConversationHistoryRow] = []
    /// Ids of live rows whose stored copies replaced them (by Hermes row id), and of live `summarized` notes a
    /// segment boundary replaced (by segment), so the screen keeps drawing the same row.
    @ObservationIgnored private var keptIds: [Int: String] = [:]
    @ObservationIgnored private var keptBoundaryIds: [String: String] = [:]
    /// The newest stored row id when each message went out: a stored user row above it with the same words shows
    /// an uncertain send landed.
    @ObservationIgnored private var sentAfter: [String: Int] = [:]
    @ObservationIgnored private var work: [Int: Task<Void, Never>] = [:]
    @ObservationIgnored private var nextWork = 0
    @ObservationIgnored private var savedOutbox: ConversationOutbox?
    @ObservationIgnored private var closed = false

    /// - Parameters:
    ///   - key: names the conversation's cache, for example connection, profile and "main".
    ///   - sessionId: any stored id of the conversation (the tip is found from it).
    ///   - posts: the add-on's cards, for the default bot's main chat only.
    public init(key: String, sessionId: String, link: any ConversationLink, history: any ConversationHistorySource,
                lineageSource: (any ConversationLineageSource)? = nil, store: any ConversationCacheStore,
                posts: (any ConversationPostSource)? = nil, configuration: Configuration = Configuration()) {
        self.configuration = configuration
        self.link = link
        postSource = posts
        window = ConversationWindow(key: key, lineage: ConversationLineage(tip: sessionId), store: store, source: history,
                                    lineageSource: lineageSource, configuration: configuration.window)
        state = ConversationState(lineage: ConversationLineage(tip: sessionId))
    }

    // MARK: Starting

    /// Shows what the cache has at once, then attaches when the line is ready.
    public func start() async {
        state.lineage = await window.lineage
        if let saved = await window.savedOutbox {
            state.outbox = saved
            savedOutbox = saved
        }
        await window.openFromCache()
        await syncWindow()
        phase = await link.currentPhase()
        if phase == .ready { attach(full: false) }
    }

    /// Feeds the engine every notice of a client that serves only this conversation.
    public func run(_ notices: AsyncStream<GatewayNotice>) async {
        for await notice in notices { receive(notice) }
    }

    /// One notice from the client. A router that serves several conversations passes each its own.
    public func receive(_ notice: GatewayNotice) {
        switch notice {
        case .phase(let next):
            phase = next
            if next == .ready {
                attachedOnThisLine = false
                attach(full: reloadWanted)
            } else {
                attachedOnThisLine = false
            }
        case .event(let event):
            if heldEvents != nil, !event.sessionId.isEmpty {
                heldEvents?.append(event)
            } else {
                apply(.event(event))
            }
        case .question(let question):
            if heldEvents != nil {
                heldQuestions.append(question)
            } else if question.sessionId == state.runtimeSession {
                apply(.question(question))
            }
        case .questionWithdrawn(let id):
            apply(.questionWithdrawn(id: id))
        case .reload(let session, _):
            guard session == state.runtimeSession else { return }
            reloadWanted = true
            apply(.reset(session: session))
            if phase == .ready { attach(full: true) }
        }
    }

    // MARK: What the person does

    /// Queues a message; it goes out when the line, the chat and the bot are ready for it.
    public func send(_ text: String) { apply(.compose(text: text)) }

    /// Sends again a message whose first send failed or may not have landed. Only ever on the person's word.
    public func sendAgain(_ outboxId: String) { apply(.resend(id: outboxId)) }

    public func discard(_ outboxId: String) { apply(.discard(id: outboxId)) }

    /// Answers a card. `result` is the question's answer (for an approval, `{choice}`).
    public func answer(card id: String, with result: GatewayJSON) {
        guard let card = state.cards.first(where: { $0.id == id }) else { return }
        let choice = result["choice"]?.stringValue
        if card.viaApprovalQueue {
            guard let runtime = state.runtimeSession, let requestId = card.approvalRequestId,
                  let ticket = book.begin(.approvalAnswer(cardId: id)) else { return }
            let params: GatewayJSON = ["session_id": .string(runtime), "request_id": .string(requestId), "choice": .string(choice ?? "deny")]
            perform {
                let result = await self.call(GatewayWire.Calls.approvalRespond.name, params, timeout: nil)
                if case .refused(let error) = self.book.finish(ticket, result) { self.problem = error.message }
            }
        } else {
            let link = link
            perform { await link.answer(question: id, method: card.method, result: result) }
        }
        apply(.answered(cardId: id, choice: choice))
    }

    /// Takes a card down here without answering, so a window elsewhere can.
    public func setAside(card id: String) {
        guard state.cards.contains(where: { $0.id == id }) else { return }
        let link = link
        perform { await link.decline(question: id) }
        apply(.setAside(cardId: id))
    }

    public func interrupt() {
        guard let runtime = state.runtimeSession, let ticket = book.begin(.interrupt) else { return }
        perform {
            let result = await self.call(GatewayWire.Calls.sessionInterrupt.name, ["session_id": .string(runtime)], timeout: nil)
            _ = self.book.finish(ticket, result)
        }
    }

    // MARK: Scrolling

    public func loadOlder() { perform { _ = try? await self.window.loadOlder(); await self.syncWindow() } }

    public func loadNewer() { perform { _ = try? await self.window.loadNewer(); await self.syncWindow() } }

    /// Back to the newest rows at once, as the jump-to-newest button does after the window paged far up. While the
    /// window already touches the newest end this changes nothing.
    public func showNewest() {
        guard !historyAtNewestEnd else { return }
        perform {
            try? await self.window.reloadNewest()
            await self.syncWindow()
            self.settleFromHistory()
        }
    }

    /// The person is looking at `transcript[index]`: load the next page ahead of the scroll.
    public func showing(row index: Int) {
        let margin = configuration.window.prefetchMargin
        if index < margin, !historyAtOldestEnd {
            loadOlder()
        } else if !historyAtNewestEnd, index >= transcript.count - margin {
            loadNewer()
        }
    }

    /// Stops following the chat: work in flight is cancelled (a send already gone stays uncertain) and the client
    /// stops watching the session. The outbox stays saved for the next engine.
    public func close() {
        guard !closed else { return }
        closed = true
        for task in work.values { task.cancel() }
        work.removeAll()
        if let session = watching {
            let link = link
            watching = nil
            Task { await link.unwatch(session: session) }
        }
    }

    /// Waits until every call and page load the engine started has finished. For tests.
    func settle() async {
        while let next = work.values.first { await next.value }
    }

    // MARK: Attaching

    private func attach(full: Bool) {
        guard !closed, phase == .ready, let ticket = book.begin(.attach(full: full)) else { return }
        if heldEvents == nil { heldEvents = [] }
        let requestedAt = state.clock
        var params: [String: GatewayJSON] = ["session_id": .string(state.lineage.tip), "omit_messages": .bool(!full)]
        if let profile = configuration.profile { params["profile"] = .string(profile) }
        perform {
            let result = await self.call(GatewayWire.Calls.sessionResume.name, .object(params), timeout: self.configuration.attachTimeout)
            self.attached(ticket, result, requestedAt: requestedAt, full: full)
        }
    }

    private func attached(_ ticket: ConversationRequestBook.Ticket, _ result: Result<GatewayJSON, any Error>,
                          requestedAt: Int, full: Bool) {
        let held = heldEvents ?? []
        let questions = heldQuestions
        heldEvents = nil
        heldQuestions = []
        let outcome = book.finish(ticket, result)
        guard !closed else { return }
        guard case .answered(let answer) = outcome, let snapshot = ConversationSnapshot(resume: answer) else {
            if case .refused(let error) = outcome { problem = error.message }
            // Not attached: what arrived meanwhile still counts, and the next ready tries again.
            for event in held { apply(.event(event)) }
            return
        }
        problem = nil
        attachedOnThisLine = true
        if full { reloadWanted = false }
        apply(.attached(snapshot, held: held, requestedAt: requestedAt, full: full))
        for question in questions where question.sessionId == snapshot.runtimeSession { apply(.question(question)) }
        if watching != snapshot.runtimeSession {
            let link = link, profile = configuration.profile, previous = watching, next = snapshot.runtimeSession
            watching = next
            perform {
                if let previous { await link.unwatch(session: previous) }
                await link.watch(session: next, profile: profile)
            }
        }
        fetchNewestHistory(restart: full)
        // Hermes asked for a reload while this lighter attach was in flight: the whole snapshot follows now.
        if reloadWanted {
            attach(full: true)
            return
        }
        flush()
    }

    // MARK: Sending

    private func flush() {
        guard !closed, phase == .ready, attachedOnThisLine, heldEvents == nil, !state.running, let runtime = state.runtimeSession,
              let entry = state.outbox.next(canSend: true), let ticket = book.begin(.submit(outboxId: entry.id)) else { return }
        sentAfter[entry.id] = historyRows.last { $0.address.segment == state.lineage.tip }?.address.rowId ?? Int.min
        apply(.sendStarted(id: entry.id))
        let outbox = state.outbox
        var params: [String: GatewayJSON] = ["session_id": .string(runtime), "text": .string(entry.text)]
        if let profile = configuration.profile { params["profile"] = .string(profile) }
        perform {
            // Saved as going out before it goes: after a crash it reads back as uncertain, never as waiting.
            await self.window.save(outbox: outbox)
            self.savedOutbox = outbox
            let result = await self.call(GatewayWire.Calls.promptSubmit.name, .object(params), timeout: self.configuration.submitTimeout)
            let sent: ConversationSendOutcome
            switch self.book.finish(ticket, result) {
            case .answered(let answer)?: sent = .accepted(userRowId: answer["user_row_id"]?.intValue)
            case .refused(let error)?: sent = .refused(error.message, retryable: error.code == GatewayRPCError.agentStarting)
            case .notSent?: sent = .notSent
            case .unknown?, nil: sent = .uncertain
            }
            self.apply(.sendFinished(id: entry.id, sent))
        }
    }

    // MARK: History

    /// Asks Hermes for the newest stored rows, as when the app comes back to the chat.
    public func refreshHistory() { fetchNewestHistory(restart: false) }

    private func fetchNewestHistory(restart: Bool) {
        fetchPosts()
        perform {
            await self.window.update(lineage: self.state.lineage)
            do {
                if restart { try await self.window.reloadNewest() } else { try await self.window.refreshNewest() }
            } catch {
                return
            }
            await self.syncWindow()
            self.settleFromHistory()
        }
    }

    /// The window has new stored rows: uncertain sends they show landed, and settled turns they now hold.
    private func settleFromHistory() {
        for entry in state.outbox.uncertain {
            let after = sentAfter[entry.id] ?? Int.min
            if let stored = historyRows.first(where: { $0.role == "user" && $0.text == entry.text && $0.address.rowId > after }) {
                apply(.sendLanded(id: entry.id, at: stored.address))
            }
        }
        let stored = Set(historyRows.map(\.address))
        let storedIds = Set(stored.map(\.rowId))
        for row in state.rows {
            if let address = row.address, storedIds.contains(address.rowId) { keptIds[address.rowId] = row.id }
            if case .note(.summarized(let into?)) = row.kind, keptBoundaryIds[into] == nil { keptBoundaryIds[into] = row.id }
        }
        apply(.absorbed(stored))
    }

    private func syncWindow() async {
        let snapshot = await window.snapshot
        historyRows = snapshot.rows
        historyAtNewestEnd = snapshot.atNewestEnd
        historyAtOldestEnd = snapshot.atOldestEnd
        let known = snapshot.lineage
        // The reducer leads on the tip; the window may have learned older segments.
        if known != state.lineage { state.lineage = state.lineage.merging(known) }
        let shown = Set(historyRows.map(\.address.rowId))
        keptIds = keptIds.filter { shown.contains($0.key) }
        compose()
    }

    // MARK: Posts

    /// The most posts a chat shows; older ones drop off the top.
    public static let postLimit = 60
    /// How far back posts are asked for.
    static let postReach: TimeInterval = 14 * 24 * 60 * 60

    /// Turn on or Keep off a rehearsal card. The post shows the tap as pending while it runs; the add-on's answer
    /// replaces it, and a failure keeps it with a problem and asks the add-on for its posts again. A lost answer is
    /// never sent again: the fetch tells.
    public func perform(_ action: ConversationPostAction, on postId: String) {
        guard let source = postSource, let index = posts.firstIndex(where: { $0.id == postId }), posts[index].pending == nil else { return }
        posts[index].pending = action
        posts[index].problem = nil
        compose()
        perform {
            let outcome: Result<ConversationPost, any Error>
            do { outcome = .success(try await source.perform(action, on: postId)) } catch { outcome = .failure(error) }
            guard let index = self.posts.firstIndex(where: { $0.id == postId }) else { return }
            self.postEdits += 1
            self.postEditedAt[postId] = self.postEdits
            switch outcome {
            case .success(let answer):
                self.posts[index] = answer.content
                self.postEditedAt[answer.id] = self.postEdits
                self.sortPosts()
            case .failure:
                self.posts[index].pending = nil
                self.posts[index].problem = String(localized: "That didn't go through. Try again in a moment.", table: "Core")
            }
            self.compose()
            if case .failure = outcome { self.fetchPosts() }
        }
    }

    private func fetchPosts() {
        guard let source = postSource else { return }
        postFetches += 1
        let number = postFetches, editsBefore = postEdits
        let since = Date().addingTimeInterval(-Self.postReach)
        perform {
            // A failed fetch keeps what shows; the cards are never the chat's problem.
            guard let fetched = try? await source.posts(since: since), number > self.postFetchLanded else { return }
            self.postFetchLanded = number
            self.takePosts(fetched, editsBefore: editsBefore)
        }
    }

    /// Fetched posts in place of the shown ones. A tap in flight stays pending, an answer that landed after the
    /// fetch started stays, and a problem stays until the add-on says something new about the post.
    private func takePosts(_ fetched: [ConversationPost], editsBefore: Int) {
        let shown = Dictionary(posts.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var unique: [String: ConversationPost] = [:]
        for var post in fetched {
            if let mine = shown[post.id] {
                if (postEditedAt[post.id] ?? 0) > editsBefore {
                    post = mine
                } else {
                    post.pending = mine.pending
                    if post.content == mine.content { post.problem = mine.problem }
                }
            }
            unique[post.id] = post
        }
        posts = Array(unique.values)
        sortPosts()
        compose()
    }

    private func sortPosts() {
        posts.sort { $0.at == $1.at ? $0.id < $1.id : $0.at < $1.at }
        if posts.count > Self.postLimit { posts.removeFirst(posts.count - Self.postLimit) }
    }

    // MARK: Running the reducer

    private func apply(_ input: ConversationInput) {
        let before = state
        state = ConversationReducer.reduce(state, input)
        if state.lineage != before.lineage {
            let lineage = state.lineage
            perform { await self.window.update(lineage: lineage) }
        }
        if before.running, !state.running { fetchNewestHistory(restart: false) }
        if state.turnNeedsPrompt, attachedOnThisLine, promptAskedForTurn != state.turn {
            promptAskedForTurn = state.turn
            attach(full: false)
        }
        if state.needsAttach, attachedOnThisLine, !reloadWanted {
            attachedOnThisLine = false
            attach(full: false)
        }
        if state.outbox != savedOutbox, state.outbox.inFlight == nil {
            let outbox = state.outbox
            savedOutbox = outbox
            perform { await self.window.save(outbox: outbox) }
        }
        compose()
        flush()
    }

    /// Stored rows of the window, a `summarized` note between segments, then the live tail when the window touches
    /// the newest end. Posts go in by time, in the same pass: each after the last shown stored row at or before it
    /// (a row without a time takes the one before it). A post older than every shown row goes at the top once the
    /// window reaches the oldest end; one newer than every stored row goes before the live tail while the window
    /// touches the newest end. Any other post belongs to rows outside the window and waits for them.
    private func compose() {
        let liveSummaries = Set(state.rows.compactMap { row -> String? in
            if case .note(.summarized(let into?)) = row.kind { return into }
            return nil
        })
        var rows: [ConversationRow] = []
        var segment: String?
        var next = 0
        func postRow(_ post: ConversationPost) -> ConversationRow { ConversationRow(id: "post:\(post.id)", kind: .post(post)) }
        // Older than the first shown row with a time: the top, or rows above the window.
        if let first = historyRows.first(where: { $0.isShown && $0.timestamp != nil })?.timestamp {
            while next < posts.count, posts[next].at.timeIntervalSince1970 < first {
                if historyAtOldestEnd { rows.append(postRow(posts[next])) }
                next += 1
            }
        }
        var time: Double?
        for stored in historyRows where stored.isShown {
            if let stamp = stored.timestamp { time = stamp }
            // Posts older than this row go after the one above it.
            if let time {
                while next < posts.count, posts[next].at.timeIntervalSince1970 < time {
                    rows.append(postRow(posts[next]))
                    next += 1
                }
            }
            let here = stored.address.segment
            if let previous = segment, previous != here, !liveSummaries.contains(here) {
                rows.append(ConversationRow(id: keptBoundaryIds[here] ?? "summary:\(here)", kind: .note(.summarized(into: here))))
            }
            segment = here
            rows.append(stored.row(id: keptIds[stored.address.rowId]))
        }
        if historyAtNewestEnd {
            rows.append(contentsOf: posts[next...].map(postRow))
            let stored = Set(historyRows.map(\.address.rowId))
            rows.append(contentsOf: state.rows.filter { row in row.address.map { !stored.contains($0.rowId) } ?? true })
        }
        transcript = rows
    }

    // MARK: Plumbing

    private func call(_ method: String, _ params: GatewayJSON, timeout: Duration?) async -> Result<GatewayJSON, any Error> {
        do {
            return .success(try await link.request(method, params, timeout: timeout))
        } catch {
            return .failure(error)
        }
    }

    private func perform(_ job: @escaping @MainActor () async -> Void) {
        guard !closed else { return }
        nextWork += 1
        let number = nextWork
        work[number] = Task { @MainActor in
            await job()
            self.work[number] = nil
        }
    }
}
