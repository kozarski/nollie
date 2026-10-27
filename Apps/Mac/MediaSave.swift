import AppKit
import CoreTransferable
import NollieCore
import UniformTypeIdentifiers

/// A chat picture offered to the share sheet. When the original is not on this Mac yet, it is
/// downloaded from the gateway right as it is shared.
struct MediaFile: Transferable {
    var profile: String?
    var ref: MediaRef

    init(ref: MediaRef, profile: String?) {
        self.profile = profile
        self.ref = ref
    }

    static var transferRepresentation: some TransferRepresentation {
        let kind = UTType.image
        return FileRepresentation(exportedContentType: kind) { (item: MediaFile) -> SentTransferredFile in
            guard let fetch = await MediaSave.localFetcher(for: item.ref, profile: item.profile) else {
                throw HermesAPIError.transport(String(localized: "Connect a gateway first."))
            }
            return SentTransferredFile(try await fetch())
        }
    }
}

/// The Mac exits for a picture: save to Downloads, reveal in Finder, copy to the pasteboard, or
/// drag out as a file.
enum MediaSave {
    // MARK: Where and what to call it

    private static var downloads: URL {
        let manager = FileManager.default
        if let found = manager.urls(for: .downloadsDirectory, in: .userDomainMask).first { return found }
        return manager.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")
    }

    /// Slashes cannot be in a file name. An empty result falls back to the source's own name.
    private static func fileName(from wanted: String, fallback: URL) -> String {
        let cleaned = wanted.replacingOccurrences(of: "/", with: "-").trimmingCharacters(in: .whitespaces)
        return cleaned.isEmpty ? fallback.lastPathComponent : cleaned
    }

    /// Finder-style numbering. "shot.png" becomes "shot 2.png", then "shot 3.png", for as long
    /// as the earlier names are taken. A name without an extension takes the number at the end.
    static func uniqueName(_ name: String, taken: (String) -> Bool) -> String {
        let path = name as NSString
        let ext = path.pathExtension
        let stem = ext.isEmpty ? name : path.deletingPathExtension
        func numbered(_ count: Int) -> String {
            ext.isEmpty ? "\(stem) \(count)" : "\(stem) \(count).\(ext)"
        }

        var count = 1
        var candidate = name
        while taken(candidate) {
            count += 1
            candidate = numbered(count)
        }
        return candidate
    }

    // MARK: Saving

    /// Copies the file into Downloads and leaves whatever is there alone. Returns where it landed.
    static func toDownloads(_ file: URL, name: String) throws -> URL {
        let folder = downloads
        let isTaken = { (candidate: String) in
            FileManager.default.fileExists(atPath: folder.appendingPathComponent(candidate).path)
        }
        let landing = folder.appendingPathComponent(uniqueName(fileName(from: name, fallback: file), taken: isTaken))
        try FileManager.default.copyItem(at: file, to: landing)
        return landing
    }

    static func failureMessage(name: String, error: Error) -> String {
        String(localized: "\(name) was not saved to Downloads. \(error.localizedDescription)", comment: "A file name, then why")
    }

    @MainActor
    private static func failureAlert(name: String, error: Error) -> NSAlert {
        let alert = NSAlert()
        alert.addButton(withTitle: String(localized: "OK"))
        alert.informativeText = failureMessage(name: name, error: error)
        alert.messageText = String(localized: "Not saved to Downloads")
        return alert
    }

    /// A menu action has no view to attach an alert to, so show a sheet on the key window, or a plain
    /// alert if no window is open.
    @MainActor
    static func explainFailure(name: String, error: Error) {
        let alert = failureAlert(name: name, error: error)
        guard let window = NSApp.keyWindow else {
            _ = alert.runModal()
            return
        }
        alert.beginSheetModal(for: window)
    }

    // MARK: Showing and copying

    static func showInFinder(_ url: URL) {
        NSWorkspace.shared.selectFile(url.path, inFileViewerRootedAtPath: "")
    }

    @discardableResult
    static func copyImage(at url: URL) -> Bool {
        let board = NSPasteboard.general
        if let image = NSImage(contentsOf: url) {
            board.clearContents()
            return board.writeObjects([image])
        }
        return false
    }

    // MARK: Fetching and dragging

    /// A way to get the file onto this Mac, ready when the gateway is. Nil when none is connected.
    @MainActor
    static func localFetcher(for ref: MediaRef, profile: String?) -> (@Sendable () async throws -> URL)? {
        guard let runtime = AppModel.shared.runtime else { return nil }
        let gateway = runtime.connection.id.uuidString
        let media = GatewayMediaAPI(api: runtime.api, profile: profile)
        return { try await MediaStore.shared.localURL(for: ref, gateway: gateway, api: media) }
    }

    /// What a drag carries. The file is only fetched when it is dropped.
    @MainActor
    static func dragProvider(for ref: MediaRef, profile: String?) -> NSItemProvider {
        let fetch = localFetcher(for: ref, profile: profile)
        let provider = NSItemProvider()
        defer { provider.suggestedName = ref.name }
        guard let fetch else { return provider }

        let type = UTType(filenameExtension: (ref.name as NSString).pathExtension) ?? .image
        provider.registerFileRepresentation(forTypeIdentifier: type.identifier, fileOptions: [], visibility: .all) { deliver in
            let progress = Progress(totalUnitCount: 1)
            Task {
                do {
                    let url = try await fetch()
                    progress.completedUnitCount = 1
                    deliver(url, false, nil)
                } catch {
                    deliver(nil, false, error)
                }
            }
            return progress
        }
        return provider
    }
}
