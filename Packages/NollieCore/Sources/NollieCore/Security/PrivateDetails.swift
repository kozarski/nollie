import Foundation

/// The personal parts of a text, so a picture made to share can hide them: email addresses, phone numbers, paths
/// under a home folder, web addresses, IP addresses, long numbers, and what the add-on already hid (`[hidden]`).
/// Pure. It errs on the side of hiding; plain words stay as they are.
public enum PrivateDetails {
    public struct Segment: Hashable, Sendable {
        public var text: String
        public var isPrivate: Bool

        public init(text: String, isPrivate: Bool) {
            self.text = text
            self.isPrivate = isPrivate
        }
    }

    /// `text` in order, cut where personal parts start and end. Joined, the segments give `text` back.
    public static func segments(of text: String) -> [Segment] {
        guard !text.isEmpty else { return [] }
        let whole = NSRange(text.startIndex..., in: text)
        var spans: [NSRange] = []
        for pattern in patterns {
            for match in pattern.matches(in: text, range: whole) {
                let span = trimmed(match.range, in: text as NSString)
                if span.length > 0 { spans.append(span) }
            }
        }
        spans.sort { $0.location < $1.location }
        // Overlapping or touching parts are one.
        var merged: [NSRange] = []
        for span in spans {
            if let last = merged.last, span.location <= NSMaxRange(last) {
                merged[merged.count - 1] = NSRange(location: last.location, length: max(NSMaxRange(last), NSMaxRange(span)) - last.location)
            } else {
                merged.append(span)
            }
        }
        var out: [Segment] = []
        var cursor = 0
        let ns = text as NSString
        for span in merged {
            if span.location > cursor {
                out.append(Segment(text: ns.substring(with: NSRange(location: cursor, length: span.location - cursor)), isPrivate: false))
            }
            out.append(Segment(text: ns.substring(with: span), isPrivate: true))
            cursor = NSMaxRange(span)
        }
        if cursor < ns.length { out.append(Segment(text: ns.substring(from: cursor), isPrivate: false)) }
        return out
    }

    private static let patterns: [NSRegularExpression] = [
        // Email addresses.
        #"[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)*\.[A-Za-z]{2,}"#,
        // Web addresses with a scheme, a `www.` host, or a host with a path (how receipts write a page), and a bare
        // host on a common web ending (`mybank.com`; receipts drop the slash of an empty path). Other bare words with
        // a dot are file names (`notes.txt`) and stay.
        #"\b[A-Za-z][A-Za-z0-9+.-]*://[^\s<>"']+"#,
        #"\bwww\.[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+(?:/[^\s<>"']*)?"#,
        #"\b(?:[A-Za-z0-9-]+\.)+[A-Za-z]{2,}(?::\d+)?/[^\s<>"']*"#,
        #"\b(?:[A-Za-z0-9-]+\.)+(?i:com|org|net|edu|gov|io|dev|app|ai|co|me|us|uk|ca|de|fr|nl|au|nz|info|biz|xyz|site|online|tech|shop|blog|cloud|page)(?::\d+)?(?![\w-])"#,
        // Paths under a home folder: /Users/<name>, /home/<name>, ~/ and ~name/.
        #"(?:/Users|/home)/[^\s/"']+(?:/[^\s"']*)?"#,
        #"(?<![\w/~])~[A-Za-z0-9._-]*/[^\s"']*"#,
        // IP addresses: IPv4, and IPv6 written in full or with `::`.
        #"(?<![\w.])(?:\d{1,3}\.){3}\d{1,3}(?![\w.]*\d)"#,
        #"(?<![\w:])(?:[0-9A-Fa-f]{1,4}:){7}[0-9A-Fa-f]{1,4}(?![\w:])"#,
        #"(?<![\w:])(?:(?:[0-9A-Fa-f]{1,4}:){1,7}|:):(?:[0-9A-Fa-f]{1,4}(?::[0-9A-Fa-f]{1,4}){0,6})?(?![\w:])"#,
        // Phone numbers: eight digits or more in groups, maybe with a country code.
        #"(?<![\w.])(?:\+\d{1,3}[\s.-]?)?(?:\(\d{2,4}\)|\d{2,4})[\s.-]?\d{3,4}[\s.-]?\d{3,4}(?![\w.]*\d)"#,
        // Long numbers: accounts, cards, codes.
        #"\d{6,}"#,
        // What the add-on hid before it was stored.
        #"\[hidden\]"#,
    ].map { try! NSRegularExpression(pattern: $0) }

    /// A match without the punctuation that ends the sentence around it.
    private static func trimmed(_ range: NSRange, in text: NSString) -> NSRange {
        var span = range
        let closing = CharacterSet(charactersIn: ".,;!?)]}'\"")
        while span.length > 1, let scalar = UnicodeScalar(text.character(at: NSMaxRange(span) - 1)), closing.contains(scalar) {
            // A path or address may end in `]` only as part of `[hidden]`.
            if text.substring(with: span).hasSuffix("[hidden]") { break }
            span.length -= 1
        }
        return span
    }
}
