import Foundation
import Testing
@testable import Nollie
@testable import NollieCore

/// An html fence inside a reply turns into a card. These cover the parsing half.
@Suite struct HTMLFenceParsingTests {
    @Test func anHTMLFenceAmongTextIsItsOwnClosedBlock() {
        let message = ["Look:", "", "```html", "<i>yo</i>", "<ul></ul>", "```", "", "Shall I go on?"].joined(separator: "\n")
        let expected: [MarkdownBlock] = [.paragraph("Look:"), .code(language: "html", text: "<i>yo</i>\n<ul></ul>", closed: true), .paragraph("Shall I go on?")]
        #expect(MarkdownParser.blocks(from: message) == expected)
        let names: [(String?, Bool)] = [("html", true), ("HTML ", true), ("htm", true), ("bash", false), (nil, false), ("", false)]
        for (name, isCard) in names { #expect(HTMLCard.isCard(language: name) == isCard, "\(String(describing: name))") }
    }

    @Test func aFenceStillOpenIsCodeForNow() {
        let blocks = MarkdownParser.blocks(from: ["Sketch:", "", "```html", "<div>partial"].joined(separator: "\n"))
        #expect(blocks.last == .code(language: "html", text: "<div>partial", closed: false))
        #expect(blocks.count == 2)
    }

    @Test func eachCardInAMessageStaysApart() {
        let blocks = MarkdownParser.blocks(from: "```html\n<p>first</p>\n```\nbetween\n```html\n<p>second</p>\n```\n```js\nlog(2)\n```")
        let cards = blocks.compactMap { block -> String? in
            if case .code(let language, let text, true) = block, HTMLCard.isCard(language: language) { return text }
            return nil
        }
        #expect(Set(cards) == ["<p>first</p>", "<p>second</p>"] && cards.count == 2)
        #expect(blocks.last == .code(language: "js", text: "log(2)", closed: true), "other languages stay plain code")
    }
}

/// The rules for what a card may load and where it may send the person.
@Suite struct HTMLCardPolicyRulesTests {
    private func go(_ address: String?, mainFrame: Bool = true, link: Bool? = nil) -> HTMLCard.Navigation {
        let url = address.flatMap { URL(string: $0) }
        if let link { return HTMLCard.navigation(to: url, isMainFrame: mainFrame, userLink: link) }
        return HTMLCard.navigation(to: url, isMainFrame: mainFrame)
    }

    @Test func aFragmentGetsWrappedAndAFullDocumentKeepsItsHead() {
        let fragment = HTMLCard.document("<p>yo</p>", dark: true)
        #expect(fragment.hasPrefix("<!doctype html><html><head>"))
        #expect(fragment.contains("color-scheme: dark") && fragment.contains("<body><p>yo</p></body>"))

        let full = HTMLCard.document("<html><head><title>Hi</title><style>p{color:blue}</style></head><body><p>x</p></body></html>", dark: false)
        #expect(full.contains("<head><meta charset=") && full.contains("utf-8"))
        #expect(full.contains("<title>Hi</title>") && full.contains("p{color:blue}") && full.contains("color-scheme: light"))
        #expect(full.components(separatedBy: "<head").count == 2, "one head, not two")
    }

    @Test func theCardsOwnDocumentStaysAndWebLinksOpenOutside() {
        // The page is built from a string, so its address is about:blank. That has to load on the
        // first pass and on each appearance change (a refused reload once left the old look in place).
        #expect(go("about:blank") == .allow)
        #expect(go(nil) == .allow)
        #expect(go("https://example.org/page") == .openOutside)
        #expect(go("mailto:me@example.org") == .openOutside)
        #expect(go("javascript:void(0)") == .block)
        #expect(go("file:///etc/hosts") == .block)
        #expect(go("https://example.org/inner", mainFrame: false) == .block)
        #expect(go("about:blank", mainFrame: false) == .block)
    }

    @Test func onlyALinkThePersonTappedLeavesForTheBrowser() {
        // Scripts, meta refreshes, forms and redirects lead nowhere, though the document itself still loads.
        #expect(go("https://example.org/page", link: false) == .block)
        #expect(go("mailto:me@example.org", link: false) == .block)
        #expect(go("about:blank", link: false) == .allow)
        #expect(go(nil, link: false) == .allow)
    }

    @Test func theContentRulesAreValidAndShutOutAllButHTTPS() throws {
        let rules = try #require(JSONSerialization.jsonObject(with: Data(HTMLCard.ruleListJSON.utf8)) as? [[String: Any]])
        func field(_ rule: [String: Any], _ section: String, _ key: String) -> String? { (rule[section] as? [String: Any])?[key] as? String }
        let patterns = Set(rules.compactMap { field($0, "trigger", "url-filter") })
        #expect(patterns.isSuperset(of: ["^http://", "^file://", "^ws://"]))
        #expect(!patterns.contains("^https://"))
        #expect(Set(rules.map { field($0, "action", "type") }) == ["block"])
    }
}
