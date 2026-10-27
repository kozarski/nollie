import SwiftUI
import WebKit

/// Hosts one card's page. The page never reports in: the card's height is read from the
/// page by the coordinator, because a script message channel would open a door into the app.
struct HTMLWebView {
    /// Right-click entries on the Mac. The sheet brings its own, so it passes nil.
    let actions: HTMLCard.Actions?
    let scrolls: Bool
    let document: String
    @Binding var loaded: Bool
    @Binding var height: CGFloat
    /// Set when the card's network rules couldn't be built. The page is then not loaded at all.
    @Binding var failed: Bool
    /// A square at the top trailing corner the page leaves alone, for the card's own button over it.
    let clearCorner: CGFloat

    init(document: String, scrolls: Bool, height: Binding<CGFloat>, loaded: Binding<Bool>,
         failed: Binding<Bool> = .constant(false), actions: HTMLCard.Actions? = nil, clearCorner: CGFloat = 0) {
        self.document = document
        self.scrolls = scrolls
        self._height = height
        self._loaded = loaded
        self._failed = failed
        self.actions = actions
        self.clearCorner = clearCorner
    }

    @MainActor static func dismantle(_ web: WKWebView, _ coordinator: Coordinator) {
        web.stopLoading()
        coordinator.measuring?.cancel()
    }

    @MainActor func makeCoordinator() -> Coordinator {
        let coordinator = Coordinator(self)
        return coordinator
    }

    @MainActor func makeWebView(_ coordinator: Coordinator) -> WKWebView {
        let web = Self.blankView()
        web.navigationDelegate = coordinator
        web.uiDelegate = coordinator
        web.allowsLinkPreview = false
        web.allowsBackForwardNavigationGestures = false
        applyLiveSettings(to: web)
        defer { coordinator.load(into: web) }
        return web
    }

    @MainActor func update(_ web: WKWebView, _ coordinator: Coordinator) {
        applyLiveSettings(to: web)
        coordinator.parent = self
        coordinator.load(into: web)
    }

    @MainActor private static func blankView() -> WKWebView {
        let config = HTMLCard.configuration()
        #if os(iOS)
        let web = CardWebView(frame: .zero, configuration: config)
        web.isOpaque = false
        for layer in [web as UIView, web.scrollView] { layer.backgroundColor = .clear }
        return web
        #else
        // A Mac web view always paints, so the page itself is given the card's colour.
        return CardWebView(frame: .zero, configuration: config)
        #endif
    }

    /// The two things a card can change once it exists: scrolling, and its menu.
    @MainActor private func applyLiveSettings(to web: WKWebView) {
        #if os(iOS)
        web.scrollView.bounces = scrolls
        web.scrollView.isScrollEnabled = scrolls
        (web as? CardWebView)?.clearCorner = clearCorner
        #else
        guard let card = web as? CardWebView else { return }
        (card.scrolls, card.actions) = (scrolls, actions)
        #endif
    }
}

#if os(macOS)
/// The web view class for cards on the Mac. Inside the thread it hands the scroll wheel up to the
/// thread, and in the sheet it scrolls on its own. Command-click goes full screen; right-click
/// opens the menu defined by the card.
final class CardWebView: WKWebView {
    @objc private func chooseCopy() { actions?.copy() }
    @objc private func chooseSource() { actions?.showSource?() }
    @objc private func chooseFull() { actions?.full() }

    var actions: HTMLCard.Actions?
    var scrolls = false

    override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        guard let actions else { return super.willOpenMenu(menu, with: event) }
        var entries: [(title: String, action: Selector)] = [("Open Full Screen", #selector(chooseFull))]
        if actions.showSource != nil { entries.append(("Show Source", #selector(chooseSource))) }
        entries.append(("Copy HTML", #selector(chooseCopy)))
        menu.removeAllItems()
        for entry in entries {
            menu.addItem(withTitle: entry.title, action: entry.action, keyEquivalent: "").target = self
        }
    }

    override func mouseDown(with event: NSEvent) {
        let commandHeld = event.modifierFlags.contains(.command)
        if commandHeld, let actions { actions.full() } else { super.mouseDown(with: event) }
    }

    override func scrollWheel(with event: NSEvent) {
        guard scrolls else { nextResponder?.scrollWheel(with: event); return }
        super.scrollWheel(with: event)
    }
}

extension HTMLWebView: NSViewRepresentable {
    static func dismantleNSView(_ web: WKWebView, coordinator: Coordinator) { dismantle(web, coordinator) }

    func updateNSView(_ web: WKWebView, context: Context) {
        let coordinator = context.coordinator
        update(web, coordinator)
    }

    func makeNSView(context: Context) -> WKWebView {
        makeWebView(context.coordinator)
    }
}
#else
/// The web view for cards on the iPhone and iPad. A web view takes every touch inside its frame
/// except where SwiftUI has drawn on top, so a tap just off the card's small round button went to
/// the page. The corner the button's fingertip square covers is left to the button.
final class CardWebView: WKWebView {
    var clearCorner: CGFloat = 0

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let corner = CGRect(x: bounds.maxX - clearCorner, y: bounds.minY, width: clearCorner, height: clearCorner)
        if clearCorner > 0, corner.contains(point) { return nil }
        return super.hitTest(point, with: event)
    }
}

extension HTMLWebView: UIViewRepresentable {
    static func dismantleUIView(_ web: WKWebView, coordinator: Coordinator) { dismantle(web, coordinator) }

    func updateUIView(_ web: WKWebView, context: Context) {
        let coordinator = context.coordinator
        update(web, coordinator)
    }

    func makeUIView(context: Context) -> WKWebView {
        makeWebView(context.coordinator)
    }
}
#endif
