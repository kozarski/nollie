import SwiftUI
import NollieCore

extension Notification.Name {
    /// Posted when a message leaves the composer (object: its chat) so the thread jumps to the end.
    static let hermesMessageSent = Self("hermesMessageSent")
    /// Posted by a disclosure with its header's position on screen, before and while it resizes.
    static let hermesRevealRow = Self("hermesRevealRow")
}

/// Little arrow that quarter-turns when its section opens.
struct FoldChevron: View {
    var open: Bool
    var font: Font = .caption2.weight(.semibold)
    var tone: AnyShapeStyle = AnyShapeStyle(.secondary)

    var body: some View {
        Image(systemName: "chevron.right")
            .font(font)
            .foregroundStyle(tone)
            .rotationEffect(.degrees(open ? 90 : 0))
    }
}

/// Shown when a bot's model won't start on the gateway, say because a provider's tool or key is
/// missing. It states the problem in simple words and points to where it can be fixed.
struct StartFailureCard: View {
    var failure: StartFailure
    var raw: String

    @State private var showRaw = false

    private var explanation: String {
        guard let provider = failure.provider else { return failure.reason }
        return "This bot uses \(provider), which needs its own command-line tool set up on the gateway computer. Nollie can't do that part from here."
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            heading
            VStack(alignment: .leading, spacing: 8) {
                Text(explanation)
                Text(Self.nextStep)
            }
            .quiet(.footnote)
            detailsToggle
            if showRaw { Text(raw).quiet(.caption2.monospaced()).textSelection(.enabled) }
        }
        .padding(12)
        .spread()
        .background(.red.opacity(0.10), in: .rect(cornerRadius: 16, style: .continuous))
    }

    private static let nextStep = "Run hermes setup on the gateway, or pick another model for this bot in the Hermes dashboard."

    private var heading: some View {
        Label("This bot's model did not start", systemImage: "exclamationmark.triangle.fill")
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.red)
    }

    private var detailsToggle: some View {
        Button(showRaw ? "Hide details" : "Details", action: flipDetails)
            .buttonStyle(.borderless)
            .font(.caption)
    }

    private func flipDetails() {
        withAnimation(.snappy) { showRaw.toggle() }
    }
}

/// A note from the gateway that shows up as if you sent it, such as a background job reporting
/// back. One quiet line with the text folded underneath.
struct InjectedNoteRow: View {
    var note: InjectedNote

    @State private var open = false

    /// Icon picked from how the note's title starts or reads.
    private var symbol: String {
        let t = note.title
        if t.contains("failed") { return "exclamationmark.circle" }
        if t.hasPrefix("Scheduled") { return "clock" }
        if t.hasPrefix("Subagent") { return "person.2" }
        return "gearshape.2"
    }

    private var heading: String {
        note.title.replacingOccurrences(of: "Scheduled run: ", with: "Scheduled run · ")
    }

    var body: some View {
        VStack(spacing: 6) {
            PlainButton { withAnimation(.snappy) { open.toggle() } } label: { pillLabel }
                .accessibilityLabel("\(note.title). \(open ? "Hides" : "Shows") the details")
            if open { details }
        }
        .frame(maxWidth: .infinity)
        .inset(v: 2)
    }

    private var pillLabel: some View {
        HStack(spacing: 6) {
            Glyph(symbol, .system(size: 11, weight: .medium))
            Text(heading).font(Ink.pill)
            Image(systemName: open ? "chevron.up" : "chevron.down")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(Ink.text3)
        }
        .foregroundStyle(Ink.text2)
        .inset(h: 11, v: 4)
        .overlay { Capsule().strokeBorder(Ink.line, lineWidth: 1) }
        .contentShape(Capsule())
    }

    private var details: some View {
        Text(TranscriptMedia.words(of: note.body, naming: 0))
            .font(.caption.monospaced())
            .textSelection(.enabled)
            .spread()
            .inset(h: 12, v: 8)
            .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 16, style: .continuous))
            .transition(.opacity.combined(with: .move(edge: .top)))
    }
}

/// Messages between bots stay in the chat. Tapping the pill opens the message right there.
struct BotMessageNotice: View {
    var handle: String
    var label: String
    var headline: String
    var text: String?
    var pending: Bool
    var onOpen: (String) -> Void

    @State private var open = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(handle: String, label: String, headline: String, body: String?, pending: Bool = false, onOpen: @escaping (String) -> Void) {
        self.handle = handle
        self.label = label
        self.headline = headline
        self.text = body
        self.pending = pending
        self.onOpen = onOpen
    }

    /// The text without any `MEDIA:` mark, unless that leaves nothing or only blank space.
    private var message: String? {
        guard let text else { return nil }
        let words = TranscriptMedia.words(of: text, naming: 0)
        return words.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : words
    }

    private var stateWord: String {
        guard message != nil else { return pending ? "Sending" : "No message text" }
        return open ? "Expanded" : "Collapsed"
    }

    private var hint: String {
        guard message != nil else { return "" }
        return open ? "Hides the message" : "Shows the message"
    }

    var body: some View {
        VStack(spacing: 0) {
            pill
            if open, let message { unfolded(message) }
        }
        .frame(maxWidth: open ? 460 : nil)
        .nollieGlass(.regular, in: .rect(cornerRadius: open ? 18 : 22))
        .inset(v: 2)
        .frame(maxWidth: .infinity)
    }

    private func unfolded(_ message: String) -> some View {
        Text(message)
            .font(.subheadline)
            .lineSpacing(3)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .spread()
            .padding(.init(top: 4, leading: 16, bottom: 16, trailing: 16))
            .accessibilityIdentifier("bot.message.\(handle).body")
            .transition(.opacity)
    }

    private var pill: some View {
        PlainButton {
            withAnimation(reduceMotion ? nil : .snappy(duration: 0.24)) { open.toggle() }
        } label: {
            pillContent
        }
        .disabled(message == nil)
        .accessibilityLabel(headline)
        .accessibilityValue(stateWord)
        .accessibilityHint(hint)
        .accessibilityIdentifier("bot.message.\(handle).toggle")
    }

    private var pillContent: some View {
        HStack(spacing: 8) {
            BotAvatar(profile: handle, size: 18, state: pending ? .working : .idle, animated: pending)
                .accessibilityHidden(true)
            Text(headline).quiet()
            if pending { ProgressView().controlSize(.mini) }
            if message != nil { FoldChevron(open: open) }
        }
        .inset(h: 14, v: 6)
        .frame(minHeight: DeviceWords.isMac ? 32 : 44)
        .frame(maxWidth: open ? .infinity : nil)
        .contentShape(.rect)
    }
}

/// The bot's reasoning, behind one tap target as wide as the row and folded until opened. Opening
/// tells the thread where the header sits so it can keep it still while the body grows.
struct ReasoningDisclosure: View {
    var text: String
    @Binding var open: Bool
    var itemID: String? = nil

    private let hold = DisclosureHold()

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // Edge to edge hit area, which a DisclosureGroup (label only) doesn't give.
            PlainButton(action: toggle) {
                HStack {
                    Label("Reasoning", systemImage: "brain").quiet()
                    Spacer(minLength: 0)
                    FoldChevron(open: open, font: .caption.weight(.semibold))
                }
                .contentShape(.rect)
            }
            .accessibilityLabel(open ? "Hide reasoning" : "Show reasoning")
            // Models write markdown (headings, lists, tables), so draw it small and calm.
            if open { reasoningBody }
        }
        .holdingHeader(hold, id: itemID)
    }

    private var reasoningBody: some View {
        let view = MarkdownView(text: text, style: .reasoning, inlineSelection: false)
        return view.equatable()
    }

    private func toggle() {
        hold.begin(id: itemID)
        withAnimation(.snappy) { open.toggle() }
    }
}
