#if os(macOS)
import Foundation
import Security
import LocalAuthentication
import Darwin

protocol RuntimeServiceSupervising: Sendable {
    func snapshot() async -> NollieRuntimeContract.Snapshot
    func start(installationID: UUID, token: String, consent: NollieRuntimeContract.StartConsent?) async throws -> NollieRuntimeContract.Snapshot
    func stop() async
}
extension NollieRuntimeSupervisor: RuntimeServiceSupervising {}

protocol RuntimeCredentialStoring: Sendable {
    func token(for installationID: UUID, create: Bool) throws -> String
}
protocol RuntimeConsentStoring: Sendable {
    func load() throws -> UUID?
    func save(_ installationID: UUID) throws
    func clear() throws
}

private actor RuntimeStartRace {
    typealias Outcome = Result<NollieRuntimeContract.Snapshot, NollieRuntimeIPCError>
    private var result: Outcome?
    private var waiter: CheckedContinuation<Outcome, Never>?
    func resolve(_ result: Outcome) {
        guard self.result == nil else { return }
        self.result = result
        waiter?.resume(returning: result)
        waiter = nil
    }
    func value() async -> Outcome {
        if let result { return result }
        return await withCheckedContinuation { waiter = $0 }
    }
}

/// Serializes consent and credential handling around the independently owned
/// child supervisor. Only RuntimeIPCExport is exposed to authenticated clients.
actor RuntimeService {
    private let supervisor: any RuntimeServiceSupervising
    private let credentials: any RuntimeCredentialStoring
    private let consent: any RuntimeConsentStoring
    private let deadline: Duration
    private var loaded = false
    private var enabledInstallationID: UUID?
    private var lastError: NollieRuntimeIPCError?
    private var operationID: UUID?
    private var startTask: Task<Void, Never>?
    private var stopping = false
    private var linkToken: (installationID: UUID, token: String)?

    init(supervisor: any RuntimeServiceSupervising, credentials: any RuntimeCredentialStoring,
         consent: any RuntimeConsentStoring, deadline: Duration = .seconds(60)) {
        self.supervisor = supervisor
        self.credentials = credentials
        self.consent = consent
        self.deadline = deadline
    }

    func status() async -> NollieRuntimeIPCResponse {
        loadConsent()
        return response(await supervisor.snapshot(), error: lastError)
    }

    func resumeEnabledInstallation() async {
        #if NOLLIE_DIRECT
        loadConsent()
        guard let id = enabledInstallationID, operationID == nil, !stopping else { return }
        _ = await start(id, createCredential: false)
        #endif
    }

    func start(installationID: String) async -> (NollieRuntimeIPCResponse, String?) {
        guard installationID.utf8.count == 36, let id = UUID(uuidString: installationID) else {
            return (response(await supervisor.snapshot(), error: .invalidRequest), nil)
        }
        return await start(id, createCredential: true)
    }

    private func start(_ id: UUID, createCredential: Bool) async -> (NollieRuntimeIPCResponse, String?) {
        #if !NOLLIE_DIRECT
        return (.init(error: .unavailable), nil)
        #else
        loadConsent()
        guard lastError != .persistenceUnavailable else { return (.init(error: .persistenceUnavailable), nil) }
        guard operationID == nil, !stopping else { return (response(await supervisor.snapshot(), error: .busy), nil) }
        // Reserve before awaiting the supervisor, so simultaneous clients cannot
        // each replace consent or mint credentials for different installations.
        let operation = UUID()
        operationID = operation
        let current = await supervisor.snapshot()
        guard operationID == operation, !stopping else { return (response(current, error: .cancelled), nil) }
        let isReady = current.phase == .ready && current.installationID == id && enabledInstallationID == id
        guard isReady || [.stopped, .failed].contains(current.phase) else {
            operationID = nil
            return (response(current, error: .busy), nil)
        }
        let token: String
        do {
            token = try credentials.token(for: id, create: createCredential && !isReady)
            guard NollieRuntimeContract.validToken(token) else { throw NollieRuntimeIPCError.credentialsUnavailable }
        } catch {
            operationID = nil
            lastError = .credentialsUnavailable
            return (response(current, error: .credentialsUnavailable), nil)
        }
        if isReady {
            operationID = nil
            lastError = nil
            return (response(current), token)
        }
        do { try consent.save(id) } catch {
            operationID = nil
            lastError = .persistenceUnavailable
            return (response(current, error: .persistenceUnavailable), nil)
        }
        enabledInstallationID = id
        lastError = nil
        let race = RuntimeStartRace()
        let supervisor = self.supervisor
        let task = Task {
            do {
                try Task.checkCancellation()
                let snapshot = try await supervisor.start(installationID: id, token: token, consent: .init(installationID: id))
                await race.resolve(.success(snapshot))
            } catch {
                let failure: NollieRuntimeIPCError = error is CancellationError || (error as? NollieRuntimeContract.Failure) == .cancelled
                    ? .cancelled : (error as? NollieRuntimeContract.Failure) == .startupTimedOut ? .startupTimedOut : .startFailed
                await race.resolve(.failure(failure))
            }
        }
        startTask = task
        let timeout = Task {
            do { try await Task.sleep(for: deadline) } catch { return }
            await race.resolve(.failure(.startupTimedOut))
        }
        let result = await race.value()
        timeout.cancel()
        guard operationID == operation, !stopping else {
            return (response(.init(phase: .stopped, installationID: id), error: .cancelled), nil)
        }
        switch result {
        case .success(let snapshot):
            operationID = nil
            startTask = nil
            guard snapshot.phase == .ready, snapshot.installationID == id else {
                return (response(snapshot, error: .startFailed), nil)
            }
            return (response(snapshot), token)
        case .failure(let error):
            lastError = error
            do { try consent.clear(); enabledInstallationID = nil } catch { lastError = .persistenceUnavailable }
            // Reply at the deadline even when preparation is still unwinding.
            // New starts remain blocked until owned-child cleanup has finished.
            stopping = true
            task.cancel()
            Task {
                await supervisor.stop()
                await task.value
                self.finishCleanup(operation)
            }
            return (response(.init(phase: .failed, installationID: id), error: lastError), nil)
        }
        #endif
    }

    func stop() async -> NollieRuntimeIPCResponse {
        #if !NOLLIE_DIRECT
        return .init(error: .unavailable)
        #else
        loadConsent()
        guard !stopping else { return (response(await supervisor.snapshot(), error: .busy)) }
        stopping = true
        let pending = startTask
        pending?.cancel()
        var failure: NollieRuntimeIPCError?
        do { try consent.clear(); enabledInstallationID = nil } catch { failure = .persistenceUnavailable }
        await supervisor.stop()
        await pending?.value
        operationID = nil
        startTask = nil
        stopping = false
        lastError = failure
        return response(await supervisor.snapshot(), error: failure)
        #endif
    }

    /// Nollie.app is gone or replaced: stops Hermes and its children and blocks new starts, without
    /// touching the saved choice or any file, so a reinstalled Nollie can pick the setup up again.
    func halt() async {
        stopping = true
        startTask?.cancel()
        await supervisor.stop()
        await startTask?.value
    }

    /// Where the Nollie Link door sends a linked phone's requests: the ready API child's
    /// loopback port and its session token. Nothing while the runtime is not ready.
    func linkUpstream() async -> (port: Int, token: String)? {
        #if NOLLIE_DIRECT
        loadConsent()
        let snapshot = await supervisor.snapshot()
        guard snapshot.phase == .ready, let id = snapshot.installationID, id == enabledInstallationID,
              let endpoint = snapshot.endpoint, endpoint.host == "127.0.0.1", let port = endpoint.port else { return nil }
        if linkToken?.installationID != id {
            guard let token = try? credentials.token(for: id, create: false), NollieRuntimeContract.validToken(token) else { return nil }
            linkToken = (id, token)
        }
        return linkToken.map { (port, $0.token) }
        #else
        return nil
        #endif
    }

    private func finishCleanup(_ operation: UUID) {
        guard operationID == operation else { return }
        operationID = nil
        startTask = nil
        stopping = false
    }
    private func loadConsent() {
        guard !loaded else { return }
        loaded = true
        do { enabledInstallationID = try consent.load() } catch { lastError = .persistenceUnavailable }
    }
    private func response(_ snapshot: NollieRuntimeContract.Snapshot, error: NollieRuntimeIPCError? = nil) -> NollieRuntimeIPCResponse {
        .init(snapshot: .init(phase: .init(rawValue: snapshot.phase.rawValue) ?? .failed,
                             installationID: snapshot.installationID, endpoint: snapshot.endpoint,
                             restartCount: snapshot.restartCount, failure: snapshot.failure?.rawValue,
                             enabledInstallationID: enabledInstallationID), error: error)
    }
}

final class RuntimeIPCExport: NSObject, NollieRuntimeIPC {
    private let service: RuntimeService
    private let link: RuntimeLink?
    private let cua: CuaInstaller?
    private let relay: RuntimeExitRelay?
    init(service: RuntimeService, link: RuntimeLink? = nil, cua: CuaInstaller? = nil, relay: RuntimeExitRelay? = nil) {
        self.service = service; self.link = link; self.cua = cua; self.relay = relay
    }
    func start(installationID: String, withReply reply: @escaping @Sendable (Data, String?) -> Void) {
        let service = service
        Task { let result = await service.start(installationID: installationID); reply(result.0.encoded(), result.1) }
    }
    func status(withReply reply: @escaping @Sendable (Data) -> Void) {
        let service = service
        Task { reply(await service.status().encoded()) }
    }
    func stop(withReply reply: @escaping @Sendable (Data) -> Void) {
        let service = service
        Task { reply(await service.stop().encoded()) }
    }
    func linkOffer(withReply reply: @escaping @Sendable (Data) -> Void) {
        guard let link else { reply(NollieLinkIPCResponse(error: .unavailable).encoded()); return }
        Task { reply(await link.offer().encoded()) }
    }
    func linkStatus(withReply reply: @escaping @Sendable (Data) -> Void) {
        guard let link else { reply(NollieLinkIPCResponse(error: .unavailable).encoded()); return }
        Task { reply(await link.status().encoded()) }
    }
    func linkCancelOffer(withReply reply: @escaping @Sendable (Data) -> Void) {
        guard let link else { reply(NollieLinkIPCResponse(error: .unavailable).encoded()); return }
        Task { reply(await link.cancelOffer().encoded()) }
    }
    func linkRemove(deviceID: String, withReply reply: @escaping @Sendable (Data) -> Void) {
        guard let link else { reply(NollieLinkIPCResponse(error: .unavailable).encoded()); return }
        Task { reply(await link.remove(deviceID: deviceID).encoded()) }
    }
    func linkAway(request: Data, withReply reply: @escaping @Sendable (Data) -> Void) {
        guard let link else { reply(NollieLinkIPCResponse(error: .unavailable).encoded()); return }
        guard let asked = NollieLinkIPCAwayRequest.decode(request) else { reply(NollieLinkIPCResponse(error: .invalidRequest).encoded()); return }
        Task { reply(await link.away(on: asked.on, host: asked.host, sealKey: asked.sealKey).encoded()) }
    }
    func linkFamily(request: Data, withReply reply: @escaping @Sendable (Data) -> Void) {
        guard let link else { reply(NollieLinkIPCResponse(error: .unavailable).encoded()); return }
        guard let asked = NollieLinkIPCFamilyRequest.decode(request) else { reply(NollieLinkIPCResponse(error: .invalidRequest).encoded()); return }
        Task { reply(await link.family(asked).encoded()) }
    }
    func cuaSetupStart(withReply reply: @escaping @Sendable (Data) -> Void) {
        guard let cua else { reply(NollieCuaSetupResponse(phase: .unavailable).encoded()); return }
        Task { reply(await cua.start().encoded()) }
    }
    func cuaSetupStatus(withReply reply: @escaping @Sendable (Data) -> Void) {
        guard let cua else { reply(NollieCuaSetupResponse(phase: .unavailable).encoded()); return }
        Task { reply(await cua.status().encoded()) }
    }
    func cuaWake(withReply reply: @escaping @Sendable (Data) -> Void) {
        guard let cua else { reply(NollieCuaSetupResponse(phase: .unavailable).encoded()); return }
        Task {
            let awake = await cua.wake()
            reply(NollieCuaSetupResponse(phase: awake ? .done : .failed).encoded())
        }
    }
    func prepareRemoval(withReply reply: @escaping @Sendable (Data) -> Void) {
        let service = service, link = link, cua = cua, relay = relay
        Task {
            let stopped = await service.stop()
            await link?.close()
            await relay?.close()
            let cuaStopped = await cua?.stopDaemon() ?? true
            #if NOLLIE_DIRECT
            let cleared = RuntimeKeychainCredentials.forgetAll()
            LinkDoorIdentity.remove(name: "com.coreykozarski.nollie.link.identity")
            #else
            let cleared = true
            #endif
            reply(NollieRuntimeRemovalResponse(hermesStopped: stopped.error == nil && stopped.snapshot.phase == .stopped,
                                               cuaStopped: cuaStopped, keychainCleared: cleared).encoded())
        }
    }
}

/// The OS checks every incoming message against the requirement before invoking
/// the exported object. No caller-supplied path or credential crosses this gate.
final class RuntimeListenerDelegate: NSObject, NSXPCListenerDelegate {
    private let service: RuntimeService
    private let link: RuntimeLink?
    private let cua: CuaInstaller?
    private let relay: RuntimeExitRelay?
    init(service: RuntimeService, link: RuntimeLink? = nil, cua: CuaInstaller? = nil, relay: RuntimeExitRelay? = nil) {
        self.service = service; self.link = link; self.cua = cua; self.relay = relay
    }
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        guard connection.effectiveUserIdentifier == getuid() else { return false }
        connection.setCodeSigningRequirement(NollieRuntimeIPCConfiguration.hostRequirement)
        connection.exportedInterface = NSXPCInterface(with: NollieRuntimeIPC.self)
        connection.exportedObject = RuntimeIPCExport(service: service, link: link, cua: cua, relay: relay)
        connection.resume()
        return true
    }
}

#if NOLLIE_DIRECT
struct RuntimeKeychainCredentials: RuntimeCredentialStoring {
    private func query(_ id: UUID) -> [String: Any] {
        let context = LAContext()
        context.interactionNotAllowed = true
        return [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "com.coreykozarski.nollie.runtime.tokens",
         kSecAttrAccount as String: id.uuidString,
         kSecUseDataProtectionKeychain as String: true,
         kSecAttrSynchronizable as String: false,
         kSecUseAuthenticationContext as String: context]
    }
    /// Deletes every installation's token, for Remove Nollie. True when none is left.
    static func forgetAll() -> Bool {
        let status = SecItemDelete([kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: "com.coreykozarski.nollie.runtime.tokens",
                                    kSecUseDataProtectionKeychain as String: true] as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    func token(for installationID: UUID, create: Bool) throws -> String {
        var lookup = query(installationID)
        lookup[kSecReturnData as String] = true
        lookup[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(lookup as CFDictionary, &item)
        if status == errSecSuccess, let data = item as? Data, let token = String(data: data, encoding: .utf8), NollieRuntimeContract.validToken(token) { return token }
        guard status == errSecItemNotFound, create else { throw NollieRuntimeIPCError.credentialsUnavailable }
        var random = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, random.count, &random) == errSecSuccess else { throw NollieRuntimeIPCError.credentialsUnavailable }
        let token = random.map { String(format: "%02x", $0) }.joined()
        var record = query(installationID)
        record[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        record[kSecValueData as String] = Data(token.utf8)
        let added = SecItemAdd(record as CFDictionary, nil)
        if added == errSecDuplicateItem { return try self.token(for: installationID, create: false) }
        guard added == errSecSuccess else { throw NollieRuntimeIPCError.credentialsUnavailable }
        return token
    }
}

/// The only persisted service choice is a version and an installation UUID.
/// File-descriptor-relative access rejects symlinks, other owners and shared files.
struct RuntimeConsentFile: RuntimeConsentStoring {
    let directory: URL
    private let name = "enabled.json"
    private struct Receipt: Codable { let version: Int; let installationID: UUID }

    func load() throws -> UUID? {
        guard let fd = try openDirectory(create: false) else { return nil }
        defer { close(fd) }
        guard try exists(in: fd) else { return nil }
        let file = openat(fd, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard file >= 0 else { throw NollieRuntimeIPCError.persistenceUnavailable }
        defer { close(file) }
        try validate(file)
        var bytes = [UInt8](repeating: 0, count: 4097)
        let count = read(file, &bytes, bytes.count)
        guard count > 0, count <= 4096,
              let receipt = try? JSONDecoder().decode(Receipt.self, from: Data(bytes.prefix(count))), receipt.version == 1 else { throw NollieRuntimeIPCError.persistenceUnavailable }
        return receipt.installationID
    }
    func save(_ installationID: UUID) throws {
        guard let fd = try openDirectory(create: true) else { throw NollieRuntimeIPCError.persistenceUnavailable }
        defer { close(fd) }
        _ = try exists(in: fd)
        let temp = ".enabled-" + UUID().uuidString
        let file = openat(fd, temp, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard file >= 0 else { throw NollieRuntimeIPCError.persistenceUnavailable }
        defer { close(file); unlinkat(fd, temp, 0) }
        let data = try JSONEncoder().encode(Receipt(version: 1, installationID: installationID))
        let count = data.withUnsafeBytes { Darwin.write(file, $0.baseAddress, $0.count) }
        guard count == data.count, fsync(file) == 0, renameat(fd, temp, fd, name) == 0, fsync(fd) == 0 else { throw NollieRuntimeIPCError.persistenceUnavailable }
    }
    func clear() throws {
        guard let fd = try openDirectory(create: false) else { return }
        defer { close(fd) }
        guard try exists(in: fd) else { return }
        guard unlinkat(fd, name, 0) == 0, fsync(fd) == 0 else { throw NollieRuntimeIPCError.persistenceUnavailable }
    }
    private func openDirectory(create: Bool) throws -> Int32? {
        var info = stat()
        if lstat(directory.path, &info) != 0 {
            guard errno == ENOENT else { throw NollieRuntimeIPCError.persistenceUnavailable }
            guard create else { return nil }
            try OwnedSetupFiles.createPrivateDirectory(directory)
        }
        let fd = try OwnedSetupFiles.directory(directory)
        guard fstat(fd, &info) == 0, info.st_uid == getuid(), info.st_mode & 0o077 == 0 else { close(fd); throw NollieRuntimeIPCError.persistenceUnavailable }
        return fd
    }
    private func exists(in directory: Int32) throws -> Bool {
        let fd = openat(directory, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        if fd < 0 {
            guard errno == ENOENT else { throw NollieRuntimeIPCError.persistenceUnavailable }
            return false
        }
        defer { close(fd) }
        try validate(fd)
        return true
    }
    private func validate(_ fd: Int32) throws {
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == getuid(), info.st_mode & 0o077 == 0,
              info.st_nlink == 1, info.st_size <= 4096 else { throw NollieRuntimeIPCError.persistenceUnavailable }
    }
}
#endif
#endif
