import SwiftUI
import NollieCore

#if os(iOS)
/// The phone's floating header: the contact pill, the Watch pill and the board card, as one
/// group that reports its height.
struct ConversationTopBar: View {
    var chat: ChatSession
    var actions: ConversationActions
    @Binding var metrics: ThreadMetrics

    var body: some View {
        VStack(spacing: 0) {
            ChatHeader(chat: chat, onBack: actions.back, onProfile: { actions.show(.profile) },
                       onComputer: { actions.show(.computer) }, onRename: { actions.show(.rename) },
                       onContext: { actions.show(.context) }, onEditBot: { actions.show(.editBot) },
                       onNewChat: actions.newChat, onClose: actions.close)
                .fixedSize(horizontal: false, vertical: true)
            WatchPill(chat: chat) { actions.show(.watch) }
                .padding(.top, 6)
                .animation(.snappy, value: BotComputerActivity.isActive(runtime: chat.runtime, profile: chat.profileName))
            BoardContextStrip(chat: chat)
        }
        // The overlay gets the thread's full height; the stack stays at its content height so
        // the task card sits right under the contact header.
        .fixedSize(horizontal: false, vertical: true)
        .background(Ink.canvas.ignoresSafeArea(edges: .top))
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { if metrics.plausibleHeader($0) { metrics.header = $0 } }
        // Single VoiceOver group, ordered behind the thread and dock. Accessibility hit tests visit elements
        // from the back of the order forwards, and the thread reaches under the header, so listing the
        // header last makes it get tried first, like a finger touching the topmost view. Swipe navigation
        // arrives after the composer, whereas VoiceOver begins at Back (see `ChatHeader`).
        .accessibilityElement(children: .contain)
        .accessibilitySortPriority(-1)
    }
}
#endif
