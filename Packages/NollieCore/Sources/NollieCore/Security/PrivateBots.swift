import Foundation

/// Bots the person flagged Private in Bot settings. What a private bot says stays out of
/// notification previews, the chat list's last line, Board activity and configuration backups.
/// The list sits in the shared Keychain, which lets the notification extension and alert helper read it too.
///
/// Each gateway has its own list: two gateways can both have a bot called "default", and one
/// being private says nothing about the other.
public struct PrivateBots: Codable, Equatable, Sendable {
    public static let account = "bots.private.v1"
    /// The one list older builds kept for every gateway. A gateway with no list of its own yet
    /// starts from it, so nothing that was private becomes public on the way.
    public private(set) var names: Set<String>
    /// Set once the one-time carry-over from older builds has run (see `adoptingLegacyNames`).
    public private(set) var settled: Bool
    /// Each gateway's list, by connection id. Nil in a list saved by an older build.
    public private(set) var connections: [String: Policy]?

    public init(names: Set<String> = [], settled: Bool = false, connections: [String: Policy]? = nil) {
        self.names = Set(names.map(Self.key))
        self.settled = settled
        self.connections = connections
    }

    /// One gateway's list.
    public struct Policy: Codable, Equatable, Sendable {
        public private(set) var names: Set<String>
        public private(set) var settled: Bool
        /// The person's last choice hasn't reached the gateway yet. Until it does, what the gateway
        /// holds can never undo it.
        public private(set) var pending: Bool
        /// Counts the person's choices, so an acknowledgement only clears the choice it was for.
        public private(set) var revision: Int
        /// The bots turned Private here that the gateway hasn't heard about yet. Sending them again
        /// adds them to the gateway's list as it is then, so another device's changes stay.
        /// Nil in a list saved by an older build.
        public private(set) var waiting: Set<String>?
        /// Where this list was kept: the gateway's address and, once known, which Hermes it is. A
        /// gateway paired again comes back under a new connection and finds its list by these.
        public private(set) var gateways: Set<String>?

        public init(names: Set<String> = [], settled: Bool = false, pending: Bool = false, revision: Int = 0,
                    waiting: Set<String>? = nil, gateways: Set<String>? = nil) {
            self.names = Set(names.map(PrivateBots.key))
            (self.settled, self.pending, self.revision) = (settled, pending, revision)
            (self.waiting, self.gateways) = (waiting.map { Set($0.map(PrivateBots.key)) }, gateways)
        }

        public func contains(_ profile: String) -> Bool {
            let name = PrivateBots.key(profile)
            // Before the carry-over, the names older builds treated as private still count.
            return names.contains(name) || (!settled && PrivateBots.carriedOver.contains(name))
        }

        /// The person's choice for one bot. It waits for the gateway's yes before it counts as shared.
        public func setting(_ profile: String, private on: Bool) -> Policy {
            var copy = self
            let name = PrivateBots.key(profile)
            var waiting = copy.waiting ?? []
            if on {
                copy.names.insert(name)
                waiting.insert(name)
            } else {
                copy.names.remove(name)
                waiting.remove(name)
            }
            copy.waiting = waiting
            copy.settled = true
            copy.pending = true
            copy.revision += 1
            return copy
        }

        public func adoptingLegacyNames(from profiles: [String]) -> Policy {
            guard !settled else { return self }
            var copy = self
            for name in profiles where PrivateBots.carriedOver.contains(PrivateBots.key(name)) { copy.names.insert(PrivateBots.key(name)) }
            copy.settled = true
            return copy
        }

        /// The gateway has the list as it stood at `revision`. A newer choice is still waiting.
        public func acknowledged(revision: Int) -> Policy {
            var copy = self
            if copy.revision == revision { (copy.pending, copy.waiting) = (false, nil) }
            return copy
        }

        /// What to send the gateway for a waiting choice: its list as it is now, plus the bots turned
        /// Private here. Nothing another device made private is dropped on the way.
        public func merging(into gateway: Set<String>) -> Set<String> {
            Set(gateway.map(PrivateBots.key)).union(waiting ?? names)
        }

        /// The same list, noted as kept at these gateway addresses.
        public func kept(at places: Set<String>) -> Policy {
            guard !places.isSubset(of: gateways ?? []) else { return self }
            var copy = self
            copy.gateways = (gateways ?? []).union(places)
            return copy
        }

        /// The gateway's list. While a choice is waiting to be sent, the gateway's list is ignored,
        /// so an old answer can't make a bot less private than the person chose.
        public func taking(_ gateway: Set<String>) -> Policy {
            guard !pending else { return self }
            var copy = self
            copy.names = Set(gateway.map(PrivateBots.key))
            copy.settled = true
            return copy
        }
    }

    // MARK: Looking up

    /// A gateway's list. One with none of its own yet starts from the list it had under an earlier
    /// connection at one of `places` (it was paired again), else from the older shared list.
    public func policy(for connection: UUID, at places: Set<String> = []) -> Policy {
        if let own = connections?[connection.uuidString] { return own }
        let before = places.isEmpty ? [] : (connections ?? [:])
            .filter { !($0.value.gateways ?? []).isDisjoint(with: places) }
            .sorted { ($0.value.revision, $0.key) > ($1.value.revision, $1.key) }
        return before.first?.value ?? legacy
    }

    private var legacy: Policy { Policy(names: names, settled: settled) }

    /// Whether a bot is private on a gateway. With no gateway named, it is private if any list
    /// says so, the older shared one included, since a gateway may still be going by it: not knowing
    /// which one is asking is answered with the stricter side.
    public func isPrivate(_ profile: String, connection: UUID?) -> Bool {
        if let connection { return policy(for: connection).contains(profile) }
        return legacy.contains(profile) || (connections ?? [:]).values.contains { $0.contains(profile) }
    }

    public func replacing(_ policy: Policy, for connection: UUID) -> PrivateBots {
        var copy = self
        var all = copy.connections ?? [:]
        all[connection.uuidString] = policy
        copy.connections = all
        return copy
    }

    /// The older shared list's view, before any gateway has a list of its own.
    public func contains(_ profile: String) -> Bool { names.contains(Self.key(profile)) }

    public func setting(_ profile: String, private on: Bool) -> PrivateBots {
        var copy = self
        if on { copy.names.insert(Self.key(profile)) } else { copy.names.remove(Self.key(profile)) }
        copy.settled = true
        return copy
    }

    /// Older builds treated a bot by its name as private. The first time this build sees the
    /// gateway's bots, those names are marked Private once; after that only the setting counts.
    public func adoptingLegacyNames(from profiles: [String]) -> PrivateBots {
        guard !settled else { return self }
        var copy = self
        for name in profiles where Self.carriedOver.contains(Self.key(name)) { copy.names.insert(Self.key(name)) }
        copy.settled = true
        return copy
    }

    static let carriedOver: Set<String> = ["private", "moss"]

    public static func key(_ name: String) -> String { name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }

    // MARK: The process's list

    /// Whether a bot is private. Pass `fresh` before showing anything in a notification or on the
    /// Lock Screen: it reads the Keychain again, because another process may have changed the list.
    /// A list that can't be read counts as private.
    public static func isPrivate(_ profile: String?, connection: UUID? = nil, fresh: Bool = false) -> Bool {
        PrivateBotsStore.shared.isPrivate(profile, connection: connection, fresh: fresh)
    }

    #if DEBUG
    /// Tests set the list for the process without touching the Keychain.
    public static func useForTesting(_ bots: PrivateBots) {
        PrivateBotsStore.shared.pin(.saved(bots))
    }
    #endif
}

/// Where the Private lists are read from and written to. One per process in the app; tests make
/// their own in memory.
public final class PrivateBotsStore: @unchecked Sendable {
    public enum Reading: Equatable, Sendable {
        case saved(PrivateBots)
        case nothingSaved
        /// Something is there that couldn't be read. Treated as private.
        case unreadable
    }

    public struct Failure: LocalizedError {
        public var errorDescription: String? { String(localized: "The Private list couldn't be read.", table: "Core") }
    }

    private let lock = NSLock()
    private let load: @Sendable () -> Reading
    private let write: @Sendable (PrivateBots) throws -> Void
    private var cached: (reading: Reading, at: Date)?
    private var pinned: Reading?
    /// How long the app's own screens keep an answer. Notifications and helpers read afresh.
    static let cacheLife: TimeInterval = 1

    public init(load: @escaping @Sendable () -> Reading, write: @escaping @Sendable (PrivateBots) throws -> Void) {
        self.load = load
        self.write = write
    }

    public static let shared = PrivateBotsStore(load: PrivateBotsStore.readKeychain,
                                                write: { try Keychain.setCodable($0, account: PrivateBots.account) })

    /// A store that keeps its list in memory.
    public static func inMemory(_ bots: PrivateBots? = nil) -> PrivateBotsStore {
        let box = Box(bots.map { .saved($0) } ?? .nothingSaved)
        return PrivateBotsStore(load: { box.value }, write: { box.value = .saved($0) })
    }

    private final class Box: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: Reading
        init(_ stored: Reading) { self.stored = stored }
        var value: Reading {
            get { lock.withLock { stored } }
            set { lock.withLock { stored = newValue } }
        }
    }

    private static func readKeychain() -> Reading {
        do {
            guard let data = try Keychain.read(account: PrivateBots.account) else { return .nothingSaved }
            guard let bots = try? JSONDecoder().decode(PrivateBots.self, from: data) else { return .unreadable }
            return .saved(bots)
        } catch {
            return .unreadable
        }
    }

    /// The list now. `fresh` skips the short memory of the last answer.
    public func reading(fresh: Bool = false) -> Reading {
        lock.lock(); defer { lock.unlock() }
        if let pinned { return pinned }
        if !fresh, let cached, Date().timeIntervalSince(cached.at) < Self.cacheLife { return cached.reading }
        let loaded = load()
        cached = (loaded, Date())
        return loaded
    }

    public func isPrivate(_ profile: String?, connection: UUID?, fresh: Bool = false) -> Bool {
        guard let profile else { return false }
        switch reading(fresh: fresh) {
        case .saved(let bots): return bots.isPrivate(profile, connection: connection)
        case .nothingSaved: return PrivateBots().isPrivate(profile, connection: connection)
        case .unreadable: return true
        }
    }

    /// A gateway's list, or nil when the saved lists can't be read. `places` finds the list a gateway
    /// paired again had before (see `PrivateBots.policy(for:at:)`).
    public func policy(for connection: UUID, at places: Set<String> = [], fresh: Bool = true) -> PrivateBots.Policy? {
        switch reading(fresh: fresh) {
        case .saved(let bots): return bots.policy(for: connection, at: places)
        case .nothingSaved: return PrivateBots().policy(for: connection)
        case .unreadable: return nil
        }
    }

    /// Changes one gateway's list. It reads afresh first, so another process's change is kept, and
    /// it won't write over a list it couldn't read. The list is noted as kept at `places`.
    @discardableResult
    public func change(_ connection: UUID, at places: Set<String> = [],
                       _ edit: (PrivateBots.Policy) -> PrivateBots.Policy) throws -> PrivateBots.Policy {
        lock.lock(); defer { lock.unlock() }
        let current: PrivateBots
        switch pinned ?? load() {
        case .saved(let bots): current = bots
        case .nothingSaved: current = PrivateBots()
        case .unreadable: throw Failure()
        }
        let updated = edit(current.policy(for: connection, at: places)).kept(at: places)
        let bots = current.replacing(updated, for: connection)
        try write(bots)
        if pinned != nil { pinned = .saved(bots) } else { cached = (.saved(bots), Date()) }
        return updated
    }

    func pin(_ reading: Reading?) {
        lock.lock(); pinned = reading; cached = nil; lock.unlock()
    }
}

/// The Private list as the Hermes side keeps it (`nollie-private-bots.json` in the main bot's
/// home, served by the workflow add-on), so the phone, the Mac and the add-ons agree.
struct PrivateBotsReply: Codable, Sendable {
    var profiles: [String]
    var saved: Bool?
}

/// Why a Private change didn't reach the gateway. The words are for the person.
public struct PrivateBotsSyncError: LocalizedError, Equatable {
    public enum Kind: Equatable, Sendable {
        /// Turned on here and kept, but the gateway hasn't heard yet.
        case notTold
        /// Turning it off needs the gateway's yes. The bot stays private.
        case notChanged
    }

    public let kind: Kind
    /// What went wrong underneath, for Advanced.
    public let detail: String

    public var errorDescription: String? {
        switch kind {
        case .notTold: String(localized: "Private is on here, but your gateway didn't get it. Try again.", table: "Core")
        case .notChanged: String(localized: "Couldn't turn Private off. It stays on for now. Try again.", table: "Core")
        }
    }
}

@MainActor
extension GatewayRuntime {
    static let privateBotsPath = "/api/plugins/nollie-workflow/private-bots"

    /// Where this gateway's Private list is kept: its address and, once known, which Hermes it is.
    var privatePlaces: Set<String> {
        Set([connection.gateway.description, connection.gatewayIdentity.map { "hermes:" + $0 }].compactMap { $0 })
    }

    /// Takes the gateway's list when it has one; otherwise gives it this device's (after the
    /// one-time carry-over). Either way the gateway now has a list of its own on this device, even
    /// one without the add-on. A choice the gateway never acknowledged is sent again first, on top
    /// of what the gateway holds now, and the gateway's own list can't replace it until it is.
    func syncPrivateBots(profiles: [String], store: PrivateBotsStore = .shared) async {
        let (id, places) = (connection.id, privatePlaces)
        guard let start = store.policy(for: id, at: places) else { return }
        let base = start.adoptingLegacyNames(from: profiles)
        if base.pending {
            let sent = base.revision
            if let list = try? await sendWaiting(base) {
                _ = try? store.change(id, at: places) {
                    $0.adoptingLegacyNames(from: profiles).acknowledged(revision: sent).taking(list)
                }
            }
            return
        }
        if let reply: PrivateBotsReply = try? await api.get(Self.privateBotsPath), reply.saved == true {
            _ = try? store.change(id, at: places) { $0.adoptingLegacyNames(from: profiles).taking(Set(reply.profiles)) }
        } else {
            _ = try? await tell(base.names)
            _ = try? store.change(id, at: places) { $0.adoptingLegacyNames(from: profiles) }
        }
    }

    /// Marks a bot Private (or not) on this device and on the gateway. Turning it on takes effect
    /// here at once and is kept even when the gateway can't be reached (then this throws, and
    /// `retryPrivateSync` or the next sync tries again). Turning it off waits for the gateway's yes.
    public func setPrivate(_ profile: String, _ on: Bool, store: PrivateBotsStore = .shared) async throws {
        let (id, places) = (connection.id, privatePlaces)
        if on {
            let chosen = try store.change(id, at: places) { $0.setting(profile, private: true) }
            let list: Set<String>
            do {
                list = try await sendWaiting(chosen)
            } catch {
                throw PrivateBotsSyncError(kind: .notTold, detail: error.localizedDescription)
            }
            try store.change(id, at: places) { $0.acknowledged(revision: chosen.revision).taking(list) }
        } else {
            guard let now = store.policy(for: id, at: places) else { throw PrivateBotsStore.Failure() }
            let wanted = now.setting(profile, private: false)
            do {
                var list = try await gatewayList() ?? wanted.names
                list = wanted.merging(into: list)
                list.remove(PrivateBots.key(profile))
                try await tell(list)
            } catch {
                throw PrivateBotsSyncError(kind: .notChanged, detail: error.localizedDescription)
            }
            // The gateway has it. The list may have moved on while we waited, so the choice is made again on top of it.
            try store.change(id, at: places) { current in
                let chosen = current.setting(profile, private: false)
                return chosen.acknowledged(revision: chosen.revision)
            }
        }
    }

    /// Whether the last choice on this gateway is still waiting for the gateway's yes.
    public func privateSyncPending(store: PrivateBotsStore = .shared) -> Bool {
        store.policy(for: connection.id, at: privatePlaces)?.pending == true
    }

    /// Sends a waiting choice again, on top of the gateway's list as it is now, since another
    /// device may have changed it in the meantime.
    public func retryPrivateSync(store: PrivateBotsStore = .shared) async throws {
        let (id, places) = (connection.id, privatePlaces)
        guard let waiting = store.policy(for: id, at: places), waiting.pending else { return }
        let list: Set<String>
        do {
            list = try await sendWaiting(waiting)
        } catch {
            throw PrivateBotsSyncError(kind: .notTold, detail: error.localizedDescription)
        }
        try store.change(id, at: places) { $0.acknowledged(revision: waiting.revision).taking(list) }
    }

    /// Reads the gateway's list as it is now, then sends it back with the bots this device turned
    /// Private added. Returns what was sent.
    private func sendWaiting(_ policy: PrivateBots.Policy) async throws -> Set<String> {
        let list = try await gatewayList().map(policy.merging(into:)) ?? policy.names
        try await tell(list)
        return list
    }

    /// The gateway's list, or nil when it has none yet or no add-on to keep one.
    private func gatewayList() async throws -> Set<String>? {
        do {
            let reply: PrivateBotsReply = try await api.get(Self.privateBotsPath)
            return reply.saved == true ? Set(reply.profiles.map(PrivateBots.key)) : nil
        } catch HermesAPIError.http(let status, _) where status == 404 {
            return nil
        }
    }

    /// Sends the whole list. Returns once the gateway says it kept it; a gateway without the
    /// add-on has nothing to tell, which is not a failure.
    private func tell(_ names: Set<String>) async throws {
        do {
            let reply: PrivateBotsReply = try await api.send("PUT", Self.privateBotsPath,
                                                             body: PrivateBotsReply(profiles: names.sorted(), saved: nil))
            guard reply.saved != false else { throw HermesAPIError.transport(String(localized: "The gateway didn't keep the list.", table: "Core")) }
        } catch HermesAPIError.http(let status, _) where status == 404 {
            return
        }
    }
}
