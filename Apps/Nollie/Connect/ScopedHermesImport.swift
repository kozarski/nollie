#if os(macOS)
import CryptoKit
import Darwin
import Foundation

/// Imported configuration is an inactive archive. Only the two reviewed instruction
/// documents are copied into the new home; credentials and automation are never adopted.
enum ScopedHermesImport {
    struct Entry: Codable, Equatable, Sendable {
        let name: String
        let bytes: Int
        let sha256: String
    }
    struct Preview: Equatable, Sendable {
        let files: [Entry]
        let exclusions = ["All profiles", "Separate credentials", "Chats and history", "Schedules", "Board", "Computer permissions and leases", "Plugins and startup hooks"]
        let summary = "Copies your instructions into a new home with Nollie's starter settings. Keeps config.yaml in a verified, inactive backup for later review. Existing files stay unchanged."
    }
    struct Result: Sendable {
        let installationID: UUID
        let directory: URL
        let home: URL
        let backup: URL
        let files: [Entry]
    }
    private struct Receipt: Encodable {
        let schema = 1
        let owner = "com.coreykozarski.nollie"
        let installationID: UUID
        let scope = "root-configuration-import"
        let activeConfigurationImported = false
        let schedulesImported = false
        let computerPermissionsImported = false
        let backupRelativePath: String
        let files: [Entry]
    }

    static func preview(source: URL) throws -> Preview {
        Preview(files: try ConfigurationBackup.snapshot(in: source).map(entry))
    }

    static func create(source: URL, preview: Preview, installations: URL) throws -> Result {
        let snapshot = try ConfigurationBackup.snapshot(in: source)
        guard snapshot.map(entry) == preview.files else {
            throw ConfigurationBackup.Failure("The source changed since the preview. Review it again before importing.")
        }
        let sourcePath = source.path
        guard installations.path != sourcePath, !installations.path.hasPrefix(sourcePath + "/") else {
            throw ConfigurationBackup.Failure("The new Nollie home must be outside the existing setup.")
        }
        let starter = try StarterAssistantDefaults.prepare(assistantName: "Nollie")
        let installationID = UUID()
        let directory = installations.appendingPathComponent(installationID.uuidString, isDirectory: true)
        try OwnedSetupFiles.createPrivateDirectory(installations)
        try OwnedSetupFiles.createPrivateDirectory(directory, exclusive: true)
        let backupParent = directory.appendingPathComponent("import-backup", isDirectory: true)
        try OwnedSetupFiles.createPrivateDirectory(backupParent, exclusive: true)
        do {
            let backup = try ConfigurationBackup.create(snapshot: snapshot, in: backupParent)
            let home = directory.appendingPathComponent("home", isDirectory: true)
            try OwnedSetupFiles.createPrivateDirectory(home, exclusive: true)
            for file in snapshot where file.name != "config.yaml" {
                try OwnedSetupFiles.writeNew(file.data, to: home.appendingPathComponent(file.name))
            }
            // Use reviewed defaults for the new copy; imported plugins, hooks and allowlists remain inactive.
            try OwnedSetupFiles.writeNew(starter.configuration, to: home.appendingPathComponent("config.yaml"))
            let receipt = Receipt(installationID: installationID,
                                  backupRelativePath: "import-backup/" + backup.directory.lastPathComponent,
                                  files: snapshot.map(entry))
            try OwnedSetupFiles.writeNew(JSONEncoder().encode(receipt), to: directory.appendingPathComponent("import-receipt.json"))
            return Result(installationID: installationID, directory: directory, home: home,
                          backup: backup.directory, files: snapshot.map(entry))
        } catch {
            try? OwnedSetupFiles.writeNew(Data("Import incomplete. No runtime was started.\n".utf8), to: directory.appendingPathComponent("INCOMPLETE"))
            throw error
        }
    }

    private static func entry(_ file: ConfigurationBackup.SnapshotFile) -> Entry {
        Entry(name: file.name, bytes: file.data.count, sha256: file.sha256)
    }
}

enum OwnedSetupFiles {
    static func createPrivateDirectory(_ url: URL, exclusive: Bool = false) throws {
        let parent = try directory(url.deletingLastPathComponent(), create: true)
        defer { close(parent) }
        let result = mkdirat(parent, url.lastPathComponent, 0o700)
        guard result == 0 || (!exclusive && errno == EEXIST) else { throw failure("The new setup folder already exists or cannot be created.") }
        let fd = openat(parent, url.lastPathComponent, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw failure("The setup folder could not be opened safely.") }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == getuid(), (info.st_mode & 0o077) == 0 else {
            throw failure("The setup folder must be private and owned by this account.")
        }
    }

    static func writeNew(_ data: Data, to url: URL, executable: Bool = false) throws {
        let parent = try directory(url.deletingLastPathComponent())
        defer { close(parent) }
        let fd = openat(parent, url.lastPathComponent, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, executable ? 0o700 : 0o600)
        guard fd >= 0 else { throw failure("A setup file could not be created. Existing files are unchanged.") }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        try handle.write(contentsOf: data)
        try handle.synchronize()
        guard try read(url, maximum: data.count + 1) == data else { throw failure("Setup file verification failed.") }
    }

    static func read(_ url: URL, maximum: Int) throws -> Data {
        let parent = try directory(url.deletingLastPathComponent())
        defer { close(parent) }
        let fd = openat(parent, url.lastPathComponent, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw failure("A setup file is missing or unsafe.") }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
              info.st_size >= 0, info.st_size <= maximum else { throw failure("A setup file is not regular or is too large.") }
        let bytes = try handle.read(upToCount: maximum + 1) ?? Data()
        guard bytes.count <= maximum else { throw failure("A setup file changed size.") }
        return bytes
    }

    static func directory(_ url: URL, create: Bool = false) throws -> Int32 {
        guard url.isFileURL, !url.pathComponents.contains("..") else { throw failure("The setup path is invalid.") }
        var fd = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard fd >= 0 else { throw failure("The setup folder is unavailable.") }
        for component in url.pathComponents.dropFirst() {
            if create, mkdirat(fd, component, 0o700) != 0, errno != EEXIST {
                close(fd)
                throw failure("The setup folder could not be created.")
            }
            let next = openat(fd, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            close(fd)
            guard next >= 0 else { throw failure("Setup paths cannot contain symbolic links.") }
            fd = next
        }
        return fd
    }

    static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    private static func failure(_ text: String) -> ConfigurationBackup.Failure { .init(text) }
}
#endif
