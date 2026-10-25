import Foundation

/// What Nollie's crew tools hand back for the chat: "I've added Scout to check new roles each
/// morning" with Meet and Undo, or a suggestion with Add and Not now. The crew add-on writes the
/// note; the buttons' answers go back to it from the app, never through the model.
public struct CrewNote: Hashable, Sendable {
    public struct Action: Hashable, Sendable, Identifiable {
        public enum Kind: String, Sendable { case meet, undo, add, notNow = "not_now" }
        public var kind: Kind
        public var label: String
        /// The member to open (Meet).
        public var profile: String?
        public var name: String?
        /// What the add-on needs back (Undo's token, the suggestion's id).
        public var token: String?
        public var suggestion: String?
        public var id: String { kind.rawValue }
    }

    public var status: String
    public var note: String
    public var profile: String?
    public var name: String?
    public var changes: [String]
    public var actions: [Action]

    public var isSuggestion: Bool { status == "suggestion" }

    /// The note in a crew tool's result; nil for other tools, failures and results with nothing
    /// to show the person.
    public static func parse(toolName: String, result: String?) -> CrewNote? {
        guard toolName.hasPrefix("crew_"), let data = result?.trimmingCharacters(in: .whitespacesAndNewlines).data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              obj["ok"] as? Bool == true, let status = obj["status"] as? String,
              let note = (obj["note"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !note.isEmpty
        else { return nil }
        let actions: [Action] = (obj["actions"] as? [[String: Any]] ?? []).compactMap { raw in
            guard let id = raw["id"] as? String, let kind = Action.Kind(rawValue: id) else { return nil }
            let label = (raw["label"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? Self.label(kind)
            return Action(kind: kind, label: label, profile: raw["profile"] as? String, name: raw["name"] as? String,
                          token: raw["token"] as? String, suggestion: raw["suggestion"] as? String)
        }
        // Only what the person should see: a change with its buttons, or a suggestion.
        guard !actions.isEmpty || ["retired", "removed", "restored", "paused", "active", "updated"].contains(status) else { return nil }
        return CrewNote(status: status, note: note, profile: obj["profile"] as? String, name: obj["name"] as? String,
                        changes: obj["changes"] as? [String] ?? [], actions: actions)
    }

    private static func label(_ kind: Action.Kind) -> String {
        switch kind {
        case .meet: "Meet"
        case .undo: "Undo"
        case .add: "Add"
        case .notNow: "Not now"
        }
    }
}

extension ToolActivity {
    /// A crew change or suggestion Nollie made in this call, shown as a card rather than a step.
    public var crewNote: CrewNote? {
        status == .done ? CrewNote.parse(toolName: name, result: resultText) : nil
    }
}

/// The add-on's answer to a tap.
public struct CrewReply: Codable, Sendable {
    public var ok: Bool?
    public var status: String?
    public var note: String?
}

@MainActor
extension GatewayRuntime {
    static let crewPath = "/api/plugins/nollie-crew"

    /// Undo or Add / Not now, answered by the person in the app. Returns the add-on's note.
    public func answerCrew(_ action: CrewNote.Action) async throws -> CrewReply {
        let reply: CrewReply
        switch action.kind {
        case .undo:
            guard let token = action.token else { throw URLError(.badURL) }
            reply = try await api.send("POST", Self.crewPath + "/undo", json: .object(["token": .string(token)]))
        case .add, .notNow:
            guard let id = action.suggestion, id.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }) else { throw URLError(.badURL) }
            reply = try await api.send("POST", Self.crewPath + "/suggestions/" + id,
                                       json: .object(["answer": .string(action.kind == .add ? "add" : "not_now")]))
        case .meet:
            return CrewReply(ok: true, status: nil, note: nil)
        }
        // A member came or went: the bot list follows.
        await loadProfiles()
        return reply
    }
}
