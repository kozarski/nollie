import AppKit
import SwiftUI

struct OnboardingWindowHeightKey: PreferenceKey {
    static var defaultValue: CGFloat { 740 }
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

/// The scene starts with SwiftUI's interactive plain window. This adapter adds the
/// normal app chrome outside setup and restores the window after the glass card closes.
struct OnboardingWindowSize: NSViewRepresentable {
    var isPresented: Bool
    var preferredHeight: CGFloat = 740
    var mainWindowUsesGlass = false

    func makeNSView(context: Context) -> Probe { Probe() }
    func updateNSView(_ view: Probe, context: Context) {
        view.setPresented(isPresented, height: preferredHeight, mainWindowUsesGlass: mainWindowUsesGlass)
    }

    static func dismantleNSView(_ view: Probe, coordinator: ()) { view.detach() }

    final class Probe: NSView {
        private var presented = false
        private weak var managedWindow: NSWindow?
        private var previous: WindowState?
        private var applying = false
        private var updateScheduled = false
        private var detached = false
        private var normalAppearanceInstalled = false
        private var exitingFullScreen = false
        private var restoreFullScreen = false
        private var preferredHeight: CGFloat = 740
        private var appliedHeight: CGFloat?
        private var mainWindowUsesGlass = false

        private static let normalStyle: NSWindow.StyleMask = [
            .titled, .closable, .miniaturizable, .resizable, .fullSizeContentView
        ]

        private struct WindowState {
            let frame: NSRect
            let style: NSWindow.StyleMask
            let background: NSColor
            let opaque: Bool
            let titlebarTransparent: Bool
            let titlebarSeparator: NSTitlebarSeparatorStyle
            let titleVisibility: NSWindow.TitleVisibility
            let movableByBackground: Bool
            let hasShadow: Bool
            let collectionBehavior: NSWindow.CollectionBehavior
            let tabbingMode: NSWindow.TabbingMode
            let toolbar: NSToolbar?
            let toolbarVisible: Bool?

            @MainActor init(_ window: NSWindow, initiallyPlain: Bool) {
                frame = window.frame
                style = initiallyPlain ? Probe.normalStyle : window.styleMask
                background = initiallyPlain ? .windowBackgroundColor : window.backgroundColor
                opaque = initiallyPlain || window.isOpaque
                titlebarTransparent = initiallyPlain ? false : window.titlebarAppearsTransparent
                titlebarSeparator = window.titlebarSeparatorStyle
                titleVisibility = initiallyPlain ? .visible : window.titleVisibility
                movableByBackground = window.isMovableByWindowBackground
                hasShadow = window.hasShadow
                collectionBehavior = window.collectionBehavior
                tabbingMode = window.tabbingMode
                toolbar = window.toolbar
                toolbarVisible = window.toolbar?.isVisible
            }
        }

        func setPresented(_ value: Bool, height: CGFloat, mainWindowUsesGlass: Bool) {
            presented = value
            preferredHeight = height
            self.mainWindowUsesGlass = mainWindowUsesGlass
            scheduleUpdate()
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window {
                if managedWindow !== window {
                    NotificationCenter.default.removeObserver(self)
                    managedWindow = window
                    normalAppearanceInstalled = false
                }
                NotificationCenter.default.removeObserver(self, name: NSWindow.didBecomeKeyNotification, object: window)
                NotificationCenter.default.removeObserver(self, name: NSWindow.didExitFullScreenNotification, object: window)
                NotificationCenter.default.removeObserver(self, name: NSWindow.didUpdateNotification, object: window)
                NotificationCenter.default.addObserver(self, selector: #selector(windowBecameKey),
                                                      name: NSWindow.didBecomeKeyNotification, object: window)
                NotificationCenter.default.addObserver(self, selector: #selector(windowExitedFullScreen),
                                                      name: NSWindow.didExitFullScreenNotification, object: window)
                NotificationCenter.default.addObserver(self, selector: #selector(windowUpdated),
                                                      name: NSWindow.didUpdateNotification, object: window)
            }
            scheduleUpdate()
        }

        @objc private func windowBecameKey() { scheduleUpdate() }
        @objc private func windowUpdated() {
            guard !presented, let window = managedWindow else { return }
            positionWindowControls(window)
        }
        @objc private func windowExitedFullScreen() {
            exitingFullScreen = false
            scheduleUpdate()
        }

        private func scheduleUpdate() {
            guard !detached, !updateScheduled else { return }
            updateScheduled = true
            // Changing .titled rebuilds AppKit's frame-view hierarchy. Never do that
            // while SwiftUI is attaching a representable or AppKit is notifying views.
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.updateScheduled = false
                guard !self.detached else { return }
                self.applyIfReady()
            }
        }

        private func applyIfReady() {
            guard let window = managedWindow, !applying else { return }
            guard presented else {
                if previous != nil {
                    restore()
                } else if !normalAppearanceInstalled {
                    normalAppearanceInstalled = true
                    let fullScreen = window.styleMask.intersection(.fullScreen)
                    window.styleMask = Self.normalStyle.union(fullScreen)
                    window.titleVisibility = .visible
                }
                applyMainWindowAppearance(window)
                return
            }
            if previous != nil {
                if appliedHeight != resolvedHeight { resize(window, firstPresentation: false) }
                return
            }
            if window.styleMask.contains(.fullScreen) {
                guard !exitingFullScreen else { return }
                restoreFullScreen = true
                exitingFullScreen = true
                window.toggleFullScreen(nil)
                return
            }
            applying = true
            defer { applying = false }
            let wasKey = window.isKeyWindow
            previous = WindowState(window, initiallyPlain: !normalAppearanceInstalled)
            // Keep resize and close behavior while removing all system frame artwork.
            // Keyboard focus comes from the scene's native plain-window implementation.
            let setupStyle: NSWindow.StyleMask = [.borderless, .closable, .resizable]
            if window.styleMask != setupStyle { window.styleMask = setupStyle }
            window.titleVisibility = .hidden
            window.toolbar?.isVisible = false
            window.tabbingMode = .disallowed
            window.collectionBehavior.remove(.fullScreenPrimary)
            window.collectionBehavior.insert(.fullScreenNone)
            window.isMovableByWindowBackground = false
            window.hasShadow = true
            window.isOpaque = false
            window.backgroundColor = .clear
            window.titlebarAppearsTransparent = true
            resize(window, firstPresentation: true)
            if wasKey { window.makeKeyAndOrderFront(nil) }
        }

        private func applyMainWindowAppearance(_ window: NSWindow) {
            let background: NSColor = mainWindowUsesGlass ? .clear : .windowBackgroundColor
            if window.isOpaque == mainWindowUsesGlass { window.isOpaque = !mainWindowUsesGlass }
            if window.backgroundColor != background { window.backgroundColor = background }
            // The sidebar card continues behind the native controls. The window owns one
            // backing surface that survives every pushed page.
            if !window.titlebarAppearsTransparent { window.titlebarAppearsTransparent = true }
            if window.titlebarSeparatorStyle != .none { window.titlebarSeparatorStyle = .none }
            positionWindowControls(window)
        }

        /// Keep AppKit's real controls, inset from the rounded card's top and left edges.
        /// Their native spacing, actions and full-screen presentation stay with AppKit.
        private func positionWindowControls(_ window: NSWindow) {
            guard !window.styleMask.contains(.fullScreen),
                  let close = window.standardWindowButton(.closeButton),
                  !close.isHidden, close.superview != nil else { return }
            let controls = [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton]
                .compactMap { window.standardWindowButton($0) }
            let closeFrame = close.convert(close.bounds, to: nil)
            let target = NSPoint(x: 32, y: window.frame.height - 30 - closeFrame.height)
            let delta = NSSize(width: target.x - closeFrame.minX, height: target.y - closeFrame.minY)
            guard abs(delta.width) > 0.5 || abs(delta.height) > 0.5 else { return }
            for button in controls {
                guard let parent = button.superview else { continue }
                let frame = button.convert(button.bounds, to: nil).offsetBy(dx: delta.width, dy: delta.height)
                button.setFrameOrigin(parent.convert(frame, from: nil).origin)
            }
        }

        private var resolvedHeight: CGFloat {
            #if DEBUG
            let args = ProcessInfo.processInfo.arguments
            if DemoMode.isOn, let i = args.firstIndex(of: "-nollie-demo-onboarding-height"),
               args.indices.contains(i + 1), let value = Double(args[i + 1]), value.isFinite {
                return CGFloat(min(1200, max(440, value)))
            }
            #endif
            return preferredHeight.isFinite ? min(1200, max(440, preferredHeight)) : 740
        }

        private func resize(_ window: NSWindow, firstPresentation: Bool) {
            let visible = window.screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1200, height: 1000)
            let width = min(firstPresentation ? 860 : window.frame.width, max(320, visible.width - 48))
            let height = min(resolvedHeight, max(320, visible.height - 48))
            let center = firstPresentation ? CGPoint(x: visible.midX, y: visible.midY)
                                          : CGPoint(x: window.frame.midX, y: window.frame.midY)
            let x = min(max(visible.minX, center.x - width / 2), visible.maxX - width)
            let y = min(max(visible.minY, center.y - height / 2), visible.maxY - height)
            appliedHeight = resolvedHeight
            window.setFrame(NSRect(x: x, y: y, width: width, height: height), display: true)
        }

        private func restore() {
            guard let window = managedWindow, let previous, !applying else { return }
            applying = true
            self.previous = nil
            appliedHeight = nil
            normalAppearanceInstalled = true
            Self.restore(previous, to: window)
            applying = false
            if restoreFullScreen && !window.styleMask.contains(.fullScreen) {
                restoreFullScreen = false
                window.toggleFullScreen(nil)
            }
        }

        private static func restore(_ previous: WindowState, to window: NSWindow) {
            window.styleMask = previous.style
            window.titleVisibility = previous.titleVisibility
            window.titlebarAppearsTransparent = previous.titlebarTransparent
            window.titlebarSeparatorStyle = previous.titlebarSeparator
            window.backgroundColor = previous.background
            window.isOpaque = previous.opaque
            window.isMovableByWindowBackground = previous.movableByBackground
            window.hasShadow = previous.hasShadow
            window.collectionBehavior = previous.collectionBehavior
            window.tabbingMode = previous.tabbingMode
            if window.toolbar === previous.toolbar, let visible = previous.toolbarVisible {
                window.toolbar?.isVisible = visible
            }
            window.setFrame(previous.frame, display: true)
        }

        func detach() {
            detached = true
            NotificationCenter.default.removeObserver(self)
            guard let window = managedWindow, let previous else { return }
            self.previous = nil
            // Teardown can also happen during layout. Restore only after it unwinds.
            DispatchQueue.main.async {
                Self.restore(previous, to: window)
            }
        }
    }
}
