import Foundation
import NollieCore

/// Mute, from the weekly note, the same on every device: the gateway keeps it (`HelperMutes`), each device reads it
/// with its bots and keeps a copy here, so a reply that finishes while the gateway is out of reach still knows.
/// A muted helper's finished replies raise no banner here, and the Mac's iCloud alerts leave them out too. A copy in
/// the shared Keychain lets the notification extension deliver a pushed reply quietly, to the list only.
/// Questions, approvals and "started using your Mac" always come through: Ask first must never wait unseen.
enum HelperMute {
    static let key = "nollie.weekly.muted"

    private static func name(_ profile: String, connection: UUID) -> String {
        connection.uuidString + "/" + PrivateBots.key(profile)
    }

    static func isMuted(_ profile: String, connection: UUID, defaults: UserDefaults = .standard) -> Bool {
        (defaults.stringArray(forKey: key) ?? []).contains(name(profile, connection: connection))
    }

    /// This device's copy for one helper, after the gateway said so.
    static func set(_ muted: Bool, profile: String, connection: UUID, defaults: UserDefaults = .standard) {
        var names = Set(defaults.stringArray(forKey: key) ?? [])
        if muted { names.insert(name(profile, connection: connection)) } else { names.remove(name(profile, connection: connection)) }
        defaults.set(names.sorted(), forKey: key)
        if defaults == .standard { HelperMutes.share(Array(names)) }
    }

    /// This device's copy for a whole gateway, as the gateway answered: other gateways' are left as they are.
    static func take(_ muted: Set<String>, connection: UUID, defaults: UserDefaults = .standard) {
        let prefix = connection.uuidString + "/"
        let others = (defaults.stringArray(forKey: key) ?? []).filter { !$0.hasPrefix(prefix) }
        let names = (others + muted.map { prefix + PrivateBots.key($0) }).sorted()
        defaults.set(names, forKey: key)
        if defaults == .standard { HelperMutes.share(names) }
    }

    @MainActor private static var syncedAt: [UUID: Date] = [:]

    /// Reads the gateway's mutes, at most every 20 seconds unless `force`. An add-on without the route keeps this
    /// device's copy.
    @MainActor
    static func sync(_ runtime: GatewayRuntime, force: Bool = false) async {
        let gateway = runtime.connection.id
        if !force, let at = syncedAt[gateway], Date().timeIntervalSince(at) < 20 { return }
        syncedAt[gateway] = Date()
        guard let muted = try? await HelperMutes.load(api: runtime.api) else { return }
        take(muted.filter { !PrivateBots.isPrivate($0, connection: gateway) }, connection: gateway)
    }
}
