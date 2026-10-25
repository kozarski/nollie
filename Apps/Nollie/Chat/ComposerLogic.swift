import Foundation

/// When a pasted or typed text is long enough to offer sending it as a file.
enum LongTextRule {
    static let limit = 800
    /// Pasting arrives in a single step, so a step of this size counts even if the text was already close.
    static let bigJump = 400

    /// True to offer the file, false to withdraw the offer, nil to leave it as it is. "Keep" holds
    /// until the text shrinks again.
    static func verdict(old: String, new: String) -> Bool? {
        if new.count < limit { return false }
        return old.count < limit || new.count - old.count > bigJump ? true : nil
    }
}

/// How a quoted reply reaches the bot: a Markdown quote placed before the message. The quote
/// bubble is excluded from the history recall inside the app.
enum QuotedMessage {
    static func wrap(_ message: String, quoting quote: String) -> String {
        guard !quote.isEmpty else { return message }
        let quoted = quote.components(separatedBy: "\n").map { "> " + $0 }.joined(separator: "\n")
        return quoted + "\n\n" + message
    }
}

/// File name given to a long text sent as an attachment: its first line, shortened, with only
/// letters, digits and spaces left.
enum PastedTextFile {
    static func name(for body: String) -> String {
        let firstLine = body.split(whereSeparator: \.isNewline).first.map(String.init) ?? "Pasted text"
        let odd = CharacterSet.alphanumerics.union(.whitespaces).inverted
        let stem = String(firstLine.prefix(32)).components(separatedBy: odd).joined().trimmingCharacters(in: .whitespaces)
        return (stem.isEmpty ? "Pasted text" : stem) + ".txt"
    }
}

/// Up and Down through earlier messages: where in the list the person is.
struct HistoryRecall {
    var past: [String]
    var cursor: Int?

    /// What the field becomes after a step, or nil when the key was not used. Past the newest
    /// message the field empties and the cursor is let go.
    mutating func step(_ step: Int, fieldIsEmpty: Bool) -> String? {
        guard !past.isEmpty, fieldIsEmpty || cursor != nil else { return nil }
        let target = (cursor ?? past.count) + step
        if target >= past.count {
            cursor = nil
            return ""
        }
        guard target >= 0 else { return nil }
        cursor = target
        return past[target]
    }
}
