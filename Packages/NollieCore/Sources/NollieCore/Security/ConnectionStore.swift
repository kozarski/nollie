import Foundation
import Observation

/// The gateways this device knows. The list and each gateway's secrets sit in the Keychain; the
/// UserDefaults only remember which one is open.
@MainActor
@Observable
public final class ConnectionStore {
    private enum Slot {
        static let index = "connections.index"
        static let activeDefaultsKey = "activeConnectionID"
        static func secrets(_ id: UUID) -> String { "secrets.\(id.uuidString)" }
    }

    public private(set) var connections: [GatewayConnection]

    /// Sign-ins the person chose to keep, guarded by Face ID or the passcode. Stored apart from
    /// `secrets(for:)` so code that copies those never sees these. The vault is opened lazily, which
    /// means the extensions, which never ask, never read it.
    @ObservationIgnored public lazy var remembered = RememberedSignInVault.standard()

    /// What this device had before a demo began, and whether the Keychain was already in memory.
    private var beforeDemo: (connections: [GatewayConnection], active: UUID?, keychainInMemory: Bool)?

    /// A "Try a demo" session is under way: the list holds only the demo and nothing is saved.
    public var isDemo: Bool { beforeDemo != nil }

    public var activeConnectionID: UUID? {
        didSet {
            // A demo leaves no trace: the choice it makes is not kept.
            guard beforeDemo == nil else { return }
            let defaults = UserDefaults.standard
            if let activeConnectionID {
                defaults.set(activeConnectionID.uuidString, forKey: Slot.activeDefaultsKey)
            } else {
                defaults.removeObject(forKey: Slot.activeDefaultsKey)
            }
        }
    }

    public init() {
        let saved = Keychain.getCodable([GatewayConnection].self, account: Slot.index) ?? []
        connections = saved
        let lastActive = UserDefaults.standard.string(forKey: Slot.activeDefaultsKey).flatMap(UUID.init(uuidString:))
        if let lastActive, saved.contains(where: { $0.id == lastActive }) {
            activeConnectionID = lastActive
        } else {
            activeConnectionID = saved.first?.id
        }
    }

    public var active: GatewayConnection? { connection(id: activeConnectionID) }

    public func connection(id: UUID) -> GatewayConnection? {
        connections.first(where: { $0.id == id })
    }

    private func connection(id: UUID?) -> GatewayConnection? {
        id.flatMap { wanted in connections.first(where: { $0.id == wanted }) }
    }

    /// Adds or replaces a gateway together with its secrets. Everything is written to the Keychain
    /// before the in-memory list changes, so a failure leaves the list as it was.
    public func upsert(_ connection: GatewayConnection, secrets: GatewaySecrets) throws {
        var entry = connection
        entry.hasAccessHeaders = secrets.access.isConfigured
        try Keychain.setCodable(secrets, account: Slot.secrets(entry.id))
        var next = connections
        if let at = next.firstIndex(where: { $0.id == entry.id }) {
            next[at] = entry
        } else {
            next.append(entry)
        }
        try Keychain.setCodable(next, account: Slot.index)
        connections = next
        if activeConnectionID == nil { activeConnectionID = entry.id }
    }

    /// Changes what the list shows about a gateway (name, notes) without touching its secrets.
    public func updateMetadata(_ connection: GatewayConnection) {
        guard let at = connections.firstIndex(where: { $0.id == connection.id }) else { return }
        connections[at] = connection
        saveIndex()
    }

    public func secrets(for id: UUID) -> GatewaySecrets {
        let stored = Keychain.getCodable(GatewaySecrets.self, account: Slot.secrets(id))
        return stored ?? GatewaySecrets()
    }

    public func saveSecrets(_ secrets: GatewaySecrets, for id: UUID) {
        _ = try? Keychain.setCodable(secrets, account: Slot.secrets(id))
        guard let row = connections.indices.first(where: { connections[$0].id == id }) else { return }
        connections[row].hasAccessHeaders = secrets.access.isConfigured
        saveIndex()
    }

    /// Starts a demo: the saved gateways are set aside untouched, the Keychain goes to memory
    /// (so nothing real is read or changed) and `demo` is the only gateway there is.
    public func beginDemo(_ demo: GatewayConnection) {
        guard beforeDemo == nil else { return }
        beforeDemo = (connections, activeConnectionID, Keychain.memoryOnly)
        Keychain.memoryOnly = true
        connections = []
        try? upsert(demo, secrets: GatewaySecrets(sessionToken: "demo"))
        activeConnectionID = demo.id
    }

    /// Ends the demo and puts the saved gateways back exactly as they were.
    public func endDemo() {
        guard let before = beforeDemo else { return }
        beforeDemo = nil
        if !before.keychainInMemory {
            Keychain.clearMemory()
            Keychain.memoryOnly = false
        }
        connections = before.connections
        activeConnectionID = before.active
    }

    /// Removes a gateway and everything kept for it.
    public func delete(id: UUID) {
        connections.removeAll(where: { $0.id == id })
        Keychain.delete(account: Slot.secrets(id))
        remembered.forget(id)          // needs no Face ID
        GatewayTrust.shared.forget(owner: id)   // a linked Mac's pin stops being trusted
        saveIndex()
        if activeConnectionID == id { activeConnectionID = connections.first?.id }
    }

    private func saveIndex() {
        try? Keychain.setCodable(connections, account: Slot.index)
    }
}
