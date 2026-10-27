import Foundation
import NollieCore

/// What of a reply is read aloud, and how it reads. Markdown marks, links and pictures are for
/// the eye, so they become plain words; code and tables are left on screen with a short mention.
enum SpokenReply {
    static let codeOnScreen = String(localized: "There's some code on screen.", comment: "Read aloud in place of code")
    static let tableOnScreen = String(localized: "There's a table on screen.", comment: "Read aloud in place of a table")

    /// The reply of the latest turn: the bot's finished words after the person's last message,
    /// ready to speak. Empty when there is nothing to read (only tools ran, or it was cut short).
    static func latestTurn(in items: [TranscriptItem]) -> String {
        let lastPerson = items.lastIndex { if case .user = $0.kind { true } else { false } } ?? -1
        let replies = items.suffix(from: lastPerson + 1).compactMap { item -> String? in
            guard case .assistant(let text, _, _) = item.kind, InterruptedTurn.parse(text) == nil else { return nil }
            let words = plain(text)
            return words.isEmpty ? nil : words
        }
        return replies.joined(separator: "\n\n")
    }

    /// One reply as it should sound.
    static func plain(_ markdown: String) -> String {
        var text = MediaScan.textWithoutMedia(markdown)
        text = replaceCode(in: text)
        var lines: [String] = []
        var inTable = false
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("|") {
                if !inTable { lines.append(tableOnScreen) }
                inTable = true
                continue
            }
            inTable = false
            lines.append(spokenLine(line))
        }
        let joined = lines.joined(separator: "\n")
            .replacing(/\n{3,}/, with: "\n\n")
            .replacing(/[ \t]{2,}/, with: " ")
        return joined.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Fenced code blocks become one sentence; inline code keeps its words without the marks.
    private static func replaceCode(in text: String) -> String {
        text.replacing(/```[^\n]*\n[\s\S]*?(```|\z)/, with: codeOnScreen)
    }

    private static func spokenLine(_ line: String) -> String {
        var line = line
        // A rule between sections says nothing.
        if line.wholeMatch(of: /[-*_]{3,}/) != nil { return "" }
        // Headings, quotes and list marks.
        line = line.replacing(/^#{1,6}\s+/, with: "")
        line = line.replacing(/^>\s?/, with: "")
        line = line.replacing(/^[-*+]\s+(\[[ xX]\]\s+)?/, with: "")
        // Pictures go, links keep their words, bare addresses say only the site.
        line = line.replacing(/!\[[^\]]*\]\([^)]*\)/, with: "")
        line = line.replacing(/\[([^\]]+)\]\([^)]*\)/) { String($0.output.1) }
        line = line.replacing(/https?:\/\/[^\s)]+/) { site(of: String($0.output)) }
        // Emphasis and code marks, and any HTML tags.
        line = line.replacing(/\*\*|__|`|~~/, with: "")
        line = line.replacing(/\*(\S[^*]*)\*/) { String($0.output.1) }
        line = line.replacing(/<[^>]+>/, with: "")
        return withoutEmoji(line).trimmingCharacters(in: .whitespaces)
    }

    /// "https://www.bbc.co.uk/news" reads as "bbc.co.uk".
    static func site(of address: String) -> String {
        guard let host = URL(string: address)?.host() else { return String(localized: "a link", comment: "Read aloud in place of a web address") }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    /// Emoji are read out by name ("smiling face with smiling eyes"), which is noise in a reply.
    private static func withoutEmoji(_ text: String) -> String {
        var kept = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            let props = scalar.properties
            let pictured = props.isEmojiPresentation || (props.isEmoji && scalar.value > 0x238C)
            let joiner = scalar.value == 0x200D || scalar.value == 0xFE0F || (0x1F3FB...0x1F3FF).contains(scalar.value)
            if !pictured && !joiner { kept.append(scalar) }
        }
        return String(kept)
    }
}
