import SwiftUI
import WebKit
import os
import NollieCore

// The containment rules for a bot's HTML card. A model that has read hostile pages may have
// written that markup, so the card is kept apart from the app: no data shared with other pages,
// no channel to message the app, https only, and no navigation inside the chat. Showing a card
// is the job of HTMLCardView.swift and HTMLWebView.swift.

enum HTMLCard {
    /// Only fences tagged html or htm turn into cards.
    static func isCard(language: String?) -> Bool {
        guard let name = language?.trimmingCharacters(in: .whitespaces).lowercased() else { return false }
        return ["html", "htm"].contains(name)
    }

    static let log = Logger(subsystem: NollieLog.subsystem, category: "chat")

    // MARK: Building the page

    /// The tags and styles put into every page's head to make it fit in the chat.
    private static func headInsert(dark: Bool, background: String?) -> String {
        let scheme = dark ? "dark" : "light"
        let tags = """
            <meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">\
            <meta name="color-scheme" content="\(scheme)">
            """
        let paper = background ?? "transparent"
        let rules: [(selector: String, declarations: String)] = [
            (":root", "color-scheme: \(scheme)"),
            ("html, body", "margin: 0; background: \(paper); color: -apple-system-label"),
            ("body", "padding: 12px; font: -apple-system-body; line-height: 1.35; overflow-wrap: anywhere; "
                + "font-family: -apple-system, system-ui, sans-serif"),
            ("a", "color: -apple-system-blue"),
            ("th, td", "text-align: left; padding: 4px 8px"),
            ("table", "border-collapse: collapse"),
            ("img, canvas, svg, video, table, pre", "max-width: 100%"),
        ]
        let css = rules.map { "\($0.selector) { \($0.declarations); }" }.joined(separator: "\n")
        return "\(tags)<style id=\"nollie-card\">\(css)</style>"
    }

    /// The page handed to the web view. A snippet gets a full document built around it. A complete
    /// document is left alone apart from our inserts, which go at the top of its head so that its
    /// own styles can still override them.
    static func document(_ html: String, dark: Bool, background: String? = nil) -> String {
        let insert = headInsert(dark: dark, background: background)
        let lower = html.lowercased()

        // Offsets are counted in characters, since lowercasing can change a string's byte length.
        func inserting(_ piece: String, atLowerIndex mark: String.Index) -> String {
            let steps = lower.distance(from: lower.startIndex, to: mark)
            let cut = html.index(html.startIndex, offsetBy: min(steps, html.count))
            return html[..<cut] + piece + html[cut...]
        }

        if let tag = lower.range(of: "<head>") ?? lower.range(of: "<head ") {
            let end = lower[tag.lowerBound...].firstIndex(of: ">").map { lower.index(after: $0) } ?? tag.upperBound
            return inserting(insert, atLowerIndex: end)
        }
        if lower.contains("<html"), let body = lower.range(of: "<body") {
            return inserting("<head>\(insert)</head>", atLowerIndex: body.lowerBound)
        }
        return ["<!doctype html>", "<html>", "<head>", insert, "</head>", "<body>", html, "</body>", "</html>"].joined()
    }

    /// The colour the page paints for itself. On the phone the web view is transparent and the
    /// card's own fill shows through. A Mac web view always paints, so the page takes the card's
    /// colour.
    @MainActor static func pageBackground(dark: Bool) -> String? {
        #if os(iOS)
        return nil
        #else
        var hex = dark ? "#1E1E1E" : "#FFFFFF"
        NSAppearance(named: dark ? .darkAqua : .aqua)?.performAsCurrentDrawingAppearance {
            guard let fill = NSColor.secondarySystemBackground.usingColorSpace(.sRGB) else { return }
            let parts = [fill.redComponent, fill.greenComponent, fill.blueComponent]
            hex = "#" + parts.map { String(format: "%02X", Int(($0 * 255).rounded())) }.joined()
        }
        return hex
        #endif
    }

    // MARK: Where a card may go

    enum Navigation: Equatable {
        case block, allow
        case openOutside
    }

    /// Rules on one navigation. The card's own page (loaded from a string, so about:blank) stays.
    /// A link the person tapped goes out to the browser. Scripts, refreshes, forms and redirects
    /// go nowhere, and frames never load.
    static func navigation(to url: URL?, isMainFrame: Bool, userLink: Bool = true) -> Navigation {
        if !isMainFrame { return .block }
        if url?.absoluteString == "about:blank" || url == nil { return .allow }
        let browserSchemes: Set<String> = ["mailto", "http", "https"]
        let scheme = url?.scheme?.lowercased() ?? ""
        return userLink && browserSchemes.contains(scheme) ? .openOutside : .block
    }

    @MainActor static func openOutside(_ url: URL) {
        #if os(macOS)
        NSWorkspace.shared.open(url)
        #else
        UIApplication.shared.open(url)
        #endif
    }

    /// What the Mac's right-click menu can do, because the web view owns that click.
    struct Actions {
        var copy: () -> Void
        var full: () -> Void
        /// Goes back to the code block. Nil when the thread doesn't offer it.
        var showSource: (() -> Void)?
    }

    // MARK: Loading limits

    /// Anything a page pulls in must come over https. Other schemes are stopped before a request
    /// goes out.
    static let ruleListJSON: String = {
        let schemes = ["file", "ftp", "ws", "wss", "http"]
        var lines: [String] = []
        for scheme in schemes {
            lines.append(#"{"trigger": {"url-filter": "^\#(scheme)://"}, "action": {"type": "block"}}"#)
        }
        return "[\n  \(lines.joined(separator: ",\n  "))\n]"
    }()

    @MainActor private static var compileTask: Task<WKContentRuleList?, Never>?

    /// The compiled rules. Built the first time, then reused.
    @MainActor static func ruleList() async -> WKContentRuleList? {
        guard compileTask == nil else { return await compileTask?.value ?? nil }
        compileTask = Task { @MainActor in
            await withCheckedContinuation { continuation in
                let store: WKContentRuleListStore = .default()
                store.compileContentRuleList(forIdentifier: "nollie-card-https-only", encodedContentRuleList: ruleListJSON) { list, problem in
                    if let problem {
                        log.error("card rules did not compile: \(problem.localizedDescription, privacy: .public)")
                    }
                    continuation.resume(returning: list)
                }
            }
        }
        let finished = await compileTask?.value
        // A failure isn't kept, so the next card tries again.
        if finished == nil { compileTask = nil }
        return finished ?? nil
    }

    /// The most height a card gets in the thread. Full Screen shows the rest.
    @MainActor static var heightCap: CGFloat {
        #if os(macOS)
        return 480
        #else
        return max(240, UIScreen.main.bounds.height * 0.6)
        #endif
    }

    /// A single throwaway data store for every card, so a long thread doesn't carry one each.
    @MainActor private static let sharedStore = WKWebsiteDataStore.nonPersistent()

    @MainActor static func configuration() -> WKWebViewConfiguration {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = sharedStore
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        // A new window can only come from a tapped link, and that opens in the browser.
        config.preferences.javaScriptCanOpenWindowsAutomatically = false
        config.mediaTypesRequiringUserActionForPlayback = .all
        config.suppressesIncrementalRendering = false
        #if os(iOS)
        config.allowsInlineMediaPlayback = true
        config.allowsPictureInPictureMediaPlayback = false
        #endif
        return config
    }
}
