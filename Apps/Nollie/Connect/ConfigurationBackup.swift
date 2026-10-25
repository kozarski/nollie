#if os(macOS)
import CryptoKit
import Darwin
import Foundation

/// A configuration snapshot, not a full Hermes backup. Only explicitly selected root files
/// are opened; databases, profiles and separate credential stores never enter this operation.
enum ConfigurationBackup {
    static let fileNames = ["config.yaml", "SOUL.md", "AGENTS.md"]
    static let maximumSize = 4 * 1024 * 1024

    struct Failure: Error, Sendable {
        var message: String
        init(_ message: String) { self.message = message }
    }
    struct Result: Sendable {
        var directory: URL
        var files: [String]
    }
    struct SnapshotFile: Sendable {
        var name: String
        var data: Data
        var sha256: String { ConfigurationBackup.hash(data) }
    }
    private struct Manifest: Codable {
        var schema = 1
        var scope = "configuration-only"
        var sensitiveSettingsMayBeIncluded = true
        var excluded = [".env and separate auth files", "profiles", "chats", "schedules", "Board", "databases"]
        var files: [Entry]
    }
    private struct Entry: Codable {
        var name: String
        var bytes: Int
        var sha256: String
    }

    static func availableFiles(in source: URL) throws -> [String] {
        try validateRoot(source)
        let root = try openDirectory(source)
        defer { close(root) }
        return try fileNames.filter { name in
            var info = stat()
            let found = fstatat(root, name, &info, AT_SYMLINK_NOFOLLOW)
            if found != 0 {
                guard errno == ENOENT else { throw Failure("A configuration file could not be checked safely.") }
                return false
            }
            guard (info.st_mode & S_IFMT) == S_IFREG, info.st_size <= maximumSize else {
                throw Failure("A configuration file is a link, is not a regular file, or is too large.")
            }
            return true
        }
    }

    static func create(from source: URL, in destination: URL) throws -> Result {
        try validateRoot(source)
        try rejectSymlinks(destination)
        let sourcePath = source.standardizedFileURL.path
        let destinationPath = destination.standardizedFileURL.path
        guard destinationPath != sourcePath, !destinationPath.hasPrefix(sourcePath + "/") else {
            throw Failure("Choose a backup location outside the existing Hermes folder.")
        }
        let content = try snapshot(in: source)
        return try create(snapshot: content, in: destination)
    }

    static func snapshot(in source: URL) throws -> [SnapshotFile] {
        try validateRoot(source)
        let root = try openDirectory(source)
        defer { close(root) }
        // Read the selected directory by descriptor. Renaming it cannot redirect reads into profiles.
        var content: [SnapshotFile] = []
        for name in fileNames {
            let descriptor = openat(root, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
            if descriptor < 0 {
                if errno == ENOENT { continue }
                throw Failure("A configuration file could not be read safely. No backup was created.")
            }
            let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
            var info = stat()
            guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
                  info.st_size >= 0, info.st_size <= maximumSize else {
                try? handle.close()
                throw Failure("A configuration file is not a regular file or is too large.")
            }
            let data = try handle.read(upToCount: maximumSize + 1) ?? Data()
            try handle.close()
            guard data.count <= maximumSize else { throw Failure("A configuration file changed size. Backup stopped.") }
            content.append(SnapshotFile(name: name, data: data))
        }
        guard !content.isEmpty else { throw Failure("No supported configuration files were found. No backup was created.") }
        return content
    }

    static func create(snapshot content: [SnapshotFile], in destination: URL) throws -> Result {
        guard !content.isEmpty, Set(content.map(\.name)).count == content.count,
              content.allSatisfy({ fileNames.contains($0.name) && $0.data.count <= maximumSize }) else {
            throw Failure("The configuration snapshot is invalid.")
        }
        let parent = try openDirectory(destination)
        defer { close(parent) }
        let name = "Nollie Configuration Backup " + UUID().uuidString
        guard mkdirat(parent, name, 0o700) == 0 else { throw Failure("The private backup folder could not be created.") }
        let output = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard output >= 0 else { throw Failure("The backup folder could not be opened safely.") }
        defer { close(output) }
        var entries: [Entry] = []
        do {
            for file in content {
                let name = file.name
                let data = file.data
                try writeExclusive(data, name: name, directory: output)
                let descriptor = openat(output, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
                guard descriptor >= 0 else { throw Failure("Backup verification failed.") }
                let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
                let copied = try handle.readToEnd() ?? Data()
                try handle.close()
                let digest = hash(data)
                guard hash(copied) == digest else { throw Failure("Backup verification failed.") }
                entries.append(Entry(name: name, bytes: data.count, sha256: digest))
            }
            let data = try JSONEncoder().encode(Manifest(files: entries))
            try writeExclusive(data, name: "manifest.json", directory: output)
            return Result(directory: destination.appendingPathComponent(name, isDirectory: true), files: entries.map(\.name))
        } catch {
            try? writeExclusive(Data("This backup did not finish verification.\n".utf8), name: "INCOMPLETE", directory: output)
            throw error
        }
    }

    static func validateRoot(_ source: URL) throws {
        // Profile directories are never an eligible source, even if explicitly selected.
        guard !source.pathComponents.contains(where: { $0.lowercased() == "profiles" }) else {
            throw Failure("Choose the root Hermes folder. Profile folders are excluded.")
        }
        try rejectSymlinks(source)
    }

    static func rejectSymlinks(_ url: URL) throws {
        guard url.isFileURL, !url.pathComponents.contains("..") else { throw Failure("Choose a local folder.") }
        var path = url
        while path.path != "/" {
            var info = stat()
            guard lstat(path.path, &info) == 0 else { throw Failure("The selected folder is unavailable.") }
            guard (info.st_mode & S_IFMT) != S_IFLNK else { throw Failure("Symbolic links are not included in configuration backups.") }
            path.deleteLastPathComponent()
        }
    }

    private static func openDirectory(_ url: URL) throws -> Int32 {
        try rejectSymlinks(url)
        var descriptor = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard descriptor >= 0 else { throw Failure("The selected folder could not be opened safely.") }
        for component in url.pathComponents.dropFirst() {
            let next = openat(descriptor, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            close(descriptor)
            guard next >= 0 else { throw Failure("The selected folder could not be opened safely.") }
            descriptor = next
        }
        return descriptor
    }

    private static func writeExclusive(_ data: Data, name: String, directory: Int32) throws {
        let descriptor = openat(directory, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw Failure("A backup file could not be created. Existing files are unchanged.") }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        try handle.write(contentsOf: data)
        try handle.synchronize()
    }

    private static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
}
#endif
