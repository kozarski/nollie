#if os(macOS)
import CryptoKit
import Darwin
import Foundation

struct NativeDependencyStep: Identifiable, Equatable, Sendable {
    enum State: String, Sendable { case notChecked, ready, needsInstall, installing, blocked, failed }
    let id: String
    let title: String
    var detail: String
    var state: State
    let optional: Bool
}

enum NativeSetupPlan {
    static var directAvailable: Bool {
        #if NOLLIE_DIRECT
        true
        #else
        false
        #endif
    }
    // Every pin below is listed in Tools/pins.json; Tools/dev/check-latest.py --local checks they agree.
    static let hermesCommit = "d923a5eb487a17c0a68801bba9ef0f56c81040a8"
    static let pythonVersion = "3.14.8"
    static let pythonKey = "cpython-3.14.8-macos-aarch64-none"
    /// SHA-256 of Services/Runtime/HermesOverlay/overlay.json: Nollie's reviewed changes to this Hermes.
    static let hermesOverlayDigest = "dbaab45cd6f846b8650c0dc91e51c2d4835f17986659668d2ebd8bcaa6541530"
    /// What a prepared Hermes receipt records: the release plus the exact reviewed changes on top.
    static var hermesPreparedVersion: String { hermes.version + "+nollie." + hermesOverlayDigest.prefix(12) }
    struct Artifact: Sendable {
        let id: String
        let version: String
        let url: URL
        let sha256: String
        let bytes: Int
    }
    static let uv = Artifact(id: "uv", version: "0.13.4",
        url: URL(string: "https://github.com/astral-sh/uv/releases/download/0.13.4/uv-aarch64-apple-darwin.tar.gz")!,
        sha256: "e0b1d4743ce64c55d9f0f4a444afa6b81125680070ee04e853fcd0f6c1ebf8f1", bytes: 14_326_193)
    static let hermes = Artifact(id: "hermes", version: "0.22.2",
        url: URL(string: "https://codeload.github.com/NousResearch/hermes-agent/tar.gz/" + hermesCommit)!,
        sha256: "616649f8ac7e3bb186999d000d77511e733b3930bd2b5921be4a85673320ef8b", bytes: 81_466_389)
    /// The preparation steps, in order. "addons" is Nollie's own add-ons; the service needs only the first four.
    static let preparationSteps = ["uv", "python", "hermes", "dependencies", "addons"]
    static let runtimeSteps = ["uv", "python", "hermes", "dependencies"]
    /// Measured for this plan: what one fresh preparation downloads and keeps on disk.
    static let downloadMegabytes = 180
    static let diskMegabytes = 800

    static var steps: [NativeDependencyStep] { [
        .init(id: "uv", title: "Download manager", detail: "uv 0.13.4. A 14.3 MB verified download, kept inside Nollie's setup folder.", state: .notChecked, optional: false),
        .init(id: "python", title: "Python runtime", detail: "Python 3.14.8. A 26.7 MB verified download. A separate runtime for Nollie, without changing your existing Python.", state: .notChecked, optional: false),
        .init(id: "hermes", title: "Hermes Agent", detail: "Hermes 0.22.2 at a fixed revision, an 81.5 MB verified download, with Nollie's reviewed changes for quiet bot chats, Board notes and safe scheduled checks.", state: .notChecked, optional: false),
        .init(id: "dependencies", title: "Runtime libraries", detail: "The exact versions in Hermes's lockfile, each checked against its recorded hash. About 40 MB.", state: .notChecked, optional: false),
        .init(id: "addons", title: "Nollie add-ons", detail: "Board follow-through, Papertrail and the Night shift, the crew, the page reader, computer previews and using apps on this Mac. The reader's own libraries are about 20 MB, each checked against its recorded hash.", state: .notChecked, optional: false),
        .init(id: "service", title: "Background service", detail: "Keeps your assistant running while this Mac is awake, even after Nollie closes. Starting it is a separate step, with your permission.", state: .notChecked, optional: false),
        .init(id: "computer", title: "Computer access", detail: "Optional. Needs a packaged computer adapter and your macOS permission approval. No permissions are copied.", state: .blocked, optional: true)
    ] }

    static func environment(installation: URL) -> [String: String] {
        let userHome = installation.appendingPathComponent("user", isDirectory: true).path
        return ["HOME": userHome, "HERMES_HOME": installation.appendingPathComponent("home").path,
                "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "en_US.UTF-8", "NO_COLOR": "1",
                "PYTHONNOUSERSITE": "1", "PYTHONDONTWRITEBYTECODE": "1",
                "UV_PYTHON_INSTALL_DIR": installation.appendingPathComponent("python").path,
                "UV_PYTHON_BIN_DIR": installation.appendingPathComponent("bin").path,
                "UV_CACHE_DIR": installation.appendingPathComponent("cache/uv").path,
                "UV_PROJECT_ENVIRONMENT": installation.appendingPathComponent("environment").path,
                "UV_NO_CONFIG": "1", "UV_NO_MODIFY_PATH": "1", "UV_PYTHON_DOWNLOADS": "manual",
                "XDG_CACHE_HOME": installation.appendingPathComponent("cache").path,
                "XDG_CONFIG_HOME": installation.appendingPathComponent("user/config").path,
                "XDG_DATA_HOME": installation.appendingPathComponent("user/data").path,
                "TMPDIR": installation.appendingPathComponent("temporary").path]
    }

    static func validateArchiveListing(names: String, verbose: String) throws {
        let entries = names.split(separator: "\n", omittingEmptySubsequences: true)
        guard !entries.isEmpty, entries.count < 100_000 else { throw failure("The downloaded archive has an invalid file list.") }
        var top: String?
        for raw in entries {
            let name = String(raw)
            let parts = name.split(separator: "/", omittingEmptySubsequences: true)
            guard !name.hasPrefix("/"), !name.contains("\\"), !parts.contains(".."),
                  !name.contains("\r"), let first = parts.first, first != "." else {
                throw failure("The downloaded archive contains an unsafe path.")
            }
            if let top, top != first { throw failure("The downloaded archive has an unexpected layout.") }
            top = String(first)
        }
        let details = verbose.split(separator: "\n", omittingEmptySubsequences: true)
        guard details.count == entries.count, details.allSatisfy({ $0.first == "-" || $0.first == "d" }) else {
            throw failure("Linked or special files are not accepted in this download.")
        }
    }

    static func failure(_ message: String) -> ConfigurationBackup.Failure { .init(message) }
}

/// Stores preparation receipts separately from runtime readiness. A downloaded dependency
/// never implies an installed background service or a working gateway connection.
actor NativeDependencyInstaller {
    struct Receipt: Codable {
        let schema: Int
        let owner: String
        let step: String
        let version: String
        let sha256: String?
        let files: [FileRecord]
    }
    struct FileRecord: Codable, Equatable {
        let path: String
        let bytes: Int
        let sha256: String
        var linkTarget: String? = nil
    }
    let installation: URL
    init(installation: URL) { self.installation = installation }

    func inspect() -> [NativeDependencyStep] {
        var steps = NativeSetupPlan.steps
        for index in steps.indices where !["service", "computer"].contains(steps[index].id) {
            let id = steps[index].id
            if !NativeSetupPlan.directAvailable {
                steps[index].state = .blocked
                steps[index].detail = "Local installation is available in the direct Mac edition."
            } else if (try? verified(id)) == true {
                steps[index].state = .ready
            } else { steps[index].state = .needsInstall }
        }
        return steps
    }

    func install(_ id: String) async throws {
        #if NOLLIE_DIRECT
        guard NativeSetupPlan.preparationSteps.contains(id) else {
            throw NativeSetupPlan.failure("This step needs a packaged, signed native service before it can run.")
        }
        #if !arch(arm64)
        throw NativeSetupPlan.failure("This runtime package currently supports Apple silicon Macs.")
        #else
        try prepareDirectories()
        if (try? verified(id)) == true { return }
        try quarantineIncompleteStep(id)
        switch id {
        case "uv": try await installArtifact(NativeSetupPlan.uv)
        case "hermes": try await installArtifact(NativeSetupPlan.hermes, overlay: NativeSetupKit.hermesOverlay())
        case "python":
            try await requireUV()
            try OwnedSetupFiles.createPrivateDirectory(installation.appendingPathComponent("python"))
            try await run(uvPath, ["--no-config", "python", "install", NativeSetupPlan.pythonKey, "--no-bin"], timeout: 600)
            let version = try await run(pythonPath, ["-I", "--version"], timeout: 15)
            guard version.trimmingCharacters(in: .whitespacesAndNewlines) == "Python " + NativeSetupPlan.pythonVersion else {
                throw NativeSetupPlan.failure("The installed Python version did not match the reviewed plan.")
            }
            try saveReceipt(id, version: NativeSetupPlan.pythonVersion)
        case "dependencies":
            try await requireUV()
            guard try verified("python"), try verified("hermes") else {
                throw NativeSetupPlan.failure("Prepare Python and Hermes before installing runtime libraries.")
            }
            _ = try await run(uvPath, ["--no-config", "sync", "--frozen", "--no-default-groups", "--no-install-project", "--no-build",
                                     "--python", pythonPath.path, "--project", sourcePath.path], timeout: 1_200)
            let envPython = installation.appendingPathComponent("environment/bin/python")
            _ = try await run(envPython, ["-I", "-B", "-c", "import fastapi, uvicorn, websockets, openai; from ruamel.yaml import YAML"], timeout: 20)
            try saveReceipt(id, version: NativeSetupPlan.hermesCommit)
        case "addons":
            guard try verified("python"), try verified("hermes"), try verified("dependencies") else {
                throw NativeSetupPlan.failure("Prepare the runtime before adding Nollie's add-ons.")
            }
            let kit = try NativeSetupKit.addOns()
            let envPython = installation.appendingPathComponent("environment/bin/python")
            // The bundled installer copies the checked add-ons, keeps dated copies of older ones, builds the
            // reader's hash-locked environment and lists the add-ons in Hermes's config, with a dated backup.
            _ = try await run(envPython, ["-I", "-B", kit.installer.path, "--kit", kit.root.path,
                                          "--installation", installation.path, "--uv", uvPath.path,
                                          "--python", pythonPath.path], timeout: 900)
            try saveAddOnsReceipt(kit)
        default: break
        }
        #endif
        #else
        throw NativeSetupPlan.failure("Local installation is available in the direct Mac edition.")
        #endif
    }

    private var uvPath: URL { installation.appendingPathComponent("uv/uv") }
    private var sourcePath: URL { installation.appendingPathComponent("hermes") }
    private var pythonPath: URL { installation.appendingPathComponent("python/" + NativeSetupPlan.pythonKey + "/bin/python3.14") }

    static func readReceipt(installation: URL, id: String) throws -> Receipt {
        guard NativeSetupPlan.preparationSteps.contains(id) else { throw NativeSetupPlan.failure("Unknown preparation step.") }
        let data = try OwnedSetupFiles.read(installation.appendingPathComponent("receipts/" + id + ".json"), maximum: 32_000_000)
        let result = try JSONDecoder().decode(Receipt.self, from: data)
        guard result.files.count < 100_000 else { throw NativeSetupPlan.failure("The preparation receipt is too large.") }
        return result
    }

    func verified(_ id: String) throws -> Bool {
        guard let receipt = try? Self.readReceipt(installation: installation, id: id), receipt.schema == 1,
              receipt.owner == "com.coreykozarski.nollie", receipt.step == id else { return false }
        switch id {
        case "uv", "hermes":
            let artifact = id == "uv" ? NativeSetupPlan.uv : NativeSetupPlan.hermes
            let version = id == "uv" ? artifact.version : NativeSetupPlan.hermesPreparedVersion
            guard receipt.version == version, receipt.sha256 == artifact.sha256 else { return false }
            let archive = try OwnedSetupFiles.read(installation.appendingPathComponent("downloads/" + id + ".tar.gz"), maximum: artifact.bytes)
            guard archive.count == artifact.bytes, OwnedSetupFiles.hash(archive) == artifact.sha256 else { return false }
            guard !receipt.files.isEmpty else { return false }
            return try inventory(installation.appendingPathComponent(id)) == receipt.files
        case "python":
            guard receipt.version == NativeSetupPlan.pythonVersion else { return false }
            guard !receipt.files.isEmpty else { return false }
            return try receipt.files == inventory(installation.appendingPathComponent("python"), allowInternalLinks: true)
        case "dependencies":
            guard receipt.version == NativeSetupPlan.hermesCommit else { return false }
            guard !receipt.files.isEmpty, try verified("python") else { return false }
            return try receipt.files == inventory(installation.appendingPathComponent("environment"), allowInternalLinks: true)
        case "addons":
            // Current only for the add-ons this app carries. Every carried file must still be in place;
            // Hermes may add its own files beside them, which is fine.
            guard let kit = try? NativeSetupKit.addOns(), receipt.version == kit.digest, !receipt.files.isEmpty else { return false }
            let home = installation.appendingPathComponent("home")
            for file in receipt.files {
                guard NativeSetupKit.isSafeRelativePath(file.path),
                      let bytes = try? OwnedSetupFiles.read(home.appendingPathComponent(file.path), maximum: file.bytes),
                      bytes.count == file.bytes, OwnedSetupFiles.hash(bytes) == file.sha256 else { return false }
            }
            return true
        default: return false
        }
    }

    /// The add-ons receipt lists each carried file where the installer put it, relative to the Hermes home.
    private func addOnsRecords(_ kit: NativeSetupKit.AddOns) throws -> [FileRecord] {
        let home = installation.appendingPathComponent("home")
        return try kit.installedFiles.map { file in
            let bytes = try OwnedSetupFiles.read(home.appendingPathComponent(file.path), maximum: file.bytes)
            guard bytes.count == file.bytes, OwnedSetupFiles.hash(bytes) == file.sha256 else {
                throw NativeSetupPlan.failure("An add-on did not install as reviewed. Nothing else was changed.")
            }
            return FileRecord(path: file.path, bytes: file.bytes, sha256: file.sha256)
        }.sorted { $0.path < $1.path }
    }

    private func record(_ file: URL, relativeTo root: URL) throws -> FileRecord {
        guard file.path.hasPrefix(root.path + "/") else { throw NativeSetupPlan.failure("A prepared file escaped its setup folder.") }
        let bytes = try OwnedSetupFiles.read(file, maximum: 100_000_000)
        return FileRecord(path: String(file.path.dropFirst(root.path.count + 1)), bytes: bytes.count, sha256: OwnedSetupFiles.hash(bytes))
    }

    func inventory(_ root: URL, allowInternalLinks: Bool = false) throws -> [FileRecord] {
        let fd = try OwnedSetupFiles.directory(root)
        close(fd)
        var records: [FileRecord] = []
        func visit(_ folder: URL) throws {
            for file in try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey]) {
                let values = try file.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey])
                if values.isSymbolicLink == true {
                    let target = try FileManager.default.destinationOfSymbolicLink(atPath: file.path)
                    var components = target.hasPrefix("/") ? [String]() : Array(file.deletingLastPathComponent().pathComponents.dropFirst())
                    for part in target.split(separator: "/") {
                        if part == "." { continue }
                        if part == ".." { if !components.isEmpty { components.removeLast() } }
                        else { components.append(String(part)) }
                    }
                    // Normalize lexically only. Foundation can rewrite /private/var to /var,
                    // which would incorrectly reject a valid link within a canonical root.
                    let resolved = "/" + components.joined(separator: "/")
                    guard allowInternalLinks, resolved.hasPrefix(installation.path + "/") else {
                        throw NativeSetupPlan.failure("A prepared component links outside its own setup.")
                    }
                    records.append(FileRecord(path: String(file.path.dropFirst(root.path.count + 1)), bytes: 0,
                                              sha256: OwnedSetupFiles.hash(Data(target.utf8)), linkTarget: target))
                } else if values.isDirectory == true { try visit(file) }
                else if values.isRegularFile == true { records.append(try record(file, relativeTo: root)) }
                else { throw NativeSetupPlan.failure("A prepared component contains an unsupported file.") }
                guard records.count < 100_000 else { throw NativeSetupPlan.failure("A prepared component has too many files.") }
            }
        }
        try visit(root)
        return records.sorted { $0.path < $1.path }
    }

    #if NOLLIE_DIRECT
    func quarantineIncompleteStep(_ id: String) throws {
        let paths: [String]
        switch id {
        case "uv", "hermes":
            // A saved download that still matches its pin is kept, so a retry does not fetch it again.
            // It is checked once more before use.
            let artifact = id == "uv" ? NativeSetupPlan.uv : NativeSetupPlan.hermes
            let saved = try? OwnedSetupFiles.read(installation.appendingPathComponent("downloads/" + id + ".tar.gz"), maximum: artifact.bytes)
            let pinned = saved.map { $0.count == artifact.bytes && OwnedSetupFiles.hash($0) == artifact.sha256 } == true
            paths = pinned ? [id, "receipts/" + id + ".json"] : [id, "downloads/" + id + ".tar.gz", "receipts/" + id + ".json"]
        case "python": paths = ["python", "receipts/python.json"]
        case "dependencies": paths = ["environment", "receipts/dependencies.json"]
        // Add-ons live in the Hermes home with the person's data. Their installer keeps dated copies itself.
        case "addons": paths = ["receipts/addons.json"]
        default: throw NativeSetupPlan.failure("Unknown preparation step.")
        }
        // Move only named dependency components. User data and verified import backups
        // are never a repair target. Renaming a link does not follow its destination.
        let quarantine = installation.appendingPathComponent("quarantine", isDirectory: true)
        try OwnedSetupFiles.createPrivateDirectory(quarantine)
        let destination = try OwnedSetupFiles.directory(quarantine)
        defer { close(destination) }
        for path in paths {
            let url = installation.appendingPathComponent(path)
            let parent = try OwnedSetupFiles.directory(url.deletingLastPathComponent())
            defer { close(parent) }
            var info = stat()
            if fstatat(parent, url.lastPathComponent, &info, AT_SYMLINK_NOFOLLOW) != 0 {
                guard errno == ENOENT else { throw NativeSetupPlan.failure("The previous preparation could not be preserved safely.") }
                continue
            }
            guard renameat(parent, url.lastPathComponent, destination, UUID().uuidString + "-" + url.lastPathComponent) == 0 else {
                throw NativeSetupPlan.failure("The previous preparation could not be preserved safely.")
            }
        }
    }

    private func prepareDirectories() throws {
        let values = try installation.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        guard let available = values.volumeAvailableCapacityForImportantUsage, available > 6_000_000_000 else {
            throw NativeSetupPlan.failure("Keep at least 6 GB free before preparing the runtime. Model downloads need more space.")
        }
        // The service creates and owns this root before a runner can write into it.
        let marker = try OwnedSetupFiles.read(installation.appendingPathComponent("ownership.json"), maximum: 4096)
        guard let object = try JSONSerialization.jsonObject(with: marker) as? [String: String],
              object["owner"] == "com.coreykozarski.nollie", object["installationID"] == installation.lastPathComponent else {
            throw NativeSetupPlan.failure("This folder is not an Nollie-owned setup.")
        }
        for name in ["downloads", "receipts", "user", "home", "bin", "cache", "temporary"] {
            try OwnedSetupFiles.createPrivateDirectory(installation.appendingPathComponent(name))
        }
    }

    private func installArtifact(_ artifact: NativeSetupPlan.Artifact, overlay: NativeSetupKit.Overlay? = nil) async throws {
        let archive = installation.appendingPathComponent("downloads/" + artifact.id + ".tar.gz")
        let bytes: Data
        if let saved = try? OwnedSetupFiles.read(archive, maximum: artifact.bytes) {
            bytes = saved
        } else {
            bytes = try await NativeArtifactDownload.fetch(artifact)
            guard bytes.count == artifact.bytes, OwnedSetupFiles.hash(bytes) == artifact.sha256 else {
                throw NativeSetupPlan.failure("The download did not match the reviewed checksum. Nothing was installed.")
            }
            try OwnedSetupFiles.writeNew(bytes, to: archive)
        }
        guard bytes.count == artifact.bytes, OwnedSetupFiles.hash(bytes) == artifact.sha256 else {
            throw NativeSetupPlan.failure("The saved download failed verification. Existing files were not replaced.")
        }
        let names = try await run(URL(fileURLWithPath: "/usr/bin/tar"), ["-tzf", archive.path], timeout: 30)
        let verbose = try await run(URL(fileURLWithPath: "/usr/bin/tar"), ["-tvzf", archive.path], timeout: 30)
        try NativeSetupPlan.validateArchiveListing(names: names, verbose: verbose)
        let output = installation.appendingPathComponent(artifact.id, isDirectory: true)
        let staging = installation.appendingPathComponent("staging-" + UUID().uuidString, isDirectory: true)
        try OwnedSetupFiles.createPrivateDirectory(staging, exclusive: true)
        _ = try await run(URL(fileURLWithPath: "/usr/bin/tar"), ["-xzf", archive.path, "-C", staging.path,
                         "--strip-components", "1", "--no-same-owner", "--no-same-permissions"], timeout: 120)
        // Nollie's reviewed changes go on before anything is published, so a receipt always describes
        // the exact tree that runs. Each original must match the reviewed one first.
        if let overlay { try overlay.apply(to: staging) }
        // Publishing is create-only. An incomplete prior directory is never silently replaced.
        if FileManager.default.fileExists(atPath: output.path) {
            // Resume the narrow crash seam between a verified publish and its receipt.
            guard try inventory(output) == inventory(staging) else {
                throw NativeSetupPlan.failure("An unfinished component differs from this release. It has been preserved for review.")
            }
            try FileManager.default.removeItem(at: staging)
        } else {
            try FileManager.default.moveItem(at: staging, to: output)
        }
        try saveReceipt(artifact.id, version: overlay == nil ? artifact.version : NativeSetupPlan.hermesPreparedVersion,
                        sha256: artifact.sha256)
    }

    private func requireUV() async throws {
        guard try verified("uv") else { throw NativeSetupPlan.failure("Prepare the verified download manager first.") }
        // Apple's standalone-code check verifies notarization without treating a CLI as an app.
        // The pinned archive hash remains required; neither check changes macOS security policy.
        do { _ = try await run(URL(fileURLWithPath: "/usr/bin/codesign"), ["--verify", "--strict", "-R=notarized", "--check-notarization", uvPath.path], timeout: 30) }
        catch { throw NativeSetupPlan.failure("macOS has not approved this download manager. This build needs a signed runtime package before preparation can continue.") }
    }

    private func saveAddOnsReceipt(_ kit: NativeSetupKit.AddOns) throws {
        let receipt = Receipt(schema: 1, owner: "com.coreykozarski.nollie", step: "addons", version: kit.digest, sha256: nil,
                              files: try addOnsRecords(kit))
        try OwnedSetupFiles.writeNew(JSONEncoder().encode(receipt), to: installation.appendingPathComponent("receipts/addons.json"))
    }

    private func saveReceipt(_ id: String, version: String, sha256: String? = nil) throws {
        let files: [FileRecord]
        switch id {
        case "uv", "hermes": files = try inventory(installation.appendingPathComponent(id))
        case "python": files = try inventory(installation.appendingPathComponent("python"), allowInternalLinks: true)
        default: files = try inventory(installation.appendingPathComponent("environment"), allowInternalLinks: true)
        }
        let receipt = Receipt(schema: 1, owner: "com.coreykozarski.nollie", step: id, version: version, sha256: sha256, files: files)
        try OwnedSetupFiles.writeNew(JSONEncoder().encode(receipt), to: installation.appendingPathComponent("receipts/" + id + ".json"))
    }

    @discardableResult private func run(_ executable: URL, _ arguments: [String], timeout: TimeInterval) async throws -> String {
        try await NativeSetupProcess.run(executable: executable, arguments: arguments, installation: installation,
                                         environment: NativeSetupPlan.environment(installation: installation), timeout: timeout)
    }
    #endif
}

#if NOLLIE_DIRECT
enum NativeSetupProcess {
    struct Failure: Error, Sendable {
        let status: Int32
        // Kept separate from user-facing errors. The setup UI never displays process output.
        let diagnostic: String
    }
    static func run(executable: URL, arguments: [String], installation: URL,
                    environment: [String: String], timeout: TimeInterval) async throws -> String {
        let work = Task.detached(priority: .userInitiated) {
            let output = installation.appendingPathComponent("temporary/process-" + UUID().uuidString)
            try OwnedSetupFiles.writeNew(Data(), to: output)
            let log = try FileHandle(forWritingTo: output)
            defer { try? log.close(); try? FileManager.default.removeItem(at: output) }
            let process = Process()
            process.executableURL = executable
            process.arguments = arguments
            process.environment = environment
            process.currentDirectoryURL = installation
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = log
            process.standardError = log
            try process.run()
            let deadline = Date().addingTimeInterval(timeout)
            while process.isRunning {
                let size = (try? FileManager.default.attributesOfItem(atPath: output.path)[.size] as? NSNumber)?.intValue ?? 0
                if Task.isCancelled || Date() >= deadline || size > 16_000_000 {
                    process.terminate()
                    for _ in 0..<20 where process.isRunning { try? await Task.sleep(for: .milliseconds(50)) }
                    if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                    for _ in 0..<50 where process.isRunning { try? await Task.sleep(for: .milliseconds(100)) }
                    throw NativeSetupPlan.failure("This preparation step stopped before completion. Existing setup files are unchanged.")
                }
                try? await Task.sleep(for: .milliseconds(100))
            }
            // isRunning is false and terminationStatus is available. waitUntilExit can
            // strand a run loop when this async task resumes on a different thread.
            guard process.terminationStatus == 0 else {
                let data = try OwnedSetupFiles.read(output, maximum: 16_000_000)
                throw Failure(status: process.terminationStatus, diagnostic: String(decoding: data.suffix(32_768), as: UTF8.self))
            }
            return String(decoding: try OwnedSetupFiles.read(output, maximum: 16_000_000), as: UTF8.self)
        }
        return try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
    }
}

/// A private session accepts only the pinned project's HTTPS release hosts and bounds
/// download size before reading the result. Response bodies never enter user-facing logs.
private final class NativeArtifactDownload: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let artifact: NativeSetupPlan.Artifact
    private var continuation: CheckedContinuation<Data, Error>?
    private var session: URLSession?
    private var cancelled = false
    private let lock = NSLock()
    private init(_ artifact: NativeSetupPlan.Artifact) { self.artifact = artifact }
    static func fetch(_ artifact: NativeSetupPlan.Artifact) async throws -> Data {
        guard NativeArtifactDownloadPolicy.allows(artifact.url) else {
            throw NativeSetupPlan.failure(NativeArtifactDownloadPolicy.redirectFailure)
        }
        let delegate = NativeArtifactDownload(artifact)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                delegate.lock.lock()
                if delegate.cancelled {
                    delegate.lock.unlock()
                    continuation.resume(throwing: CancellationError())
                    return
                }
                delegate.continuation = continuation
                let configuration = URLSessionConfiguration.ephemeral
                configuration.timeoutIntervalForRequest = 60
                configuration.timeoutIntervalForResource = 600
                configuration.httpCookieStorage = nil
                configuration.urlCredentialStorage = nil
                let queue = OperationQueue()
                queue.maxConcurrentOperationCount = 1
                let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: queue)
                delegate.session = session
                delegate.lock.unlock()
                session.downloadTask(with: artifact.url).resume()
            }
        } onCancel: { delegate.finish(.failure(CancellationError())) }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        guard let url = request.url, NativeArtifactDownloadPolicy.allows(url) else {
            completionHandler(nil)
            finish(.failure(NativeSetupPlan.failure(NativeArtifactDownloadPolicy.redirectFailure)))
            return
        }
        completionHandler(request)
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        if totalBytesWritten > artifact.bytes || totalBytesExpectedToWrite > artifact.bytes {
            finish(.failure(NativeSetupPlan.failure("The download was larger than the reviewed release.")))
        }
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        let status = (downloadTask.response as? HTTPURLResponse)?.statusCode
        guard status == 200 else {
            finish(.failure(NativeSetupPlan.failure(NativeArtifactDownloadPolicy.httpFailure(status)))); return
        }
        do {
            let size = try location.resourceValues(forKeys: [.fileSizeKey]).fileSize
            guard size == artifact.bytes else { throw NativeSetupPlan.failure("The download size did not match the reviewed release.") }
            let data = try Data(contentsOf: location)
            guard data.count == artifact.bytes, OwnedSetupFiles.hash(data) == artifact.sha256 else {
                throw NativeSetupPlan.failure("The download failed checksum verification.")
            }
            finish(.success(data))
        } catch {
            finish(.failure((error as? ConfigurationBackup.Failure) ?? NativeSetupPlan.failure("The download could not be read for verification.")))
        }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            finish(.failure(NativeSetupPlan.failure(NativeArtifactDownloadPolicy.transportFailure(error))))
        }
    }
    private func finish(_ result: Result<Data, Error>) {
        lock.lock()
        cancelled = true
        let pending = continuation
        continuation = nil
        let active = session
        session = nil
        lock.unlock()
        pending?.resume(with: result)
        active?.invalidateAndCancel()
    }
}

enum NativeArtifactDownloadPolicy {
    static let redirectFailure = "The release server redirected outside the approved download hosts. Nothing was installed."

    static func allows(_ url: URL) -> Bool {
        let hosts = ["github.com", "codeload.github.com", "release-assets.githubusercontent.com", "objects.githubusercontent.com"]
        return url.scheme == "https" && hosts.contains(url.host ?? "") && url.user == nil && url.password == nil
            && (url.port == nil || url.port == 443)
    }

    static func httpFailure(_ status: Int?) -> String {
        guard let status else { return "The release server did not return an HTTP response. You can retry this step." }
        return "The release server returned HTTP \(status). You can retry this step."
    }

    static func transportFailure(_ error: Error) -> String {
        let error = error as NSError
        if error.domain == NSURLErrorDomain {
            return "The download stopped with network error \(error.code). You can retry this step."
        }
        return "The download stopped before verification. You can retry this step."
    }
}
#endif
#endif
