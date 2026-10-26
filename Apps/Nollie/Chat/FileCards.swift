import NollieCore
import SwiftUI
import QuickLook
import UniformTypeIdentifiers
#if os(iOS)
import UIKit
#endif

/// One card per non-picture file in a reply. Tap it to download (same gateway route and cache the
/// pictures use) and preview in Quick Look. Press and hold, or secondary-click on a Mac, for the
/// Share and Save options. Nothing is fetched unless the reply itself named the path.
struct FileCardStrip: View {
    private static let shownLimit = 12

    var refs: [MediaRef]
    @State private var previewing: URL?
    var profile: String?
    var alignment: HorizontalAlignment = .leading

    var body: some View {
        VStack(alignment: alignment, spacing: 8) {
            ForEach(refs.prefix(Self.shownLimit)) { ref in
                FileCard(ref: ref, profile: profile) { previewing = $0 }
            }
        }
        .spread(alignment == .trailing ? .trailing : .leading)
        .filePreview($previewing)
    }
}

/// What is known about one file: is it on this device, on its way, or turned down.
@MainActor @Observable
final class FileFetch {
    let ref: MediaRef
    let profile: String?
    /// The file under its real name once it is on this device.
    private(set) var copy: URL?
    private(set) var downloading = false
    private(set) var problem: String?

    init(ref: MediaRef, profile: String?) {
        self.ref = ref
        self.profile = profile
    }

    /// The line under the file name: a problem, progress, the size, or how to get it.
    var status: String {
        if let problem { return problem }
        if downloading { return "Downloading…" }
        guard let copy, let bytes = try? FileManager.default.attributesOfItem(atPath: copy.path)[.size] as? Int else {
            return "\(DeviceWords.Tap) to download"
        }
        return ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    func lookForCopy(runtime: GatewayRuntime?) async {
        guard let runtime, let cached = await MediaStore.shared.cached(ref, gateway: runtime.connection.id.uuidString) else { return }
        copy = FileCard.named(cached, as: ref.name)
    }

    /// Downloads into the media cache. When the gateway says no, the status line explains it.
    func download(runtime: GatewayRuntime?) async {
        if downloading { return }
        guard let runtime else {
            problem = "There is no gateway connected right now."
            return
        }
        downloading = true
        problem = nil
        defer { downloading = false }
        do {
            let gateway = runtime.connection.id.uuidString
            let route = GatewayMediaAPI(api: runtime.api, profile: profile)
            let cached = try await MediaStore.shared.localURL(for: ref, gateway: gateway, api: route)
            copy = FileCard.named(cached, as: ref.name)
        } catch {
            problem = FileFetchFailure.describe(error, name: ref.name)
        }
    }
}

/// A single file: an icon for its kind, its name, and a status line (the size once it's here).
struct FileCard: View {
    @Environment(AppModel.self) private var model
    var onOpen: (URL) -> Void
    #if os(iOS)
    @State private var savingToFiles: URL?
    #endif
    var profile: String?
    @State private var fetch: FileFetch
    var ref: MediaRef

    init(ref: MediaRef, profile: String?, onOpen: @escaping (URL) -> Void) {
        self.ref = ref
        self.profile = profile
        self.onOpen = onOpen
        _fetch = State(initialValue: FileFetch(ref: ref, profile: profile))
    }

    private static let icons: [MediaScan.FileKind: String] = [
        .pdf: "doc.richtext", .table: "tablecells", .archive: "archivebox", .audio: "waveform",
        .video: "film", .text: "doc.text", .code: "chevron.left.forwardslash.chevron.right",
    ]

    private var icon: String { Self.icons[MediaScan.FileKind.of(ref.name)] ?? "doc" }

    private var cardFill: Color {
        #if os(iOS)
        return Color(.secondarySystemBackground)
        #else
        return Color(nsColor: .controlBackgroundColor)
        #endif
    }

    var body: some View {
        PlainButton(action: openFile) { content }
            .accessibilityLabel("File \(ref.name), \(fetch.status)")
            .accessibilityHint("Opens it")
            .accessibilityIdentifier("file.card")
            .contextMenu { menu }
            #if os(iOS)
            .background { FilesExporter(url: $savingToFiles) }
            #else
            // A drag carries the named copy once it exists; until then the drop itself fetches the
            // file under its real name, since an empty provider would drop nothing.
            .onDrag { dragItem }
            #endif
            .task(id: ref.id) { await fetch.lookForCopy(runtime: model.runtime) }
    }

    #if os(macOS)
    private var dragItem: NSItemProvider {
        if let copy = fetch.copy, let provider = NSItemProvider(contentsOf: copy) { return provider }
        return MediaSave.dragProvider(for: ref, profile: profile)
    }
    #endif

    private func openFile() {
        Task {
            if fetch.copy == nil { await fetch.download(runtime: model.runtime) }
            if let copy = fetch.copy { onOpen(copy) }
        }
    }

    private var content: some View {
        HStack(spacing: 12) {
            badge
            labels
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(cardFill, in: .rect(cornerRadius: 14))
        .frame(maxWidth: 360, alignment: .leading)
        .contentShape(.rect)
    }

    private var labels: some View {
        let tint: AnyShapeStyle = fetch.problem == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(.red)
        return VStack(alignment: .leading, spacing: 2) {
            Text(ref.name)
                .lineLimit(2)
                .font(.subheadline.weight(.medium))
                .multilineTextAlignment(.leading)
            Text(fetch.status)
                .multilineTextAlignment(.leading)
                .quiet(.caption, tint)
                .lineLimit(3)
        }
    }

    private var badge: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10).fill(Color.accentColor.opacity(0.15)).frame(square: 40)
            if fetch.downloading {
                ProgressView().controlSize(.small)
            } else {
                Glyph(icon, .system(size: 18, weight: .semibold), Color.accentColor)
            }
        }
    }

    @ViewBuilder private var menu: some View {
        if let copy = fetch.copy {
            ShareLink(item: copy, preview: SharePreview(ref.name)) {
                Label("Share", systemImage: "square.and.arrow.up")
            }
            #if os(iOS)
            Button { savingToFiles = copy } label: { Label("Save to Files", systemImage: "folder") }
            #else
            Button { saveToDownloads(copy) } label: { Label("Save to Downloads", systemImage: "square.and.arrow.down") }
            #endif
        } else {
            Button { Task { await fetch.download(runtime: model.runtime) } } label: { Label("Download", systemImage: "arrow.down.circle") }
        }
    }

    /// Cached files are stored under a hash, but Preview, Share and Save ought to show the actual
    /// file name. So the bytes are copied once more under that name.
    static func named(_ cached: URL, as name: String) -> URL {
        let files = FileManager.default
        let hashName = cached.deletingPathExtension().lastPathComponent
        let namedRoot = cached.deletingLastPathComponent().appendingPathComponent("named", isDirectory: true)
        let folder = namedRoot.appendingPathComponent(hashName, isDirectory: true)
        let target = folder.appendingPathComponent(name)
        if !files.fileExists(atPath: target.path) {
            try? files.createDirectory(at: folder, withIntermediateDirectories: true)
            try? files.copyItem(at: cached, to: target)
        }
        return files.fileExists(atPath: target.path) ? target : cached
    }

    #if os(macOS)
    private func saveToDownloads(_ file: URL) {
        do {
            MediaSave.showInFinder(try MediaSave.toDownloads(file, name: ref.name))
        } catch {
            let name = ref.name
            MediaSave.explainFailure(name: name, error: error)
        }
    }
    #endif
}

/// Words for why a file did not arrive.
enum FileFetchFailure {
    private static let offlineCodes: Set<URLError.Code> = [.notConnectedToInternet, .networkConnectionLost, .cannotConnectToHost, .timedOut]

    static func describe(_ error: Error, name: String) -> String {
        switch error {
        case HermesAPIError.http(401, _), HermesAPIError.http(403, _):
            return "The gateway would not let Nollie open \(name)."
        case HermesAPIError.http(404, _):
            return "\(name) is gone from the gateway."
        case HermesAPIError.http(413, _):
            return "\(name) is too big for the gateway to send."
        case HermesAPIError.transport:
            return "Nollie could not get to the gateway to fetch \(name)."
        case let failure as URLError where offlineCodes.contains(failure.code):
            return "You are offline. \(name) can download once the gateway is back."
        default:
            return "\(name) did not download: \(error.localizedDescription)"
        }
    }
}

#if os(iOS)
/// Brings up the system Save to Files sheet for a file we already hold locally.
struct FilesExporter: UIViewControllerRepresentable {
    @Binding var url: URL?

    func makeCoordinator() -> Coordinator { Coordinator(target: $url) }

    func updateUIViewController(_ host: UIViewController, context: Context) {
        guard let url else { return }
        if context.coordinator.shown == url { return }
        context.coordinator.shown = url
        let sheet = UIDocumentPickerViewController(forExporting: [url], asCopy: true)
        sheet.delegate = context.coordinator
        host.present(sheet, animated: true)
    }

    func makeUIViewController(context: Context) -> UIViewController {
        UIViewController()
    }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let target: Binding<URL?>
        var shown: URL?

        init(target: Binding<URL?>) { self.target = target }

        private func reset() {
            shown = nil
            target.wrappedValue = nil
        }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) { reset() }
        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) { reset() }
    }
}
#endif
