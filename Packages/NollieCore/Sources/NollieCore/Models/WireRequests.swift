import Foundation

// Questions the gateway puts to the app while a chat is running. Each one is a request from
// the server that waits for an answer (approve a command, answer a question, supply a value).

/// A command or tool call waiting for a yes or no.
public struct ApprovalRequest: Sendable, Identifiable, Hashable, Codable {
    /// The scope that choosing "Session" or "Always" would grant: a command pattern such as
    /// `rm -rf`, a whole tool like `execute_code`, or a rule scoped to a tool like
    /// `write_file:<hash>`. It is never the exact command line. Nil from older gateways.
    public var patternKey: String?
    public var smartDenied: Bool?
    public var toolName: String?
    public var choices: [String]?
    public var description: String?
    public var command: String?
    public var sessionId: String
    public var requestId: String

    public init(requestId: String,
                sessionId: String,
                command: Optional<String> = nil,
                description: Optional<String> = nil,
                choices: Optional<[String]> = nil,
                toolName: Optional<String> = nil,
                smartDenied: Optional<Bool> = nil,
                patternKey: Optional<String> = nil) {
        self.patternKey = patternKey
        self.smartDenied = smartDenied
        self.toolName = toolName
        self.choices = choices
        self.description = description
        self.command = command
        self.sessionId = sessionId
        self.requestId = requestId
    }

    public var id: String { requestId }

    private static let usualChoices = ["once", "session", "always", "deny"]

    /// The buttons to offer: the gateway's list, or the usual four when it sent none.
    public var offeredChoices: [String] {
        guard let choices, !choices.isEmpty else { return Self.usualChoices }
        return choices
    }

    /// What choosing "Always" would allow, in words.
    public var alwaysScope: String {
        let key = (patternKey ?? "").trimmingCharacters(in: .whitespaces)
        switch key {
        case "":
            return String(localized: "this kind of command", table: "Core", comment: "Safety: what Always allow covers, as in: Always allow this kind of command?")
        case _ where key.hasPrefix("tirith:"):
            return String(localized: "this finding (session only)", table: "Core", comment: "Safety: what Always allow covers")
        case _ where key.hasPrefix("cua:"):
            return Self.screenScope(of: key)
        case _ where key.contains(":"):
            let tool = String(key.prefix { $0 != ":" })
            return String(localized: "the \(tool) tool, for requests like this one", table: "Core", comment: "Safety: what Always allow covers; the value is a tool's name")
        case toolName, "execute_code":
            return String(localized: "the \(key) tool", table: "Core", comment: "Safety: what Always allow covers; the value is a tool's name")
        default:
            return String(localized: "commands matching “\(key)”", table: "Core", comment: "Safety: what Always allow covers; the value is a command pattern")
        }
    }

    /// Screen control keys look like `cua:<action>:<background|foreground>`.
    private static func screenScope(of key: String) -> String {
        let pieces = key.split(separator: ":").map(String.init)
        let action = pieces.count > 1 ? pieces[1] : ""
        let inFront = pieces.count > 2 && pieces[2] == "foreground"
        switch (action, inFront) {
        case ("", true): return String(localized: "screen control on this Mac's screen, in front", table: "Core", comment: "Safety: what Always allow covers; keep exact meaning")
        case ("", false): return String(localized: "screen control on this Mac's screen, in the background", table: "Core", comment: "Safety: what Always allow covers; keep exact meaning")
        case ("type", true): return String(localized: "all typing on this Mac's screen, in front", table: "Core", comment: "Safety: what Always allow covers; keep exact meaning")
        case ("type", false): return String(localized: "all typing on this Mac's screen, in the background", table: "Core", comment: "Safety: what Always allow covers; keep exact meaning")
        case ("key", true): return String(localized: "every key press on this Mac's screen, in front", table: "Core", comment: "Safety: what Always allow covers; keep exact meaning")
        case ("key", false): return String(localized: "every key press on this Mac's screen, in the background", table: "Core", comment: "Safety: what Always allow covers; keep exact meaning")
        case ("set_value", true): return String(localized: "every field change on this Mac's screen, in front", table: "Core", comment: "Safety: what Always allow covers; keep exact meaning")
        case ("set_value", false): return String(localized: "every field change on this Mac's screen, in the background", table: "Core", comment: "Safety: what Always allow covers; keep exact meaning")
        case ("focus_app", true): return String(localized: "every app switch on this Mac's screen, in front", table: "Core", comment: "Safety: what Always allow covers; keep exact meaning")
        case ("focus_app", false): return String(localized: "every app switch on this Mac's screen, in the background", table: "Core", comment: "Safety: what Always allow covers; keep exact meaning")
        default:
            let name = action.replacingOccurrences(of: "_", with: "-")
            return inFront
                ? String(localized: "every \(name) on this Mac's screen, in front", table: "Core", comment: "Safety: what Always allow covers; the value is the gateway's action name")
                : String(localized: "every \(name) on this Mac's screen, in the background", table: "Core", comment: "Safety: what Always allow covers; the value is the gateway's action name")
        }
    }
}

public struct ClarifyQuestion: Codable, Hashable, Sendable, Identifiable {
    public let multiSelect: Bool?
    public let choices: [String]?
    public let qid: String
    public let question: String

    public var id: String { qid }
}

/// The bot asks something. It is either one question or a list of them, with `answers`
/// filled in once some are answered.
public struct ClarifyRequest: Codable, Hashable, Sendable {
    public let multiSelect: Bool?
    public let choices: [String]?
    public let questions: [ClarifyQuestion]?
    public let answers: [String: String]?
    public let sessionId: String
    public let question: String?
}

/// The bot needs a value from the person, such as a key for a service.
public struct ValuePromptRequest: Codable, Hashable, Sendable {
    public let sessionId: String
    public let command: String?
    public let envVar: String?
    public let prompt: String?
    public let backend: String?
    public let displayName: String?
    public let origin: String?
    public let site: String?
    public let hint: String?
}
