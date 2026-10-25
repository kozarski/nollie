import Foundation

/// Masks anything in a piece of text that looks like a secret or an address, before the text is
/// shared. It errs on the side of hiding too much: a shared file is never the place for a token.
public enum LogRedactor {
    private struct Rule {
        let expression: NSRegularExpression
        let template: String
        /// Looks at the matched text; false leaves it alone.
        let accepts: (@Sendable (String) -> Bool)?

        init(_ pattern: String, _ template: String, accepts: (@Sendable (String) -> Bool)? = nil) {
            // The patterns are fixed in this file; a typo would fail every test at once.
            expression = try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
            self.template = template
            self.accepts = accepts
        }
    }

    private static let rules: [Rule] = [
        // Authorization: Bearer abc..., Basic abc...
        Rule(#"\b(bearer|basic)\s+[A-Za-z0-9._~+/=-]{8,}"#, "$1 <redacted>"),
        // token=..., "api_key": "...", HERMES_DASHBOARD_SESSION_TOKEN=..., password: ..., secret=...
        Rule(#"(["']?[a-z0-9_.-]*(?:token|api[_-]?key|apikey|secret|password|passwd|authorization|cookie)["']?\s*[:=]\s*)("[^"]*"|'[^']*'|[^\s&,;"'}\]]+)"#,
             "$1<redacted>"),
        // Sign-in callbacks and signed links: ?code=...&state=...
        Rule(#"([?&](?:code|state|key|sig|signature)=)[^\s&]+"#, "$1<redacted>"),
        // Known key shapes.
        Rule(#"\bsk-[A-Za-z0-9][A-Za-z0-9_-]{15,}"#, "<redacted-key>"),
        Rule(#"\b(?:ghp|gho|ghu|ghs|ghr)_[A-Za-z0-9]{20,}"#, "<redacted-key>"),
        Rule(#"\bgithub_pat_[A-Za-z0-9_]{20,}"#, "<redacted-key>"),
        Rule(#"\bxox[abprs]-[A-Za-z0-9-]{10,}"#, "<redacted-key>"),
        Rule(#"\bAKIA[0-9A-Z]{16}\b"#, "<redacted-key>"),
        Rule(#"\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]*"#, "<redacted-token>"),
        // Long hex, such as a 64-character token.
        Rule(#"\b[0-9a-f]{32,}\b"#, "<redacted-hex>"),
        // Long base64-looking runs. A path or a word is left alone: it needs a digit, both cases,
        // and almost no slashes.
        Rule(#"[A-Za-z0-9+/_-]{32,}={0,2}"#, "<redacted-secret>", accepts: { text in
            guard !text.hasPrefix("/") else { return false }
            let hasDigit = text.contains { $0.isNumber }
            let hasLower = text.contains { $0.isLowercase }
            let hasUpper = text.contains { $0.isUppercase }
            return hasDigit && hasLower && hasUpper && text.filter({ $0 == "/" }).count <= 2
        }),
        // Email addresses.
        Rule(#"[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)*\.[A-Za-z]{2,}"#, "<email>"),
    ]

    public static func redact(_ text: String) -> String {
        var result = text
        for rule in rules {
            let whole = NSRange(result.startIndex..., in: result)
            if let accepts = rule.accepts {
                // Replace back to front so earlier ranges stay valid.
                let matches = rule.expression.matches(in: result, range: whole).reversed()
                for match in matches {
                    guard let range = Range(match.range, in: result), accepts(String(result[range])) else { continue }
                    result.replaceSubrange(range, with: rule.template)
                }
            } else {
                result = rule.expression.stringByReplacingMatches(in: result, range: whole, withTemplate: rule.template)
            }
        }
        return result
    }
}
