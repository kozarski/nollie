import NollieCore
import SwiftUI

/// Looks for pictures and files named in a message. Rows ask this all the time and most messages
/// name nothing, so every call starts with a cheap check for any hint of media.
enum TranscriptMedia {
    private static let lineStarts = ["/", "~/"]
    private static let afterNewline = ["\n/", "\n~/", "\r\n/", "\r\n~/"]

    /// True when a line of the text could begin with an absolute or home path.
    private static func hasPathLine(_ text: String) -> Bool {
        lineStarts.contains { text.hasPrefix($0) } || afterNewline.contains { text.contains($0) }
    }

    private static func hints(_ text: String, anyOf markers: [String]) -> Bool {
        hasPathLine(text) || markers.contains { text.contains($0) }
    }

    static func images(in text: String) -> [MediaRef] {
        hints(text, anyOf: ["MEDIA:", "!["]) ? MediaScan.images(in: text) : []
    }

    /// The files that are not pictures.
    static func files(in text: String) -> [MediaRef] {
        hints(text, anyOf: ["MEDIA:", "]("]) ? MediaScan.files(in: text) : []
    }

    /// What the bubble says once the media it names sit under it. A `MEDIA:` mark always goes, even
    /// one whose file can't be shown (a folder, a path on another machine), so its line is never
    /// left in the words.
    static func words(of text: String, naming count: Int) -> String {
        count == 0 && !MediaScan.hasMediaMark(text) ? text : MediaScan.textWithoutMedia(text)
    }

    /// The pictures a person attached to their own message, found by name in its text.
    static func attachedImages(in text: String, profile: String?) -> [MediaRef] {
        if !text.contains("[User attached image:") { return [] }
        let names = MediaScan.attachedImageNames(in: text)
        return names.map { name in MediaScan.attachedImageRef(name: name, profile: profile) }
    }
}

/// Fetching a gateway file into the media cache, shared by the thumbnails and the Mac menu.
private enum GatewayCopy {
    @MainActor static func inCache(_ ref: MediaRef, runtime: GatewayRuntime) async -> URL? {
        await MediaStore.shared.cached(ref, gateway: runtime.connection.id.uuidString)
    }

    @MainActor static func download(_ ref: MediaRef, profile: String?, runtime: GatewayRuntime) async -> URL? {
        let source = GatewayMediaAPI(api: runtime.api, profile: profile)
        return try? await MediaStore.shared.localURL(for: ref, gateway: runtime.connection.id.uuidString, api: source)
    }
}

/// A row of small pictures, fetched as thumbnails through the gateway. The full bitmap stays out
/// of the thread (a long run of screenshots once ate a phone's memory) and loads only in the viewer.
struct MediaThumbStrip: View {
    private static let limit = 12

    var refs: [MediaRef]
    @State private var opened: MediaRef?
    var profile: String?
    var side: CGFloat = 150
    var alignment: HorizontalAlignment = .leading

    var body: some View {
        let items = Array(refs.prefix(Self.limit))
        Group {
            // One or two pictures sit still where they fit. More, or two too wide for a narrow
            // bubble, scroll sideways rather than push the thread off the screen.
            if items.count > 2 {
                ScrollView(.horizontal, showsIndicators: false) { thumbs(items) }
            } else {
                ViewThatFits(in: .horizontal) {
                    thumbs(items)
                    ScrollView(.horizontal, showsIndicators: false) { thumbs(items) }
                }
            }
        }
        .spread(alignment == .trailing ? .trailing : .leading)
        .sheet(item: $opened) { picked in
            let viewer = ImageViewerSheet(ref: picked, profile: profile)
            viewer.withAppModel()
        }
    }

    private func thumbs(_ items: [MediaRef]) -> some View {
        HStack(spacing: 8) {
            ForEach(items) { ref in
                PlainButton { opened = ref } label: { MediaThumb(ref: ref, profile: profile, side: side) }
                    .accessibilityHint("Opens it full screen")
                    .accessibilityLabel("Image \(ref.name)")
                    #if os(macOS)
                    .contextMenu { MacMediaMenu(ref: ref, profile: profile, onOpen: { opened = ref }) }
                    .onDrag { MediaSave.dragProvider(for: ref, profile: profile) }
                    #endif
            }
        }
    }
}

#if os(macOS)
/// The right-click menu for a picture on the Mac.
struct MacMediaMenu: View {
    @Environment(AppModel.self) private var model
    var ref: MediaRef
    var profile: String?
    var onOpen: () -> Void

    var body: some View {
        Button(action: onOpen) { Label("Open", systemImage: "arrow.up.left.and.arrow.down.right") }
        Button { Task { await saveToDownloads() } } label: { Label("Save to Downloads", systemImage: "square.and.arrow.down") }
        Button { Task { await copyPicture() } } label: { Label("Copy Image", systemImage: "doc.on.doc") }
        let file = MediaFile(ref: ref, profile: profile)
        ShareLink(item: file, preview: SharePreview(ref.name)) { Label("Share", systemImage: "square.and.arrow.up") }
    }

    private func original() async -> URL? {
        guard let runtime = model.runtime else { return nil }
        return await GatewayCopy.download(ref, profile: profile, runtime: runtime)
    }

    private func copyPicture() async {
        if let file = await original() { MediaSave.copyImage(at: file) }
    }

    private func saveToDownloads() async {
        guard let file = await original() else { return }
        let name = ref.name
        do {
            let saved = try MediaSave.toDownloads(file, name: name)
            MediaSave.showInFinder(saved)
        } catch {
            MediaSave.explainFailure(name: name, error: error)
        }
    }
}
#endif

/// A square thumbnail. It shows a spinner while loading, then the picture, or the file name if
/// the gateway could not supply it.
struct MediaThumb: View {
    var ref: MediaRef
    @State private var phase = Phase.loading
    var profile: String?
    var side: CGFloat

    private enum Phase {
        case missing
        case loading
        case ready(UIImage)
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 12)
        let backing = Color(.secondarySystemBackground)
        Group {
            switch phase {
            case .loading:
                ProgressView().frame(square: side).background(backing, in: shape)
            case .ready(let picture):
                Image(uiImage: picture).resizable().scaledToFill().frame(square: side).clipShape(shape)
            case .missing:
                VStack(spacing: 6) {
                    Glyph("photo", .title2, .secondary)
                    Text(ref.name).quiet(.caption2).lineLimit(2).multilineTextAlignment(.center)
                }
                .padding(8)
                .frame(square: side)
                .background(backing, in: shape)
            }
        }
        .task(id: ref.id) { phase = await load() }
    }

    private func load() async -> Phase {
        guard let runtime = AppModel.shared.runtime else { return .missing }
        var file = await GatewayCopy.inCache(ref, runtime: runtime)
        if file == nil { file = await GatewayCopy.download(ref, profile: profile, runtime: runtime) }
        guard let file, !Task.isCancelled,
              let picture = await AttachmentThumbs.imageAsync(at: file, side: side) else { return .missing }
        return .ready(picture)
    }
}
