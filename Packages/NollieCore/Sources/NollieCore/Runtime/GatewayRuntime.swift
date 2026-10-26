import Foundation
import Observation
import OSLog

/// The live side of one gateway: the REST client and the socket, the bots, the chats that are
/// open, and what is waiting on the person. The app holds one for the gateway it is using.
///
/// This file has the state and the day-to-day work (start and stop, calls, chats, events).
/// Signing in is in GatewayRuntime+Auth.swift, finding the gateway's address in
/// GatewayRuntime+Endpoints.swift, bots and identity in GatewayRuntime+Bots.swift, and the
/// notification names in GatewayNotifications.swift.
@MainActor
@Observable
public final class GatewayRuntime {

    // MARK: Connection

    public internal(set) var connection: GatewayConnection
    public internal(set) var secrets: GatewaySecrets
    public let api: HermesAPI
    /// Where the answers come from (the network, or the demo's in-process gateway).
    public let backend: GatewayBackend
    public private(set) var socket: GatewaySocket!
    public var socketState: SocketState = .idle
    /// Set to false when nothing should open a socket (a test runtime, say). Starting, reconnecting
    /// and new credentials then keep it shut, and the capability probe does not wait on it.
    public var socketEnabled = true
    /// True while the phone app sits in the background. Replies still streaming keep gathering
    /// text off-screen and paint it once when the app returns.
    public var isAway = false {
        didSet {
            guard oldValue, !isAway else { return }
            registry.all.forEach { $0.cameBack() }
            // Coming back, check the socket now; if it died unnoticed while away, we learn it here instead of at the next heartbeat.
            Task { [socket] in await socket?.checkAlive() }
        }
    }

    let store: ConnectionStore
    let log = Logger(subsystem: NollieLog.subsystem, category: "runtime")

    // MARK: Signing in (see +Auth)

    /// Called when the session is over for good (the refresh token was refused). If the person
    /// chose to remember their sign-in on this device, the app uses it to get a fresh session.
    /// Returns that session, or nil to hand the choice back to the person.
    public var signInAgain: (@MainActor (GatewayConnection, GatewaySecrets) async -> GatewaySecrets?)?
    /// Turns true when the gateway refuses the refresh token and stays that way until a sign-in
    /// succeeds. A socket refused while it is false (a 4401 close, or a ticket refused right after a
    /// good renewal) would not be fixed by signing in, so a remembered sign-in stays unused.
    public internal(set) var refreshRefused = false

    // MARK: Where the gateway is (see +Endpoints)

    /// Set only by the direct Mac app, for an installation it owns and has saved.
    public var managedEndpointResolver: (@MainActor @Sendable () async throws -> GatewayURL)?
    /// For a linked Mac: finds its door again before every socket attempt, wherever it answers.
    public var linkResolver: NollieLinkResolver?
    /// Set while a linked Mac can't be found, cleared when it answers.
    public internal(set) var linkUnreachable: String?
    /// The linked Mac's last word: its hosts, whether away from home is on, and Tailscale.
    public internal(set) var linkInfo: NollieLinkHostsReply?
    /// The demo copy asks the mock gateway, which answers the door's routes.
    public var linkDemo = false
    var awaitingManagedStartup = false
    var managedLifecycleGeneration = UUID()
    @ObservationIgnored var linkRefreshing = false

    /// How this phone reaches its linked Mac right now. Nil when it isn't linked to one.
    public var linkReach: NollieLinkReach? {
        guard connection.linkedMac != nil else { return nil }
        if linkUnreachable != nil { return .away }
        return NollieTailnet.isTailnetHost(connection.gateway.host) ? .tailnet : .home
    }

    // MARK: Bots

    public var profiles: [ProfileInfo] = []
    public var profileHome: String? = nil
    public var selectedProfile: String? {
        didSet {
            var saved = connection
            saved.lastProfile = selectedProfile
            store.updateMetadata(saved)
            if oldValue != selectedProfile { Task { await refreshCapabilities() } }
        }
    }

    // MARK: Chats and what waits on the person

    public var lastError: String? = nil
    /// Chats (by stored id) with a card waiting on the person.
    public var needsAttention = Set<String>()
    /// Not private, so tests can put a chat in the registry and feed it events without a gateway.
    var registry = ChatRegistry<ChatSession>()
    /// Every open chat, oldest first.
    public var chats: [ChatSession] { registry.all }

    /// Count of server-initiated requests (approvals, clarifying questions and so on) seen on this
    /// socket since it connected, plus the newest one. The diagnostics page shows these to tell
    /// "nothing is being sent" from "it is sent but not shown".
    public internal(set) var serverRequestsReceived = 0
    public internal(set) var lastServerRequest: String? = nil
    /// What the gateway said it will send us after `client.capabilities`.
    public internal(set) var serverRequestsAdvertised: [String] = []

    // MARK: Hooks the owning app fills in

    public var pushRegistrar: (any PushRegistrationSyncing)? = nil
    public var cardNotifier: (any CardNotifying)? = nil
    public var activityReporterFactory: @MainActor () -> any TurnActivityReporting = { NoTurnActivity() }
    /// The app's own answer to an approval, tried before any card is shown. Given the request and
    /// the bot's profile, it returns a choice (such as "always") or nil to show the card as usual.
    /// The app uses it for screen actions of a bot whose System control is on.
    public var approvalAutoAnswer: (@MainActor (ApprovalRequest, String) -> String?)? = nil

    // MARK: Parts that belong to this gateway

    /// Restart and update runs, shared by the Companion and the "restart required" banner.
    public let maintenance = MaintenanceModel()
    /// Hermes' "Restart required" notice while the dashboard runs old code; nil otherwise.
    /// Only /api/model/options reveals it, so we ask on connect, on a profile switch and on
    /// reconnect, rather than letting the model list trip over it later.
    public var restartRequired: String? = nil
    public let projects = ProjectsStore()
    public let kanban = KanbanStore()

    var globalEventTask: Task<Void, Never>? = nil
    /// True after `dispose()`. A disposed runtime does not start again or open chats.
    public private(set) var isDisposed = false

    // MARK: Creating

    public init(connection: GatewayConnection, store: ConnectionStore, backend: GatewayBackend = .network) {
        let known = store.secrets(for: connection.id)
        self.backend = backend
        self.connection = connection
        self.store = store
        self.secrets = known
        self.selectedProfile = connection.lastProfile
        self.api = HermesAPI(gateway: connection.gateway, signer: RequestSigner(authMode: connection.authMode, secrets: known),
                             urlSession: backend.urlSession ?? HermesAPI.makeSession())
        trustSavedLink()
        socket = makeSocket()
        keepSessionFresh()
    }

    /// Only a link that is already saved is trusted across the process. One that isn't yet is
    /// checked with its own pin instead.
    private func trustSavedLink() {
        guard let link = connection.linkedMac,
              store.connection(id: connection.id)?.linkedMac?.pin == link.pin else { return }
        GatewayTrust.shared.register(link, hosts: [connection.gateway.host], owner: connection.id)
        linkResolver = NollieLinkResolver()
    }

    private func makeSocket() -> GatewaySocket {
        // Each hook goes through a weak reference, so the socket never keeps the runtime alive.
        let address: @Sendable () async throws -> (URL, [String: String]) = { [weak self] in
            if let runtime = self { return try await runtime.websocketURL() }
            throw SocketError.cancelled
        }
        // One hop to the main actor for each batch of events, not for each event.
        let events: @Sendable (GatewayEventBatch) -> Void = { [weak self] batch in
            let arrived = batch.take()
            Task { @MainActor in self?.handle(batch: arrived) }
        }
        let states: @Sendable (SocketState) -> Void = { [weak self] next in
            Task { @MainActor in self?.socketStateChanged(to: next) }
        }
        return GatewaySocket(
            urlProvider: address,
            transport: backend.transport,
            onEvents: events,
            onState: states,
            onServerRequest: { [weak self] request in await self?.answer(serverRequest: request) },
            onReconnected: { [weak self] in await self?.didReconnect() })
    }

    /// Lets the REST client renew the session by itself when the gateway answers 401.
    private func keepSessionFresh() {
        let client = api
        Task {
            await client.setRefresher { [weak self] in
                guard let runtime = self else { throw HermesAPIError.sessionExpired }
                return try await runtime.refreshSigner()
            }
        }
    }

    private func socketStateChanged(to state: SocketState) {
        socketState = state
        if state.isOpen && awaitingManagedStartup {
            Task { await finishManagedStartup() }
        }
    }

    // MARK: Start and stop

    public func start() async {
        guard !isDisposed else { return }
        managedLifecycleGeneration = UUID()
        projects.attach(self)
        kanban.attach(self)
        awaitingManagedStartup = managedEndpointResolver != nil
        guard socketEnabled else {
            await loadProfilesAndCapabilities()
            return
        }
        await socket.connect()
        // Wait briefly for the socket before the first HTTP call. Just after it opens the route can still
        // be starting, and requesting profiles that soon produced an error which the connect loop was
        // going to cure anyhow (#305). Whatever this pass misses, the reconnect loads.
        try? await socket.waitUntilReady(timeout: 8)
        await loadProfilesAndCapabilities()
    }

    private func loadProfilesAndCapabilities() async {
        if managedEndpointResolver != nil {
            await finishManagedStartup()
            return
        }
        await loadProfiles()
        await refreshCapabilities()
    }

    func finishManagedStartup() async {
        guard awaitingManagedStartup && socketState.isOpen else { return }
        awaitingManagedStartup = false
        lastError = nil
        let started = managedLifecycleGeneration
        await loadProfiles()
        if started == managedLifecycleGeneration { await refreshCapabilities() }
    }

    public func stop() async {
        kanban.stopActivityUpdates()
        kanban.stopEvents()
        globalEventTask?.cancel()
        awaitingManagedStartup = false
        managedLifecycleGeneration = UUID()
        await socket.disconnect()
    }

    /// Lets this gateway go for good, such as when the person switches to another or removes it.
    /// Unlike `stop()`, which a restart follows, nothing comes back: the open chats are released
    /// (and their work and waiting answers ended), so the runtime, its transcripts and its sign-in
    /// are freed once no screen holds them. A chat a screen still holds stays readable only.
    public func dispose() async {
        isDisposed = true
        let open = registry.all
        registry = ChatRegistry<ChatSession>()
        needsAttention = []
        for chat in open { chat.dispose() }
        await stop()
    }

    public func reconnectNow() async {
        await socket.disconnect()
        guard socketEnabled else { return }
        await socket.connect()
    }

    /// The socket came back after dropping: say what we can answer again, fetch what the
    /// first load missed, and let the open chats catch up.
    func didReconnect() async {
        await advertiseCapabilities()
        if profiles.isEmpty {
            // Clear the error: the first load may have run before the route existed (#305).
            lastError = nil
            await loadProfiles()
        }
        for chat in chats { await chat.reattachAfterReconnect() }
        await probeCodeSkew()
    }

    // MARK: Calls

    /// Params with the bot added when one is chosen. Nulls are dropped.
    public func profileParams(_ base: [String: JSONValue] = [:], profile: String? = nil) -> JSONValue {
        let owner = profile ?? selectedProfile
        return Self.params(base, owner: owner)
    }

    /// Adds the owner to a call that belongs to a single bot. It never falls back to whichever bot
    /// is selected, since the selection can change after a chat was opened.
    public nonisolated static func params(_ base: [String: JSONValue], owner: String?) -> JSONValue {
        var all = base
        if let owner, !owner.isEmpty { all["profile"] = .string(owner) }
        return .object(all.compactingNulls)
    }

    /// A call on a chat's own bot.
    public func rpc(_ method: String, _ params: [String: JSONValue] = Dictionary(), owner: String?, timeout: TimeInterval = 120) async throws -> JSONValue {
        try await call(method, Self.params(params, owner: owner), timeout)
    }

    /// Calls the selected bot, or `profile` if one is passed, so peeking at another bot's chat
    /// does not move the selection.
    public func rpc(_ method: String, _ params: [String: JSONValue] = Dictionary(), profile: String? = nil, timeout: TimeInterval = 120) async throws -> JSONValue {
        try await call(method, profileParams(params, profile: profile), timeout)
    }

    private func call(_ method: String, _ params: JSONValue, _ timeout: TimeInterval) async throws -> JSONValue {
        try await socket.waitUntilReady()
        return try await socket.call(method, params: params, timeout: timeout)
    }
}
