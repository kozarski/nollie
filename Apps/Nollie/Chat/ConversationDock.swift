import SwiftUI
import NollieCore

/// Whatever sits at the bottom of a chat: a notice, the queue, then the composer or a card.
/// A single glass container lets the composer fold into a card and back out.
struct BottomDock: View {
    @Bindable var chat: ChatSession
    /// A card that asks something (a password, a choice) and takes the composer's place.
    /// Approvals are different: they sit in the thread and the composer stays below them.
    private var question: PendingCard? { chat.cards.first { $0.method != "approval" } }
    @Binding var text: String
    @Binding var quote: String
    private let spacing: CGFloat = 12
    var namespace: Namespace.ID
    /// Set for another bot's chat, where a Read-only pill takes the composer's place.
    var readOnly = false

    var body: some View {
        // Only the parts that morph sit inside the container. Menus inside it, like the + button's,
        // stopped answering taps on the phone, which is why the composer paints its own glass.
        GlassEffectContainer(spacing: spacing) {
            stack
        }
        .animation(.snappy, value: question?.id)
        .animation(.snappy, value: chat.banner)
    }

    private var stack: some View {
        VStack(spacing: 10) {
            notice
            if !chat.queue.isEmpty { QueueStrip(chat: chat) }
            occupant
        }
        .inset(h: spacing)
        .padding(.bottom, 8)
    }

    @ViewBuilder private var notice: some View {
        if let banner = chat.banner {
            DockBanner(words: banner) { chat.banner = nil }
        }
    }

    @ViewBuilder private var occupant: some View {
        if readOnly {
            readOnlyPill
        } else if let question {
            // No context menu on this card; the secure field was prone to misbehave under a long press when the menu came up empty.
            PendingCardView(chat: chat, card: question)
                .glassEffectID("dock", in: namespace)
        } else {
            composer
        }
    }

    private var composer: some View {
        ComposerView(chat: chat, text: $text, quote: $quote, namespace: namespace)
    }

    /// Stands in for the composer in a chat from another bot, opened from a notice. People can read
    /// it, not reply, and its cards stay with the bot they belong to.
    private var readOnlyPill: some View {
        Label("Read-only", systemImage: "lock")
            .quiet(.subheadline.weight(.medium))
            .inset(h: 16, v: 10)
            .nollieGlass(.regular, in: .capsule)
            .glassEffectID("dock", in: namespace)
            .accessibilityLabel("Read-only. This chat belongs to another bot.")
    }
}

/// A short notice above the composer that can be closed.
private struct DockBanner: View {
    var words: String
    var dismiss: () -> Void

    private static let slideUp = AnyTransition.opacity.combined(with: .move(edge: .bottom))

    var body: some View {
        HStack {
            Text(words).font(.footnote).lineLimit(3)
            Spacer()
            PlainButton(action: dismiss) { Glyph("xmark.circle.fill", .body, .secondary) }
        }
        .padding(12)
        .nollieGlass(.regular, in: RoundedRectangle(cornerRadius: 16))
        .transition(Self.slideUp)
    }
}

/// Messages waiting until the bot is done. Each can be reworded or taken out.
struct QueueStrip: View {
    @Bindable var chat: ChatSession
    @State private var editing: QueuedMessage?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Queued (\(chat.queue.count))").quiet(.caption.weight(.semibold))
            ForEach(chat.queue, content: row)
        }
        .padding(12)
        .nollieGlass(.regular, in: .rect(cornerRadius: 16))
        .modifier(QueueEditor(chat: chat, editing: $editing))
    }

    private func row(_ message: QueuedMessage) -> some View {
        HStack {
            Text(message.summary).font(.subheadline).lineLimit(2)
            Spacer()
            PlainButton { editing = message } label: { Image(systemName: "pencil") }
            PlainButton(role: .destructive) { chat.removeQueued(message.id) } label: { Image(systemName: "trash") }
        }
    }
}

/// The alert for editing the wording of a queued message.
private struct QueueEditor: ViewModifier {
    var chat: ChatSession
    @Binding var editing: QueuedMessage?
    @State private var words = ""

    private var isOpen: Binding<Bool> {
        Binding { editing != nil } set: { open in
            if !open { editing = nil }
        }
    }

    func body(content: Content) -> some View {
        content
            .alert("Edit queued message", isPresented: isOpen) {
                TextField("Message", text: $words)
                Button("Save", action: save)
                Button("Cancel", role: .cancel) { editing = nil }
            }
            .onChange(of: editing) { _, picked in
                if let picked { words = picked.text }
            }
    }

    private func save() {
        if let editing { chat.updateQueued(editing.id, text: words) }
        editing = nil
    }
}
