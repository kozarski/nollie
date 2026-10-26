import SwiftUI
import WebKit
import os

/// How a card's height is read from its page: the body's own box (scrollHeight never shrinks
/// below the view, so a card could only ever grow), sampled a few times while scripts draw.
private enum HeightProbe {
    static let script = """
        (() => {
          const box = document.body;
          return Math.ceil(box ? box.getBoundingClientRect().height : document.documentElement.scrollHeight);
        })()
        """
    static let sampleTimes: [Int] = [0, 250, 800, 2000, 4000]
    static let range: ClosedRange<Double> = 24...6000
}

extension HTMLWebView {
    /// WebKit's delegate for one card. It loads the page once, rules on each navigation and
    /// reads the page height back.
    @MainActor final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        var parent: HTMLWebView
        var measuring: Task<Void, Never>?
        private var currentPage: String?

        init(_ parent: HTMLWebView) {
            self.parent = parent
        }

        /// Puts the page in once. Asking again for the same page does nothing.
        func load(into web: WKWebView) {
            let page = parent.document
            if page == currentPage { return }
            currentPage = page
            Task { @MainActor in
                // Without its rules a card could reach more than it should, so it isn't drawn.
                guard let rules = await HTMLCard.ruleList() else {
                    parent.failed = true
                    return
                }
                parent.failed = false
                web.configuration.userContentController.add(rules)
                web.loadHTMLString(page, baseURL: nil)
            }
        }

        private static func kind(of action: WKNavigationAction) -> String {
            switch action.navigationType {
            case .linkActivated: "link"
            case .formSubmitted, .formResubmitted: "form"
            case .backForward: "history"
            case .reload: "reload"
            default: "other"
            }
        }

        private static func words(for ruling: HTMLCard.Navigation) -> String {
            switch ruling {
            case .allow: "allowed"
            case .block: "blocked"
            case .openOutside: "sent to the browser"
            }
        }

        private func rule(for action: WKNavigationAction, mainFrame: Bool) -> HTMLCard.Navigation {
            HTMLCard.navigation(to: action.request.url, isMainFrame: mainFrame, userLink: action.navigationType == .linkActivated)
        }

        // Declared in the async form on purpose. A closure form once almost matched the
        // requirement, WebKit never called it, and a tapped link opened inside the card.
        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
            let ruling = rule(for: action, mainFrame: action.targetFrame?.isMainFrame ?? true)
            // What a card links to can be anything it was told to write, so only the kind and the ruling are logged.
            HTMLCard.log.notice("card navigation: \(Self.kind(of: action), privacy: .public), \(Self.words(for: ruling), privacy: .public)")
            if ruling == .openOutside, let url = action.request.url { HTMLCard.openOutside(url) }
            return ruling == .allow ? .allow : .cancel
        }

        // A tapped window.open or target=_blank goes to the browser. No second web view is made.
        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                     for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            if let url = action.request.url, rule(for: action, mainFrame: true) == .openOutside {
                HTMLCard.openOutside(url)
            }
            return nil
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            startMeasuring(webView)
        }

        private func startMeasuring(_ web: WKWebView) {
            let previous = measuring
            previous?.cancel()
            measuring = Task { @MainActor [weak self, weak web] in
                var waited = 0
                for time in HeightProbe.sampleTimes {
                    try? await Task.sleep(for: .milliseconds(time - waited))
                    waited = time
                    guard !Task.isCancelled, let self, let web else { return }
                    let reply = try? await web.evaluateJavaScript(HeightProbe.script)
                    if let value = (reply as? NSNumber)?.doubleValue, value > 0 { self.take(height: value) }
                    parent.loaded = true
                }
            }
        }

        private func take(height value: Double) {
            let clamped = CGFloat(min(max(value, HeightProbe.range.lowerBound), HeightProbe.range.upperBound))
            if abs(clamped - parent.height) > 1 { parent.height = clamped }
        }
    }
}
