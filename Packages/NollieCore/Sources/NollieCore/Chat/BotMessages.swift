import Foundation

/// A message that one bot sends another. This happens by running the other bot's command line
/// quietly through the terminal tool, or through a dedicated message tool on newer gateways. In
/// both cases people should read "Messaged Scout" rather than a shell transcript.
public struct BotDelivery: Hashable, Sendable {
    public var message: String?

    public init(target: String, message: String? = nil) {
        (self.target, self.message) = (target, message)
    }

    public var target: String

    private enum Reading {
        static let commandArg = TextPattern(#""command"\s*:\s*"((?:[^"\\]|\\.)*)""#)
        static let peerDM = TextPattern(#"\bpeer\s+dm\s+("?)([A-Za-z0-9][A-Za-z0-9_/.-]{0,80})\1"#)
        static let profileFlag = TextPattern(#"(?:^|[\s;&|])(?:-p|--profile)[\s=]+("?)([a-z0-9][a-z0-9_-]{0,63})\1(?=\s|$)"#, caseInsensitive: true)
        static let shortProfileFlag = TextPattern(#"(?:^|[\s;&|])-p[\s=]+("?)([a-z0-9][a-z0-9_-]{0,63})\1(?=\s|$)"#, caseInsensitive: true)
        static let quietFlag = TextPattern(#"(?:^|\s)(?:-q|-Q|--quiet|--query-file)(?:\s|=|$)"#)
        static let botChatFlag = TextPattern(#"-c\s+["']?Bot Chat"#, caseInsensitive: true)
        static let chatWord = TextPattern(#"\bchat\b"#)
        static let targetArg = TextPattern(#""target"\s*:\s*"([^"]+)""#)
        static let messageArg = TextPattern(#""message"\s*:\s*"((?:[^"\\]|\\.)*)""#)
    }

    /// Looks for a message to another bot in one tool call. Nil when the call is something else.
    public static func parse(name: String, context: String?, argsText: String?) -> BotDelivery? {
        // The gateway's preview of a command is cut short; the arguments hold all of it.
        let command = argsText.flatMap { Reading.commandArg.capture(1, in: $0) }.map(Self.unescaped) ?? context ?? ""

        // A peer DM spells out its recipient and brings the sender's own -p; try it first.
        if let peer = Reading.peerDM.capture(2, in: command) {
            return BotDelivery(target: key(peer))
        }
        // The delivery runner wraps the command line; the bot to reach follows -p.
        if command.contains("--run-delivery"), let bot = Reading.shortProfileFlag.capture(2, in: command) {
            return BotDelivery(target: bot.lowercased())
        }
        // Running another bot's command line quietly is a delivery whatever the spelling: inline text,
        // a query file, or the bot's "Bot Chat" thread.
        let isQuiet = Reading.quietFlag.matches(command)
        let intoBotChat = Reading.botChatFlag.matches(command)
        let looksSent = isQuiet || intoBotChat || command.contains("Message from")
        if looksSent, Reading.chatWord.matches(command), let bot = Reading.profileFlag.capture(2, in: command) {
            return BotDelivery(target: bot.lowercased(), message: words(afterFlag: "-q", in: command))
        }
        // Newer gateways have a tool for it.
        return fromMessageTool(name: name, context: context, argsText: argsText)
    }

    /// The dedicated tool: its arguments name the bot, or failing that the preview does.
    private static func fromMessageTool(name: String, context: String?, argsText: String?) -> BotDelivery? {
        guard ["message_agent", "send_message_to_agent"].contains(name) else { return nil }
        let args = argsText ?? ""
        if let recipient = Reading.targetArg.capture(1, in: args) {
            return BotDelivery(target: key(recipient), message: Reading.messageArg.capture(1, in: args))
        }
        guard let preview = context, !preview.isEmpty else { return nil }
        return BotDelivery(target: key(preview))
    }

    private static func unescaped(_ raw: String) -> String {
        [("\\n", "\n"), ("\\\"", "\"")].reduce(raw) { $0.replacingOccurrences(of: $1.0, with: $1.1) }
    }

    /// The routing alias for a bot as people and tools write it: "@Dr. Foo", "scribe@laptop" and
    /// "peer/scribe" become "dr. foo", "scribe" and "scribe".
    public static func key(_ value: String) -> String {
        var name = value.trimmingCharacters(in: .whitespaces)
        if name.first == "@" { name.removeFirst() }
        if let at = name.lastIndex(of: "@") { name = String(name[..<at]) }
        let last = name.split(separator: "/").last.map(String.init) ?? name
        return last.lowercased()
    }

    /// The quoted text that follows a flag such as `-q`, without any "Message from" lead-in.
    private static func words(afterFlag flag: String, in command: String) -> String? {
        guard let hit = command.range(of: flag + " ") else { return nil }
        let rest = command[hit.upperBound...].drop { $0 == " " || $0 == "\t" }
        guard let quote = rest.first, quote == "\"" || quote == "'" else { return nil }
        let inside = rest.dropFirst()
        let said = inside.firstIndex(of: quote).map { String(inside[..<$0]) } ?? String(inside)
        return AgentMessage.parse(said)?.body ?? said
    }
}

/// A message that came in from another bot, in either of the two shapes the gateway files it.
public struct AgentMessage: Hashable, Sendable {
    public var body: String
    public var sender: String
    public var handle: String?

    public init(sender: String, handle: String?, body: String) {
        (self.sender, self.handle, self.body) = (sender, handle, body)
    }

    private enum Reading {
        static let friendly = TextPattern(#"^Message from (?:🤖\s*)?([^:\n(]{1,64}?)(?:\s*\(@([a-z0-9][a-z0-9_-]{0,63})(?:@[a-zA-Z0-9][a-zA-Z0-9_-]{0,63})?\))?:\s*([\s\S]*)$"#)
        static let bracketed = TextPattern(#"^\[Message from agent '([^']{1,64})'\]\s*([\s\S]*)$"#)
    }

    public static func parse(_ text: String) -> AgentMessage? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let g = Reading.friendly.groups(in: trimmed), let who = g[1], let body = g[3] {
            return AgentMessage(sender: who.trimmingCharacters(in: .whitespaces), handle: g[2], body: body)
        }
        if let g = Reading.bracketed.groups(in: trimmed), let who = g[1], let body = g[2] {
            return AgentMessage(sender: who, handle: nil, body: body)
        }
        return nil
    }

    /// The sender's routing alias, in the same form as a delivery target.
    public var key: String { BotDelivery.key(handle ?? sender) }
}
