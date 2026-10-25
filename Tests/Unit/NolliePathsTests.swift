import Foundation
import Testing
@testable import NollieCore

/// One folder for everything Nollie writes outside its app, and the one-time move from where
/// earlier versions kept a few things. Real files in a private temporary folder.
@Suite struct NolliePathsTests {
    private func sandbox() throws -> URL {
        let base = try #require(realpath(FileManager.default.temporaryDirectory.path, nil))
        defer { free(base) }
        let root = URL(fileURLWithPath: String(cString: base)).appendingPathComponent("paths-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func write(_ text: String, _ url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    @Test func everythingLivesUnderOneFolderOnTheDirectMac() {
        let support = URL(fileURLWithPath: "/Users/me/Library/Application Support")
        let layout = NolliePaths.Layout(applicationSupport: support, systemCaches: URL(fileURLWithPath: "/Users/me/Library/Caches"), sandboxed: false)
        let root = support.path + "/Nollie"
        #expect(layout.root.path == root)
        for url in [layout.setups, layout.runtimeService, layout.cuaSetup, layout.cua, layout.conversations, layout.companionBackups,
                    layout.computer, layout.botAvatars, layout.logs, layout.caches, layout.transcripts, layout.media, layout.webImages] {
            #expect(url.path.hasPrefix(root + "/"), "\(url.path)")
        }
        #expect(layout.cua.path == root + "/Cua")
        #expect(layout.transcripts.path == root + "/Caches/transcripts")
        // The demo copy never shares a folder with the real app.
        #expect(NolliePaths.Layout(applicationSupport: support, systemCaches: support, sandboxed: false, demo: true).root.lastPathComponent == "Nollie Demo")
    }

    @Test func aSandboxedEditionKeepsCachesInItsContainersCachesFolder() {
        let container = URL(fileURLWithPath: "/c/Library")
        let layout = NolliePaths.Layout(applicationSupport: container.appendingPathComponent("Application Support"),
                                        systemCaches: container.appendingPathComponent("Caches"), sandboxed: true)
        #expect(layout.media.path == "/c/Library/Caches/nollie-media")
        #expect(layout.botAvatars.path == "/c/Library/Application Support/Nollie/BotAvatars")
        let moves = NolliePaths.legacyMoves(layout: layout, applicationSupport: container.appendingPathComponent("Application Support"),
                                            systemCaches: container.appendingPathComponent("Caches"), library: container, sandboxed: true)
        #expect(moves.map(\.to) == [layout.botAvatars])
    }

    @Test func earlierFoldersMoveInAndNothingIsCopiedAndForgotten() throws {
        let home = try sandbox()
        defer { try? FileManager.default.removeItem(at: home) }
        let support = home.appendingPathComponent("Library/Application Support"), caches = home.appendingPathComponent("Library/Caches")
        let library = home.appendingPathComponent("Library")
        let layout = NolliePaths.Layout(applicationSupport: support, systemCaches: caches, sandboxed: false)
        let chat = UUID().uuidString
        try write("photo", support.appendingPathComponent("BotAvatars/scout.jpg"))
        try write("[]", caches.appendingPathComponent("transcripts/\(chat)/one.json"))
        try write("png", caches.appendingPathComponent("nollie-media/abc"))
        // Console's folder for Nollie's own log files is not an old place: it stays where it is.
        try write("log", library.appendingPathComponent("Logs/Nollie/Nollie.log"))
        // Already at the new place: kept there, and the older copy stays where it was.
        try write("newer", layout.webImages.appendingPathComponent("same"))
        try write("older", caches.appendingPathComponent("nollie-web-images/same"))
        try write("other", caches.appendingPathComponent("nollie-web-images/other"))
        let moves = NolliePaths.legacyMoves(layout: layout, applicationSupport: support, systemCaches: caches, library: library, sandboxed: false)
        let results = moves.map { NolliePaths.move($0) }
        #expect(results == [.moved, .moved, .moved, .left("some items were already there")])
        #expect(try String(contentsOf: layout.botAvatars.appendingPathComponent("scout.jpg"), encoding: .utf8) == "photo")
        #expect(FileManager.default.fileExists(atPath: layout.transcripts.appendingPathComponent("\(chat)/one.json").path))
        #expect(FileManager.default.fileExists(atPath: library.appendingPathComponent("Logs/Nollie/Nollie.log").path))
        #expect(!FileManager.default.fileExists(atPath: support.appendingPathComponent("BotAvatars").path))
        #expect(try String(contentsOf: layout.webImages.appendingPathComponent("same"), encoding: .utf8) == "newer")
        #expect(try String(contentsOf: caches.appendingPathComponent("nollie-web-images/same"), encoding: .utf8) == "older")
        #expect(FileManager.default.fileExists(atPath: layout.webImages.appendingPathComponent("other").path))
        // Safe to repeat: nothing left to move is touched.
        #expect(moves.map { NolliePaths.move($0) }.prefix(3) == [.nothingThere, .nothingThere, .nothingThere])
    }

    @Test func aFolderThatIsntNolliesOrIsALinkStaysWhereItIs() throws {
        let home = try sandbox()
        defer { try? FileManager.default.removeItem(at: home) }
        let support = home.appendingPathComponent("Application Support")
        let layout = NolliePaths.Layout(applicationSupport: support, systemCaches: home.appendingPathComponent("Caches"), sandboxed: false)
        try write("not a photo", support.appendingPathComponent("BotAvatars/notes.txt"))
        let avatars = NolliePaths.Move(from: support.appendingPathComponent("BotAvatars"), to: layout.botAvatars, shape: .files(["jpg"]))
        #expect(NolliePaths.move(avatars) == .left("not Nollie's"))
        #expect(FileManager.default.fileExists(atPath: support.appendingPathComponent("BotAvatars/notes.txt").path))

        try write("x", home.appendingPathComponent("Caches/transcripts/not-a-uuid/a.json"))
        let transcripts = NolliePaths.Move(from: home.appendingPathComponent("Caches/transcripts"), to: layout.transcripts, shape: .uuidFolders)
        #expect(NolliePaths.move(transcripts) == .left("not Nollie's"))

        let elsewhere = home.appendingPathComponent("Elsewhere")
        try write("keep", elsewhere.appendingPathComponent("a"))
        try FileManager.default.createSymbolicLink(at: home.appendingPathComponent("Caches/nollie-media"), withDestinationURL: elsewhere)
        let media = NolliePaths.Move(from: home.appendingPathComponent("Caches/nollie-media"), to: layout.media, shape: .anything)
        #expect(NolliePaths.move(media) == .left("not a folder"))
        #expect(FileManager.default.fileExists(atPath: elsewhere.appendingPathComponent("a").path))
    }

    @Test func bulkyFoldersThatCanBeFetchedAgainStayOutOfBackups() throws {
        let home = try sandbox()
        defer { try? FileManager.default.removeItem(at: home) }
        let layout = NolliePaths.Layout(applicationSupport: home, systemCaches: home.appendingPathComponent("SystemCaches"), sandboxed: false)
        let setup = layout.setups.appendingPathComponent(UUID().uuidString)
        for folder in [layout.cua, layout.caches, setup.appendingPathComponent("cache"), setup.appendingPathComponent("home")] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        #expect(Set(NolliePaths.rebuildable(layout)) == [layout.cua, layout.caches, setup.appendingPathComponent("cache", isDirectory: true)])
        NolliePaths.excludeRebuildableFromBackup(layout)
        for folder in [layout.cua, layout.caches, setup.appendingPathComponent("cache")] {
            #expect(try folder.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)
        }
        // A setup's own home (its chats and memory) stays in backups.
        #expect(try setup.appendingPathComponent("home").resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup != true)
    }
}
