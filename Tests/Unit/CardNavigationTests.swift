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

    @MainActor @Test(.timeLimit(.minutes(2))) func webKitSeesTheDelegateAndAPageCannotWalkOffTheCard() async throws {
        let measured = Cell<CGFloat>(0)
        let finished = Cell(false)
        // The card says it has loaded by setting `loaded`, once WebKit finished the page and it was first measured.
        // The test waits for exactly that, however long a busy computer takes to start WebKit and build the card's rules.
        let (loads, loadSeen) = AsyncStream.makeStream(of: Void.self)
        let page = "<p id=\"line\">hello</p><a href=\"https://example.org/away\">leave</a>"
        let view = HTMLWebView(document: HTMLCard.document(page, dark: false), scrolls: false,
                               height: Binding(get: { measured.value }, set: { measured.value = $0 }),
                               loaded: Binding(get: { finished.value }, set: {
                                   finished.value = $0
                                   if $0 { loadSeen.yield() }
                               }))
        // The web view only holds its delegate weakly, so the coordinator is kept here.
        let coordinator = view.makeCoordinator()
        let web = view.makeWebView(coordinator)
        defer { withExtendedLifetime(coordinator) {} }

        let policy = NSSelectorFromString("webView:decidePolicyForNavigationAction:decisionHandler:")
        let listener: NSObjectProtocol? = web.navigationDelegate
        let hears = listener?.responds(to: policy) ?? false
        #expect(hears)

        // The test's two-minute limit ends this wait only if the page never loads.
        var waiting = loads.makeAsyncIterator()
        _ = await waiting.next()
        try #require(finished.value, "the card never said its page had loaded")
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
