import Foundation
import Observation
import OSLog

/// How long a chat's call to the gateway may take, unless it says otherwise.
let chatCallTimeout: Double = 2 * 60

/// A message written while the bot is busy, waiting its turn. It owns the files that were staged
/// when the person sent it, so a later message can never take them.
public struct QueuedMessage: Identifiable, Hashable, Sendable {
    public var id = UUID()
    public var text: String
    public var attachments: [AttachmentPreview]

    public init(text: String, attachments: [AttachmentPreview] = []) {
        self.text = text
        self.attachments = attachments
    }

    /// What the queue shows: the words, or a count of files when there are none.
    public var summary: String {
        guard text.isEmpty, !attachments.isEmpty else { return text }
        return attachments.count == 1 ? "1 file" : "\(attachments.count) files"
    }
}

/// A question from the gateway that waits for the person: an approval, a clarification, a
/// password, a secret, or one of the vault prompts.
public struct PendingCard: Hashable, Identifiable, Sendable {
    /// True when the approval queue listed the card, so it is answered with `approval.respond`.
    public var viaApprovalRPC: Bool
    public var params: JSONValue
    public var method: String
    public var id: String

    /// The request methods that become cards.
    static let askingMethods: Set<String> = ["approval", "clarify", "sudo", "secret",
                                             "vault.unlock_prompt", "vault.save_login", "vault.code"]
    private static let valuePromptMethods = askingMethods.subtracting(["approval", "clarify"])

    public init(id: String, method: String, params: JSONValue, viaApprovalRPC: Bool = false) {
        self.viaApprovalRPC = viaApprovalRPC
        self.params = params
        self.method = method
        self.id = id
    }

    private func decoded<T: Decodable>(for methods: Set<String>, as kind: T.Type) -> T? {
        methods.contains(method) ? try? params.decode(kind) : nil
    }

    public var approval: ApprovalRequest? { decoded(for: ["approval"], as: ApprovalRequest.self) }
    public var clarify: ClarifyRequest? { decoded(for: ["clarify"], as: ClarifyRequest.self) }
    public var valuePrompt: ValuePromptRequest? { decoded(for: Self.valuePromptMethods, as: ValuePromptRequest.self) }
    public var isSecret: Bool { !["approval", "clarify"].contains(method) }

    /// Does a notification `key` point at this card? Matches the card's id, or for approvals the request
    /// id in either spelling: plain (as the Companion pushes carry it) or the queue's `queue-<id>`.
    /// Both cards of one approval answer to it.
    public func isNamed(by key: String) -> Bool {
        if key.isEmpty { return false }
        var accepted: Set<String> = [id]
        if let request = approval?.requestId, !request.isEmpty {
            accepted.formUnion([request, "queue-\(request)"])
        }
        return accepted.contains(key)
    }
}

/// One live conversation: its transcript, the reply being assembled, the questions waiting for
/// the person, the messages queued to send and the attachments staged.
///
/// The class body holds state and the opening of a chat. The rest lives beside it:
/// `ChatSession+Snapshots`, `+Cards`, `+Events`, `+Streaming`, `+Sending` and `+Commands`.
@MainActor
@Observable
public final class ChatSession: @MainActor Identifiable, ChatIdentity {
    /// Held strongly on purpose: a chat a screen keeps open must outlive a switch of gateway. The loop
    /// this makes with the runtime's list of open chats is cut by `GatewayRuntime.dispose()`.
    public let runtime: GatewayRuntime
    @ObservationIgnored let log = Logger(subsystem: NollieLog.subsystem, category: "chat")
    @ObservationIgnored let activity: any TurnActivityReporting

    /// The bot that owns this chat. It is set on open or create and never changes, so each call and
    /// header uses it even if another bot is selected afterwards. Resuming under the selected bot once
    /// caused the gateway to file the chat in that bot's store.
    public let profile: String?

    // What the screen shows.
    public var items: [TranscriptItem] = []
    public var banner: String?
    public var cards: [PendingCard] = []
    public var queue: [QueuedMessage] = []
    public var staged: [AttachmentPreview] = []
    public var usage: Usage?
    public var info: SessionLiveInfo?
    public var title: String
    public var composerHistory: [String] = []
    public var lastSubmitStatus: String?
    public var stale = false
    public var resumeError: String?
    /// Reason the last turn ended early, if this device knows (Stop was pressed here, or the app was
    /// away from the gateway mid-turn). Sending the next message resets it.
    public var interruptCause: InterruptedTurn.Cause?

    public internal(set) var storedID: String
    public internal(set) var runtimeID = ""
    /// Ids the chat held before Hermes compressed it into a new stored session. Links,
    /// notifications and routes made earlier still find the chat by them.
    public internal(set) var formerStoredIDs: [String] = []
    /// Set from open until `session.resume` returns. The cache (or a REST page) fills the screen in the
    /// meantime, so the chat appears immediately and catches up once the reply lands.
    public internal(set) var isResuming = false
    public var id: String { storedID }

    public var statusLine: String? {
        didSet {
            guard isRunning, statusLine != oldValue, cards.isEmpty else { return }
            activity.update(for: self, attention: false)
        }
    }

    public var isRunning = false {
        didSet {
            guard isRunning != oldValue else { return }
            if isRunning { turnBegan() } else { turnEnded() }
        }
    }

    // Bookkeeping that is never drawn.
    @ObservationIgnored var reply = LiveReply()
    @ObservationIgnored var clock = TurnClock()
    @ObservationIgnored var book = SnapshotBook()
    @ObservationIgnored var ledger = CardLedger()
    @ObservationIgnored var toolRows: [String: String] = [:]
    @ObservationIgnored var inlineAnswers: [String: CheckedContinuation<JSONValue?, Never>] = [:]
    @ObservationIgnored var catalogCache: CommandsCatalog?
    @ObservationIgnored var startedHere = false
    /// A message is being uploaded and handed to the gateway. Anything sent meanwhile is queued, so
    /// messages go one at a time, each with its own files.
    @ObservationIgnored var isSubmitting = false
    @ObservationIgnored var adoptingTurn = false
    @ObservationIgnored var summarizedRowShown = false
    @ObservationIgnored var bannerIsReconnect = false
    @ObservationIgnored var endPhase = "done"
    @ObservationIgnored var lastApprovalCheck = Date.distantPast
    @ObservationIgnored var lastActivityUpdate = Date.distantPast
    @ObservationIgnored var lastStatsUpdate = Date.distantPast
    @ObservationIgnored var activityEndTask: Task<Void, Never>?
    @ObservationIgnored var approvalPollTask: Task<Void, Never>?
    @ObservationIgnored var resumeTask: Task<Void, Never>?

    /// Hook that runs off the main actor before snapshot rows are built. Always nil in the app. Tests
    /// set it to pause a build and watch what comes in during the wait.
    @ObservationIgnored var beforeSnapshotRows: (@Sendable (JSONValue) async -> Void)?
    /// Replacement for the gateway on this chat's calls. Always nil in the app. Tests set it to decide
    /// the reply to each call and its timing.
    @ObservationIgnored var gatewayStandIn: (@MainActor (String, [String: JSONValue]) async throws -> JSONValue)?

    public init(runtime: GatewayRuntime, storedID: String? = nil, title: String? = nil, profile: String? = nil) {
        let named = (profile ?? "").isEmpty ? nil : profile
        self.storedID = storedID ?? ""
        self.title = title ?? "New chat"
        self.activity = runtime.activityReporterFactory()
        self.profile = named ?? runtime.selectedProfile
        self.runtime = runtime
    }

    // MARK: Derived

    public var profileName: String { profile ?? info?.profileName ?? runtime.selectedProfile ?? "default" }
    public var modelName: String { info?.model ?? "" }
    public var firstCard: PendingCard? { cards.isEmpty ? nil : cards[0] }
    public var needsAttention: Bool { cards.count > 0 }
    /// A turn this device sent is running. Only this app knows; the gateway does not.
    public var turnStartedHere: Bool { isRunning && startedHere }

    /// Model and context first, since on a phone the end of the line is what gets cut off and the
    /// bot's name is the part the person can best spare.
    public var subtitle: String {
        let shortModel = modelName.split(separator: "/").last.map(String.init) ?? modelName
        var parts = [modelName.isEmpty ? "no model" : shortModel]
        if let percent = usage?.computedContextPercent { parts.append("\(percent)%") }
        parts.append(profileName)
        return parts.joined(separator: " · ")
    }

    // MARK: Talking to the gateway

    /// A call to the gateway with this chat's bot attached.
    func rpc(_ method: String, _ params: [String: JSONValue] = [:], timeout: Double = chatCallTimeout) async throws -> JSONValue {
        if let standIn = gatewayStandIn { return try await standIn(method, params) }
        let bot = profile
        let live = runtime
        return try await live.rpc(method, params, owner: bot, timeout: timeout)
    }


    /// A call about this chat's live session: its runtime id goes in with `extra`.
    func ask(_ method: String, _ extra: [String: JSONValue] = [:], timeout: Double = 120) async throws -> JSONValue {
        try await rpc(method, extra.merging(["session_id": .string(runtimeID)]) { mine, _ in mine }, timeout: timeout)
    }

    // MARK: Adding rows

    func addRow(_ kind: TranscriptItem.Kind) {
        items.append(TranscriptItem(id: UUID().uuidString, kind: kind))
    }

    func addNote(_ text: String, symbol: String = "terminal") {
        addRow(.system(text: text, symbol: symbol))
    }

    func addFailure(_ text: String) {
        addRow(.error(text: text))
    }

    // MARK: A turn starting and stopping

    private func turnBegan() {
        activityEndTask?.cancel()
        activityEndTask = nil
        // Approval frames sometimes never arrive: a proxy drops one, another client answers first, or the
        // gateway never recorded the capability. So while a turn runs we ask the gateway's queue every few
        // seconds, and the card appears regardless.
        approvalPollTask?.cancel()
        approvalPollTask = Delay.repeating(every: .seconds(6), while: { [weak self] in self?.isRunning == true }) { [weak self] in
            await self?.pollPendingApprovals()
        }
    }

    private func turnEnded() {
        approvalPollTask?.cancel()
        approvalPollTask = nil
        // All turn endings funnel through this spot (reclaim, idle snapshot, stray session.info), which
        // keeps the turn surface from outliving its turn. Ending is deferred slightly: the brief idle
        // between send and first token must not shut an activity that just opened. Completion and error
        // end it at once.
        let phase = endPhase
        endPhase = "done"
        activityEndTask?.cancel()
        activityEndTask = Delay.run(after: .seconds(2)) { [weak self] in
            if let me = self, !me.isRunning { me.activity.end(for: me, phase: phase) }
        }
    }

    // MARK: Letting go

    /// The gateway this chat belongs to is being let go for good. Stops the chat's own work and frees
    /// anyone still waiting on the person's answer, with no value, so nothing is decided on the
    /// person's behalf. A chat a screen still holds stays readable but does nothing more.
    func dispose() {
        let wasRunning = isRunning
        // No answer is coming any more, so the chat stops looking busy: no typing, no status, and
        // whatever the bot had said so far stands as a finished bubble.
        sealStreamingForTool()
        (isRunning, isSubmitting, statusLine) = (false, false, nil)
        for task in [resumeTask, approvalPollTask, activityEndTask] { task?.cancel() }
        (resumeTask, approvalPollTask, activityEndTask) = (nil, nil, nil)
        let waiting = inlineAnswers
        inlineAnswers = [:]
        for waiter in waiting.values { waiter.resume(returning: nil) }
        if wasRunning { activity.end(for: self, phase: "done") }
        isResuming = false
    }

    // MARK: Opening

    /// Hermes moves a chat to a new stored session when it compresses the chat, and says so in
    /// `session.info` and in snapshots. The chat follows the live one, keeps its rows under the new
    /// id, and the old id still finds it.
    func follow(storedID newID: String) {
        guard !newID.isEmpty, newID != storedID else { return }
        if !storedID.isEmpty, !formerStoredIDs.contains(storedID) { formerStoredIDs.append(storedID) }
        storedID = newID
        if !items.isEmpty { saveTranscriptCache() }
        NotificationCenter.default.post(name: .hermesSessionsChanged, object: nil)
    }

    /// Starts a new session on the gateway.
    public func create(cwd: String? = nil) async throws {
        var wanted: [String: JSONValue] = [:]
        wanted["cols"] = 80
        if let folder = cwd, !folder.isEmpty {
            wanted["cwd"] = .string(folder)
            wanted["cwd_explicit"] = true
        }
        let answer = try await rpc("session.create", wanted)
        let live = answer.text("session_id") ?? ""
        runtimeID = live
        storedID = answer.text("stored_session_id") ?? live
        info = try? answer["info"]?.decode(SessionLiveInfo.self)
        let given = info?.title ?? ""
        title = given.isEmpty ? "New chat" : given
        items.removeAll()
        await loadUsage()
    }

    public func resume() async throws {
        try await resumeFromGateway()
        await loadUsage()
    }

    /// Fetches the session snapshot (`session.resume`) and applies it. The snapshot's open questions
    /// count as read no sooner than when the call left: the gateway collects them last, right before
    /// replying, so an answer sent from this device in the meantime may land after that point.
    func resumeFromGateway() async throws {
        let startedAt = Date()
        let ticket = ledger.beginList(at: startedAt)
        defer { ledger.endList(ticket) }
        let wire: [String: JSONValue] = ["session_id": .string(storedID), "cols": 80]
        let answer = try await rpc("session.resume", wire)
        await apply(snapshot: answer, listedAt: startedAt)
    }

    /// Re-attaches after the socket came back.
    public func reattachAfterReconnect(retrying: Bool = true) async {
        let failure: Error?
        do {
            try await resumeFromGateway()
            failure = nil
        } catch {
            failure = error
        }
        stale = failure != nil
        guard let failure else {
            if bannerIsReconnect { banner = nil; bannerIsReconnect = false }
            // Messages kept back while the line was down go now, unless a turn is still running.
            drainQueue()
            return
        }
        if failure is CancellationError { return }
        if let socketError = failure as? SocketError {
            // A later reconnect superseded this one, or the socket vanished before this call (network still
            // settling, or a dead socket found when returning). That later reconnect re-attaches the chat, so
            // a banner for something about to heal itself would only add noise.
            if case .notConnected = socketError { return }
            if case .timeout = socketError, retrying {
                try? await Task.sleep(for: .seconds(2))
                await reattachAfterReconnect(retrying: false)
                return
            }
        }
        explainFailedReattach(failure.localizedDescription)
    }

    private func explainFailedReattach(_ why: String) {
        if why.contains("CancellationError") { return }
        bannerIsReconnect = true
        // A one-time run, such as a scheduled task, can disappear: it was never stored, or a restart lost it.
        let missing = why.localizedCaseInsensitiveContains("not found")
        banner = missing
            ? "This chat is gone from the gateway. It may have been a one-off run, or the gateway restarted without it. Start a new chat to carry on."
            : "Back online, but this chat could not be picked up again: \(why)"
    }

    /// While `resume()` runs, shows the most recent transcript this device holds, or a REST page if
    /// there is no cache. The live snapshot then takes over from either.
    public func beginResume() {
        if items.isEmpty {
            let saved = TranscriptCache.load(connection: runtime.connection.id, storedID: storedID) ?? []
            if !saved.isEmpty { show(history: saved) }
        }
        isResuming = true
        resumeError = nil
        if items.isEmpty { Task { [weak self] in await self?.prefetchFromREST() } }
        resumeTask = Task { [weak self] in await self?.finishOpening() }
    }

    private func finishOpening() async {
        do {
            try await resume()
            resumeError = nil
        } catch {
            resumeError = error.localizedDescription
        }
        isResuming = false
    }

    /// Waits until the live attach finishes, for callers that need the runtime session id.
    public func awaitResume() async { await resumeTask?.value }

    private func show(history messages: [TranscriptMessage]) {
        items = TranscriptItem.fromHistory(messages)
        book.fetched = Set(items.map(\.id))
    }

    private func prefetchFromREST() async {
        let newest = [URLQueryItem(name: "limit", value: "60"), URLQueryItem(name: "order", value: "latest")]
        guard let page: JSONValue = try? await runtime.api.get("/api/sessions/\(storedID)/messages", query: newest, profile: profile),
              isResuming, items.isEmpty else { return }
        show(history: (page["messages"]?.arrayValue ?? []).compactMap { try? $0.decode(TranscriptMessage.self) })
    }

    func saveTranscriptCache() {
        let (connection, stored) = (runtime.connection.id, storedID)
        TranscriptCache.save(items, connection: connection, storedID: stored)
    }

    // MARK: Usage and context

    public func loadUsage() async {
        guard let answer = try? await ask("session.usage"), let fresh: Usage = try? answer.decode() else { return }
        usage = fresh
    }

    public func contextBreakdown() async throws -> ContextBreakdown {
        try await ask("session.context_breakdown").decode()
    }
}
