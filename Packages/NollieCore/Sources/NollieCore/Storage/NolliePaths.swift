import Foundation

/// The one place Nollie keeps what it writes outside its app: `~/Library/Application Support/Nollie`.
/// On the iPhone and in the Mac App Store edition the app's own container is already one place, so
/// there the system's caches folder is still used for caches.
///
/// Everything that writes a file outside the app asks this type where. `Tools/dev/test_one_folder.py`
/// fails when new code looks a folder up for itself. The exceptions, which macOS or the person own:
/// preferences (the defaults domain), the Keychain, Privacy & Security rows, temporary files the
/// system clears, and anything inside a person's own existing Hermes.
public enum NolliePaths {
    public struct Layout: Equatable, Sendable {
        /// `Application Support/Nollie` (`Nollie Demo` for the demo copy, which never shares data).
        public let root: URL
        /// `root/Caches` on the Direct Mac edition; the container's own caches folder elsewhere.
        public let caches: URL

        public init(applicationSupport: URL, systemCaches: URL, sandboxed: Bool, demo: Bool = false) {
            root = applicationSupport.appendingPathComponent(demo ? "Nollie Demo" : "Nollie", isDirectory: true)
            caches = sandboxed ? systemCaches : root.appendingPathComponent("Caches", isDirectory: true)
        }

        /// Prepared managed setups, one folder each, named by installation ID with an ownership record.
        public var setups: URL { root.appendingPathComponent("Setups", isDirectory: true) }
        /// Nollie Runtime's private records: its consent, linked phones, a note when Nollie.app was gone.
        public var runtimeService: URL { root.appendingPathComponent("RuntimeService", isDirectory: true) }
        /// Records of what the Cua setup did, and its download while it runs.
        public var cuaSetup: URL { root.appendingPathComponent("CuaSetup", isDirectory: true) }
        /// Cua's own app, when Nollie installed it (it never goes in Applications).
        public var cua: URL { root.appendingPathComponent("Cua", isDirectory: true) }
        public var conversations: URL { root.appendingPathComponent("Conversations", isDirectory: true) }
        public var companionBackups: URL { root.appendingPathComponent("CompanionBackups", isDirectory: true) }
        public var computer: URL { root.appendingPathComponent("Computer", isDirectory: true) }
        public var botAvatars: URL { root.appendingPathComponent("BotAvatars", isDirectory: true) }
        public var logs: URL { root.appendingPathComponent("Logs", isDirectory: true) }
        public var transcripts: URL { caches.appendingPathComponent("transcripts", isDirectory: true) }
        public var media: URL { caches.appendingPathComponent("nollie-media", isDirectory: true) }
        public var webImages: URL { caches.appendingPathComponent("nollie-web-images", isDirectory: true) }

        /// The names Nollie itself puts directly in `root`. Anything else there isn't Nollie's.
        public static let knownChildren: Set<String> = ["Setups", "RuntimeService", "CuaSetup", "Cua", "Conversations",
                                                        "CompanionBackups", "Computer", "BotAvatars", "Logs", "Caches"]
    }

    /// This process's layout.
    public static let current: Layout = {
        let fm = FileManager.default
        let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support", isDirectory: true)
        let caches = fm.urls(for: .cachesDirectory, in: .userDomainMask).first ?? fm.temporaryDirectory
        return Layout(applicationSupport: support, systemCaches: caches, sandboxed: isSandboxed,
                      demo: Bundle.main.bundleIdentifier?.hasSuffix(".demo") == true)
    }()

    public static var root: URL { current.root }

    /// iPhone always; on the Mac, the App Store edition and the extensions.
    public static var isSandboxed: Bool {
        #if os(macOS)
        ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil
        #else
        true
        #endif
    }

    /// Creates a folder of Nollie's (and the folders above it, inside Nollie's) when it is missing.
    @discardableResult
    public static func folder(_ url: URL) -> URL {
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return url
    }

    // MARK: Moving in

    /// Where earlier versions kept things, and where they live now. The move happens once, at
    /// launch, and is safe to repeat: nothing already moved is touched again.
    public struct Move: Equatable, Sendable {
        public let from: URL
        public let to: URL
        /// Only files with these extensions, or only folders named by a UUID (transcripts): a folder
        /// with anything else in it isn't Nollie's and stays where it is.
        public let shape: Shape
        public enum Shape: Equatable, Sendable { case files(Set<String>), uuidFolders, anything }
    }

    public static func legacyMoves(layout: Layout, applicationSupport: URL, systemCaches: URL, library: URL?,
                                   sandboxed: Bool) -> [Move] {
        var moves = [Move(from: applicationSupport.appendingPathComponent("BotAvatars", isDirectory: true),
                          to: layout.botAvatars, shape: .files(["jpg"]))]
        guard !sandboxed else { return moves }
        moves += [Move(from: systemCaches.appendingPathComponent("transcripts", isDirectory: true), to: layout.transcripts, shape: .uuidFolders),
                  Move(from: systemCaches.appendingPathComponent("nollie-media", isDirectory: true), to: layout.media, shape: .anything),
                  Move(from: systemCaches.appendingPathComponent("nollie-web-images", isDirectory: true), to: layout.webImages, shape: .anything)]
        // ~/Library/Logs/Nollie is where Console shows the Mac log files (NollieLogFiles), so it is
        // no longer an old place: nothing in it moves.
        return moves
    }

    public enum MoveResult: Equatable, Sendable { case nothingThere, moved, merged, left(String) }

    /// Moves one old folder into Nollie's folder. Never copies and forgets: each item is renamed
    /// into place, and an item already at the new place stays in the old folder rather than being
    /// overwritten. A link, or a folder that doesn't look like Nollie's, is left alone.
    @discardableResult
    public static func move(_ move: Move, fileManager fm: FileManager = .default) -> MoveResult {
        var info = stat()
        guard lstat(move.from.path, &info) == 0 else { return .nothingThere }
        guard (info.st_mode & S_IFMT) == S_IFDIR else { return .left("not a folder") }
        guard let items = try? fm.contentsOfDirectory(atPath: move.from.path) else { return .left("unreadable") }
        guard fits(items, in: move.from, shape: move.shape) else { return .left("not Nollie's") }
        try? fm.createDirectory(at: move.to.deletingLastPathComponent(), withIntermediateDirectories: true,
                                attributes: [.posixPermissions: 0o700])
        if lstat(move.to.path, &info) != 0 {
            do { try fm.moveItem(at: move.from, to: move.to); return .moved } catch { return .left("couldn't move") }
        }
        guard (info.st_mode & S_IFMT) == S_IFDIR else { return .left("something else is in its place") }
        var kept = false
        for name in items where name != ".DS_Store" {
            let target = move.to.appendingPathComponent(name)
            if lstat(target.path, &info) == 0 { kept = true; continue }
            do { try fm.moveItem(at: move.from.appendingPathComponent(name), to: target) } catch { kept = true }
        }
        if !kept {
            try? fm.removeItem(at: move.from.appendingPathComponent(".DS_Store"))
            _ = rmdir(move.from.path)
        }
        return kept ? .left("some items were already there") : .merged
    }

    static func fits(_ items: [String], in folder: URL, shape: Move.Shape) -> Bool {
        let relevant = items.filter { $0 != ".DS_Store" }
        switch shape {
        case .anything: return true
        case .files(let extensions):
            return relevant.allSatisfy { name in
                var info = stat()
                return extensions.contains((name as NSString).pathExtension.lowercased())
                    && lstat(folder.appendingPathComponent(name).path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFREG
            }
        case .uuidFolders:
            return relevant.allSatisfy { name in
                var info = stat()
                return UUID(uuidString: name) != nil
                    && lstat(folder.appendingPathComponent(name).path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFDIR
            }
        }
    }

    /// At launch: moves this device's earlier locations into Nollie's folder. The demo copy never
    /// does, because the old locations belonged to the real app.
    public static func moveInLegacyFolders() {
        guard !(Bundle.main.bundleIdentifier?.hasSuffix(".demo") ?? false) else { return }
        let fm = FileManager.default
        guard let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first,
              let caches = fm.urls(for: .cachesDirectory, in: .userDomainMask).first else { return }
        #if os(macOS)
        let library: URL? = fm.urls(for: .libraryDirectory, in: .userDomainMask).first
        #else
        let library: URL? = nil
        #endif
        for move in legacyMoves(layout: current, applicationSupport: support, systemCaches: caches, library: library, sandboxed: isSandboxed) {
            self.move(move, fileManager: fm)
        }
        excludeRebuildableFromBackup(current)
    }

    // MARK: Backups

    /// Big folders that can be fetched or rebuilt again: caches, Cua's app, and each managed setup's
    /// download cache (where models and packages land). Kept out of Time Machine and device backups.
    public static func rebuildable(_ layout: Layout, fileManager fm: FileManager = .default) -> [URL] {
        var folders = [layout.cua]
        if layout.caches.path.hasPrefix(layout.root.path + "/") { folders.append(layout.caches) }
        else { folders += [layout.transcripts, layout.media, layout.webImages] }
        for name in (try? fm.contentsOfDirectory(atPath: layout.setups.path)) ?? [] where UUID(uuidString: name) != nil {
            folders.append(layout.setups.appendingPathComponent(name).appendingPathComponent("cache", isDirectory: true))
        }
        return folders
    }

    /// Marks each rebuildable folder that exists. No admin rights are needed; the mark stays with the folder.
    public static func excludeRebuildableFromBackup(_ layout: Layout, fileManager fm: FileManager = .default) {
        for folder in rebuildable(layout, fileManager: fm) {
            var info = stat()
            guard lstat(folder.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR else { continue }
            var url = folder
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try? url.setResourceValues(values)
        }
    }
}
