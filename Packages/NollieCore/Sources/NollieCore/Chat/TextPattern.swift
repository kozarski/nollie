import Foundation

/// A small wrapper over NSRegularExpression for the places that read free text from the gateway.
/// Patterns are compiled once; a bad pattern is a programmer error and traps at first use.
struct TextPattern: @unchecked Sendable {
    private let expression: NSRegularExpression

    init(_ pattern: String, caseInsensitive: Bool = false) {
        var options: NSRegularExpression.Options = []
        if caseInsensitive { options.insert(.caseInsensitive) }
        expression = try! NSRegularExpression(pattern: pattern, options: options)
    }

    /// The capture groups of the first match in `text` (index 0 is the whole match); a group that
    /// did not take part is nil. Nil when nothing matches.
    func groups(in text: String) -> [String?]? {
        let whole = NSRange(text.startIndex..., in: text)
        guard let hit = expression.firstMatch(in: text, range: whole) else { return nil }
        return (0..<hit.numberOfRanges).map { i in
            Range(hit.range(at: i), in: text).map { String(text[$0]) }
        }
    }

    func matches(_ text: String) -> Bool { groups(in: text) != nil }

    /// One capture group of the first match, or nil.
    func capture(_ index: Int, in text: String) -> String? {
        guard let all = groups(in: text), index < all.count else { return nil }
        return all[index]
    }
}
