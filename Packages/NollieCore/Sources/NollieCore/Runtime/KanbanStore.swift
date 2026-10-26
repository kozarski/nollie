import Foundation

/// Feeds the Board page from the gateway's kanban plugin: does the plugin exist, which boards
/// there are, the board on screen with its workers, and a socket that signals when to re-read.
/// Writes are in KanbanStore+Writing.swift and each finishes with a fresh read.
@MainActor
@Observable
public final class KanbanStore {
    /// Whether the plugin responds; unknown until the first probe. The last result is saved for each
    /// gateway to stop the page flickering at startup.
    public enum Availability: String, Sendable { case unknown, present, absent }

    /// What is saved between launches for one gateway.
    private struct Memory {
        let gateway: String
        private var availabilityKey: String { "kanban.available." + gateway }
        private var boardKey: String { "kanban.board." + gateway }

        var availability: Availability? {
            get { UserDefaults.standard.string(forKey: availabilityKey).flatMap(Availability.init(rawValue:)) }
            nonmutating set { UserDefaults.standard.set(newValue?.rawValue, forKey: availabilityKey) }
        }

        var board: String? {
            get { UserDefaults.standard.string(forKey: boardKey) }
            nonmutating set { UserDefaults.standard.set(newValue, forKey: boardKey) }
        }
    }

    /// The board in front and who is working on it, swapped as one piece.
    private struct Shown {
        var board: KanbanBoard?
        var workers: [KanbanWorker] = []
    }

    // Counters and flags the page watches.
    public private(set) var loading = false
    public private(set) var liveConnected = false
    /// How often the board was read. Tests count it; events landing together make one read.
    public private(set) var reads = 0
    public private(set) var lastRead: Date?

    // The data.
    public private(set) var availability: Availability = .unknown
    public private(set) var selectedBoard: String?
    public private(set) var boards: [KanbanBoardMeta] = []
    private var shown = Shown()
    public var board: KanbanBoard? { shown.board }
    public var workers: [KanbanWorker] { shown.workers }
    public private(set) var assignees: [KanbanAssignee] = []
    /// Which bots are busy on any board, followed even if the Board page was never opened.
    public private(set) var activity = KanbanActivity()

    /// Server wording for the latest failure, passed through untouched.
    public var lastError: String?
    /// Server wording for the latest refused change. Later reads do not clear it.
    public internal(set) var lastRefusal: String?

    private weak var runtime: GatewayRuntime?
    private var heardBefore: Availability?
    private var cursor = KanbanEventCursor()
    private var mayFollowActivity = false
    private var currentRead: Task<Void, Never>?
    private var queuedRead: Task<Void, Never>?
    private let stream = KanbanEventStream()
    private let watch = KanbanActivityWatch()

    public init() {
        stream.onConnection = { [weak self] connected in self?.liveConnected = connected }
        stream.onFrame = { [weak self] frame in
            guard let self else { return }
            if self.cursor.take(frame) { self.readSoon() }
        }
    }

    func attach(_ runtime: GatewayRuntime) {
        self.runtime = runtime
        mayFollowActivity = true
        heardBefore = memory.availability
        selectedBoard = memory.board
    }

    private var memory: Memory { Memory(gateway: runtime?.connection.id.uuidString ?? "") }

    // MARK: What the pages rely on

    /// The probe result, or else the one saved for this gateway.
    public var effective: Availability {
        if availability != .unknown { return availability }
        return heardBefore ?? .unknown
    }

    public var isPresent: Bool {
        if case .present = effective { return true }
        return false
    }

    public var api: KanbanAPI? {
        guard let runtime else { return nil }
        return KanbanAPI(api: runtime.api, board: selectedBoard)
    }

    public var selectedBoardMeta: KanbanBoardMeta? {
        for candidate in boards where candidate.slug == selectedBoard { return candidate }
        return nil
    }

    /// Looks up the worker for a task. Its run id lives here, not on the board card.
    public func worker(for task: KanbanTask) -> KanbanWorker? {
        for candidate in shown.workers where candidate.taskId == task.id { return candidate }
        return nil
    }

    // MARK: Reading

    /// Reloads the board and workers. The reload is a task of its own, so if the page's task restarts
    /// partway (changing tab, reappearing) the request under it is not cancelled, and anyone calling
    /// during a reload waits for that one instead of starting a second.
    public func refresh() async {
        guard isPresent, let api else { return }
        if let underway = currentRead {
            await underway.value
            return
        }
        let task = Task { @MainActor [weak self] in
            if let self { await self.readBoard(with: api) }
        }
        currentRead = task
        await task.value
        currentRead = nil
    }

    private func readBoard(with api: KanbanAPI) async {
        reads += 1
        loading = shown.board == nil
        defer { loading = false }
        let asked = selectedBoard
        async let columns = api.board()
        async let running = api.workers()
        do {
            let (fresh, busy) = try await (columns, running)
            // Another board was picked while this one loaded; the answer isn't for it.
            if asked != selectedBoard { return }
            shown = Shown(board: fresh, workers: busy.workers)
            cursor.start(fromBoard: fresh.latestEventId)
            lastRead = .now
            lastError = nil
        } catch {
            lastError = Self.message(error)
        }
    }

    /// The plugin's client, or a thrown error when there is no gateway yet.
    private func connectedAPI() throws -> KanbanAPI {
        guard let api else { throw HermesAPIError.transport("No gateway") }
        return api
    }

    public func refreshBoards() async {
        if let listing = try? await api?.boards() { boards = listing.boards }
    }

    public func loadAssignees() async {
        if let people = try? await api?.assignees() { assignees = people }
    }

    public func detail(_ id: String) async throws -> KanbanTaskDetail {
        let client = try connectedAPI()
        return try await client.task(id)
    }

    public func log(_ id: String, tail: Int = 20_000) async throws -> KanbanLog {
        let client = try connectedAPI()
        return try await client.log(id, tail: tail)
    }

    /// Switches to another board, with a fresh read and a fresh socket.
    public func select(board slug: String) {
        if selectedBoard == slug { return }
        memory.board = slug
        selectedBoard = slug
        shown = Shown()
        cursor = KanbanEventCursor()
        Task {
            await refresh()
            startEvents()
        }
    }

    /// Events tend to arrive in a burst after a change, so they share one read.
    private func readSoon() {
        queuedRead?.cancel()
        queuedRead = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(300)) } catch { return }
            await self?.refresh()
        }
    }

    // MARK: Is the plugin there?

    /// Fetches the boards to learn whether the plugin exists. A reply means it does and a 404 means it
    /// doesn't (disabled plugins say "Plugin not found", unmounted ones return the server's bare Not Found).
    public func probe() async {
        guard let api else { return }
        let epoch = watch.epoch
        do {
            let listing = try await api.boards()
            if Task.isCancelled || epoch != watch.epoch { return }
            boards = listing.boards
            if selectedBoardMeta == nil { selectedBoard = listing.current ?? boards.first?.slug }
            note(.present)
            followActivity()
        } catch HermesAPIError.http(let status, _) where status == 404 {
            note(.absent)
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func note(_ answer: Availability) {
        availability = answer
        heardBefore = answer
        memory.availability = answer
        if answer == .absent { resetActivity() }
    }

    // MARK: Which bots are busy

    private func followActivity() {
        guard mayFollowActivity else { return }
        watch.begin(
            refreshBoards: { [weak self] in
                guard let self, self.runtime?.isAway == false else { return }
                await self.refreshBoards()
            },
            look: { [weak self] in
                guard let self, let runtime = self.runtime, !runtime.isAway else { return nil }
                let client = runtime.api
                let bots = Set(runtime.profiles.map(\.name))
                return await KanbanActivity.read(boards: self.boards.map(\.slug), profiles: bots,
                                                 connection: runtime.connection.id) { slug in
                    try await KanbanAPI(api: client, board: slug).workers().workers
                }
            },
            show: { [weak self] seen in self?.activity = seen })
    }

    public func stopActivityUpdates() {
        mayFollowActivity = false
        resetActivity()
    }

    private func resetActivity() {
        watch.end()
        activity = KanbanActivity()
    }

    // MARK: Live socket

    /// Connects to the kanban plugin's own socket, separate from the main gateway link, and reloads the board for any
    /// frame that has events in it. Reconnects with increasing waits until `stopEvents()` is called.
    public func startEvents() {
        guard isPresent, runtime?.backend.isInProcess != true else {
            stream.stop()
            return
        }
        stream.run { [weak self] in
            guard let self, let runtime = self.runtime else { throw CancellationError() }
            let items = [self.selectedBoard.map { URLQueryItem(name: "board", value: $0) }, self.cursor.sinceQuery].compactMap { $0 }
            return try await runtime.pluginSocketRequest(path: KanbanAPI.base + "/events", query: items)
        }
    }

    public func stopEvents() {
        stream.stop()
    }
}
