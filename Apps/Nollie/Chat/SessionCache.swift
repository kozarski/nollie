import Foundation
import NollieCore

/// Remembers each gateway's and bot's latest chat list. The Chats tab paints it right away
/// on launch while a fresh list loads. Stored as small JSON blobs in UserDefaults and
/// wiped from Settings > Appearance.
enum SessionCache {
    static let prefix = ["sessions", "cache", ""].joined(separator: ".")

    static func entryName(for gateway: UUID, bot: String?) -> String {
        [prefix + gateway.uuidString, bot ?? "-"].joined(separator: ".")
    }

    private static func decode(_ stored: Any?) -> [StoredSession]? {
        (stored as? Data).flatMap { try? JSONDecoder().decode([StoredSession].self, from: $0) }
    }

    private static var stored: [String: Any] {
        UserDefaults.standard.dictionaryRepresentation().filter { $0.key.hasPrefix(prefix) }
    }

    static func load(connection: UUID, profile: String?) -> [StoredSession] {
        let name = entryName(for: connection, bot: profile)
        return decode(UserDefaults.standard.object(forKey: name)) ?? []
    }

    /// Fallback for a first launch with a new bot: the biggest list stored for this gateway under
    /// any bot, so the page has something to show until the real one arrives.
    static func loadAny(connection: UUID) -> [StoredSession] {
        let stem = prefix + connection.uuidString + "."
        return stored
            .compactMap { $0.key.hasPrefix(stem) ? decode($0.value) : nil }
            .max { $0.count < $1.count } ?? []
    }

    static func save(_ sessions: [StoredSession], connection: UUID, profile: String?) {
        guard let blob = try? JSONEncoder().encode(sessions) else { return }
        UserDefaults.standard.set(blob, forKey: entryName(for: connection, bot: profile))
    }

    static func clearAll() {
        stored.keys.forEach { UserDefaults.standard.removeObject(forKey: $0) }
    }

    static var approximateBytes: Int {
        stored.values.reduce(0) { $0 + (($1 as? Data)?.count ?? 0) }
    }
}
