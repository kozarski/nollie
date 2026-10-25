import Foundation
import SwiftUI
import Testing
import WebKit
@testable import Nollie
@testable import NollieCore

/// A real web view with the card's coordinator. WebKit finds the navigation delegate by the
/// method's exact selector; a near match once went unseen and a tapped link opened its page
/// inside the card. So: the delegate must answer to that selector, and a page that sends
/// itself elsewhere must stay where it is.
@Suite struct CardNavigationTests {
    private final class Cell<Value>: @unchecked Sendable {
        var value: Value
        init(_ value: Value) { self.value = value }
    }

    @MainActor @Test func webKitSeesTheDelegateAndAPageCannotWalkOffTheCard() async throws {
        let measured = Cell<CGFloat>(0)
        let finished = Cell(false)
        let page = "<p id=\"line\">hello</p><a href=\"https://example.org/away\">leave</a>"
        let view = HTMLWebView(document: HTMLCard.document(page, dark: false), scrolls: false,
                               height: Binding(get: { measured.value }, set: { measured.value = $0 }),
                               loaded: Binding(get: { finished.value }, set: { finished.value = $0 }))
        // The web view only holds its delegate weakly, so the coordinator is kept here.
        let coordinator = view.makeCoordinator()
        let web = view.makeWebView(coordinator)
        defer { withExtendedLifetime(coordinator) {} }

        let policy = NSSelectorFromString("webView:decidePolicyForNavigationAction:decisionHandler:")
        let listener: NSObjectProtocol? = web.navigationDelegate
        let hears = listener?.responds(to: policy) ?? false
        #expect(hears)

        for _ in 0..<200 where !finished.value { try await Task.sleep(for: .milliseconds(50)) }
        #expect(finished.value)
        let first = try await web.evaluateJavaScript("document.getElementById('line').textContent") as? String
        #expect(first == "hello")

        // The page tries to go elsewhere; the card refuses and keeps its own document.
        _ = try? await web.evaluateJavaScript("location.href = 'https://example.org/away'; 0")
        try await Task.sleep(for: .seconds(0.8))
        let location = web.url?.absoluteString
        #expect(location == nil || location == "about:blank")
        let after = try await web.evaluateJavaScript("document.getElementById('line') ? document.getElementById('line').textContent : ''") as? String
        #expect(after == "hello")
    }
}
