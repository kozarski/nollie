#if os(macOS) && NOLLIE_DIRECT
import Darwin
import Foundation

/// Direct-edition process adapter. No shell, inherited environment, global service
/// command, saved-PID adoption or process-name scan enters this implementation.
actor NativeRuntimeBackend: NollieRuntimeBackend {
    typealias Contract = NollieRuntimeContract
    static let entrypointDigest = "e3daa133da1f446d869a7087736318ff36b6571b240ca3c4bc38e21bf7b9de09"
    static let addonsDigest = "a95bc01015dca09b77bedd38967e057d9158bf2aeb109af53c8a2d2faa8149cc"
    private let installations: URL
    private let entrypoint: URL
    private var lease: Int32 = -1
    private var preparation = UUID()
    private var activePlan: Contract.Plan?
    private var children: [UUID: ChildProcess] = [:]
    private let session: URLSession
    /// Papertrail's door: open while Hermes runs, so every connection it makes is noted.
    private var door: PapertrailDoor?
    /// Papertrail's network filter link, while Hermes runs and the switch is on.
    private var filter: RuntimeNetworkFilter?

    private struct ChildProcess {
        let handle: Contract.Child
        let output: Int32
        var owner: Int32
        let launched: Date
        var pending = Data()
        var port: Int?
        var exitCode: Int32?
    }
    init(installations: URL, entrypoint: URL) {
        self.installations = installations
        self.entrypoint = entrypoint
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.urlCredentialStorage = nil
        config.urlCache = nil
        config.connectionProxyDictionary = [:]
        config.timeoutIntervalForRequest = 2
        config.timeoutIntervalForResource = 3
        session = URLSession(configuration: config, delegate: NoRuntimeRedirects(), delegateQueue: nil)
    }

    func prepare(installationID: UUID) async throws -> Contract.Plan {
        guard children.isEmpty, lease < 0 else { throw Contract.Failure.alreadyRunning }
        let epoch = UUID()
        preparation = epoch
        let root = installations.appendingPathComponent(installationID.uuidString, isDirectory: true)
        try Self.validateOwnership(root, installationID: installationID)
        let addons = entrypoint.deletingLastPathComponent().appendingPathComponent("managed_addons.py")
        guard OwnedSetupFiles.hash(try OwnedSetupFiles.read(entrypoint, maximum: 32_768)) == Self.entrypointDigest,
              OwnedSetupFiles.hash(try OwnedSetupFiles.read(addons, maximum: 65_536)) == Self.addonsDigest else {
            throw Contract.Failure.preparationChanged
        }
        let installer = NativeDependencyInstaller(installation: root)
        for id in ["uv", "python", "hermes", "dependencies"] {
            guard try await installer.verified(id) else { throw Contract.Failure.preparationChanged }
            guard preparation == epoch else { throw Contract.Failure.cancelled }
        }
        let runtime = root.appendingPathComponent("runtime")
        try OwnedSetupFiles.createPrivateDirectory(runtime)
        try OwnedSetupFiles.createPrivateDirectory(runtime.appendingPathComponent("store"))
        let directory = try OwnedSetupFiles.directory(runtime)
        defer { close(directory) }
        let lock = openat(directory, "supervisor.lock", O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard lock >= 0 else { throw Contract.Failure.invalidInstallation }
        var info = stat()
        guard fstat(lock, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
              info.st_uid == getuid(), info.st_nlink == 1, (info.st_mode & 0o077) == 0 else {
            close(lock); throw Contract.Failure.invalidInstallation
        }
        guard flock(lock, LOCK_EX | LOCK_NB) == 0 else { close(lock); throw Contract.Failure.alreadyRunning }
        lease = lock
        var plan = Contract.Plan(installationID: installationID, installation: root,
                                 executable: root.appendingPathComponent("environment/bin/python"), entrypoint: entrypoint)
        // No door, no start: nothing Hermes sends may go out unnoted.
        guard let door = await openDoor(home: plan.home) else {
            flock(lock, LOCK_UN); close(lock); lease = -1
            throw Contract.Failure.launchFailed
        }
        plan.door = door
        activePlan = plan
        return plan
    }

    static func validateOwnership(_ root: URL, installationID: UUID) throws {
        guard root.lastPathComponent == installationID.uuidString else { throw Contract.Failure.invalidInstallation }
        for folder in [root, root.appendingPathComponent("home"), root.appendingPathComponent("user")] {
            let fd = try OwnedSetupFiles.directory(folder)
            defer { close(fd) }
            var info = stat()
            guard fstat(fd, &info) == 0, info.st_uid == getuid(), (info.st_mode & 0o077) == 0 else {
                throw Contract.Failure.invalidInstallation
            }
        }
        let data = try OwnedSetupFiles.read(root.appendingPathComponent("ownership.json"), maximum: 4096)
        guard let values = try? JSONDecoder().decode([String: String].self, from: data),
              values["owner"] == Contract.owner, values["installationID"] == installationID.uuidString else {
            throw Contract.Failure.invalidInstallation
        }
    }

    func launch(_ role: Contract.Role, plan: Contract.Plan, token: String) throws -> Contract.Child {
        guard lease >= 0, activePlan?.installationID == plan.installationID,
              !children.values.contains(where: { $0.handle.role == role }), Contract.validToken(token) else {
            throw Contract.Failure.invalidInstallation
        }
        var output: [Int32] = [-1, -1]
        var owner: [Int32] = [-1, -1]
        guard pipe(&output) == 0 else { throw Contract.Failure.launchFailed }
        guard pipe(&owner) == 0 else { close(output[0]); close(output[1]); throw Contract.Failure.launchFailed }
        var succeeded = false
        defer {
            close(output[1]); close(owner[0])
            if !succeeded { close(output[0]); close(owner[1]) }
        }
        for fd in output + owner { _ = fcntl(fd, F_SETFD, FD_CLOEXEC) }
        _ = fcntl(output[0], F_SETFL, O_NONBLOCK)
        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        guard posix_spawn_file_actions_init(&actions) == 0, posix_spawnattr_init(&attributes) == 0 else {
            throw Contract.Failure.launchFailed
        }
        defer { posix_spawn_file_actions_destroy(&actions); posix_spawnattr_destroy(&attributes) }
        let settings = [
            posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0),
            posix_spawn_file_actions_adddup2(&actions, output[1], STDOUT_FILENO),
            posix_spawn_file_actions_addopen(&actions, STDERR_FILENO, "/dev/null", O_WRONLY, 0),
            posix_spawn_file_actions_adddup2(&actions, owner[0], 3),
            posix_spawn_file_actions_addchdir(&actions, plan.source.path),
            posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT))
        ]
        guard settings.allSatisfy({ $0 == 0 }) else { throw Contract.Failure.launchFailed }
        var argv = ([plan.executable.path] + plan.arguments(for: role)).map { strdup($0) } + [nil]
        var environment = plan.environment(for: role, token: token).sorted { $0.key < $1.key }.map { strdup($0.key + "=" + $0.value) } + [nil]
        defer { argv.forEach { free($0) }; environment.forEach { free($0) } }
        var pid: pid_t = 0
        guard posix_spawn(&pid, plan.executable.path, &actions, &attributes, &argv, &environment) == 0 else {
            throw Contract.Failure.launchFailed
        }
        let handle = Contract.Child(id: UUID(), pid: pid, role: role)
        children[handle.id] = ChildProcess(handle: handle, output: output[0], owner: owner[1], launched: Date())
        succeeded = true
        return handle
    }

    /// waitpid is the only reaper. Until it reaps this child, its PID cannot be
    /// recycled, so the later signals cannot land on an unrelated process.
    private func collectExit(_ child: inout ChildProcess) -> Int32? {
        if let code = child.exitCode { return code }
        var status: Int32 = 0
        let result = waitpid(child.handle.pid, &status, WNOHANG)
        if result == child.handle.pid { child.exitCode = (status & 0x7f) == 0 ? (status >> 8) & 0xff : 128 + (status & 0x7f) }
        else if result < 0 && errno == ECHILD { child.exitCode = -1 }
        return child.exitCode
    }
    private func drain(_ child: inout ChildProcess) {
        var bytes = [UInt8](repeating: 0, count: 4096)
        // Output is deliberately not persisted. Only the exact ready sentinel survives.
        for _ in 0..<16 {
            let count = read(child.output, &bytes, bytes.count)
            if count <= 0 { break }
            child.pending.append(contentsOf: bytes.prefix(count))
            while let end = child.pending.firstIndex(of: 10) {
                let line = String(decoding: child.pending[..<end], as: UTF8.self)
                child.pending.removeSubrange(...end)
                if child.handle.role == .api, let port = Contract.readyPort(line) { child.port = port }
            }
            if child.pending.count > 8192 { child.pending.removeAll() }
        }
    }
    func health(_ handle: Contract.Child, plan: Contract.Plan, token: String) async throws -> Contract.Health {
        guard var child = children[handle.id], child.handle == handle,
              activePlan?.installationID == plan.installationID else { return .exited(-1) }
        drain(&child)
        let status = collectExit(&child)
        children[handle.id] = child
        if let status { return .exited(status) }
        if handle.role == .api {
            guard let port = child.port else { return .starting }
            var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/api/host/identity")!)
            request.setValue(token, forHTTPHeaderField: "X-Hermes-Session-Token")
            let (stream, response) = try await session.bytes(for: request)
            guard let response = response as? HTTPURLResponse, response.statusCode == 200,
                  response.url == request.url else { throw Contract.Failure.identityMismatch }
            var data = Data()
            for try await byte in stream {
                guard data.count < 4096 else { throw Contract.Failure.identityMismatch }
                data.append(byte)
            }
            try Contract.verifyIdentity(data, expectedPID: handle.pid)
            guard children[handle.id]?.exitCode == nil, children[handle.id] != nil else { return .exited(-1) }
            return .ready(port: port)
        }
        struct GatewayState: Decodable { let pid: Int32; let hermes_home: String; let gateway_state: String; let updated_at: String }
        guard let data = try? OwnedSetupFiles.read(plan.home.appendingPathComponent("gateway_state.json"), maximum: 65_536),
              let state = try? JSONDecoder().decode(GatewayState.self, from: data), state.pid == handle.pid,
              state.hermes_home == plan.home.path,
              Self.gatewayHeartbeatIsCurrent(state.updated_at, launched: child.launched) else { return .starting }
        if state.gateway_state == "startup_failed" { throw Contract.Failure.launchFailed }
        return state.gateway_state == "running" ? .ready(port: nil) : .starting
    }
    private static func timestamp(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: text) ?? ISO8601DateFormatter().date(from: text)
    }
    static func gatewayHeartbeatIsCurrent(_ text: String, launched: Date, now: Date = Date()) -> Bool {
        guard let updated = timestamp(text) else { return false }
        // Match Hermes' 120-second stale-heartbeat boundary. A small forward
        // tolerance allows clock rounding without accepting a far-future record.
        return updated >= launched.addingTimeInterval(-1)
            && updated >= now.addingTimeInterval(-120)
            && updated <= now.addingTimeInterval(5)
    }

    func stop(_ handle: Contract.Child) async {
        guard var child = children[handle.id], child.handle == handle else { return }
        if child.owner >= 0 { close(child.owner); child.owner = -1 }
        if collectExit(&child) == nil { _ = kill(handle.pid, SIGTERM) }
        children[handle.id] = child
        for attempt in 0..<70 {
            guard var pending = children[handle.id] else { return }
            drain(&pending)
            if collectExit(&pending) != nil {
                close(pending.output)
                children.removeValue(forKey: handle.id)
                return
            }
            if attempt == 50 { _ = kill(handle.pid, SIGKILL) }
            children[handle.id] = pending
            // A caller cancellation must not abandon child cleanup.
            await Task.detached { try? await Task.sleep(for: .milliseconds(100)) }.value
        }
    }
    func release() async {
        preparation = UUID()
        for child in children.values.map(\.handle) { await stop(child) }
        guard children.isEmpty else { return }
        filter?.stop()
        filter = nil
        door?.stop()
        door = nil
        if lease >= 0 { flock(lease, LOCK_UN); close(lease); lease = -1 }
        activePlan = nil
    }

    /// A fresh door with a fresh secret for each run.
    private func openDoor(home: URL) async -> Contract.Door? {
        filter?.stop()
        filter = nil
        door?.stop()
        let book = PapertrailDoorBook(home: home)
        let state = RuntimeNetworkFilter.readSwitch(directory: NolliePaths.current.runtimeService)
        var configuration = PapertrailDoor.Configuration()
        configuration.refuseUnplaced = state.refuse
        let made = PapertrailDoor(configuration: configuration, book: book)
        guard let port = try? await made.start() else { made.stop(); door = nil; return nil }
        door = made
        if state.on {
            let link = RuntimeNetworkFilter(book: book, switch: state)
            link.start()
            filter = link
        }
        return Contract.Door(port: port, secret: made.secret)
    }
}

private final class NoRuntimeRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
#endif
