import Foundation

/// One of the starter looks. Ids are stable (they are stored per bot); names are for people.
public enum CharacterLookID: String, CaseIterable, Codable, Sendable, Identifiable {
    case nollie, kick, swell, spike, nite, duo

    public var id: String { rawValue }

    /// The look everyone starts with, and the default profile's look.
    public static let main: CharacterLookID = .nollie

    /// The name people see ("Nollie", "Kick").
    public var name: String { CharacterCatalog.shared.look(self).name }

    /// The look a bot has until someone picks another: the default profile is Nollie, every
    /// other profile a stable pick from the rest, the same on every device.
    public static func defaultLook(forProfile profile: String) -> CharacterLookID {
        let key = profile.trimmingCharacters(in: .whitespaces).lowercased()
        if key.isEmpty || key == "default" { return .main }
        let others = allCases.filter { $0 != .main }
        // FNV-1a over a salted name: Swift's own hash is seeded per launch, so it would not be
        // stable. The salt spreads the usual profile names over different looks.
        var hash: UInt32 = 2_166_136_261
        for byte in ("nollie." + key).utf8 { hash = (hash ^ UInt32(byte)) &* 16_777_619 }
        return others[Int(hash % UInt32(others.count))]
    }
}

/// What a bot is doing, as its character shows it. Raw values match the art package's states.
public enum CharacterState: String, CaseIterable, Codable, Sendable {
    case idle, listening, thinking, working
    case usingTool = "using_tool"
    case speaking
    case needsYou = "needs_you"
    /// A one-shot: a happy hop, then back to idle on its own.
    case done
    case error, asleep

    /// Short words for people ("Thinking it over").
    public var caption: String { CharacterCatalog.shared.manifest.states[rawValue]?.caption ?? rawValue }
}

/// Who stands in for a bot: one of the looks, or a photo the person chose. Saved per profile as
/// a string (`look:<id>` or `photo`) in `botAvatars`, and mirrored for the extensions.
public enum CharacterChoice: Hashable, Sendable {
    case look(CharacterLookID)
    case photo

    public var raw: String {
        switch self {
        case .look(let id): return "look:\(id.rawValue)"
        case .photo: return "photo"
        }
    }

    /// Nil for anything that is not a current choice: empty, or a value saved by the old faces
    /// ("studio:…", "initial", "animated:…"). Those bots get their profile's default look.
    public init?(raw: String) {
        if raw == "photo" { self = .photo; return }
        guard raw.hasPrefix("look:"), let id = CharacterLookID(rawValue: String(raw.dropFirst(5))) else { return nil }
        self = .look(id)
    }

    /// The choice a bot shows: its stored one if it is current, else its default look.
    public static func resolve(raw: String?, profile: String) -> CharacterChoice {
        raw.flatMap(CharacterChoice.init(raw:)) ?? .look(.defaultLook(forProfile: profile))
    }

    /// The look to draw, also for a photo bot when the photo is missing.
    public func look(forProfile profile: String) -> CharacterLookID {
        if case .look(let id) = self { return id }
        return .defaultLook(forProfile: profile)
    }

    /// A stored `{profile: raw}` map with the old faces' values dropped (photos stay), and
    /// whether anything changed. Run once at launch so the mirror only carries current values.
    public static func migrated(_ stored: [String: String]) -> (map: [String: String], changed: Bool) {
        let kept = stored.filter { CharacterChoice(raw: $0.value) != nil }
        return (kept, kept.count != stored.count)
    }
}
