#if os(macOS)
import Foundation
import Darwin
import Security
import Testing

struct RuntimeServiceTests {
    private let token = String(repeating: "b", count: 64)

    @Test func signingRequirementsAreValidAndRejectTheFixtureExecutable() throws {
        for text in [NollieRuntimeIPCConfiguration.hostRequirement, NollieRuntimeIPCConfiguration.helperRequirement] {
            var requirement: SecRequirement?
            #expect(SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess)
            let parsedRequirement = try #require(requirement)
            var code: SecCode?
            #expect(SecCodeCopySelf([], &code) == errSecSuccess)
            #expect(SecCodeCheckValidity(try #require(code), [], parsedRequirement) != errSecSuccess)
            #expect(text.contains("5985LRZFZS"))
            #expect(text.contains("anchor apple generic"))
        }
        #expect(NollieRuntimeIPCConfiguration.hostRequirement != NollieRuntimeIPCConfiguration.helperRequirement)
    }

    @Test func wireDocumentHasNoCredentialAndRoundTrips() throws {
        let id = UUID()
        let response = NollieRuntimeIPCResponse(snapshot: .init(phase: .ready, installationID: id,
            endpoint: URL(string: "http://127.0.0.1:23456"), enabledInstallationID: id, keysLeftInFiles: 0))
        let data = response.encoded()
        #expect(try JSONDecoder().decode(NollieRuntimeIPCResponse.self, from: data) == response)
        let text = String(decoding: data, as: UTF8.self)
        #expect(!text.contains("token"))
        #expect(!text.contains(token))
    }

    #if NOLLIE_DIRECT
    @Test func gatewayReadinessRequiresRecentHeartbeatFromThisLaunch() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let launched = now.addingTimeInterval(-300)
        func text(_ offset: TimeInterval) -> String { ISO8601DateFormatter().string(from: now.addingTimeInterval(offset)) }
        #expect(NativeRuntimeBackend.gatewayHeartbeatIsCurrent(text(0), launched: launched, now: now))
        #expect(NativeRuntimeBackend.gatewayHeartbeatIsCurrent(text(-120), launched: launched, now: now))
        #expect(!NativeRuntimeBackend.gatewayHeartbeatIsCurrent(text(-121), launched: launched, now: now))
        #expect(NativeRuntimeBackend.gatewayHeartbeatIsCurrent(text(5), launched: launched, now: now))
        #expect(!NativeRuntimeBackend.gatewayHeartbeatIsCurrent(text(6), launched: launched, now: now))
        #expect(!NativeRuntimeBackend.gatewayHeartbeatIsCurrent(text(-5), launched: now, now: now))
        #expect(!NativeRuntimeBackend.gatewayHeartbeatIsCurrent("invalid", launched: launched, now: now))
    }

    @Test func statusAndInvalidRequestDoNotMintOrLaunch() async {
        let supervisor = ServiceFixtureSupervisor()
        let consent = ServiceFixtureConsent()
        let credentials = ServiceFixtureCredentials(token: token)
        let service = RuntimeService(supervisor: supervisor, credentials: credentials, consent: consent)
        #expect(await service.status().snapshot.phase == .stopped)
        #expect(await service.start(installationID: "/other/installation").0.error == .invalidRequest)
        #expect(await supervisor.starts == 0)
        #expect(credentials.requests.isEmpty)
        #expect(consent.saved == nil)
    }

    @Test func unsignedAnonymousClientIsRejectedBeforeServiceMutation() async {
        let supervisor = ServiceFixtureSupervisor()
        let credentials = ServiceFixtureCredentials(token: token)
        let consent = ServiceFixtureConsent()
        let service = RuntimeService(supervisor: supervisor, credentials: credentials, consent: consent)
        // Prove this fixture can exchange an ordinary XPC message, then replace
        // only its listener with the real signed-client boundary.
        let control = ServiceFixtureOpenListener(service: service)
        #expect(await anonymousRequest(delegate: control, installationID: nil) == "reply")
        let protected = RuntimeListenerDelegate(service: service)
        #expect(await anonymousRequest(delegate: protected, installationID: UUID().uuidString) == "rejected")
        #expect(await supervisor.starts == 0)
        #expect(credentials.requests.isEmpty)
        #expect(consent.saved == nil)
    }

    private func anonymousRequest(delegate: any NSXPCListenerDelegate, installationID: String?) async -> String {
        let listener = NSXPCListener.anonymous()
        listener.delegate = delegate
        listener.resume()
        let connection = NSXPCConnection(listenerEndpoint: listener.endpoint)
        connection.remoteObjectInterface = NSXPCInterface(with: NollieRuntimeIPC.self)
        connection.resume()
        let result = ServiceFixtureXPCResult()
        let timeout = Task {
            try? await Task.sleep(for: .seconds(3))
            if !Task.isCancelled { await result.resolve("timeout") }
        }
        let proxy = connection.remoteObjectProxyWithErrorHandler { _ in Task { await result.resolve("rejected") } }
        if let proxy = proxy as? NollieRuntimeIPC {
            if let installationID {
                proxy.start(installationID: installationID) { _, _ in Task { await result.resolve("reply") } }
            } else {
                proxy.status { _ in Task { await result.resolve("reply") } }
            }
        } else {
            await result.resolve("invalidProxy")
        }
        let value = await result.wait()
        timeout.cancel()
        connection.invalidate()
        listener.invalidate()
        withExtendedLifetime(delegate) {}
        return value
    }

    @Test func explicitStartPersistsOnlyConsentAndReadyStartIsIdempotent() async throws {
        let supervisor = ServiceFixtureSupervisor()
        let consent = ServiceFixtureConsent()
        let credentials = ServiceFixtureCredentials(token: token)
        let service = RuntimeService(supervisor: supervisor, credentials: credentials, consent: consent)
        let id = UUID()
        let first = await service.start(installationID: id.uuidString)
        #expect(first.0.error == nil)
        #expect(first.0.snapshot.phase == .ready)
        #expect(first.1 == token)
        #expect(consent.saved == id)
        let again = await service.start(installationID: id.uuidString)
        #expect(again.1 == token)
        #expect(await supervisor.starts == 1)
        #expect(credentials.requests.map(\.create) == [true, false])
        #expect(await service.start(installationID: UUID().uuidString).0.error == .busy)
        #expect(consent.saved == id)
        #expect(await service.stop().snapshot.phase == .stopped)
        #expect(consent.saved == nil)
        #expect(await service.status().snapshot.enabledInstallationID == nil)
    }

    @Test func restartUsesExistingCredentialAndStopPreventsFutureRestore() async {
        let id = UUID()
        let supervisor = ServiceFixtureSupervisor()
        let consent = ServiceFixtureConsent(saved: id)
        let credentials = ServiceFixtureCredentials(token: token)
        let service = RuntimeService(supervisor: supervisor, credentials: credentials, consent: consent)
        await service.resumeEnabledInstallation()
        #expect(await supervisor.starts == 1)
        #expect(credentials.requests.map(\.create) == [false])
        #expect(await service.status().snapshot.enabledInstallationID == id)
        _ = await service.stop()
        let next = RuntimeService(supervisor: ServiceFixtureSupervisor(), credentials: credentials, consent: consent)
        await next.resumeEnabledInstallation()
        #expect(await next.status().snapshot.phase == .stopped)
        #expect(credentials.requests.count == 1)
    }

    @Test func missingCredentialOrBadConsentNeverLaunches() async {
        let supervisor = ServiceFixtureSupervisor()
        let missing = RuntimeService(supervisor: supervisor,
            credentials: ServiceFixtureCredentials(token: nil), consent: ServiceFixtureConsent(saved: UUID()))
        await missing.resumeEnabledInstallation()
        #expect(await missing.status().error == .credentialsUnavailable)
        let broken = RuntimeService(supervisor: supervisor,
            credentials: ServiceFixtureCredentials(token: token), consent: ServiceFixtureConsent(failRead: true))
        #expect(await broken.start(installationID: UUID().uuidString).0.error == .persistenceUnavailable)
        #expect(await supervisor.starts == 0)
    }

    @Test func consentWriteFailureDoesNotStartAndFailedStartRevokesConsent() async {
        let supervisor = ServiceFixtureSupervisor(fail: true)
        let unwritable = RuntimeService(supervisor: supervisor,
            credentials: ServiceFixtureCredentials(token: token), consent: ServiceFixtureConsent(failWrite: true))
        #expect(await unwritable.start(installationID: UUID().uuidString).0.error == .persistenceUnavailable)
        #expect(await supervisor.starts == 0)
        let consent = ServiceFixtureConsent()
        let failed = RuntimeService(supervisor: supervisor, credentials: ServiceFixtureCredentials(token: token), consent: consent)
        let result = await failed.start(installationID: UUID().uuidString)
        #expect(result.0.error == .startFailed)
        #expect(result.1 == nil)
        #expect(consent.saved == nil)
    }

    @Test func concurrentStartAndStopCannotReturnStaleCredentials() async throws {
        let supervisor = ServiceFixtureSupervisor(delay: .seconds(10))
        let consent = ServiceFixtureConsent()
        let credentials = ServiceFixtureCredentials(token: token)
        let service = RuntimeService(supervisor: supervisor, credentials: credentials, consent: consent)
        let first = Task { await service.start(installationID: UUID().uuidString) }
        while await supervisor.starts == 0 { await Task.yield() }
        #expect(await service.start(installationID: UUID().uuidString).0.error == .busy)
        #expect(await service.stop().error == nil)
        let cancelled = await first.value
        #expect(cancelled.0.error == .cancelled)
        #expect(cancelled.1 == nil)
        #expect(consent.saved == nil)
        #expect(await service.status().snapshot.phase == .stopped)
    }

    @Test func deadlineReturnsNoTokenAndCleansUpWithoutAutomaticRetry() async throws {
        let supervisor = ServiceFixtureSupervisor(delay: .seconds(10))
        let consent = ServiceFixtureConsent()
        let service = RuntimeService(supervisor: supervisor, credentials: ServiceFixtureCredentials(token: token),
                                     consent: consent, deadline: .milliseconds(10))
        let result = await service.start(installationID: UUID().uuidString)
        #expect(result.0.error == .startupTimedOut)
        #expect(result.1 == nil)
        #expect(consent.saved == nil)
        for _ in 0..<100 {
            if await supervisor.stops > 0 { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(await supervisor.stops > 0)
        #expect(await supervisor.starts == 1)
    }

    @Test func failedRevocationIsReportedEvenThoughOwnedChildrenStop() async {
        let supervisor = ServiceFixtureSupervisor()
        let consent = ServiceFixtureConsent(failClear: true)
        let service = RuntimeService(supervisor: supervisor, credentials: ServiceFixtureCredentials(token: token), consent: consent)
        let id = UUID()
        _ = await service.start(installationID: id.uuidString)
        let stopped = await service.stop()
        #expect(stopped.error == .persistenceUnavailable)
        #expect(stopped.snapshot.phase == .stopped)
        #expect(stopped.snapshot.enabledInstallationID == id)
        #expect(await supervisor.stops == 1)
    }

    @Test func consentReceiptIsPrivateAtomicAndContainsNoCredential() throws {
        let root = try fixtureDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("consent")
        let store = RuntimeConsentFile(directory: directory)
        #expect(try store.load() == nil)
        #expect(!FileManager.default.fileExists(atPath: directory.path))
        let id = UUID()
        try store.save(id)
        #expect(try store.load() == id)
        let file = directory.appendingPathComponent("enabled.json")
        let body = try Data(contentsOf: file)
        let object = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(Set(object.keys) == Set(["version", "installationID"]))
        var info = stat()
        #expect(lstat(file.path, &info) == 0)
        #expect(info.st_mode & 0o777 == 0o600)
        let next = UUID()
        try store.save(next)
        #expect(try store.load() == next)
        try store.clear()
        #expect(try store.load() == nil)
    }

    @Test func consentRejectsSymlinksSharedFilesMalformedDataAndHardlinks() throws {
        let root = try fixtureDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("consent")
        let store = RuntimeConsentFile(directory: directory)
        let file = directory.appendingPathComponent("enabled.json")
        try store.save(UUID())
        #expect(chmod(file.path, 0o644) == 0)
        #expect(throws: (any Error).self) { try store.load() }
        #expect(chmod(file.path, 0o600) == 0)
        let other = root.appendingPathComponent("other")
        #expect(link(file.path, other.path) == 0)
        #expect(throws: (any Error).self) { try store.clear() }
        try FileManager.default.removeItem(at: other)
        try Data("bad".utf8).write(to: file)
        #expect(throws: (any Error).self) { try store.load() }
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: other)
        #expect(throws: (any Error).self) { try store.save(UUID()) }
    }

    private func fixtureDirectory() throws -> URL {
        let path = try #require(realpath(FileManager.default.temporaryDirectory.path, nil))
        defer { free(path) }
        let url = URL(fileURLWithPath: String(cString: path)).appendingPathComponent("nollie-service-" + UUID().uuidString)
        try OwnedSetupFiles.createPrivateDirectory(url)
        return url
    }
    #else
    @Test func storeBuildCannotStartOrStopAService() async {
        let supervisor = ServiceFixtureSupervisor()
        let credentials = ServiceFixtureCredentials(token: token)
        let consent = ServiceFixtureConsent(saved: UUID())
        let service = RuntimeService(supervisor: supervisor, credentials: credentials, consent: consent)
        #expect(await service.start(installationID: UUID().uuidString).0.error == .unavailable)
        #expect(await service.stop().error == .unavailable)
        await service.resumeEnabledInstallation()
        #expect(await supervisor.starts == 0)
        #expect(credentials.requests.isEmpty)
    }
    #endif
}

private actor ServiceFixtureSupervisor: RuntimeServiceSupervising {
    var starts = 0
    var stops = 0
    private var current = NollieRuntimeContract.Snapshot()
    let delay: Duration
    let fail: Bool
    init(delay: Duration = .zero, fail: Bool = false) { self.delay = delay; self.fail = fail }
    func snapshot() -> NollieRuntimeContract.Snapshot { current }
    func start(installationID: UUID, token: String, consent: NollieRuntimeContract.StartConsent?) async throws -> NollieRuntimeContract.Snapshot {
        starts += 1
        current = .init(phase: .starting, installationID: installationID)
        if delay > .zero { try await Task.sleep(for: delay) }
        try Task.checkCancellation()
        if fail { throw NollieRuntimeContract.Failure.launchFailed }
        current.phase = .ready
        current.endpoint = URL(string: "http://127.0.0.1:23456")
        return current
    }
    func stop() { stops += 1; current = .init() }
}

private actor ServiceFixtureXPCResult {
    private var value: String?
    private var waiter: CheckedContinuation<String, Never>?
    func resolve(_ value: String) {
        guard self.value == nil else { return }
        self.value = value
        waiter?.resume(returning: value)
        waiter = nil
    }
    func wait() async -> String {
        if let value { return value }
        return await withCheckedContinuation { waiter = $0 }
    }
}

/// Deliberately unsigned fixture control. Never compiled into the helper target.
private final class ServiceFixtureOpenListener: NSObject, NSXPCListenerDelegate {
    let service: RuntimeService
    init(service: RuntimeService) { self.service = service }
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        connection.exportedInterface = NSXPCInterface(with: NollieRuntimeIPC.self)
        connection.exportedObject = RuntimeIPCExport(service: service)
        connection.resume()
        return true
    }
}

// Synchronization protects the synchronous storage seams without touching a real
// Keychain, prepared installation or service registration in these fixtures.
private final class ServiceFixtureCredentials: RuntimeCredentialStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var calls: [(id: UUID, create: Bool)] = []
    let value: String?
    init(token: String?) { value = token }
    var requests: [(id: UUID, create: Bool)] { lock.withLock { calls } }
    func token(for id: UUID, create: Bool) throws -> String {
        lock.withLock { calls.append((id, create)) }
        guard let value else { throw NollieRuntimeIPCError.credentialsUnavailable }
        return value
    }
}
private final class ServiceFixtureConsent: RuntimeConsentStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var value: UUID?
    let failRead: Bool
    let failWrite: Bool
    let failClear: Bool
    init(saved: UUID? = nil, failRead: Bool = false, failWrite: Bool = false, failClear: Bool = false) {
        value = saved; self.failRead = failRead; self.failWrite = failWrite; self.failClear = failClear
    }
    var saved: UUID? { lock.withLock { value } }
    func load() throws -> UUID? {
        if failRead { throw NollieRuntimeIPCError.persistenceUnavailable }
        return saved
    }
    func save(_ id: UUID) throws {
        if failWrite { throw NollieRuntimeIPCError.persistenceUnavailable }
        lock.withLock { value = id }
    }
    func clear() throws {
        if failClear { throw NollieRuntimeIPCError.persistenceUnavailable }
        lock.withLock { value = nil }
    }
}
#endif
