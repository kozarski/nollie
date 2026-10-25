#if os(macOS)
import CryptoKit
import Darwin
import Foundation

/// The Cua release Nollie installs or updates to: the reviewed Developer ID build, checked
/// against Cua's published checksum, its team identifier and Apple's notarization before
/// anything is copied. Nothing from the download runs until it has passed all three.
enum CuaRelease {
    static let version = "0.12.0"
    /// The cua CLI inside that app. Cua's MIT Hermes plugin needs the 0.5 line.
    static let cliVersion = "0.5.0"
    static let url = URL(string: "https://github.com/trycua/cua/releases/download/cua-spaces-v0.12.0/cua-spaces-0.12.0-darwin-universal.dmg")!
    static let sha256 = "dac3e0be7dd510cf4b3ed3bfa17016945c97cb72922c3549559c4d74c505e836"
    static let bytes = 227_675_515
    static let teamID = "YCK386LBJ7"
    static let bundleID = "com.trycua.spaces.macos"
    static let appName = "Cua Spaces.app"
    static let requirement = #"anchor apple generic and identifier "com.trycua.spaces.macos" and certificate leaf[subject.OU] = "YCK386LBJ7""#
    static let downloadPage = URL(string: "https://cua.ai/download")!

    /// GitHub's release hosts only, over HTTPS, for the download and its redirects.
    static func allowsDownload(from url: URL) -> Bool {
        let hosts = ["github.com", "release-assets.githubusercontent.com", "objects.githubusercontent.com"]
        return url.scheme == "https" && hosts.contains(url.host ?? "") && url.user == nil && url.password == nil
            && (url.port == nil || url.port == 443)
    }

    /// Numeric dotted versions compared part by part; anything unreadable counts as older.
    static func isOlder(_ installed: String?, than wanted: String = version) -> Bool {
        func parts(_ text: String) -> [Int]? {
            let core = text.split(separator: "-").first.map(String.init) ?? text
            let numbers = core.split(separator: ".").map { Int($0) }
            return numbers.contains(nil) || numbers.isEmpty ? nil : numbers.compactMap { $0 }
        }
        guard let installed, let have = parts(installed), let want = parts(wanted) else { return true }
        for i in 0..<max(have.count, want.count) {
            let a = i < have.count ? have[i] : 0, b = i < want.count ? want[i] : 0
            if a != b { return a < b }
        }
        return false
    }

    /// The local computers Cua can run on this Mac, from `cua --json runtime doctor`.
    static func canRunLinux(doctor: Data) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: doctor) as? [String: Any],
              let backends = object["backends"] as? [[String: Any]] else { return false }
        return backends.contains { ["managed", "container", "lume", "qemu"].contains($0["backend"] as? String ?? "") && $0["ready"] as? Bool == true }
    }

    /// A runtime Cua can add by itself (never through another package manager).
    static func provisionable(doctor: Data) -> [String] {
        guard let object = try? JSONSerialization.jsonObject(with: doctor) as? [String: Any],
              let backends = object["backends"] as? [[String: Any]] else { return [] }
        return backends.compactMap { backend in
            guard backend["provisionable"] as? Bool == true, let name = backend["backend"] as? String,
                  ["lume"].contains(name) else { return nil }
            let steps = backend["provisioning"] as? [String] ?? []
            return steps.contains { $0.hasPrefix("brew ") } ? nil : name
        }
    }
}

/// Everything the installer does to the Mac, so the order and refusals can be tested.
protocol CuaSetupSystem: Sendable {
    /// The app in use and its version: the person's own copy in Applications first, else Nollie's.
    func installedApp() -> (url: URL, version: String?)?
    func download(_ url: URL, to file: URL, maximum: Int, progress: @escaping @Sendable (Double) -> Void) async throws
    func sha256(_ file: URL) throws -> String
    func size(_ file: URL) -> Int?
    func attach(_ image: URL) async throws -> URL
    func detach(_ mount: URL) async
    /// Code signature with the pinned requirement, then Gatekeeper's notarization check.
    func verify(_ app: URL) async throws
    func version(_ app: URL) -> String?
    func isRunning() -> Bool
    /// Copies the verified app beside its destination in Nollie's own folder, checks the copy again,
    /// then swaps it in. Only ever Nollie's own copy is replaced.
    func install(_ app: URL, at destination: URL) async throws
    /// Whether Cua's own folder (`~/.cua`) is there, so a fresh install can record who made it.
    func cuaHomeExists() -> Bool
    func run(_ executable: URL, _ arguments: [String], timeout: TimeInterval) async throws -> (status: Int32, output: Data)
    func daemonSocketExists() -> Bool
    func installDestination() -> URL
}

struct CuaSetupFailure: Error, Equatable {
    let message: String
    let phase: NollieCuaSetupResponse.Phase
    init(_ message: String, phase: NollieCuaSetupResponse.Phase = .failed) { self.message = message; self.phase = phase }
}

/// One automatic setup at a time: get or update Cua, start it, and make sure it can run
/// local Linux computers. The app asks the person once before starting it.
///
/// Only Cua's background part (`cua daemon`) ever runs, headless. Nothing here opens the Cua
/// Spaces app, which would show its own menu bar item, or makes it a login item. Nollie Runtime
/// starts the background part when it launches (once a setup has finished) and stops it before
/// Nollie is removed or when Nollie.app is gone.
actor CuaInstaller {
    private let system: any CuaSetupSystem
    private let work: URL
    private var state = NollieCuaSetupResponse()
    private var task: Task<Void, Never>?

    init(system: any CuaSetupSystem, work: URL) {
        self.system = system
        self.work = work
    }

    /// `installed.json`: written only when Nollie put Cua on this Mac itself, so removing Nollie
    /// can take Cua away again and leave a Cua the person set up alone.
    var receiptURL: URL { work.appendingPathComponent(NollieCuaReceipt.fileName) }
    /// `ready.json`: a setup finished, so Cua's background part is Nollie's to start.
    var readyURL: URL { work.appendingPathComponent("ready.json") }

    /// At launch: wakes Cua's background part when a Nollie setup finished before. Never installs.
    func startDaemonIfSetUp() async {
        guard task == nil, FileManager.default.fileExists(atPath: readyURL.path) else { return }
        _ = await wake()
    }

    /// Starts Cua's background part if Cua is on this Mac. Never downloads or opens anything.
    func wake() async -> Bool {
        guard let cli else { return false }
        if !system.daemonSocketExists() {
            _ = try? await system.run(cli, ["daemon", "start"], timeout: 60)
            for _ in 0..<20 where !system.daemonSocketExists() {
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
        return system.daemonSocketExists()
    }

    /// Stops Cua's background part. True when it is not running afterwards.
    func stopDaemon() async -> Bool {
        guard system.daemonSocketExists() else { return true }
        guard let cli else { return false }
        _ = try? await system.run(cli, ["daemon", "stop"], timeout: 60)
        for _ in 0..<20 where system.daemonSocketExists() {
            try? await Task.sleep(for: .milliseconds(250))
        }
        return !system.daemonSocketExists()
    }

    func status() -> NollieCuaSetupResponse {
        var current = state
        if task == nil, current.phase == .idle {
            current.installedVersion = system.installedApp()?.version
        }
        return current
    }

    /// Starts the setup, or reports the one already running. A finished setup can be started
    /// again; it skips whatever is already done.
    func start() -> NollieCuaSetupResponse {
        guard task == nil else { return state }
        state = NollieCuaSetupResponse(phase: .checking)
        task = Task { [weak self] in await self?.perform() }
        return state
    }

    /// Waits for the running setup, for tests.
    func wait() async { await task?.value }

    private func set(_ phase: NollieCuaSetupResponse.Phase, fraction: Double? = nil) {
        state.phase = phase
        state.fraction = fraction
    }

    private func setFraction(_ fraction: Double) {
        guard state.phase == .downloading else { return }
        state.fraction = min(1, max(0, fraction))
    }

    private func perform() async {
        do {
            try await install()
            try await startCua()
            try await prepareComputers()
            state.installedVersion = system.installedApp()?.version
            writePrivately(Data("{\"version\":1}\n".utf8), to: readyURL)
            set(.done)
        } catch let failure as CuaSetupFailure {
            state.failure = failure.message
            set(failure.phase)
        } catch {
            state.failure = "Couldn't set up Cua by itself."
            set(.failed)
        }
        task = nil
    }

    private func install() async throws {
        set(.checking)
        if let installed = system.installedApp(), !CuaRelease.isOlder(installed.version) {
            state.installedVersion = installed.version
            return
        }
        let installed = system.installedApp()
        if let installed, installed.url.standardizedFileURL != system.installDestination().standardizedFileURL {
            // The person's own Cua in Applications: Nollie uses it but never moves, replaces or deletes it.
            throw CuaSetupFailure("Your copy of Cua is older than Nollie needs. Update it from Cua's site, then try again.")
        }
        if installed != nil, system.isRunning() {
            throw CuaSetupFailure("Quit Cua Spaces so Nollie can update it.", phase: .needsQuit)
        }
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let image = work.appendingPathComponent("cua-spaces-\(CuaRelease.version).dmg")
        if (try? system.sha256(image)) != CuaRelease.sha256 {
            try? FileManager.default.removeItem(at: image)
            set(.downloading, fraction: 0)
            do {
                try await system.download(CuaRelease.url, to: image, maximum: CuaRelease.bytes) { fraction in
                    Task { await self.setFraction(fraction) }
                }
            } catch {
                throw CuaSetupFailure("The download didn't finish. Check the internet connection and try again.")
            }
            set(.checking)
            guard system.size(image) == CuaRelease.bytes, (try? system.sha256(image)) == CuaRelease.sha256 else {
                try? FileManager.default.removeItem(at: image)
                throw CuaSetupFailure("The download didn't match Cua's published release, so it wasn't used.")
            }
        }
        set(.checking)
        let mount = try await system.attach(image)
        do {
            let app = mount.appendingPathComponent(CuaRelease.appName)
            do { try await system.verify(app) } catch {
                throw CuaSetupFailure("That copy of Cua isn't signed by Cua, so it wasn't installed.")
            }
            guard system.version(app) == CuaRelease.version else {
                throw CuaSetupFailure("That copy of Cua isn't the expected version, so it wasn't installed.")
            }
            set(.installing)
            let destination = system.installDestination()
            let cuaHomeExisted = system.cuaHomeExists()
            if let installed, system.daemonSocketExists() {
                // The older daemon runs from the bundle being replaced; the new one starts below.
                _ = try? await system.run(installed.url.appendingPathComponent("Contents/MacOS/cua"), ["daemon", "stop"], timeout: 60)
            }
            do { try await system.install(app, at: destination) } catch {
                throw CuaSetupFailure("Couldn't set up Cua in Nollie's folder.")
            }
            if installed == nil {
                // Nollie put Cua here: record exactly what it made, for a clean removal later.
                let receipt = NollieCuaReceipt(app: destination.path, madeCuaHome: !cuaHomeExisted)
                if let data = try? JSONEncoder().encode(receipt) { writePrivately(data, to: receiptURL) }
            }
        } catch {
            await system.detach(mount)
            throw error
        }
        await system.detach(mount)
        try? FileManager.default.removeItem(at: image)
    }

    private var cli: URL? {
        system.installedApp()?.url.appendingPathComponent("Contents/MacOS/cua")
    }

    private func startCua() async throws {
        set(.starting)
        guard let cli else { throw CuaSetupFailure("Cua didn't install properly.") }
        if !system.daemonSocketExists() {
            _ = try? await system.run(cli, ["daemon", "start"], timeout: 60)
            for _ in 0..<60 where !system.daemonSocketExists() {
                try await Task.sleep(for: .milliseconds(500))
            }
        }
        guard system.daemonSocketExists() else { throw CuaSetupFailure("Cua didn't start. Try again in a moment.") }
    }

    /// A small private record in Nollie's own folder: written beside, then moved into place.
    private func writePrivately(_ data: Data, to url: URL) {
        try? FileManager.default.createDirectory(at: work, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let temporary = work.appendingPathComponent("." + UUID().uuidString)
        guard FileManager.default.createFile(atPath: temporary.path, contents: data, attributes: [.posixPermissions: 0o600]) else { return }
        if rename(temporary.path, url.path) != 0 { try? FileManager.default.removeItem(at: temporary) }
    }

    private func prepareComputers() async throws {
        set(.preparing)
        guard let cli else { throw CuaSetupFailure("Cua didn't install properly.") }
        func doctor() async -> Data {
            (try? await system.run(cli, ["--json", "runtime", "doctor"], timeout: 60))?.output ?? Data()
        }
        var report = await doctor()
        if CuaRelease.canRunLinux(doctor: report) { return }
        for component in CuaRelease.provisionable(doctor: report) {
            _ = try? await system.run(cli, ["runtime", "setup", component], timeout: 900)
        }
        report = await doctor()
        guard CuaRelease.canRunLinux(doctor: report) else {
            throw CuaSetupFailure("Cua can't run computers on this Mac yet. Its download page lists what it needs.")
        }
    }
}

/// The real Mac. Only the helper uses it; the app never runs anything it downloads.
/// Nollie's own copy of Cua lives in `Application Support/Nollie/Cua`, never in Applications, so it
/// shows up in neither Applications nor Launchpad. A copy the person installed is used as it is.
struct CuaMacSystem: CuaSetupSystem {
    var home = FileManager.default.homeDirectoryForCurrentUser
    var own = NolliePaths.current.cua

    func installedApp() -> (url: URL, version: String?)? {
        for folder in NollieCuaPlaces.folders(home: home, own: own) {
            let app = folder.appendingPathComponent(CuaRelease.appName)
            if FileManager.default.fileExists(atPath: app.appendingPathComponent("Contents/Info.plist").path) {
                return (app, version(app))
            }
        }
        return nil
    }

    func version(_ app: URL) -> String? {
        guard let data = try? Data(contentsOf: app.appendingPathComponent("Contents/Info.plist")),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              plist["CFBundleIdentifier"] as? String == CuaRelease.bundleID else { return nil }
        return plist["CFBundleShortVersionString"] as? String
    }

    func installDestination() -> URL { own.appendingPathComponent(CuaRelease.appName) }

    func download(_ url: URL, to file: URL, maximum: Int, progress: @escaping @Sendable (Double) -> Void) async throws {
        try await CuaDownload.fetch(url, to: file, maximum: maximum, progress: progress)
    }

    func size(_ file: URL) -> Int? {
        (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.intValue
    }

    func sha256(_ file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 4 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    func attach(_ image: URL) async throws -> URL {
        let (status, output) = try await run(URL(fileURLWithPath: "/usr/bin/hdiutil"),
                                             ["attach", "-nobrowse", "-readonly", "-noautoopen", "-mountrandom", "/private/tmp", "-plist", image.path],
                                             timeout: 120)
        guard status == 0, let plist = try? PropertyListSerialization.propertyList(from: output, format: nil) as? [String: Any],
              let entities = plist["system-entities"] as? [[String: Any]],
              let point = entities.compactMap({ $0["mount-point"] as? String }).first else {
            throw CuaSetupFailure("Couldn't open the Cua download.")
        }
        return URL(fileURLWithPath: point)
    }

    func detach(_ mount: URL) async {
        _ = try? await run(URL(fileURLWithPath: "/usr/bin/hdiutil"), ["detach", "-quiet", mount.path], timeout: 60)
    }

    func verify(_ app: URL) async throws {
        let codesign = try await run(URL(fileURLWithPath: "/usr/bin/codesign"),
                                     ["--verify", "--deep", "--strict", "-R=" + CuaRelease.requirement, app.path], timeout: 180)
        let gatekeeper = try await run(URL(fileURLWithPath: "/usr/sbin/spctl"),
                                       ["--assess", "--type", "execute", app.path], timeout: 120)
        guard codesign.status == 0, gatekeeper.status == 0 else { throw CuaSetupFailure("Unsigned copy.") }
    }

    func isRunning() -> Bool {
        // The app's own window process, by its executable path. Its daemon is stopped separately.
        guard let app = installedApp()?.url,
              let data = try? Data(contentsOf: app.appendingPathComponent("Contents/Info.plist")),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let executable = plist["CFBundleExecutable"] as? String, !executable.contains("/") else { return false }
        let out = Process()
        out.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        out.arguments = ["-f", "/" + CuaRelease.appName + "/Contents/MacOS/" + executable]
        out.standardOutput = FileHandle.nullDevice
        out.standardError = FileHandle.nullDevice
        do { try out.run(); out.waitUntilExit() } catch { return false }
        return out.terminationStatus == 0
    }

    func install(_ app: URL, at destination: URL) async throws {
        let folder = destination.deletingLastPathComponent()
        guard folder.standardizedFileURL == own.standardizedFileURL else { throw CuaSetupFailure("Not Nollie's folder.") }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        NolliePaths.excludeRebuildableFromBackup(NolliePaths.current)
        let staged = folder.appendingPathComponent(".Cua Spaces.nollie-\(UUID().uuidString).app")
        // ditto copies Cua's signed app exactly as it is; nothing in it is changed.
        let copied = try await run(URL(fileURLWithPath: "/usr/bin/ditto"), [app.path, staged.path], timeout: 600)
        do {
            guard copied.status == 0 else { throw CuaSetupFailure("Copy failed.") }
            try await verify(staged)
            if FileManager.default.fileExists(atPath: destination.path) {
                // Nollie's own older copy, in Nollie's own folder.
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.moveItem(at: staged, to: destination)
        } catch {
            try? FileManager.default.removeItem(at: staged)
            throw error
        }
    }

    func cuaHomeExists() -> Bool {
        var info = stat()
        return lstat(home.appendingPathComponent(".cua").path, &info) == 0
    }

    func daemonSocketExists() -> Bool {
        var info = stat()
        return lstat(home.appendingPathComponent(".cua/cua.sock").path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFSOCK
    }

    func run(_ executable: URL, _ arguments: [String], timeout: TimeInterval) async throws -> (status: Int32, output: Data) {
        try await Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = executable
            process.arguments = arguments
            process.environment = ["HOME": home.path, "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "en_US.UTF-8",
                                   "NO_COLOR": "1", "CUA_TELEMETRY": "0"]
            let output = Pipe()
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            process.standardInput = FileHandle.nullDevice
            try process.run()
            let deadline = Date().addingTimeInterval(timeout)
            let reader = Task.detached { output.fileHandleForReading.readDataToEndOfFile() }
            while process.isRunning {
                if Date() > deadline { process.terminate(); break }
                try? await Task.sleep(for: .milliseconds(100))
            }
            process.waitUntilExit()
            let data = await reader.value
            return (process.terminationStatus, data.count > 4 << 20 ? Data() : data)
        }.value
    }
}

/// A streaming download to a file, with a size limit and the release hosts only.
private final class CuaDownload: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let destination: URL
    private let maximum: Int
    private let progress: @Sendable (Double) -> Void
    private var continuation: CheckedContinuation<Void, Error>?
    private var moved = false
    private let lock = NSLock()

    private init(destination: URL, maximum: Int, progress: @escaping @Sendable (Double) -> Void) {
        self.destination = destination; self.maximum = maximum; self.progress = progress
    }

    static func fetch(_ url: URL, to destination: URL, maximum: Int, progress: @escaping @Sendable (Double) -> Void) async throws {
        let delegate = CuaDownload(destination: destination, maximum: maximum, progress: progress)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 3600
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                delegate.lock.lock(); delegate.continuation = continuation; delegate.lock.unlock()
                session.downloadTask(with: url).resume()
            }
        } onCancel: { session.invalidateAndCancel() }
    }

    private func finish(_ result: Result<Void, Error>) {
        lock.lock(); let pending = continuation; continuation = nil; lock.unlock()
        pending?.resume(with: result)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        guard let url = request.url, CuaRelease.allowsDownload(from: url) else {
            completionHandler(nil); task.cancel(); return
        }
        completionHandler(request)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        if totalBytesWritten > maximum { downloadTask.cancel(); return }
        progress(Double(totalBytesWritten) / Double(maximum))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard (downloadTask.response as? HTTPURLResponse)?.statusCode == 200 else { return }
        do {
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: location, to: destination)
            lock.lock(); moved = true; lock.unlock()
        } catch {}
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock(); let ok = moved; lock.unlock()
        if let error { finish(.failure(error)) } else if ok { finish(.success(())) } else { finish(.failure(CuaSetupFailure("Download failed."))) }
    }
}
#endif
