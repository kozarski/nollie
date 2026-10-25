import Foundation

/// A table of text values kept in UserDefaults as one JSON string, such as each bot's colour or
/// look. Reading never fails: anything unreadable is an empty table.
struct DefaultsTable {
    let key: String

    func read() -> [String: String] {
        Self.decode(UserDefaults.standard.string(forKey: key) ?? "")
    }

    func write(_ table: [String: String]) {
        guard let data = try? JSONEncoder().encode(table), let text = String(data: data, encoding: .utf8) else { return }
        UserDefaults.standard.set(text, forKey: key)
    }

    /// The table in a stored string. Views that watch the string with @AppStorage use this too.
    static func decode(_ text: String) -> [String: String] {
        guard let data = text.data(using: .utf8) else { return [:] }
        return (try? JSONDecoder().decode([String: String].self, from: data)) ?? [:]
    }
}
