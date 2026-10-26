import PhotosUI
import SwiftUI
import UniformTypeIdentifiers
import NollieCore

/// The composer at the bottom of a chat: the + button and its panel, the text, and the round ink
/// button at the end that is the mic, send or stop depending on what the chat is doing.
struct ComposerView: View {
    /// Keyboard focus. It runs both ways because the text view underneath is UIKit.
    @State private var focused = false
    @State private var sources = AttachSources()
    @State private var dictation = DictationController()
    @State private var showHistory = false
    @State private var historyCursor: Int?
    /// True after a paste has put a long block of text in the field.
    @State private var longTextOffer = false
    @State private var attachTappedAt: Date?
    /// The Appearance setting that makes the on-screen Return send. Off, it adds a line.
    @AppStorage(ChatStyle.returnSends) private var returnSends = false

    @Bindable var chat: ChatSession
    @Binding var text: String
    /// The message being answered. It goes out as a quote above the new message.
    @Binding var quote: String
    /// The dock's morph namespace. Approval cards morph out of the text capsule alone, because the
    /// steer strip comes and goes beneath it.
    var namespace: Namespace.ID

    private var intake: ChatIntake { ChatIntake(chat: chat) }

    var body: some View {
        // The + button's glass turns into the panel's only inside one container. Matching ids
        // outside it did nothing and the panel simply scaled in.
        GlassEffectContainer(spacing: 0) { column }
    }

    // MARK: Layout

    private var column: some View {
        VStack(spacing: 8) {
            if longTextOffer {
                LongTextOffer(keep: { withAnimation(.snappy) { longTextOffer = false } }, attach: attachTextAsFile)
            }
            if !chat.staged.isEmpty { stagedStrip }
            if !quote.isEmpty {
                ReplyQuoteStrip(quote: quote) { withAnimation(.snappy) { quote = "" } }
            }
            if TalkMode.shared.isOn(in: chat) { TalkBar(namespace: namespace) } else { capsule }
            if chat.isRunning && !text.isEmpty { steerStrip }
        }
        .overlay(alignment: .topLeading) { panelOverlay }
        .background { outsideTap }
        .animation(.snappy(duration: 0.2), value: dictation.isListening)
        .modifier(DropAndImport(chat: chat, importFile: { intake.file($0) }))
        .modifier(lifecycle)
        .modifier(attachHooks)
        .modifier(VoiceHooks(chat: chat))
        .sheet(isPresented: $showHistory) { historySheet().withAppModel() }
    }

    private func historySheet() -> some View {
        HistorySheet(history: chat.composerHistory, pick: { text = $0 })
            .sheetFrame()
    }

    private var lifecycle: ComposerLifecycle {
        ComposerLifecycle(chat: chat,
                          dictationError: dictation.error,
                          clearDictationError: { dictation.error = nil },
                          takeFocus: takeFocusIfAsked,
                          focusNow: { focused = true })
    }

    private var attachHooks: AttachSourceHooks {
        AttachSourceHooks(sources: sources,
                          onPhotos: { await intake.photos($0) },
                          onCamera: { data, name in chat.stageAttachment(data: data, name: name, kind: .image) },
                          onFiles: { $0.forEach { intake.file($0) } },
                          onAudio: { intake.file($0, kind: .audio) })
    }

    private var stagedStrip: some View {
        StagedStrip(files: chat.staged) { id in
            withAnimation(.snappy) { chat.removeStaged(id) }
        }
    }

    /// The capsule: round + at the start, the words in the middle, the ink button at the end.
    private var capsule: some View {
        HStack(alignment: .bottom, spacing: 10) {
            plusButton
            middle.spread()
            if text.isEmpty && chat.staged.isEmpty && !dictation.isListening && !dictation.isTranscribing { TalkModeButton(chat: chat) }
            ComposerEndButton(chat: chat, text: text, dictation: dictation,
                              onSend: { await send() }, onDictated: dictated)
        }
        .padding(Ink.composerInset)
        .frame(minHeight: Ink.composerHeight)
        .composerSurface(namespace: namespace)
    }

    /// While the mic listens the field gives way to the waveform. The words arrive once it stops.
    @ViewBuilder private var middle: some View {
        if dictation.isListening {
            DictationWaveform(dictation: dictation)
                .padding(.vertical, (Ink.composerButton - 26) / 2)
                .transition(.opacity)
        } else {
            field
        }
    }

    private var steerStrip: some View {
        HStack {
            Text("Your bot is busy. Send queues this message.").quiet(.caption2)
            Spacer()
            Button("Steer now", action: steerNow).font(.caption2)
        }
        .inset(h: 8)
    }

    private func steerNow() {
        let words = text
        text = ""
        Task { await chat.steer(words) }
    }

    // MARK: The attach panel

    private var attachRows: [AttachItem] {
        let recall: (() -> Void)? = chat.composerHistory.isEmpty ? nil : { showHistory = true }
        return sources.items(paste: pasteFromClipboard, history: recall)
    }

    /// The panel opens from the + button yet floats over the entire composer, quote strip included.
    /// Attached to the button itself it would hide the strip.
    @ViewBuilder private var panelOverlay: some View {
        if sources.panelOpen {
            AttachPanel(items: attachRows, close: closePanel)
                .glassEffectID("attach", in: namespace)
                .onGeometryChange(for: CGFloat.self, of: { $0.size.height }, action: panelMeasured)
                .offset(y: -(sources.panelHeight + 10))
                // The glass opens from the button and tucks back into it, while the rows fade in and out.
                .glassEffectTransition(.matchedGeometry)
                .transition(.opacity)
                .zIndex(2)
        }
    }

    private func panelMeasured(_ height: CGFloat) {
        sources.panelHeight = height
        guard let tapped = attachTappedAt else { return }
        attachTappedAt = nil
        let millis = Int(Date().timeIntervalSince(tapped) * 1000)
        Perf.note("attach panel on screen \(millis) ms after the tap")
    }

    /// A tap outside the panel dismisses it. The tap catcher is deliberately huge.
    @ViewBuilder private var outsideTap: some View {
        if sources.panelOpen {
            Color.clear
                .contentShape(.rect)
                .frame(width: 3000, height: 4000)
                .onTapGesture(perform: closePanel)
        }
    }

    private func closePanel() {
        withAnimation(.snappy(duration: 0.28)) { sources.panelOpen = false }
    }

    private func togglePanel() {
        // Like the keyboard, the panel claims the bottom of the screen, as Messages does. If both
        // were open the panel climbed over the thread and hid the header.
        if !sources.panelOpen {
            focused = false
            attachTappedAt = Date()
        }
        withAnimation(.snappy(duration: 0.32)) { sources.panelOpen.toggle() }
    }

    /// The round +, pale grey in the capsule, turning into a cross while the panel is open.
    private var plusButton: some View {
        PlainButton(action: togglePanel) {
            Glyph("plus", .system(size: Ink.composerButton * 0.4, weight: .medium), Ink.text)
                .rotationEffect(.degrees(sources.panelOpen ? 45 : 0))
                .frame(square: Ink.composerButton)
                .background(Ink.plusFill, in: .circle)
                .contentShape(.circle)
        }
        .accessibilityLabel(sources.panelOpen ? "Close attach panel" : "Attach")
    }

    // MARK: Focus

    /// Ask Nollie opens the main chat only. Another chat still on screen must not grab the keyboard
    /// first, and behind App Lock nobody wants it.
    private func takeFocusIfAsked() {
        let model = AppModel.shared
        let mainEntry = BotsHome.shared.entry(chat.runtime, chat.profileName)
        let isMain = chat.storedID == model.composerFocusSession
            || chat.title == "Bot Chat"
            || mainEntry.storedID == chat.storedID
        guard model.composerFocusWanted, isMain else { return }
        model.composerFocusRequestedAt = nil
        // Wait a moment so the field is in its window and can take the keyboard.
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(400))
            focused = true
        }
    }

    // MARK: The words

    private var field: some View {
        ComposerTextView(text: $text, placeholder: "Message \(botName)", focused: $focused,
                         accessibilityID: "composer.text",
                         onSend: sendFromField,
                         onPasteData: { data, name, type in intake.pasted(data, name: name, type: type) },
                         onArrow: { recallHistory($0) },
                         returnSends: returnSends)
            .font(Ink.message)
            .inset(v: Ink.composerTextInset)
            .onChange(of: text) { old, new in offerFileForLongText(old: old, new: new) }
    }

    /// Offered once when the text turns long: a paste crosses the line in one jump, typing crosses
    /// it once. Choosing Keep stays dismissed until the text gets short again.
    private func offerFileForLongText(old: String, new: String) {
        guard let long = LongTextRule.verdict(old: old, new: new) else { return }
        if long {
            withAnimation(.snappy) { longTextOffer = true }
        } else {
            longTextOffer = false
        }
    }

    /// The name in the placeholder, such as "Message Nollie".
    private var botName: String {
        let profile = chat.runtime.profiles.first { $0.name == chat.profileName }
        return profile?.shownName ?? chat.profileName
    }

    private func dictated(_ words: String) {
        text = words
        focused = true
    }

    // MARK: Actions

    /// Moves the field's text into a staged text file and empties the field.
    private func attachTextAsFile() {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty, let data = body.data(using: .utf8) else { return }
        chat.stageAttachment(data: data, name: PastedTextFile.name(for: body), kind: .file)
        withAnimation(.snappy) {
            longTextOffer = false
            text = ""
        }
    }

    private func sendFromField() {
        Task { await send() }
    }

    private func send() async {
        // Away from home without Tailscale the app says so and keeps what was typed.
        guard !AppModel.shared.awayBlocks() else { return }
        let outgoing = QuotedMessage.wrap(text, quoting: quote)
        historyCursor = nil
        (quote, text, focused) = ("", "", true)
        NotificationCenter.default.post(name: .hermesMessageSent, object: chat)
        guard let restored = await chat.send(outgoing) else { return }
        text = restored
    }

    /// Steps through earlier messages with Up and Down. True if the key did something.
    private func recallHistory(_ step: Int) -> Bool {
        var recall = HistoryRecall(past: chat.composerHistory, cursor: historyCursor)
        let found = recall.step(step, fieldIsEmpty: text.isEmpty)
        historyCursor = recall.cursor
        guard let found else { return false }
        text = found
        return true
    }

    /// Paste from the attach menu: pictures and files become attachments and text goes in the field.
    private func pasteFromClipboard() {
        let board = UIPasteboard.general
        let stamp = Intake.stamp()
        if board.hasImages, let jpeg = board.image?.jpegData(compressionQuality: 0.9) {
            chat.stageAttachment(data: jpeg, name: "photo-\(stamp).jpg", kind: .image)
        } else if let words = board.string {
            text += words
        } else if let (identifier, value) = board.items.first?.first, let data = value as? Data {
            let type = UTType(identifier) ?? .data
            let ext = type.preferredFilenameExtension ?? "bin"
            intake.pasted(data, name: "pasted-\(stamp).\(ext)", type: type)
        } else {
            chat.banner = "There's nothing to paste."
        }
    }
}
