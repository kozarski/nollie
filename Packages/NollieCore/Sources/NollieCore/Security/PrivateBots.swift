import Foundation

/// Bots the person flagged Private in Bot settings. What a private bot says stays out of
/// notification previews, the chat list's last line, Board activity and configuration backups.
/// The list sits in the shared Keychain, which lets the notification extension and alert helper read it too.
public struct PrivateBots: Codable, Equatable, Sendable {
    public static let account = "bots.private.v1"
    public private(set) var names: Set<String>
    /// Set once the one-time carry-over from older builds has run (see `adoptingLegacyNames`).
    public private(set) var settled: Bool

    public init(names: Set<String> = [], settled: Bool = false) {
        self.names = Set(names.map(Self.key))
        self.settled = settled
    }

    nonisolated(unsafe) private static var cached: PrivateBots?
    private static let lock = NSLock()

    /// The saved list (empty when nothing is saved yet). Read once per process, then kept.
    public static var current: PrivateBots {
        lock.lock(); defer { lock.unlock() }
        if let cached { return cached }
        let loaded = Keychain.getCodable(Self.self, account: account) ?? PrivateBots()
        cached = loaded
        return loaded
    }

    #if DEBUG
    /// Tests set the list for the process without touching the Keychain.
    public static func useForTesting(_ bots: PrivateBots) {
        lock.lock(); cached = bots; lock.unlock()
    }
    #endif

    public static func isPrivate(_ profile: String?) -> Bool {
        guard let profile else { return false }
        return current.contains(profile)
    }

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
        for name in profiles where ["private", "moss"].contains(Self.key(name)) { copy.names.insert(Self.key(name)) }
        copy.settled = true
        return copy
    }

    public func save() throws {
        try Keychain.setCodable(self, account: Self.account)
        Self.lock.lock(); Self.cached = self; Self.lock.unlock()
    }

    private static func key(_ name: String) -> String { name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
}

/// The Private list as the Hermes side keeps it (`nollie-private-bots.json` in the main bot's
/// home, served by the workflow add-on), so the phone, the Mac and the add-ons agree.
struct PrivateBotsReply: Codable, Sendable {
    var profiles: [String]
    var saved: Bool?
}

@MainActor
extension GatewayRuntime {
    static let privateBotsPath = "/api/plugins/nollie-workflow/private-bots"

    /// Takes the gateway's list when it has one; otherwise gives it this device's (after the
    /// one-time carry-over). A gateway without the add-on leaves the device's list as it is.
    func syncPrivateBots(profiles: [String]) async {
        var local = PrivateBots.current
        if !local.settled { local = local.adoptingLegacyNames(from: profiles) }
        if let reply: PrivateBotsReply = try? await api.get(Self.privateBotsPath), reply.saved == true {
            local = PrivateBots(names: Set(reply.profiles), settled: true)
        } else {
            let _: PrivateBotsReply? = try? await api.send("PUT", Self.privateBotsPath,
                                                            body: PrivateBotsReply(profiles: local.names.sorted(), saved: nil))
        }
        if local != PrivateBots.current { try? local.save() }
    }

    /// Marks a bot Private (or not) on this device and on the gateway.
    public func setPrivate(_ profile: String, _ on: Bool) async throws {
        let updated = PrivateBots.current.setting(profile, private: on)
        try updated.save()
        let _: PrivateBotsReply? = try? await api.send("PUT", Self.privateBotsPath,
                                                        body: PrivateBotsReply(profiles: updated.names.sorted(), saved: nil))
    }
}
