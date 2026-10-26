import SwiftUI
import NollieCore

/// The screens a conversation can open over itself.
enum ConversationPanel: Hashable {
    case context, profile, computer, watch, rename, editBot
}

/// What the header and the Mac toolbar can ask of the conversation they belong to.
struct ConversationActions {
    var show: (ConversationPanel) -> Void
    var newChat: () -> Void
    /// Leaves the screen; `close` also closes the chat.
    var back: () -> Void
    var close: () -> Void
}

/// The sheets over a conversation, each shown while its panel is in `open`.
struct ConversationSheets: ViewModifier {
    var chat: ChatSession
    @Binding var open: Set<ConversationPanel>

    private func flag(_ panel: ConversationPanel) -> Binding<Bool> {
        Binding(get: { open.contains(panel) }, set: { on in
            if on { open.insert(panel) } else { open.remove(panel) }
        })
    }

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: flag(.context)) { ContextBreakdownSheet(chat: chat).sheetFrame().withAppModel() }
            .sheet(isPresented: flag(.profile)) {
                ProfileInfoSheet(chat: chat, profileName: chat.profileName).sheetFrame().withAppModel()
            }
            .sheet(isPresented: flag(.computer)) { ComputerView(chat: chat).withAppModel() }
            .modifier(WatchPresenter(isPresented: flag(.watch), chat: chat))
            .renameSheet(for: chat, isPresented: flag(.rename))
            .sheet(isPresented: flag(.editBot)) {
                if let bot = chat.runtime.profiles.first(where: { $0.name == chat.profileName }) {
                    NewBotSheet(runtime: chat.runtime, editing: bot).sheetFrame().withAppModel()
                }
            }
    }
}

/// Watch takes over the whole phone screen, yet on a Mac it opens in a sheet.
private struct WatchPresenter: ViewModifier {
    var isPresented: Binding<Bool>
    var chat: ChatSession

    func body(content: Content) -> some View {
        #if os(iOS)
        content.fullScreenCover(isPresented: isPresented) { WatchView(chat: chat).withAppModel() }
        #else
        content.sheet(isPresented: isPresented) { WatchView(chat: chat).withAppModel() }
        #endif
    }
}

/// Approving or denying from a notification, when "Confirm approvals" is on, gets one more question on the
/// card it concerns.
struct ApprovalConfirmation: ViewModifier {
    @Environment(AppModel.self) private var model
    var chat: ChatSession
    @Binding var asked: ApprovalConfirm?

    private var denying: Bool { asked?.choice == "deny" }

    private var shown: Binding<Bool> {
        Binding(get: { asked != nil }, set: { if !$0 { clear() } })
    }

    private func clear() {
        asked = nil
        model.approvalConfirm = nil
    }

    func body(content: Content) -> some View {
        content
            .alert(denying ? "Deny this action?" : "Approve this action?", isPresented: shown) {
                Button(denying ? "Deny" : "Allow once", role: denying ? .destructive : nil, action: confirm)
                Button("Cancel", role: .cancel, action: clear)
            } message: {
                Text(words)
            }
            .onChange(of: model.approvalConfirm, initial: true) { _, pending in
                if let pending, pending.storedID == chat.storedID { asked = pending }
            }
    }

    private var waitingCard: PendingCard? {
        asked.flatMap { chat.approvalCard(named: [$0.cardID]) }
    }

    private var words: String {
        guard let request = waitingCard?.approval else { return "That request is not waiting any more." }
        return ConversationView.confirmWords(request)
    }

    private func confirm() {
        if let asked, let card = waitingCard, !model.awayBlocks() {
            Task { await chat.respond(card: card, result: ["choice": .string(asked.choice)]) }
        }
        clear()
    }
}

/// Keeps the app model's idea of the visible chat right as the chat appears, is covered, and goes.
@MainActor
struct ChatVisibility: ViewModifier {
    @Environment(AppModel.self) private var model
    var chat: ChatSession
    var requestedID: String?
    var obscured: Bool
    var clearRead: () -> Void

    func body(content: Content) -> some View {
        content
            .onAppear(perform: appeared)
            .onChange(of: obscured) { _, covered in
                // A dismissed sheet from an older chat cannot change the current chat's visibility.
                guard model.visibleChat === chat else { return }
                model.visibleChatIsObscured = covered
                if !covered { clearRead() }
            }
            .onChange(of: model.botSheet) { _, sheet in if sheet == nil { clearRead() } }
            // Anything that came in for this chat during its absence counts as read now, and its notifications
            // leave Notification Center.
            .onChange(of: chat.items.count) { clearRead() }
            .onDisappear(perform: left)
    }

    private func appeared() {
        model.visibleChatID = chat.storedID
        model.visibleChat = chat
        model.visibleChatRequestedID = requestedID
        model.visibleChatIsObscured = obscured
        clearRead()
    }

    private func left() {
        if model.visibleChatID == chat.storedID { model.visibleChatID = nil }
        if model.visibleChat === chat {
            model.visibleChat = nil
            model.visibleChatRequestedID = nil
            model.visibleChatIsObscured = false
        }
        // When a chat is left, return to the default bot if one is set.
        model.runtime?.returnToDefaultProfile()
    }
}
