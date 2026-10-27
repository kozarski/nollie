import Foundation

/// One bot's look as the gateway keeps it for all of the person's devices: a character id and a
/// colour, either of which may be missing (that device left the default). A photo never goes there.
public struct SharedBotLook: Codable, Equatable, Sendable {
    public var look: String?
    public var colour: String?

    public init(look: String? = nil, colour: String? = nil) {
        (self.look, self.colour) = (look, colour)
    }

    /// What this device has saved for a bot: its character pick (a photo stays here, so it counts
    /// as none) and its colour pick. Nil when there is neither.
    public init?(avatar: String?, colour: String?) {
        let look = avatar.flatMap(CharacterChoice.init(raw:)).flatMap { choice -> String? in
            if case .look(let id) = choice { return id.rawValue }
            return nil
        }
        let picked = colour.flatMap { $0.isEmpty ? nil : $0 }
        guard look != nil || picked != nil else { return nil }
        self.init(look: look, colour: picked)
    }
}

/// Keeps each bot's look the same on every device. Looks used to stay on the device where they were
/// picked, so a Mac guessed a different character and colour for a helper added on a phone. The
/// choices now live with the gateway (the workflow add-on's `bot-looks` route); each device takes
/// them, and offers its own for bots the gateway has no look for yet.
public enum SharedBotLooks {
    public static let path = "/api/plugins/nollie-workflow/bot-looks"

    /// What the route answers.
    public struct Reply: Decodable, Sendable {
        public var bots: [String: SharedBotLook]?
        public var saved: Bool?
    }

    /// What a sync does on this device.
    public struct Plan: Equatable, Sendable {
        /// This device's choice tables after taking the gateway's looks.
        public var avatars: [String: String]
        public var colours: [String: String]
        /// Looks this device has and the gateway lacks, to send.
        public var offers: [String: SharedBotLook]
    }

    /// Takes the gateway's look for each of `bots` (the gateway's own, private ones left out), except
    /// where a change made here is still on its way (`unsent`). A photo picked here stays; its bot's
    /// colour still follows. A bot the gateway has no look for keeps this device's, which is offered.
    public static func plan(shared: [String: SharedBotLook], avatars: [String: String], colours: [String: String],
                            bots: [String], unsent: Set<String>) -> Plan {
        var plan = Plan(avatars: avatars, colours: colours, offers: [:])
        for bot in bots {
            let mine = SharedBotLook(avatar: avatars[bot], colour: colours[bot])
            if unsent.contains(bot) { continue }
            guard let theirs = shared[bot] else {
                if let mine { plan.offers[bot] = mine }
                continue
            }
            // A look this build doesn't know (a newer app picked it) leaves this device's as it is.
            let known = theirs.look.map { CharacterLookID(rawValue: $0) != nil } ?? true
            if avatars[bot] != CharacterChoice.photo.raw, known {
                plan.avatars[bot] = theirs.look.flatMap(CharacterLookID.init(rawValue:)).map { CharacterChoice.look($0).raw }
            }
            plan.colours[bot] = theirs.colour.flatMap { $0.isEmpty ? nil : $0 }
        }
        return plan
    }
}
