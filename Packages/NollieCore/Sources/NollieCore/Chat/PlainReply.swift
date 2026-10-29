import Foundation

/// A reply read out as plain sentences, for a one-line preview or a notification. Markdown
/// marks go, links keep their words, and the parts that make no sense out loud are replaced by a
/// short note: code, tables and HTML cards. Callers hand over the bot's own text only, never
/// tool calls, tool output, thinking or helper rows.
public enum PlainReply {
    public static var tableOmitted: String { String(localized: "There's a table in the app.", table: "Core") }
    public static var cardOmitted: String { String(localized: "There's a card in the app.", table: "Core") }
    public static var codeOmitted: String { String(localized: "There's a code block in the app.", table: "Core") }

    public static func text(_ markdown: String) -> String {
        var reader = Incremental()
        var sentences = reader.feed(markdown)
        sentences.append(contentsOf: reader.finish())
        let spoken = sentences.joined(separator: " ")
        return spoken.replacingOccurrences(of: "  ", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Streaming reader. `feed` returns the parts that are complete: finished lines, and finished
    /// sentences within a paragraph under construction. Unfinished structure (a line, a code fence or a
    /// table) is kept back until more arrives or `finish()` is called.
    struct Incremental: Sendable {
        /// Where the reader is in the reply.
        private enum Zone: Sendable {
            case prose
            /// The very first line was `---`: front matter if a `key:` line follows.
            case frontMatterMaybe
            case frontMatter
            case code(marker: String, language: String)
        }

        private var zone = Zone.prose
        private var unfinishedLine = ""
        private var startedReading = false
        /// Rows of the table being passed over, so it can be named once when it ends.
        private var tableRows = 0
        /// A line holding a pipe but not wrapped in pipes. It is a table header only if the
        /// delimiter row comes next, so it waits.
        private var headerCandidate: String?

        init() {}

        mutating func feed(_ chunk: String) -> [String] {
            unfinishedLine += chunk
            var said: [String] = []
            while let end = unfinishedLine.firstIndex(of: "\n") {
                let line = String(unfinishedLine[..<end])
                unfinishedLine.removeSubrange(...end)
                said += read(line)
            }
            // A long paragraph gives up its finished sentences before its line ends.
            if case .prose = zone, !unfinishedLine.contains("|"),
               let boundary = Self.lastSentenceEnd(in: unfinishedLine) {
                let done = String(unfinishedLine[..<boundary])
                unfinishedLine.removeSubrange(..<boundary)
                said += read(done)
            }
            return said
        }

        /// The last words, plus the note owed for a code fence that never closed.
        mutating func finish() -> [String] {
            var said = read(unfinishedLine)
            unfinishedLine = ""
            said += dropCandidate()
            if case .code(_, let language) = zone {
                said.append(Self.note(forCodeIn: language))
                zone = .prose
            }
            said += closeTable()
            return said
        }

        // MARK: One line

        private mutating func read(_ rawLine: String) -> [String] {
            // Pictures are shown, not spoken, so their lines add nothing.
            let line = MediaScan.textWithoutMedia(rawLine).trimmingCharacters(in: .whitespaces)
            let isFirst = !startedReading
            startedReading = true

            if let early = readInsideZone(line, isFirst: isFirst) { return early }

            if line.hasPrefix("```") || line.hasPrefix("~~~") {
                let before = dropCandidate() + closeTable()
                zone = .code(marker: String(line.prefix(3)),
                             language: line.dropFirst(3).trimmingCharacters(in: .whitespaces))
                return before
            }
            if headerCandidate != nil {
                guard Self.isDelimiterRow(line) else {
                    // Not a table after all: say the held words, then take this line afresh.
                    return dropCandidate() + read(rawLine)
                }
                headerCandidate = nil
                tableRows += 2
                return []
            }
            if let skipped = readTableLine(line) { return skipped }

            var said = closeTable()
            guard !line.isEmpty, !["---", "***", "___"].contains(line) else { return said }
            let words = PlainReply.words(inLine: line)
            if !words.isEmpty { said.append(words) }
            return said
        }

        /// Front matter and code fences swallow their lines. Nil means the line is ordinary.
        private mutating func readInsideZone(_ line: String, isFirst: Bool) -> [String]? {
            switch zone {
            case .prose:
                guard isFirst, line == "---" else { return nil }
                zone = .frontMatterMaybe
            case .frontMatterMaybe:
                // A key on the second line makes the dashes front matter; otherwise they were a rule.
                let hasKey = line.firstMatch(of: /^[A-Za-z0-9_-]+:(\s|$)/) != nil
                zone = hasKey ? .frontMatter : .prose
                if !hasKey { return nil }
            case .frontMatter:
                if ["---", "..."].contains(line) { zone = .prose }
            case .code(let marker, let language):
                guard line.hasPrefix(marker) else { return [] }
                zone = .prose
                return [Self.note(forCodeIn: language)]
            }
            return []
        }

        /// A line of a table is counted, not said; a line with a stray pipe waits to be judged.
        private mutating func readTableLine(_ line: String) -> [String]? {
            let wrapped = line.count > 1 && line.hasPrefix("|") && line.hasSuffix("|")
            if wrapped || (tableRows > 0 && line.contains("|")) {
                tableRows += 1
                return []
            }
            guard tableRows == 0, line.contains("|") else { return nil }
            headerCandidate = line
            return []
        }

        private mutating func closeTable() -> [String] {
            defer { tableRows = 0 }
            return tableRows > 0 ? [PlainReply.tableOmitted] : []
        }

        /// Gives up on a held header line and says it as ordinary words.
        private mutating func dropCandidate() -> [String] {
            guard let held = headerCandidate else { return [] }
            headerCandidate = nil
            let words = PlainReply.words(inLine: held)
            return words.isEmpty ? [] : [words]
        }

        private static func note(forCodeIn language: String) -> String {
            ["html", "htm"].contains(language.lowercased()) ? PlainReply.cardOmitted : PlainReply.codeOmitted
        }

        /// A table's delimiter row: pipes, colons, dashes and spaces only, with a dash somewhere.
        static func isDelimiterRow(_ line: String) -> Bool {
            line.contains("-") && line.allSatisfy { "|:- ".contains($0) }
        }

        /// The index just after the last sentence end in a line still being written, when it is
        /// safe to cut there: followed by a space, nothing left open before it (backtick, link,
        /// emphasis), and far enough in that an abbreviation is not taken for an ending.
        static func lastSentenceEnd(in text: String) -> String.Index? {
            var cut: String.Index?
            var ticks = 0, squares = 0, rounds = 0, stars = 0
            var index = text.startIndex
            while index < text.endIndex {
                let char = text[index]
                switch char {
                case "`": ticks += 1
                case "[": squares += 1
                case "]": squares -= 1
                case "(": rounds += 1
                case ")": rounds -= 1
                case "*": stars += 1
                default: break
                }
                let following = text.index(after: index)
                let closesSentence = ".!?…".contains(char) && following < text.endIndex && text[following] == " "
                let nothingOpen = ticks % 2 == 0 && squares == 0 && rounds == 0 && stars % 2 == 0
                if closesSentence, nothingOpen, text.distance(from: text.startIndex, to: following) >= 12 {
                    cut = following
                }
                index = following
            }
            return cut
        }
    }

    /// Rewrites applied in order to the inside of a line: each pattern and what replaces it.
    /// There is no lookbehind in this engine, so a single mark keeps the character before it.
    private static let markRemovals: [(NSRegularExpression, String)] = [
        (#"!\[\]\([^)]*\)"#, NSRegularExpression.escapedTemplate(for: String(localized: "an image", table: "Core", comment: "Read out in place of a picture with no description"))),
        (#"!\[([^\]]+)\]\([^)]*\)"#, "$1"),
        (#"\[([^\]]+)\]\([^)]*\)"#, "$1"),
        (#"`([^`]*)`"#, "$1"),
        (#"\*\*([^*]+)\*\*"#, "$1"),
        (#"__([^_]+)__"#, "$1"),
        (#"(^|[^\w*])\*([^*]+)\*(?!\w)"#, "$1$2"),
        (#"(^|[^\w_])_([^_]+)_(?!\w)"#, "$1$2"),
        (#"~~([^~]+)~~"#, "$1"),
    ].map { (try! NSRegularExpression(pattern: $0.0), $0.1) }

    /// Takes a pattern off the front of `text`; true if there was one.
    private static func dropLeading(_ pattern: String, from text: inout String) -> Bool {
        guard let hit = text.range(of: "^" + pattern, options: .regularExpression) else { return false }
        text.removeSubrange(hit)
        return true
    }

    /// One markdown line as spoken words. Headings, bullets and numbers lose their markers,
    /// emphasis loses its marks, links and code keep their text, and a closing stop is added to
    /// a heading, bullet or task so the lines still read as sentences.
    static func words(inLine line: String) -> String {
        var text = line
        var isListy = dropLeading(#"#{1,6}\s+"#, from: &text)
        isListy = dropLeading(#"(?:[-*+]|\d+[.)])\s+"#, from: &text) || isListy
        if let box = text.range(of: #"^\[([ xX])\]\s*"#, options: .regularExpression) {
            let done = text[box].lowercased().contains("x")
            text.replaceSubrange(box, with: done ? String(localized: "Done: ", table: "Core", comment: "Read out before a ticked checklist item; keep the space")
                : String(localized: "To do: ", table: "Core", comment: "Read out before an unticked checklist item; keep the space"))
            isListy = true
        }
        _ = dropLeading(#">\s?"#, from: &text)

        for (pattern, template) in markRemovals {
            text = pattern.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text),
                                                    withTemplate: template)
        }
        text = text.replacingOccurrences(of: "&nbsp;", with: " ").trimmingCharacters(in: .whitespaces)

        if isListy, let last = text.last, !".!?:;…".contains(last) { text += "." }
        return text
    }
}
