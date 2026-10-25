import NollieCore
import QuickLook
import SwiftUI

/// The look shared by the small bars that float above the composer.
private struct StripFrame: ViewModifier {
    var corner: CGFloat

    func body(content: Content) -> some View {
        content
            .inset(h: 12, v: 8)
            .nollieGlass(.regular, in: .rect(cornerRadius: corner))
            .transition(.opacity.combined(with: .move(edge: .bottom)))
    }
}

private extension View {
    func stripFrame(corner: CGFloat) -> some View { modifier(StripFrame(corner: corner)) }
}

/// The prompt after a huge paste: keep it as text, or turn it into an attached file.
struct LongTextOffer: View {
    var keep: () -> Void
    var attach: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Glyph("doc.text", .body, .secondary)
            Text("That's a lot of text.")
            Spacer(minLength: 0)
            Button("Keep", action: keep)
            Button("Attach as file", action: attach)
                .fontWeight(.semibold)
                .buttonStyle(.nollieGlassProminent)
        }
        .font(.subheadline)
        .stripFrame(corner: 16)
    }
}

/// Reminds the person which message they are answering, with a button to drop the reply.
struct ReplyQuoteStrip: View {
    var quote: String
    var cancel: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Capsule().frame(width: 3).foregroundStyle(Color.nollie)
            heading
            Spacer(minLength: 0)
            PlainButton(action: cancel) { Glyph("xmark.circle.fill", .body, .secondary) }
                .accessibilityLabel("Cancel reply")
        }
        // The accent bar has no height of its own and would stretch the strip to fill the screen.
        .fixedSize(horizontal: false, vertical: true)
        .stripFrame(corner: 14)
    }

    private var heading: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Replying to").quiet(.caption2.weight(.semibold))
            Text(quote).lineLimit(2).quiet()
        }
    }
}

/// Past messages, newest first. Choosing one puts it back in the composer.
struct HistorySheet: View {
    @Environment(\.dismiss) private var dismiss
    let history: [String]
    let pick: (String) -> Void

    /// Newest message first.
    private var newestFirst: [String] { history.reversed() }

    var body: some View {
        NavigationStack {
            List(newestFirst.indices, id: \.self) { row in
                Button(action: { choose(newestFirst[row]) }) {
                    Text(newestFirst[row]).lineLimit(3)
                }
            }
            .toolbar { doneItem }
            .navigationTitle("Message History")
        }
    }

    private func choose(_ message: String) {
        pick(message)
        dismiss()
    }

    @ToolbarContentBuilder private var doneItem: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button("Done") { dismiss() }
        }
    }
}

/// A scrolling row of cards for files waiting to be sent. Tapping one previews it; the cross removes it.
struct StagedStrip: View {
    @State private var previewURL: URL?
    var files: [AttachmentPreview]
    var remove: (AttachmentPreview.ID) -> Void

    var body: some View {
        ScrollView(.horizontal) { cards }
            .scrollIndicators(.hidden)
            .quickLookPreview($previewURL)
    }

    private var cards: some View {
        HStack(spacing: 10) {
            ForEach(files) { file in
                StagedCard(attachment: file, onOpen: { previewURL = file.localURL }, onRemove: { remove(file.id) })
                    .transition(.opacity.combined(with: .scale(scale: 0.9)))
            }
        }
        .padding(.leading, 2)
    }
}
