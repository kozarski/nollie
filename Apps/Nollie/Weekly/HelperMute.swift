import Foundation
import NollieCore

/// Mute, from the weekly note: this device raises no banner when a muted helper finishes a reply. Questions and
/// approvals still come through, since Ask first must never wait unseen, and so does "started using your Mac".
/// Kept on this device only, per gateway, so muting Scout on the iPhone leaves the Mac as it was.
enum HelperMute {
    static let key = "nollie.weekly.muted"

    private static func name(_ profile: String, connection: UUID) -> String {
        connection.uuidString + "/" + PrivateBots.key(profile)
    }

    static func isMuted(_ profile: String, connection: UUID, defaults: UserDefaults = .standard) -> Bool {
        (defaults.stringArray(forKey: key) ?? []).contains(name(profile, connection: connection))
    }

    static func set(_ muted: Bool, profile: String, connection: UUID, defaults: UserDefaults = .standard) {
        var names = Set(defaults.stringArray(forKey: key) ?? [])
        if muted { names.insert(name(profile, connection: connection)) } else { names.remove(name(profile, connection: connection)) }
        defaults.set(names.sorted(), forKey: key)
    }

    /// Nollie's own main bot reaches the iPhone through the Mac's iCloud alerts too, which a phone can't quiet yet,
    /// so only the other helpers offer Mute.
    static func offered(for profile: String) -> Bool { PrivateBots.key(profile) != "default" }
}
