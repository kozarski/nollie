import PhotosUI
import SwiftUI
import UniformTypeIdentifiers
import NollieCore

/// Compose, in the style of Messages. A To: field takes the bot, matching bots appear as cards
/// beneath it, and the first message is written at the bottom.
struct NewChatSheet: View {
    struct Start {
        var profile: String
        var text: String
        var attachments: [AttachmentPreview]
    }

    var runtime: GatewayRuntime
    var onStart: (Start) -> Void

    @Environment(\.dismiss) private var dismiss
    @AppStorage(ChatStyle.returnSends) private var returnSends: Bool = false
    @State private var draft = NewChatDraft()
    @State private var recipient = Recipient()
    @FocusState private var toFocused: Bool
    /// The message field is UIKit, so its focus is tracked with a flag of our own.
    @State private var messageFocused = false
    @State private var sources = AttachSources()
    /// The sheet's size and where the message row sits in it, so the attach panel and the tap
    /// catcher around it fit the sheet itself.
    @State private var sheetSize = CGSize.zero
    @State private var rowFrame = CGRect.zero
    nonisolated private static let space = "newchat.sheet"

    private var canSend: Bool { recipient.bot != nil && draft.hasContent }

    private func focus(to: Bool, message: Bool) {
        toFocused = to
        messageFocused = message
    }

    var body: some View {
        let matches = recipient.matches(in: runtime.profiles)
        VStack(spacing: 0) {
            header
            RecipientRow(recipient: recipient, focus: $toFocused, matches: matches,
                         onPicked: pick, onPlus: { focus(to: true, message: false) })
            BotMatchList(matches: matches, typed: recipient.words, problem: draft.problem, onPicked: pick)
            firstMessage
        }
        .coordinateSpace(.named(Self.space))
        .onGeometryChange(for: CGSize.self) { $0.size } action: { sheetSize = $0 }
        .presentationDetents([.large])
        .presentationDragIndicator(.hidden)
        .onAppear { toFocused = true }
        .modifier(hooks)
    }

    private var hooks: AttachSourceHooks {
        AttachSourceHooks(sources: sources,
                          onPhotos: { await draft.take(photos: $0) },
                          onCamera: { data, name in draft.hold(data, name: name, kind: .image) },
                          onFiles: { $0.forEach(draft.take(file:)) },
                          onAudio: { draft.take(file: $0) })
    }

    private func send() async {
        guard let bot = recipient.bot, canSend else { return }
        onStart(Start(profile: bot.name, text: draft.trimmedText, attachments: draft.files))
        dismiss()
    }

    private func pick(_ bot: ProfileInfo) {
        recipient.choose(bot)
        focus(to: false, message: true)
    }

    private var header: some View {
        HStack {
            Color.clear.frame(square: 40)
            Spacer()
            Text("New Message").font(.headline)
            Spacer()
            GlassCircleButton(symbol: "xmark", diameter: 40, action: { dismiss() })
                .accessibilityLabel("Close")
        }
        .padding(EdgeInsets(top: 14, leading: 16, bottom: 10, trailing: 16))
    }

    // MARK: The first message

    private var firstMessage: some View {
        VStack(spacing: 8) {
            if !draft.files.isEmpty {
                StagedStrip(files: draft.files) { draft.drop($0) }
                    // Without a fixed height the scroll view takes room the bot list needs.
                    .frame(height: StagedCard.side + 12)
            }
            messageRow
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(Self.space)) } action: { rowFrame = $0 }
                .overlay(alignment: .topLeading) { attachPopup }
                .background(alignment: .topLeading) { outsideTapCatcher }
                // Room for the panel: from under the sheet's header down to the row.
                .environment(\.attachPanelRoom, max(0, rowFrame.minY - 80))
        }
        .inset(h: 16, v: 8)
    }

    private var messageRow: some View {
        HStack(alignment: .bottom, spacing: 8) {
            attachButton
            fieldAndSend
        }
    }

    private var fieldAndSend: some View {
        HStack(alignment: .bottom, spacing: 6) {
            messageField
            sendButton
        }
        .frame(minHeight: 36)
        // Not the interactive style, which grabbed touches meant for the Paste menu.
        .nollieGlass(.regular, in: .rect(cornerRadius: 18))
    }

    private var messageField: some View {
        let hint = recipient.bot == nil
            ? String(localized: "Choose a bot first")
            : String(localized: "Message", comment: "Placeholder in the message box")
        return ComposerTextView(text: $draft.text, placeholder: hint, focused: $messageFocused,
                                accessibilityID: "newchat.text",
                                onSend: { Task { await send() } },
                                onPasteData: { bytes, filename, kind in draft.hold(bytes, name: filename, type: kind) },
                                returnSends: returnSends)
            .inset(v: 7)
            .padding(.leading, 14)
            .disabled(recipient.bot == nil)
    }

    private var attachButton: some View {
        PlainButton {
            if !sources.panelOpen { focus(to: false, message: false) }
            withAnimation(.snappy(duration: 0.32)) { sources.panelOpen.toggle() }
        } label: {
            Glyph("plus", .body.weight(.semibold))
                .rotationEffect(.degrees(sources.panelOpen ? 45 : 0))
                .frame(square: 36)
                .nollieGlass(.regular.interactive(), in: .circle)
        }
        .disabled(recipient.bot == nil)
        .accessibilityLabel(sources.panelOpen ? "Close attach panel" : "Attach")
        .accessibilityIdentifier("newchat.attach")
    }

    private var sendButton: some View {
        let fill: AnyShapeStyle = canSend ? AnyShapeStyle(Color.nollie) : AnyShapeStyle(.tertiary)
        return PlainButton { Task { await send() } } label: {
            Glyph("arrow.up", .body.weight(.bold), .white)
                .frame(square: 28)
                .background(fill, in: .circle)
        }
        .disabled(!canSend)
        .padding([.trailing, .bottom], 4)
        .accessibilityLabel("Send")
        .accessibilityIdentifier("newchat.send")
    }

    private func closePanel() {
        withAnimation(.snappy(duration: 0.28)) { sources.panelOpen = false }
    }

    /// The panel opens upward from the + button, above the message field.
    @ViewBuilder private var attachPopup: some View {
        if sources.panelOpen {
            AttachPanel(items: sources.items(paste: draft.takeFromClipboard), close: closePanel)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { sources.panelHeight = $0 }
                .offset(y: -(sources.panelHeight + 10))
                .transition(.opacity.combined(with: .scale(scale: 0.2, anchor: .bottomLeading)))
                .zIndex(2)
        }
    }

    /// Catches a tap anywhere in the sheet outside the panel and closes it. It hangs behind the
    /// message row, stretched to cover the whole sheet from there.
    @ViewBuilder private var outsideTapCatcher: some View {
        if sources.panelOpen {
            Color.clear
                .contentShape(.rect)
                .frame(width: sheetSize.width, height: sheetSize.height)
                .offset(x: -rowFrame.minX, y: -rowFrame.minY)
                .onTapGesture(perform: closePanel)
        }
    }
}
