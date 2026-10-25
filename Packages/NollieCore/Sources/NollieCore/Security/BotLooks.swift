import Foundation

/// Each bot's look, written by the app to the Keychain group everyone shares. Notification extensions
/// have no access to the app's defaults or container, so they read this copy to draw the same bot.
/// All tables are keyed by profile name.
public struct BotLooks: Codable, Sendable {
    public static let account = "botLooks"

    /// Photo avatars: a JPEG of about 128 px.
    public var photos: [String: Data] = [:]
    /// "look:<id>" or "photo" (see `CharacterChoice`).
    public var avatars: [String: String] = [:]
    /// "#RRGGBB".
    public var colors: [String: String] = [:]

    public init(colors: [String: String] = [:], avatars: [String: String] = [:], photos: [String: Data] = [:]) {
        (self.colors, self.avatars, self.photos) = (colors, avatars, photos)
    }

    public static func load() -> BotLooks {
        guard let mirrored = Keychain.getCodable(BotLooks.self, account: account) else { return BotLooks() }
        return mirrored
    }

    public func save() {
        try? Keychain.setCodable(self, account: Self.account)
    }

    /// The name this bot is filed under. The app mirrors both profile and label, so each is tried
    /// as written, then either one ignoring case. nil when the bot is not here.
    public func key(profile: String, label: String) -> String? {
        let names = [profile, label].filter { !$0.isEmpty }
        let known = Set(colors.keys).union(avatars.keys)
        if let exact = names.first(where: known.contains) { return exact }
        let folded = names.map { $0.lowercased() }
        return known.first { folded.contains($0.lowercased()) }
    }

    /// What to draw for a bot filed under `key`. A photo choice without a photo falls back to the
    /// bot's own look.
    public func choice(key: String?, profile: String) -> CharacterChoice {
        let picked = CharacterChoice.resolve(raw: key.flatMap { avatars[$0] }, profile: profile)
        guard picked == .photo else { return picked }
        let photo = key.flatMap { photos[$0] }
        return photo == nil ? .look(picked.look(forProfile: profile)) : picked
    }
}
