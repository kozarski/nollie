import Foundation

/// Gathers the pieces of a reply as they stream in, and settles them when the turn completes.
public struct StreamAssembler: Sendable {
    public private(set) var isStreaming = Bool()
    public private(set) var deltaCount = Int.zero
    public private(set) var reasoning = String()
    public private(set) var text = String()

    public init() {}

    public mutating func reset() {
        text = ""
        reasoning = ""
        deltaCount = 0
        isStreaming = false
    }

    public mutating func start() {
        reset()
        isStreaming = true
    }

    /// Adds a piece of the reply. A stream that was never started starts here.
    public mutating func appendDelta(_ chunk: String) {
        startIfNeeded()
        text.append(chunk)
        deltaCount += 1
    }

    public mutating func appendReasoning(_ chunk: String) {
        startIfNeeded()
        reasoning.append(chunk)
    }

    private mutating func startIfNeeded() {
        if isStreaming == false { start() }
    }

    /// Ends the stream. The gateway's final text, when it sent one, is the authority.
    public mutating func complete(finalText: String?) -> String {
        isStreaming = false
        if let authoritative = finalText, authoritative.isEmpty == false { text = authoritative }
        return text
    }

    private static let thinkingTags = ["<think>", "</think>", "<reasoning>", "</reasoning>",
                                       "<REASONING_SCRATCHPAD>", "</REASONING_SCRATCHPAD>"]

    /// Prepares text to compare an answer against reasoning: tags stripped, whitespace runs
    /// collapsed to single spaces, ends trimmed.
    public static func normalized(_ s: String) -> String {
        let stripped = thinkingTags.reduce(s) { $0.replacingOccurrences(of: $1, with: " ") }
        let words = stripped.split(whereSeparator: { $0.isWhitespace })
        return words.joined(separator: " ")
    }

    /// The reasoning that stays on a completed reply.
    ///
    /// Some models send their full answer as reasoning and no content at all. The gateway turns that
    /// into the reply, so a reasoning card would just say it twice and is left out; anything thought
    /// before the answer is kept. If the reply streamed text of its own, its reasoning was real and
    /// stays as it came. `gatewayReasoning` is the reasoning field of `message.complete`, which
    /// equals the answer when the turn was promoted.
    public static func settledReasoning(streamedText: String, reasoning: String, finalText: String, gatewayReasoning: String? = .none) -> String? {
        let thoughts = reasoning.trimmingCharacters(in: .whitespacesAndNewlines)
        // Real thinking with its own streamed reply, or nothing to settle at all.
        if thoughts.isEmpty { return nil }
        if streamedText.contains(where: { !$0.isWhitespace }) { return reasoning }

        let answer = normalized(finalText)
        let thinking = normalized(thoughts)
        if answer.isEmpty { return reasoning }
        if answer == thinking { return nil }

        // The answer closes out the reasoning, so everything before it was thinking.
        if let start = suffixStart(of: finalText, in: thoughts) {
            let before = String(thoughts[..<start]).trimmingCharacters(in: .whitespacesAndNewlines)
            return before.isEmpty ? nil : before
        }
        // A promoted turn shows up with the answer repeated as reasoning. Reasoning that contains the
        // answer, or part of it (the stream was picked up midway after a reconnect), counts as that
        // answer.
        guard let sent = gatewayReasoning, normalized(sent) == answer else { return reasoning }
        let isThatAnswer = thinking.contains(answer) || answer.contains(thinking)
        return isThatAnswer ? nil : reasoning
    }

    /// Locates `suffix` at the tail of `text`, ignoring whitespace in both because chunk edges
    /// move it. Gives nil if `text` ends differently.
    static func suffixStart(of suffix: String, in text: String) -> String.Index? {
        let wanted = suffix.filter { !$0.isWhitespace }
        let solid = text.indices.filter { !text[$0].isWhitespace }
        guard !wanted.isEmpty, solid.count >= wanted.count else { return nil }
        let first = solid.count - wanted.count
        for (offset, letter) in wanted.enumerated() where text[solid[first + offset]] != letter { return nil }
        return solid[first]
    }

    /// The final `message.complete` text is the full turn. Tool calls may have split the stream, so
    /// its opening part is already shown in earlier bubbles and the last bubble should hold just what
    /// follows. If the two texts no longer agree, the whole text is returned as the best guess.
    public static func tail(ofFinalText full: String, alreadySealed sealed: String) -> String {
        if sealed.isEmpty { return full }
        if full.hasPrefix(sealed) {
            let rest = full.dropFirst(sealed.count)
            return withoutLeadingBlankLines(String(rest))
        }

        // Chunks and the final text can differ only in whitespace (chunk boundaries, a trailing
        // newline). Compare ignoring whitespace while tracking where the sealed text ends in `full`,
        // so a cosmetic difference cannot show the turn twice.
        var cursor = full.startIndex
        for letter in sealed where !letter.isWhitespace {
            guard let hit = full[cursor...].firstIndex(where: { !$0.isWhitespace }), full[hit] == letter else { return full }
            cursor = full.index(after: hit)
        }
        return withoutLeadingBlankLines(String(full[cursor...]))
    }

    /// The remainder gets a bubble of its own, so blank lines at its start mean nothing. The first
    /// real line keeps its indent, which may be what opens a code block.
    private static func withoutLeadingBlankLines(_ text: String) -> String {
        String(text.drop(while: { $0 == "\n" || $0 == "\r" }))
    }
}
