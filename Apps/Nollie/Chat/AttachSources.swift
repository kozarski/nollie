import PhotosUI
import SwiftUI
import UniformTypeIdentifiers
import NollieCore

/// Turns what the person picked (photos, files) into bytes and names, before anything is staged.
enum Intake {
    static let sizeLimit = 200 * 1024 * 1024

    private static let kinds: [(type: UTType, kind: AttachmentPreview.Kind)] = [
        (.image, .image), (.pdf, .pdf), (.audio, .audio), (.movie, .video),
    ]

    /// How a file of this type is shown.
    static func kind(of type: UTType?) -> AttachmentPreview.Kind {
        guard let type else { return .file }
        return kinds.first { type.conforms(to: $0.type) }?.kind ?? .file
    }

    static func stamp() -> Int { Int(Date().timeIntervalSince1970) }

    typealias Photo = (data: Data, name: String, kind: AttachmentPreview.Kind)

    /// Loads photo-picker items. Each is named after the moment it was picked.
    static func load(_ picks: [PhotosPickerItem]) async -> [Photo] {
        var loaded: [Photo] = []
        for pick in picks {
            guard let data = try? await pick.loadTransferable(type: Data.self) else { continue }
            let types = pick.supportedContentTypes
            let isClip = types.contains { $0.conforms(to: .movie) }
            let ext = types.first?.preferredFilenameExtension ?? (isClip ? "mov" : "jpg")
            let stem = isClip ? "video" : "photo"
            loaded.append((data, "\(stem)-\(stamp()).\(ext)", isClip ? .video : .image))
        }
        return loaded
    }

    enum Outcome {
        case read(Data, name: String, type: UTType)
        case refused(String)
    }

    /// Reads a picked file, or says in a sentence why it could not be taken.
    static func read(_ url: URL) -> Outcome {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let name = url.lastPathComponent
        guard let data = try? Data(contentsOf: url) else {
            return .refused(String(localized: "Nollie couldn't open \(name)."))
        }
        if data.count > sizeLimit {
            return .refused(String(localized: "\(name) is over 200 MB, which is too big to attach."))
        }
        let type = UTType(filenameExtension: url.pathExtension) ?? .data
        return .read(data, name: name, type: type)
    }
}

/// Which picker is open, plus the rows of the + panel that open them.
@MainActor @Observable
final class AttachSources {
    var panelOpen = false
    var panelHeight: CGFloat = 356
    var showPhotos = false
    var showCamera = false
    var showFiles = false
    var showRecorder = false
    var chosenPhotos: [PhotosPickerItem] = []

    #if os(iOS)
    /// Whether this device has a camera. The first check starts the capture hardware and made the
    /// panel stutter when it opened, so a chat asks ahead of time and the answer is kept.
    nonisolated(unsafe) private static var cameraKnown: Bool?

    static var cameraAvailable: Bool {
        if let known = cameraKnown { return known }
        let answer = UIImagePickerController.isSourceTypeAvailable(.camera)
        cameraKnown = answer
        return answer
    }
    #endif

    /// Rows for the + panel. Message History is dimmed when there is nothing to bring back.
    func items(paste: @escaping () -> Void, history: (() -> Void)? = nil) -> [AttachItem] {
        var rows: [AttachItem] = []
        #if os(iOS)
        rows.append(row("Camera", "camera.fill", .black, disabled: !Self.cameraAvailable) { $0.showCamera = true })
        #endif
        rows.append(row("Photos", "photo.on.rectangle.angled", Color(red: 0.98, green: 0.45, blue: 0.3)) { $0.showPhotos = true })
        rows.append(row("Files", "folder.fill", .blue) { $0.showFiles = true })
        rows.append(row("Audio", "waveform", .red) { $0.showRecorder = true })
        rows.append(AttachItem(title: "Paste", symbol: "doc.on.clipboard.fill", color: .indigo, action: paste))
        rows.append(AttachItem(title: "Message History", symbol: "clock.arrow.circlepath", color: .orange,
                               disabled: history == nil, action: history ?? {}))
        return rows
    }

    private func row(_ title: LocalizedStringResource, _ symbol: String, _ color: Color, disabled: Bool = false,
                     open: @escaping (AttachSources) -> Void) -> AttachItem {
        AttachItem(title: title, symbol: symbol, color: color, disabled: disabled) { [self] in open(self) }
    }
}

/// Attaches the pickers behind the + panel. Whatever they return goes to the closures.
struct AttachSourceHooks: ViewModifier {
    @Bindable var sources: AttachSources
    var onPhotos: ([PhotosPickerItem]) async -> Void
    var onCamera: (Data, String) -> Void
    var onFiles: ([URL]) -> Void
    var onAudio: (URL) -> Void

    private static let photoLimit = 6
    private static let photoFilter = PHPickerFilter.any(of: [.videos, .images])

    func body(content: Content) -> some View {
        content
            .photosPicker(isPresented: $sources.showPhotos, selection: $sources.chosenPhotos,
                          maxSelectionCount: Self.photoLimit, matching: Self.photoFilter)
            .onChange(of: sources.chosenPhotos) { _, picks in
                guard !picks.isEmpty else { return }
                Task {
                    await onPhotos(picks)
                    sources.chosenPhotos = []
                }
            }
            #if os(iOS)
            .fullScreenCover(isPresented: $sources.showCamera) {
                CameraPicker(onImage: onCamera)
                    .ignoresSafeArea()
                    .withAppModel()
            }
            #endif
            .fileImporter(isPresented: $sources.showFiles, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
                guard case .success(let urls) = result else { return }
                onFiles(urls)
            }
            .sheet(isPresented: $sources.showRecorder) {
                AudioRecorderSheet(onFinished: onAudio)
                    .sheetFrame(.compact)
                    .withAppModel()
            }
    }
}
