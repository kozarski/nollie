import Foundation

/// Output tokens, time and speed for one turn of the bot.
public struct TurnStats: Hashable, Sendable {
    public var seconds: Double
    public var outputTokens: Int
    /// True when the count came from the gateway's usage numbers, false for a guess from length.
    public var exact: Bool

    public init(outputTokens: Int, seconds: Double, exact: Bool) {
        (self.outputTokens, self.seconds, self.exact) = (outputTokens, seconds, exact)
    }

    public var tokensPerSecond: Double? {
        guard seconds > 0.5 else { return nil }
        return Double(outputTokens) / seconds
    }

    /// Reads like "930 tokens · 41 tok/s · 22.7s", and a count that was estimated carries a leading "~".
    public var label: String {
        let count = exact ? String(localized: "\(outputTokens) tokens", table: "Core")
            : String(localized: "~\(outputTokens) tokens", table: "Core", comment: "An estimated number of tokens")
        let rate = tokensPerSecond.map { perSecond in
            let figure = perSecond.formatted(.number.precision(.fractionLength(0)).grouping(.never))
            return String(localized: "\(figure) tok/s", table: "Core", comment: "Tokens a second")
        }
        let time: String
        if seconds >= 60 {
            let minutes = (seconds / 60).formatted(.number.precision(.fractionLength(1)).grouping(.never))
            time = String(localized: "\(minutes) min", table: "Core", comment: "How long a reply took, in minutes")
        } else {
            let shown = seconds.formatted(.number.precision(.fractionLength(1)).grouping(.never))
            time = String(localized: "\(shown)s", table: "Core", comment: "How long a reply took, in seconds")
        }
        return [count, rate, time].compactMap { $0 }.joined(separator: " · ")
    }

    /// Exact when usage before and after the turn shows growth; otherwise four characters a token.
    public static func make(outputBefore: Int? = nil, outputAfter: Int? = nil, streamedCharacters: Int, seconds: Double) -> TurnStats {
        if let before = outputBefore, let after = outputAfter, before < after {
            return TurnStats(outputTokens: after - before, seconds: seconds, exact: true)
        }
        let guess = max(1, streamedCharacters / 4)
        return TurnStats(outputTokens: guess, seconds: seconds, exact: false)
    }
}

/// Text the gateway inserted in place of the person's own message, such as a background job checking
/// in, the prompt of a scheduled run or a system line. Rendered as a small collapsed notice, not a bubble.
public struct InjectedNote: Hashable, Sendable {
    /// What the note is, for its symbol. The title is in the person's language, so it is not read for this.
    public enum Kind: Hashable, Sendable {
        case backgroundFinished, backgroundFailed, scheduledRun, subagent, subagentFailed, gateway
    }

    public var title: String
    public var body: String
    public var kind: Kind = .gateway
    public var failed: Bool { kind == .backgroundFailed || kind == .subagentFailed }

    private static let cronName = TextPattern(#"\[Cronjob "([^"]+)""#)

    public static func parse(_ text: String) -> InjectedNote? {
        let note = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard note.hasPrefix("[") else { return nil }
        let lower = note.lowercased()
        guard let (title, kind) = title(for: note, lowercased: lower) else { return nil }
        return InjectedNote(title: title, body: note, kind: kind)
    }

    private static func title(for note: String, lowercased lower: String) -> (String, Kind)? {
        if lower.hasPrefix("[important: background process") || lower.hasPrefix("[background process") {
            let cleanExit = lower.contains("completed normally") || lower.contains("exit code 0")
            let failed = lower.contains("failed") || lower.contains("non-zero") || (lower.contains("exit code") && !cleanExit)
            return failed ? (String(localized: "Background process failed", table: "Core"), .backgroundFailed)
                : (String(localized: "Background process finished", table: "Core"), .backgroundFinished)
        }
        if lower.hasPrefix("[cronjob") {
            let title = cronName.capture(1, in: note).map { String(localized: "Scheduled run · \($0)", table: "Core", comment: "The value is a schedule's name") }
            return (title ?? String(localized: "Scheduled run", table: "Core"), .scheduledRun)
        }
        // Reports from delegated helpers, passed to the bot as plain text with a bracketed heading (async
        // delegation, batch or task results). They are machine text and must never read as the person's words.
        if lower.hasPrefix("[async delegation") {
            let heading = lower.prefix { $0 != "]" }
            if heading.contains("fail") { return (String(localized: "Subagent failed", table: "Core"), .subagentFailed) }
            return heading.contains("batch") ? (String(localized: "Subagents reported back", table: "Core"), .subagent)
                : (String(localized: "Subagent reported back", table: "Core"), .subagent)
        }
        if ["[important:", "[system", "[note"].contains(where: { lower.hasPrefix($0) }) {
            return (String(localized: "Note from the gateway", table: "Core"), .gateway)
        }
        return nil
    }
}

/// Raised when the gateway cannot launch the bot's model, most often since a provider's command line
/// tool or key is absent from its machine. Carries enough for the chat to say so and offer a different model.
public struct StartFailure: Hashable, Sendable {
    public var reason: String
    public var provider: String?

    private static let missingCLI = TextPattern(#"[Cc]ould not find the '([^']+)' CLI command"#)
    private static let providerName = TextPattern(#"provider '([^']+)'"#)

    public static func parse(_ text: String) -> StartFailure? {
        let lower = text.lowercased()
        let cliMissing = lower.contains("cli command") && lower.contains("could not find")
        guard lower.contains("could not start the assistant") || cliMissing else { return nil }

        var reason = text
        if let marker = reason.range(of: "Details:") { reason = String(reason[marker.upperBound...]) }
        if let advice = reason.range(of: "Check the model") { reason = String(reason[..<advice.lowerBound]) }
        reason = reason.replacingOccurrences(of: "..", with: ".")
        return StartFailure(reason: reason.trimmingCharacters(in: .whitespacesAndNewlines),
                            provider: missingCLI.capture(1, in: text) ?? providerName.capture(1, in: text))
    }
}
