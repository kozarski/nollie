import Foundation

/// The approval card's question when Ask first holds an action: the workflow add-on asks through
/// Hermes's own gate with the rule `plugin_rule:nollie-ask-first:<kind>:<id>` and the whole action
/// in plain words. A fresh id each time, so only Allow once and Deny mean anything.
public struct AskFirstAsk: Equatable, Sendable {
    public static let rulePrefix = "plugin_rule:nollie-ask-first:"

    public enum Kind: String, CaseIterable, Sendable {
        case send, buy, post, delete, unsure
        /// A change to the person's calendar, reminders or contacts on their Mac (the add-on's apple_data).
        case calendar, reminders, contacts
    }

    public var kind: Kind
    public var id: String
    /// The action without the check line. Computer clicks and keys use plain words.
    public var summary: String
    /// The last line when it is exactly `You're about to press “<label>”.`, shown on its own.
    public var check: String?
    /// The button named in the check line.
    public var buttonLabel: String?

    public init?(_ approval: ApprovalRequest?) {
        guard let approval, let key = approval.patternKey, key.hasPrefix(Self.rulePrefix) else { return nil }
        let rest = key.dropFirst(Self.rulePrefix.count).split(separator: ":", omittingEmptySubsequences: false)
        guard rest.count == 2, let kind = Kind(rawValue: String(rest[0])) else { return nil }
        let id = String(rest[1])
        guard id.count == 32, id.allSatisfy({ $0.isASCII && $0.isHexDigit && !$0.isUppercase }) else { return nil }
        var lines = (approval.description ?? "").components(separatedBy: "\n")
        var check: String?
        var label: String?
        if let last = lines.last, let found = Self.checkLabel(last) {
            check = last
            label = found
            lines.removeLast()
        }
        let summary = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !summary.isEmpty else { return nil }
        self.kind = kind
        self.id = id
        self.summary = Self.plainSummary(summary)
        self.check = check
        self.buttonLabel = label
    }

    /// Older add-ons included computer details. Only their action headline is cleaned, never
    /// commands, message text or the original approval.
    private static func plainSummary(_ summary: String) -> String {
        let point = #"(?:at \([^\r\n]+\)|on item [^\r\n]+|somewhere Nollie can't name)"#
        let action = #"(?:Press [^\r\n]+|Click "# + point + #"|Type “[\s\S]*” and press Return)"#
        let place = #"(?:its computer(?: \([^\r\n]+\))?|this Mac|the browser|a computer or browser)"#
        guard let range = summary.range(of: #"\A"# + action + " on " + place + #"\.(?=\n|\z)"#,
                                        options: .regularExpression) else { return summary }
        var headline = String(summary[range])
        if headline.hasSuffix(")."), let location = headline.range(of: " on its computer (", options: .backwards) {
            headline.replaceSubrange(location.lowerBound..., with: " on its computer.")
        }
        headline = headline.replacingOccurrences(of: #"\AClick "# + point + " on ",
                                                 with: "Click on ", options: .regularExpression)
        var rest = String(summary[range.upperBound...])
        if headline.hasPrefix("Press “") {
            rest = rest.replacingOccurrences(of: #"\A\nClick "# + point + #"\.(?=\n|\z)"#,
                                            with: "", options: .regularExpression)
        }
        return headline + rest
    }

    /// The label in a check line, exactly as the add-on writes it (curly quotes, 1 to 60 characters).
    static func checkLabel(_ line: String) -> String? {
        let start = "You're about to press \u{201C}", end = "\u{201D}."
        let scalars = line.unicodeScalars
        guard line.hasPrefix(start), line.hasSuffix(end),
              scalars.count > start.unicodeScalars.count + end.unicodeScalars.count else { return nil }
        // Counted as the add-on counts it (code points), so the two agree on where 60 ends.
        let label = String(String.UnicodeScalarView(scalars.dropFirst(start.unicodeScalars.count).dropLast(end.unicodeScalars.count)))
        guard (1...60).contains(label.unicodeScalars.count), !label.contains("\n"), !label.contains("\r") else { return nil }
        return label
    }
}

// MARK: - Checking it's the owner

extension AskFirstAsk {
    /// The kinds that spend money or speak for the person. With Face ID for buying and sending on
    /// (Settings, Privacy), a yes to one of these checks it's the owner first.
    public static let ownerCheckedKinds: Set<Kind> = [.buy, .send, .post]

    /// Whether a yes to this approval should check it's the owner. Read from the rule's key alone, so
    /// a request whose words can't be read is covered all the same.
    public static func needsOwner(_ approval: ApprovalRequest?) -> Bool {
        guard let key = approval?.patternKey, key.hasPrefix(rulePrefix) else { return false }
        let word = key.dropFirst(rulePrefix.count).split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false).first
        guard let word, let kind = Kind(rawValue: String(word)) else { return false }
        return ownerCheckedKinds.contains(kind)
    }
}
