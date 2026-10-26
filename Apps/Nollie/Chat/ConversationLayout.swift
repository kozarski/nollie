import SwiftUI
import NollieCore

/// Heights and offsets of the dock, header and keyboard, so the thread can keep its last line clear.
struct ThreadMetrics: Equatable {
    var dock: CGFloat = 60
    var dockTop: CGFloat = 0
    /// How far the keyboard rises over the home-indicator area. Tracked manually, since SwiftUI's
    /// avoidance gives the inset to a scroll view inside the dock and leaves the dock where it is.
    var keyboard: CGFloat = 0
    #if os(macOS)
    var header: CGFloat = 0
    #else
    var header: CGFloat = 96
    #endif
    /// The owning window's safe area at the top (status bar, island) and bottom (home indicator),
    /// measured from the window the chat is in and kept current as it resizes.
    var safeTop: CGFloat = 0
    var safeBottom: CGFloat = 0
    /// Height of the chat's own frame. A dock or header reporting more than fits in it is a
    /// half-done layout pass, not a measurement.
    var container: CGFloat = 0

    /// Whether `height` is believable for a dock (composer and any cards over it).
    func plausibleDock(_ height: CGFloat) -> Bool {
        height >= 1 && (container <= 0 || height < container * 0.75)
    }

    /// Whether `height` is believable for the floating header.
    func plausibleHeader(_ height: CGFloat) -> Bool {
        height >= 1 && (container <= 0 || height < container * 0.66)
    }

    /// Margins for the thread as (dock top, fallback bottom, top). Mac puts the dock in a bottom inset
    /// and uses the window toolbar as header, so the thread needs no extra space there.
    var thread: (dockTop: CGFloat, fallback: CGFloat, top: CGFloat) {
        #if os(macOS)
        (0, 0, 0)
        #else
        (dockTop, dock + keyboard, header + safeTop)
        #endif
    }

    /// Room the attach panel may take above the composer: from under the header to the dock.
    var roomAboveDock: CGFloat {
        guard dockTop > 0 else { return .infinity }
        return max(0, dockTop - header - safeTop - 16)
    }

    #if os(iOS)
    /// How much room a keyboard frame change asks for in `window`; nil when the frame is not an
    /// actual keyboard, or there is no window yet. The frame arrives in screen coordinates and is
    /// read in the window's own, so a window that is resized, moved or on another display still
    /// gets the right answer.
    @MainActor static func keyboardInset(_ note: Notification, in window: UIWindow?) -> CGFloat? {
        guard let window, let value = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue else { return nil }
        let space = window.windowScene?.screen.coordinateSpace ?? window.coordinateSpace
        let frame = window.convert(value.cgRectValue, from: space)
        return keyboardRise(frame, in: window.bounds, safeBottom: window.safeAreaInsets.bottom)
    }

    /// The keyboard's rise over a window's bottom safe area. Floating keyboards, a hardware keyboard's
    /// accessory bar, frames from other windows and full-screen rectangles would otherwise fling the
    /// dock upward. Genuine keyboards are pinned to the bottom edge and stop short of two thirds of
    /// the window's height.
    static func keyboardRise(_ frame: CGRect, in bounds: CGRect, safeBottom: CGFloat) -> CGFloat? {
        guard bounds.height > 0 else { return nil }
        let visible = frame.intersection(bounds)
        let hugsBottom = visible.isNull || visible.maxY >= bounds.maxY - 1 || frame.minY >= bounds.maxY
        guard hugsBottom, frame.height < bounds.height * 0.66 else { return nil }
        let raised = max(0, bounds.maxY - frame.minY) - safeBottom
        return min(max(0, raised), bounds.height * 0.6)
    }
    #endif
}

/// Floats the dock and header over the thread. On the phone both overlay the text, which scrolls
/// underneath their glass, with the keyboard followed by hand. The Mac's dock is a bottom inset.
struct ConversationFrame<Thread: View, Dock: View, Header: View>: View {
    @Binding var metrics: ThreadMetrics
    @ViewBuilder var thread: Thread
    @ViewBuilder var dock: Dock
    @ViewBuilder var header: Header

    var body: some View {
        #if os(macOS)
        VStack(spacing: 0) {
            header
            thread
        }
        .clipped()
        .safeAreaInset(edge: .bottom, spacing: 0) {
            dock
                .frame(maxWidth: Ink.composerWidth + 24)
                .spread(.center)
                .padding(.bottom, 12)
        }
        #else
        thread
            .overlay(alignment: .bottom) {
                // On a wide screen the composer keeps to the thread's reading column.
                dock
                    .frame(maxWidth: ReadingColumn.composer)
                    .spread(.center)
                    .environment(\.attachPanelRoom, metrics.roomAboveDock)
            }
            .overlay(alignment: .top) { header }
            .environment(\.threadViewport, metrics.container)
            .ignoresSafeArea(.keyboard, edges: .bottom)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { metrics.container = $0 }
            .background(WindowProbe(window: window) { insets in
                if metrics.safeTop != insets.top { metrics.safeTop = insets.top }
                if metrics.safeBottom != insets.bottom { metrics.safeBottom = insets.bottom }
            })
            .onReceive(keyboardChanges, perform: followKeyboard)
        #endif
    }

    #if os(iOS)
    /// The window this chat is drawn in, found by `WindowProbe`.
    @State private var window = WindowRef()

    private var keyboardChanges: NotificationCenter.Publisher {
        NotificationCenter.default.publisher(for: UIResponder.keyboardWillChangeFrameNotification)
    }

    private func followKeyboard(_ note: Notification) {
        guard let inset = ThreadMetrics.keyboardInset(note, in: window.window) else { return }
        withAnimation(.interpolatingSpring(mass: 3, stiffness: 1000, damping: 500, initialVelocity: 0)) {
            metrics.keyboard = inset
        }
    }
    #endif
}

/// The reading column on iPhone and iPad: wide screens keep the thread and composer to a
/// comfortable line length, centred. A phone is narrower than this, so nothing changes there.
enum ReadingColumn {
    #if os(macOS)
    static let thread = Ink.column
    static let composer = Ink.composerWidth + 24
    #else
    static let thread: CGFloat = 720
    static let composer: CGFloat = 764
    #endif
}

extension EnvironmentValues {
    /// Height the attach panel may use above the composer; infinite until the dock is measured.
    @Entry var attachPanelRoom: CGFloat = .infinity
}

#if os(iOS)
/// Holds the chat's window without keeping it alive.
final class WindowRef {
    weak var window: UIWindow?
}

/// Finds the window it is drawn in, and reports that window's safe area whenever it changes: on
/// first showing, rotating, resizing, or moving to the other display of a foldable.
struct WindowProbe: UIViewRepresentable {
    var window: WindowRef
    var changed: (UIEdgeInsets) -> Void

    func makeUIView(context: Context) -> Probe {
        let probe = Probe()
        probe.isUserInteractionEnabled = false
        return probe
    }

    func updateUIView(_ probe: Probe, context: Context) {
        probe.holder = window
        probe.changed = changed
    }

    final class Probe: UIView {
        var holder: WindowRef?
        var changed: ((UIEdgeInsets) -> Void)?
        private var last: UIEdgeInsets?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            report()
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            report()
        }

        override func safeAreaInsetsDidChange() {
            super.safeAreaInsetsDidChange()
            report()
        }

        private func report() {
            holder?.window = window
            guard let window, window.safeAreaInsets != last else { return }
            last = window.safeAreaInsets
            let insets = window.safeAreaInsets
            // Reported after this layout pass, not during it.
            DispatchQueue.main.async { [weak self] in self?.changed?(insets) }
        }
    }
}
#endif

/// Copies the dock's height and its on-screen top edge into the metrics, and lifts the dock above
/// the keyboard.
struct DockMeasured: ViewModifier {
    @Binding var metrics: ThreadMetrics

    func body(content: Content) -> some View {
        content
            // A height of zero means the dock isn't laid out yet, and must not wipe the fallback.
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                if metrics.plausibleDock(height) { metrics.dock = height }
            }
            .padding(.bottom, metrics.keyboard)
            // The dock's on-screen top, counting the keyboard. The thread takes its own bottom edge in the
            // same way and holds the last line over this one.
            .onGeometryChange(for: CGFloat.self, of: { $0.frame(in: .global).minY }, action: { metrics.dockTop = $0 })
    }
}

/// Shows the board task this chat was opened from, with a way to go back to it.
struct BoardContextStrip: View {
    @Environment(AppModel.self) private var model
    var chat: ChatSession

    var body: some View {
        if let context = model.boardChatContext,
           context.matches(connectionID: chat.runtime.connection.id, sessionID: chat.storedID) {
            BoardChatContextCard(context: context,
                                 onReturn: { model.returnToBoardTask(context) },
                                 onDismiss: { model.boardChatContext = nil })
                .frame(maxWidth: Ink.column)
                .fixedSize(horizontal: false, vertical: true)
                .inset(h: 16, v: 8)
        }
    }
}
