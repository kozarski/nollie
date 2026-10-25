import Foundation

/// A reply's text as the screen draws it: paragraphs of inline Markdown and fenced code blocks, in order. Pure, so
/// a row works it out once per text rather than on every redraw.
enum ConversationReplyBlock: Hashable, Sendable {
    case text(String)
    case code(language: String?, String)
}

enum ConversationReplyBlocks {
    /// Splits on fenced code (three backticks or tildes on a line of their own). A fence left open, as in a reply
    /// still streaming, runs to the end.
    static func parse(_ text: String) -> [ConversationReplyBlock] {
        var blocks: [ConversationReplyBlock] = []
        var prose: [Substring] = []
        var code: [Substring] = []
        var fence: (marker: String, language: String?)?

        func flushProse() {
            let joined = softBreaks(prose).trimmingCharacters(in: .newlines)
            if !joined.isEmpty { blocks.append(.text(joined)) }
            prose.removeAll()
        }

        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let open = fence {
                if trimmed == open.marker {
                    blocks.append(.code(language: open.language, code.joined(separator: "\n")))
                    code.removeAll()
                    fence = nil
                } else {
                    code.append(line)
                }
            } else if let marker = ["```", "~~~"].first(where: { trimmed.hasPrefix($0) }) {
                flushProse()
                let language = trimmed.dropFirst(marker.count).trimmingCharacters(in: .whitespaces)
                fence = (marker, language.isEmpty ? nil : language)
            } else {
                prose.append(line)
            }
        }
        if let open = fence {
            blocks.append(.code(language: open.language, code.joined(separator: "\n")))
        }
        flushProse()
        return blocks
    }

    /// Lines joined as Markdown reads them: a single line break inside a paragraph is a space, a blank line ends
    /// the paragraph, and a line that starts a list item, a quote or a bold lead-in starts a line of its own.
    static func softBreaks(_ lines: [Substring]) -> String {
        var out = ""
        var previousBlank = true
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                out += "\n\n"
                previousBlank = true
                continue
            }
            if !previousBlank {
                out += startsOwnLine(trimmed) || out.hasSuffix("  ") ? "\n" : " "
            }
            out += line
            previousBlank = false
        }
        // Runs of blank lines read as one paragraph break.
        while out.contains("\n\n\n") { out = out.replacingOccurrences(of: "\n\n\n", with: "\n\n") }
        return out
    }

    private static func startsOwnLine(_ line: String) -> Bool {
        if ["- ", "* ", "+ ", "> ", "**", "#", "|"].contains(where: { line.hasPrefix($0) }) { return true }
        // "1. " or "12) "
        let digits = line.prefix { $0.isNumber }
        guard !digits.isEmpty else { return false }
        let rest = line.dropFirst(digits.count)
        return rest.hasPrefix(". ") || rest.hasPrefix(") ")
    }

    /// Inline Markdown (bold, italics, code, links) with the line breaks kept; the plain words if it does not
    /// parse.
    static func attributed(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace,
                                                              failurePolicy: .returnPartiallyParsedIfPossible)
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }

    // Rows are drawn again whenever a cell shows them and measured once more besides: what a text parses to is
    // kept, so it is worked out once. A few hundred texts at most; a reply still streaming misses each time.
    @MainActor private static var blockCache: [String: [ConversationReplyBlock]] = [:]
    @MainActor private static var attributedCache: [String: AttributedString] = [:]

    @MainActor static func blocks(_ text: String) -> [ConversationReplyBlock] {
        if let kept = blockCache[text] { return kept }
        let parsed = parse(text)
        if blockCache.count > 600 { blockCache.removeAll(keepingCapacity: true) }
        blockCache[text] = parsed
        return parsed
    }

    @MainActor static func inline(_ text: String) -> AttributedString {
        if let kept = attributedCache[text] { return kept }
        let made = attributed(text)
        if attributedCache.count > 1_200 { attributedCache.removeAll(keepingCapacity: true) }
        attributedCache[text] = made
        return made
    }
}
