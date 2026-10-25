#if os(macOS)
import Darwin
import Foundation
import NollieCore

/// What the coordinator needs from a running helper: tool calls in a session, and Stop.
protocol ComputerDriving: AnyObject, Sendable {
    func call(_ session: String, _ tool: String, _ args: [String: Any]) throws -> [String: Any]
    @discardableResult func stop() -> TimeInterval
    var isRunning: Bool { get }
}

/// The Nollie Computer helper process for one approved task, and Nollie's two trusted sessions in it.
///
/// Only Nollie starts it, with `Process` (never `open`), so macOS charges its Accessibility and
/// Screen Recording use to Nollie. It runs in embedded, bounded mode on a private socket, with
/// telemetry, update checks and scripts off and a home folder of its own, and exits when Nollie
/// closes its stdin, quits or crashes. Stop revokes every session, closes stdin and, if it is
/// still there after half a second, kills it: always gone within a second.
final class ComputerHelper: ComputerDriving, @unchecked Sendable {
    enum Failure: LocalizedError, Equatable {
        case missing, notReady, refused(String), unreadable
        var errorDescription: String? {
            switch self {
            case .missing: "Nollie Computer isn't in this copy of Nollie."
            case .notReady: "Nollie Computer didn't start."
            case let .refused(message): message
            case .unreadable: "Nollie Computer sent an answer Nollie couldn't read."
            }
        }
    }

    static var executable: URL { Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/Nollie Computer") }
    static var isBundled: Bool { FileManager.default.isExecutableFile(atPath: executable.path) }

    let process = Process()
    private let stdin = Pipe()
    let runDirectory: URL
    var socketPath: String { runDirectory.appendingPathComponent("driver.sock").path }
    private var sessions: [String: DriverLine] = [:]
    private let lock = NSLock()

    /// Starts the helper with the closed door. Throws when it isn't bundled or never answers.
    init(executable: URL = ComputerHelper.executable, support: URL = ComputerHelper.supportDirectory,
         hostBundleID: String = Bundle.main.bundleIdentifier ?? "com.coreykozarski.nollie") throws {
        guard FileManager.default.isExecutableFile(atPath: executable.path) else { throw Failure.missing }
        let fm = FileManager.default
        runDirectory = fm.temporaryDirectory.appendingPathComponent("nollie-computer-" + UUID().uuidString.prefix(8))
        try fm.createDirectory(at: runDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        // A fresh home for every task: nothing one task's driver wrote is there for the next.
        let home = support.appendingPathComponent("home")
        try? fm.removeItem(at: home)
        try fm.createDirectory(at: home, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let door = runDirectory.appendingPathComponent("door.yaml")
        try ComputerManifest.door().write(to: door, atomically: true, encoding: .utf8)

        process.executableURL = executable
        process.arguments = ["serve", "--embedded", "--socket", socketPath,
                             "--pid-file", runDirectory.appendingPathComponent("driver.pid").path,
                             "--host-bundle-id", hostBundleID, "--no-permissions-gate",
                             "--permission-mode", "bounded", "--capability-manifest", door.path,
                             "--approve-capability-manifest"]
        process.environment = Self.environment(home: home, hostBundleID: hostBundleID)
        process.standardInput = stdin
        let log = Self.logURL
        try? fm.createDirectory(at: log.deletingLastPathComponent(), withIntermediateDirectories: true)
        fm.createFile(atPath: log.path, contents: nil)
        let handle = try? FileHandle(forWritingTo: log)
        process.standardOutput = handle ?? FileHandle.nullDevice
        process.standardError = handle ?? FileHandle.nullDevice
        try process.run()
        guard waitForSocket(timeout: 10) else {
            stop()
            throw Failure.notReady
        }
    }

    deinit { stop() }

    static var supportDirectory: URL { NolliePaths.current.computer }
    static var logURL: URL { NolliePaths.current.logs.appendingPathComponent("Nollie Computer.log") }

    /// An allowlist, not Nollie's whole environment: embedded mode, private state, nothing that
    /// phones home, no scripting.
    static func environment(home: URL, hostBundleID: String) -> [String: String] {
        let parent = ProcessInfo.processInfo.environment
        var env: [String: String] = [:]
        for key in ["USER", "LOGNAME", "TMPDIR", "LANG"] { env[key] = parent[key] }
        env["HOME"] = home.path
        env["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin"
        env["CUA_DRIVER_EMBEDDED"] = "1"
        env["CUA_DRIVER_HOST_BUNDLE_ID"] = hostBundleID
        env["CUA_DRIVER_PARENT_LIVENESS_STDIN"] = "1"
        env["CUA_DRIVER_RS_HOME"] = home.appendingPathComponent("driver").path
        env["CUA_HOME"] = home.appendingPathComponent("cua").path
        env["CUA_DRIVER_TELEMETRY_HOME"] = home.appendingPathComponent("driver").path
        // Warnings only: the driver's warnings carry lengths and errors, never typed text or labels.
        env["CUA_LOG"] = "warn"
        env["DO_NOT_TRACK"] = "1"
        env["CUA_DRIVER_RS_TELEMETRY_ENABLED"] = "0"
        env["CUA_TELEMETRY_ENABLED"] = "0"
        env["CUA_TELEMETRY"] = "0"
        env["CUA_TELEMETRY_FORBID_NETWORK"] = "1"
        env["CUA_DRIVER_RS_UPDATE_CHECK"] = "0"
        env["CUA_DRIVER_DISABLE_RUN_SCRIPT"] = "1"
        env["CUA_DRIVER_EXPERIMENTAL_SCRIPT"] = "0"
        return env
    }

    var isRunning: Bool { process.isRunning }

    // MARK: Sessions

    /// Opens a trusted session bound to a manifest. Only Nollie, the parent, may do this.
    /// Each session's own idle clock runs for the whole task: the bot may spend a while in one
    /// app, and Nollie enforces the task's 5 idle minutes across both sessions itself.
    func openSession(_ name: String, manifest: String, ttl: TimeInterval = ComputerTask.lifetime,
                     idle: TimeInterval = ComputerTask.lifetime) throws {
        let path = runDirectory.appendingPathComponent("\(name).yaml")
        try manifest.write(to: path, atomically: true, encoding: .utf8)
        // Longer than the driver's own 100-second limit on one action, so a reply is never left behind.
        let line = try DriverLine(path: socketPath, timeout: 120)
        let options: [String: Any] = ["public_session": "nollie-\(name)", "mode": "bounded",
                                      "ttl_seconds": Int(ttl), "idle_ttl_seconds": Int(idle),
                                      "capability_manifest_path": path.path]
        let reply = try line.send(["method": "trusted_session_begin", "args": options], timeout: 10)
        guard reply["ok"] as? Bool == true else { throw Failure.refused(Self.errorText(reply)) }
        lock.withLock { sessions[name] = line }
    }

    /// One tool call in a trusted session: the result's MCP content and structured content.
    func call(_ session: String, _ tool: String, _ args: [String: Any]) throws -> [String: Any] {
        guard let line = lock.withLock({ sessions[session] }) else { throw Failure.refused("That app isn't approved.") }
        let reply = try line.send(["method": "trusted_session_call", "name": tool, "args": args])
        guard reply["ok"] as? Bool == true, let result = reply["result"] as? [String: Any] else {
            throw Failure.refused(Self.errorText(reply))
        }
        if result["isError"] as? Bool == true { throw Failure.refused(Self.errorText(["result": result])) }
        return result
    }

    /// A plain call on the shared socket, as any process running as this user could make it.
    func callOutsideSession(_ tool: String, _ args: [String: Any] = [:]) throws -> [String: Any] {
        try DriverLine(path: socketPath).send(["method": "call", "name": tool, "args": args])
    }

    func metadata() throws -> [String: Any] {
        let reply = try DriverLine(path: socketPath).send(["method": "metadata"])
        return reply["result"] as? [String: Any] ?? [:]
    }

    static func errorText(_ reply: [String: Any]) -> String {
        if let error = reply["error"] as? String { return error }
        let result = reply["result"] as? [String: Any] ?? [:]
        let text = (result["content"] as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }.joined(separator: " ")
        return text.isEmpty ? "The Mac refused that." : String(text.prefix(400))
    }

    // MARK: Stop

    /// Revokes every session, closes the helper's stdin and makes sure it is gone. Safe to repeat.
    /// Returns how long the process took to go.
    @discardableResult
    func stop() -> TimeInterval {
        let started = Date()
        if process.isRunning {
            _ = try? DriverLine(path: socketPath, timeout: 0.2).send(["method": "revoke_authorization", "args": ["all": true]])
        }
        // End the process first: an action in progress dies with it. Then free the connections,
        // without waiting for a call that may be blocked on them.
        try? stdin.fileHandleForWriting.close()
        let lines = lock.withLock {
            defer { sessions.removeAll() }
            return Array(sessions.values)
        }
        lines.forEach { $0.abort() }
        if process.isRunning {
            let deadline = Date().addingTimeInterval(0.5)
            while process.isRunning, Date() < deadline { usleep(10_000) }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            let hard = Date().addingTimeInterval(0.3)
            while process.isRunning, Date() < hard { usleep(5_000) }
        }
        try? FileManager.default.removeItem(at: runDirectory)
        return Date().timeIntervalSince(started)
    }

    private func waitForSocket(timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if !process.isRunning { return false }
            if (try? DriverLine(path: socketPath, timeout: 0.5).send(["method": "metadata"]))?["ok"] as? Bool == true { return true }
            usleep(50_000)
        }
        return false
    }
}

/// One connection to the helper's socket: a JSON line out, a JSON line back.
final class DriverLine: @unchecked Sendable {
    private let fd: Int32
    private let defaultTimeout: TimeInterval
    private let lock = NSLock()
    private let state = NSLock()
    private var buffer = Data()
    private var dead = false

    init(path: String, timeout: TimeInterval = 120) throws {
        // Connected on a local descriptor first: a failure closes it here, once, and the object
        // (whose deinit closes `fd`) never exists.
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ComputerHelper.Failure.notReady }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { Darwin.close(fd); throw ComputerHelper.Failure.notReady }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            for (i, b) in bytes.enumerated() { raw[i] = b }
            raw[bytes.count] = 0
        }
        var tv = timeval(tv_sec: Int(timeout), tv_usec: Int32((timeout - floor(timeout)) * 1_000_000))
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var noSigPipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard rc == 0 else { Darwin.close(fd); throw ComputerHelper.Failure.notReady }
        self.fd = fd
        self.defaultTimeout = timeout
    }

    deinit {
        abort()
        lock.withLock { Darwin.close(fd) }
    }

    /// Ends the connection now, even while another thread waits on it: the wait returns at once.
    func abort() {
        state.withLock { dead = true }
        Darwin.shutdown(fd, SHUT_RDWR)
    }

    func close() { abort() }

    /// One request and its reply. Any failure (a timeout included) ends the connection, so a
    /// late reply can never be read as the answer to the next request.
    func send(_ request: [String: Any], timeout: TimeInterval? = nil) throws -> [String: Any] {
        try lock.withLock {
            guard !state.withLock({ dead }) else { throw ComputerHelper.Failure.notReady }
            do {
                return try exchange(request, timeout: timeout)
            } catch {
                abort()
                throw error
            }
        }
    }

    private func exchange(_ request: [String: Any], timeout: TimeInterval?) throws -> [String: Any] {
            // This exchange's limit only: the next one gets its own, or the line's default.
            let limit = timeout ?? defaultTimeout
            var tv = timeval(tv_sec: Int(limit), tv_usec: Int32((limit - floor(limit)) * 1_000_000))
            setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
            var data = try JSONSerialization.data(withJSONObject: request)
            data.append(0x0A)
            let written = data.withUnsafeBytes { write(fd, $0.baseAddress, data.count) }
            guard written == data.count else { throw ComputerHelper.Failure.notReady }
            var chunk = [UInt8](repeating: 0, count: 65536)
            while !buffer.contains(0x0A) {
                let n = read(fd, &chunk, chunk.count)
                guard n > 0 else { throw ComputerHelper.Failure.notReady }
                buffer.append(chunk, count: n)
                guard buffer.count < 64 << 20 else { throw ComputerHelper.Failure.unreadable }
            }
            let end = buffer.firstIndex(of: 0x0A)!
            let line = buffer[buffer.startIndex..<end]
            buffer = Data(buffer[buffer.index(after: end)...])
            guard let reply = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else {
                throw ComputerHelper.Failure.unreadable
            }
            return reply
    }
}
#endif
