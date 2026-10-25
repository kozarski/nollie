import QuickLook
import SwiftUI
import NollieCore

/// A long text trimmed to its first few lines until someone asks for the rest. A terminal
/// transcript can run to thousands of lines.
struct LineCap {
    var text: String
    var cap: Int

    var lines: [Substring] { text.split(separator: "\n", omittingEmptySubsequences: false) }
    var isCut: Bool { lines.count > cap }
    var hiddenCount: Int { lines.count - cap }

    /// What to draw: the whole text (up to 20,000 characters) when open or short, else the head.
    func shown(expanded: Bool) -> String {
        if expanded || !isCut { return String(text.prefix(20_000)) }
        return lines.prefix(cap).joined(separator: "\n")
    }
}

/// Monospaced text on a light ground, showing `lineCap` lines until "Show more" is tapped.
struct CodeBlock: View {
    var text: String
    var lineCap: Int

    @State private var expanded = false

    var body: some View {
        let capped = LineCap(text: text, cap: lineCap)
        VStack(alignment: .leading, spacing: 4) {
            block(capped.shown(expanded: expanded))
            if capped.isCut {
                Button(expanded ? "Show less" : "Show \(capped.hiddenCount) more lines") {
                    withAnimation(.snappy) { expanded.toggle() }
                }
                .font(.caption)
            }
        }
    }

    private func block(_ shown: String) -> some View {
        Text(shown)
            .textSelection(.enabled)
            .font(.system(.caption, design: .monospaced))
            .padding(.leading, 10)
            .padding(.vertical, 10)
            .padding(.trailing, 34)
            .fixedSize(horizontal: false, vertical: true)
            .spread()
            .background(Color(.secondarySystemBackground), in: .rect(cornerRadius: 16, style: .continuous))
            .overlay(alignment: .topTrailing) { CopyButton(text: text).padding(6) }
    }
}

/// What you attached to your own message: little thumbnails, or chips with the file name.
struct AttachmentStrip: View {
    var attachments: [AttachmentPreview]

    @State private var previewing: URL?

    var body: some View {
        HStack(spacing: 8) {
            ForEach(attachments) { item in
                PlainButton { previewing = item.localURL ?? previewing } label: { chip(for: item) }
            }
        }
        .quickLookPreview($previewing)
    }

    private static let symbols: [AttachmentPreview.Kind: String] = [
        .pdf: "doc.richtext", .audio: "waveform", .video: "video",
    ]

    /// Only ever a small thumbnail and not the whole photo, as a thread of screenshots would otherwise
    /// hold a 12-megapixel bitmap for every row.
    @ViewBuilder private func chip(for item: AttachmentPreview) -> some View {
        let outline = RoundedRectangle(cornerRadius: 16, style: .continuous)
        if item.kind == .image, let file = item.localURL, let thumb = AttachmentThumbs.image(at: file, side: 96) {
            Image(uiImage: thumb).resizable().scaledToFill().frame(square: 96).clipShape(outline)
        } else {
            Label(item.name, systemImage: Self.symbols[item.kind] ?? "doc")
                .font(.caption)
                .lineLimit(1)
                .padding(8)
                .nollieGlass(.regular, in: outline)
        }
    }
}

/// Clipboard button that shows a check for a moment once the text is copied.
struct CopyButton: View {
    var text: String

    @State private var copied = false

    var body: some View {
        PlainButton(action: copy) {
            Glyph(copied ? "checkmark" : "doc.on.doc", .caption, copied ? Color.green : Color.secondary)
                .contentShape(.rect)
                .frame(width: 24, height: 20)
        }
        .accessibilityLabel(copied ? "Copied" : "Copy code")
    }

    private func copy() {
        UIPasteboard.general.string = text
        withAnimation(.snappy) { copied = true }
        Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            withAnimation { copied = false }
        }
    }
}
