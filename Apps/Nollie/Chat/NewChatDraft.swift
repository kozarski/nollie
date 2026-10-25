import PhotosUI
import SwiftUI
import UniformTypeIdentifiers
import NollieCore

/// The first message of a chat that does not exist yet: its words and the files picked for it.
/// Files are copied into a holding folder right away, so the chat can take them once it opens.
@MainActor @Observable
final class NewChatDraft {
    var text = ""
    var files: [AttachmentPreview] = []
    var problem: String?

    private static var holdingFolder: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("newchat-staged", isDirectory: true)
    }

    var hasContent: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !files.isEmpty
    }

    var trimmedText: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    func hold(_ data: Data, name: String, kind: AttachmentPreview.Kind) {
        let folder = Self.holdingFolder
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let target = folder.appendingPathComponent("\(UUID().uuidString)-\(name)")
        do { try data.write(to: target) } catch {
            problem = "Could not stage \(name)."
            return
        }
        let card = AttachmentPreview(id: target.lastPathComponent, name: name, kind: kind, localURL: target, byteCount: data.count)
        withAnimation(.snappy) { files.append(card) }
    }

    func hold(_ data: Data, name: String, type: UTType) {
        hold(data, name: name, kind: Intake.kind(of: type))
    }

    func drop(_ id: String) {
        withAnimation(.snappy) { files.removeAll { $0.id == id } }
    }

    func take(photos: [PhotosPickerItem]) async {
        for photo in await Intake.load(photos) { hold(photo.data, name: photo.name, kind: photo.kind) }
    }

    func take(file url: URL) {
        switch Intake.read(url) {
        case .read(let data, let name, let type): hold(data, name: name, type: type)
        case .refused(let why): problem = why
        }
    }

    func takeFromClipboard() {
        let board = UIPasteboard.general
        if board.hasImages, let jpeg = board.image?.jpegData(compressionQuality: 0.9) {
            hold(jpeg, name: "photo-\(Intake.stamp()).jpg", kind: .image)
        } else if let words = board.string {
            text += words
        }
    }
}
