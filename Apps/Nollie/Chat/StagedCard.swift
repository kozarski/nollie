import NollieCore
import SwiftUI
import UniformTypeIdentifiers
import QuickLookThumbnailing

/// One queued attachment in the composer. It is a square card with a true preview (the photo, or the
/// first page of a document via Quick Look), a small pill for the kind at the bottom, and a
/// remove button in a corner.
struct StagedCard: View {
    var attachment: AttachmentPreview
    var onOpen: () -> Void
    var onRemove: () -> Void
    private static let cardRadius: CGFloat = 18

    @Environment(\.displayScale) private var displayScale
    @State private var preview: UIImage?

    static let side: CGFloat = 92

    /// The pill's word and the stand-in symbol before the preview is ready.
    private var kindFacts: (word: String, symbol: String) {
        let table: [AttachmentPreview.Kind: (String, String)] = [
            .image: ("Image", "photo"),
            .pdf: ("PDF", "doc.richtext"),
            .audio: ("Audio", "waveform"),
            .video: ("Video", "video"),
        ]
        return table[attachment.kind] ?? (fileWord, "doc.text")
    }

    /// Plain text and source files read as "Text" (a long paste lands as one). Everything else
    /// shows its extension.
    private var fileWord: String {
        let ext = URL(fileURLWithPath: attachment.name).pathExtension.lowercased()
        guard let type = UTType(filenameExtension: ext) else { return ext.isEmpty ? "File" : ext.uppercased() }
        if [UTType.text, .sourceCode].contains(where: type.conforms(to:)) { return "Text" }
        return ext.isEmpty ? "File" : ext.uppercased()
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            PlainButton(action: onOpen) { tile }
                .accessibilityLabel("\(kindFacts.word): \(attachment.name)")
            removeButton
        }
        .padding(.top, 6)
        .padding(.bottom, 8)
        .padding(.trailing, 6)
        .task(id: attachment.id) { preview = await drawPreview() }
    }

    private var tile: some View {
        let corner = RoundedRectangle(cornerRadius: Self.cardRadius)
        return picture
            .frame(square: Self.side)
            .background(Color(.secondarySystemGroupedBackground), in: corner)
            .clipShape(corner)
            .overlay(corner.strokeBorder(.primary.opacity(0.08), lineWidth: 1))
            .overlay(alignment: .bottom) { kindPill }
    }

    private var kindPill: some View {
        Text(kindFacts.word)
            .font(.caption.weight(.semibold))
            .inset(h: 12, v: 5)
            .nollieGlass(.regular, in: .capsule)
            .offset(y: 6)
    }

    @ViewBuilder private var picture: some View {
        switch (preview, attachment.kind) {
        case (let shot?, .image), (let shot?, .video):
            Image(uiImage: shot).resizable().scaledToFill()
        case (let page?, _):
            sheetOfPaper(page)
        case (nil, _):
            Image(systemName: kindFacts.symbol)
                .foregroundStyle(.secondary)
                .font(.system(size: 28, weight: .light))
        }
    }

    /// A document page drawn small on its own paper, like a sheet lying on a desk.
    private func sheetOfPaper(_ page: UIImage) -> some View {
        Image(uiImage: page)
            .resizable()
            .scaledToFit()
            .clipShape(.rect(cornerRadius: 4))
            .shadow(color: Color(white: 0, opacity: 0.12), radius: 2, x: 0, y: 1)
            .padding(.init(top: 10, leading: 16, bottom: 14, trailing: 16))
    }

    private var removeButton: some View {
        PlainButton(action: onRemove) {
            Glyph("xmark", .system(size: 11, weight: .bold), .white)
                .frame(square: 24)
                .background(.black.opacity(0.75), in: .circle)
                .overlay { Circle().strokeBorder(Color.white.opacity(0.9), lineWidth: 1.5) }
        }
        .offset(x: 6, y: -6)
        .accessibilityLabel("Remove \(attachment.name)")
    }

    private func drawPreview() async -> UIImage? {
        guard let file = attachment.localURL else { return nil }
        if attachment.kind == .image, let photo = UIImage(contentsOfFile: file.path) {
            let edge = Self.side * displayScale
            return photo.preparingThumbnail(of: .init(width: edge, height: edge)) ?? photo
        }
        // Quick Look covers the rest: first page of a PDF, top of a text file, a video frame.
        let box = CGSize(width: Self.side * 2, height: Self.side * 2)
        let ask = QLThumbnailGenerator.Request(fileAt: file, size: box, scale: displayScale, representationTypes: .thumbnail)
        return try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: ask).uiImage
    }
}
