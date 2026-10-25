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

    /// Margins for the thread as (dock top, fallback bottom, top). Mac puts the dock in a bottom inset
    /// and uses the window toolbar as header, so the thread needs no extra space there.
    var thread: (dockTop: CGFloat, fallback: CGFloat, top: CGFloat) {
        #if os(macOS)
        (0, 0, 0)
        #else
        (dockTop, dock + keyboard, header + Self.statusBarHeight)
        #endif
    }

    #if os(iOS)
    private static var window: UIWindow? {
        UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow }.first
    }
    static var statusBarHeight: CGFloat { window?.safeAreaInsets.top ?? 0 }
    /// Height of the home indicator area under the key window; zero without one.
    static var homeIndicatorHeight: CGFloat { window?.safeAreaInsets.bottom ?? 0 }

    /// How much room a keyboard frame change asks for; nil when the frame is not an actual keyboard.
    /// Floating keyboards, a hardware keyboard's accessory bar, frames from other scenes and
    /// full-screen rectangles would otherwise fling the dock upward. Genuine keyboards are pinned to
    /// the bottom edge and stop short of two thirds of the screen height.
    static func keyboardInset(_ note: Notification) -> CGFloat? {
        guard let value = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue else { return nil }
        let frame = value.cgRectValue
        let screen = UIScreen.main.bounds
        let visible = frame.intersection(screen)
        let hugsBottom = visible.isNull || visible.maxY >= screen.maxY - 1 || frame.minY >= screen.maxY
        guard hugsBottom, frame.height < screen.height * 0.66 else { return nil }
        let raised = max(0, screen.maxY - frame.minY) - homeIndicatorHeight
        return min(max(0, raised), screen.height * 0.6)
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
            .overlay(alignment: .bottom) { dock }
            .overlay(alignment: .top) { header }
            .ignoresSafeArea(.keyboard, edges: .bottom)
            .onReceive(keyboardChanges, perform: followKeyboard)
        #endif
    }

    #if os(iOS)
    private var keyboardChanges: NotificationCenter.Publisher {
        NotificationCenter.default.publisher(for: UIResponder.keyboardWillChangeFrameNotification)
    }

    private func followKeyboard(_ note: Notification) {
        guard let inset = ThreadMetrics.keyboardInset(note) else { return }
        withAnimation(.interpolatingSpring(mass: 3, stiffness: 1000, damping: 500, initialVelocity: 0)) {
            metrics.keyboard = inset
        }
    }
    #endif
}

/// Copies the dock's height and its on-screen top edge into the metrics, and lifts the dock above
/// the keyboard.
struct DockMeasured: ViewModifier {
    @Binding var metrics: ThreadMetrics

    func body(content: Content) -> some View {
        content
            // A height of zero means the dock isn't laid out yet, and must not wipe the fallback.
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                if (1..<400).contains(height) { metrics.dock = height }
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
