import AppKit
import Combine
import SwiftUI

/// Whether Nollie is the app in front. One watcher serves every window.
@MainActor @Observable
private final class FrontApp {
    static let shared = FrontApp()

    private(set) var isActive = NSApp?.isActive ?? true
    @ObservationIgnored private var listeners: Set<AnyCancellable> = []

    private init() {
        let center = NotificationCenter.default
        center.publisher(for: NSApplication.didBecomeActiveNotification)
            .sink { _ in MainActor.assumeIsolated { FrontApp.shared.isActive = true } }
            .store(in: &listeners)
        center.publisher(for: NSApplication.didResignActiveNotification)
            .sink { _ in MainActor.assumeIsolated { FrontApp.shared.isActive = false } }
            .store(in: &listeners)
    }
}

/// Decides when the bots in a window animate (see `botsLive`).
///
/// Rule: a person must be able to see them. So the window has to be showing (not minimised,
/// obscured, on a different Space, or behind a locked screen), and the main window also needs Nollie
/// frontmost. Activity decides, not key-window state: the voice window is key while it runs, yet
/// the bots behind it should keep moving. Two views opt out with `needsKey: false` and
/// only need to be on screen: the menu bar panel and the voice window that floats.
struct BotWindowLiveness: ViewModifier {
    var needsKey: Bool

    @State private var onScreen = true
    @Environment(\.appearsActive) private var windowActive

    func body(content: Content) -> some View {
        let appInFront = FrontApp.shared.isActive
        let someoneCanSee = onScreen && (windowActive || appInFront || !needsKey)
        return content
            .background(OnScreenProbe(isOnScreen: $onScreen))
            .environment(\.botsLive, someoneCanSee)
    }
}

extension View {
    func botWindowLiveness(needsKey: Bool) -> some View {
        let rule = BotWindowLiveness(needsKey: needsKey)
        return modifier(rule)
    }
}

/// An invisible view that reports whether its window is visible.
private struct OnScreenProbe: NSViewRepresentable {
    @Binding var isOnScreen: Bool

    func makeNSView(context: Context) -> Watcher {
        let watcher = Watcher()
        let binding = $isOnScreen
        watcher.report = { visible in
            guard binding.wrappedValue != visible else { return }
            binding.wrappedValue = visible
        }
        return watcher
    }

    func updateNSView(_ view: Watcher, context: Context) {
        view.look()
    }

    final class Watcher: NSView {
        var report: (Bool) -> Void = { _ in }
        private var listeners: Set<AnyCancellable> = []

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            listeners.removeAll()
            guard let window else { return send(false) }

            let center = NotificationCenter.default
            let changes = [
                NSWindow.didChangeOcclusionStateNotification,
                NSWindow.didMiniaturizeNotification,
                NSWindow.didDeminiaturizeNotification,
            ]
            Publishers.MergeMany(changes.map { center.publisher(for: $0, object: window) })
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in MainActor.assumeIsolated { self?.look() } }
                .store(in: &listeners)
            look()
        }

        func look() {
            guard let window else { return send(false) }
            send(window.occlusionState.contains(.visible) && !window.isMiniaturized)
        }

        /// Handed over a turn later: a window can change while SwiftUI is in the middle of layout.
        private func send(_ visible: Bool) {
            Task { @MainActor [weak self] in self?.report(visible) }
        }
    }
}
