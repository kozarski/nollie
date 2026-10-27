#if os(macOS)
import Foundation
import Darwin
import Testing

struct RuntimeSupervisorTests {
    typealias C = NollieRuntimeContract
    private let token = String(repeating: "a", count: 64)
    private func plan(_ id: UUID = UUID()) -> C.Plan {
        .init(installationID: id, installation: URL(fileURLWithPath: "/fixture/" + id.uuidString),
              executable: URL(fileURLWithPath: "/fixture/python"), entrypoint: URL(fileURLWithPath: "/signed/runtime_entry.py"))
    }

    @Test func commandsAndEnvironmentCannotAdoptTheUsersInstallation() {
        let plan = plan()
        for role in [C.Role.api, .gateway] {
            let values = plan.environment(for: role, token: token)
            #expect(values["HERMES_HOME"] == plan.home.path)
            #expect(values["HOME"] == plan.installation.appendingPathComponent("user").path)
            #expect(values["HERMES_RUNTIME_DIR"] == plan.installation.appendingPathComponent("runtime/store").path)
            #expect(values["HERMES_DISABLE_LAZY_INSTALLS"] == "1")
            #expect(values["HERMES_DESKTOP"] == nil)
            #expect(values["OPENAI_API_KEY"] == nil)
            #expect(values["SSH_AUTH_SOCK"] == nil)
            #expect(values["HERMES_DASHBOARD_SESSION_TOKEN"] == (role == .api ? token : nil))
            #expect(plan.arguments(for: role).first == "-I")
            #expect(!plan.arguments(for: role).contains(token))
        }
    }
    @Test func hermesLeavesOnlyThroughPapertrailsDoor() {
        var plan = plan()
        #expect(plan.environment(for: .api, token: token)["HTTPS_PROXY"] == nil)
        plan.door = C.Door(port: 41_234, secret: String(repeating: "cd", count: 32))
        let url = "http://unplaced.program:\(String(repeating: "cd", count: 32))@127.0.0.1:41234"
        for role in [C.Role.api, .gateway] {
            let values = plan.environment(for: role, token: token)
            for name in ["HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "http_proxy", "https_proxy", "all_proxy"] {
                #expect(values[name] == url, "\(name)")
            }
            #expect(values["NO_PROXY"] == "localhost,127.0.0.1,::1")
            #expect(values["no_proxy"] == "localhost,127.0.0.1,::1")
            #expect(values["NODE_USE_ENV_PROXY"] == "1")
            #expect(values["HERMES_HOME"] == plan.home.path)
        }
    }
    @Test func readinessRejectsPublicHealthAndOtherProcesses() throws {
        try C.verifyIdentity(Data(#"{"ok":true,"protocolVersion":1,"pid":123,"role":"serve","servesSpa":false}"#.utf8), expectedPID: 123)
        for body in [#"{"ok":true}"#, #"{"ok":true,"protocolVersion":1,"pid":124,"role":"serve","servesSpa":false}"#,
                     #"{"ok":true,"protocolVersion":1,"pid":123,"role":"desktop-serve","servesSpa":false}"#,
                     #"{"ok":true,"protocolVersion":1,"pid":123,"role":"serve","servesSpa":true}"#] {
            #expect(throws: C.Failure.identityMismatch) { try C.verifyIdentity(Data(body.utf8), expectedPID: 123) }
        }
        #expect(C.readyPort("HERMES_BACKEND_READY port=23456") == 23456)
        for line in ["port=23456", "HERMES_BACKEND_READY port=0", "HERMES_BACKEND_READY port=65536", "HERMES_BACKEND_READY port=23456 token=secret"] {
            #expect(C.readyPort(line) == nil)
        }
    }
    @Test func invalidTokenNeverQualifiesAsLocalAuthority() {
        #expect(C.validToken(token))
        for candidate in ["", "mock-token", String(repeating: "a", count: 63), String(repeating: "Z", count: 64), token + "\n"] {
            #expect(!C.validToken(candidate))
        }
    }

    #if NOLLIE_DIRECT
    @Test func ownershipRequiresPrivateRealFoldersAndMatchingIdentity() throws {
        guard let resolved = realpath(FileManager.default.temporaryDirectory.path, nil) else { throw C.Failure.invalidInstallation }
        let parent = URL(fileURLWithPath: String(cString: resolved)).appendingPathComponent("nollie-owner-fixture-" + UUID().uuidString)
        free(resolved)
        try OwnedSetupFiles.createPrivateDirectory(parent)
        defer { try? FileManager.default.removeItem(at: parent) }
        let id = UUID()
        let root = parent.appendingPathComponent(id.uuidString)
        for path in [root, root.appendingPathComponent("home"), root.appendingPathComponent("user")] {
            try OwnedSetupFiles.createPrivateDirectory(path)
        }
        let ownership = root.appendingPathComponent("ownership.json")
        try OwnedSetupFiles.writeNew(JSONEncoder().encode(["owner": C.owner, "installationID": id.uuidString]), to: ownership)
        try NativeRuntimeBackend.validateOwnership(root, installationID: id)
        #expect(throws: C.Failure.invalidInstallation) { try NativeRuntimeBackend.validateOwnership(root, installationID: UUID()) }
        #expect(chmod(root.appendingPathComponent("home").path, 0o755) == 0)
        #expect(throws: C.Failure.invalidInstallation) { try NativeRuntimeBackend.validateOwnership(root, installationID: id) }
        #expect(chmod(root.appendingPathComponent("home").path, 0o700) == 0)
        try FileManager.default.removeItem(at: root.appendingPathComponent("user"))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("user"), withDestinationURL: root.appendingPathComponent("home"))
        #expect(throws: (any Error).self) { try NativeRuntimeBackend.validateOwnership(root, installationID: id) }
    }
    @Test func bothVerifiedChildrenAreRequiredBeforeReady() async throws {
        let backend = FakeRuntimeBackend(plan: plan())
        let supervisor = NollieRuntimeSupervisor(backend: backend, pollInterval: .milliseconds(1), startupPolls: 10)
        let id = backend.plan.installationID
        let result = try await supervisor.start(installationID: id, token: token, consent: .init(installationID: id))
        #expect(result.phase == .ready)
        #expect(result.endpoint?.absoluteString == "http://127.0.0.1:23456")
        #expect(await backend.launched == [.api, .gateway])
        await supervisor.stop()
        #expect(await backend.stopped.count == 2)
        #expect(await supervisor.snapshot().phase == .stopped)
        #expect(await supervisor.snapshot().endpoint == nil)
    }
    @Test func missingConsentDoesNotInspectOrStartAnything() async {
        let backend = FakeRuntimeBackend(plan: plan())
        let supervisor = NollieRuntimeSupervisor(backend: backend)
        await #expect(throws: C.Failure.consentRequired) {
            try await supervisor.start(installationID: UUID(), token: token, consent: nil)
        }
        #expect(await backend.prepareCount == 0)
        #expect(await backend.launched.isEmpty)
    }
    @Test func failedReceiptCannotLaunchAChild() async {
        let backend = FakeRuntimeBackend(plan: plan(), preparationFailure: .preparationChanged)
        let supervisor = NollieRuntimeSupervisor(backend: backend)
        let id = backend.plan.installationID
        await #expect(throws: C.Failure.preparationChanged) {
            try await supervisor.start(installationID: id, token: token, consent: .init(installationID: id))
        }
        #expect(await backend.launched.isEmpty)
        #expect(await supervisor.snapshot().phase == .failed)
    }
    @Test func secondChildFailureStopsOnlyTheChildAlreadyOwned() async {
        let backend = FakeRuntimeBackend(plan: plan(), failGatewayLaunch: true)
        let supervisor = NollieRuntimeSupervisor(backend: backend)
        let id = backend.plan.installationID
        await #expect(throws: C.Failure.launchFailed) {
            try await supervisor.start(installationID: id, token: token, consent: .init(installationID: id))
        }
        #expect(await backend.stopped.map(\.role) == [.api])
        #expect(await supervisor.snapshot().endpoint == nil)
    }
    @Test func staleReadinessCannotTurnAStoppedStartGreen() async {
        let backend = FakeRuntimeBackend(plan: plan(), healthDelay: .milliseconds(40))
        let supervisor = NollieRuntimeSupervisor(backend: backend, pollInterval: .milliseconds(1), startupPolls: 5)
        let id = backend.plan.installationID
        let start = Task { try await supervisor.start(installationID: id, token: token, consent: .init(installationID: id)) }
        while await backend.launched.count < 2 { await Task.yield() }
        await supervisor.stop()
        _ = try? await start.value
        #expect(await supervisor.snapshot().phase == .stopped)
        #expect(await supervisor.snapshot().endpoint == nil)
        #expect(await backend.active.isEmpty)
    }
    @Test func timeoutCleansUpBothRolesWithoutReportingReady() async {
        let backend = FakeRuntimeBackend(plan: plan(), neverReady: true)
        let supervisor = NollieRuntimeSupervisor(backend: backend, pollInterval: .milliseconds(1), startupPolls: 2)
        let id = backend.plan.installationID
        await #expect(throws: C.Failure.startupTimedOut) {
            try await supervisor.start(installationID: id, token: token, consent: .init(installationID: id))
        }
        #expect(await backend.stopped.count == 2)
        #expect(await supervisor.snapshot().phase == .failed)
    }
    @Test func repeatedCrashesStopAtABoundedRestartLimit() async throws {
        let backend = FakeRuntimeBackend(plan: plan(), crashAfterReady: true)
        let supervisor = NollieRuntimeSupervisor(backend: backend, pollInterval: .milliseconds(1), startupPolls: 5,
                                               monitorInterval: .milliseconds(1), restartDelays: [.milliseconds(1), .milliseconds(1), .milliseconds(1)])
        let id = backend.plan.installationID
        _ = try await supervisor.start(installationID: id, token: token, consent: .init(installationID: id))
        for _ in 0..<500 {
            if await supervisor.snapshot().phase == .failed { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        let result = await supervisor.snapshot()
        #expect(result.phase == .failed)
        #expect(result.failure == .restartLimit)
        #expect(result.restartCount == 3)
        #expect(await backend.prepareCount == 4)
        #expect(await backend.active.isEmpty)
        #expect(result.endpoint == nil)
    }
    @Test func changedReceiptsOnRestartDoNotLaunchReplacementCode() async throws {
        let backend = FakeRuntimeBackend(plan: plan(), crashAfterReady: true, rejectSecondPreparation: true)
        let supervisor = NollieRuntimeSupervisor(backend: backend, pollInterval: .milliseconds(1), startupPolls: 5,
                                               monitorInterval: .milliseconds(1), restartDelays: [.milliseconds(1)])
        let id = backend.plan.installationID
        _ = try await supervisor.start(installationID: id, token: token, consent: .init(installationID: id))
        for _ in 0..<500 {
            if await supervisor.snapshot().phase == .failed { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(await supervisor.snapshot().failure == .preparationChanged)
        #expect(await backend.launched.count == 2)
        #expect(await backend.active.isEmpty)
    }
    @Test func repeatedStartDoesNotCreateAnotherScheduler() async throws {
        let backend = FakeRuntimeBackend(plan: plan())
        let supervisor = NollieRuntimeSupervisor(backend: backend)
        let id = backend.plan.installationID
        _ = try await supervisor.start(installationID: id, token: token, consent: .init(installationID: id))
        await #expect(throws: C.Failure.alreadyRunning) {
            try await supervisor.start(installationID: id, token: token, consent: .init(installationID: id))
        }
        #expect(await backend.launched.count == 2)
        await supervisor.stop()
    }
    #else
    @Test func storeBuildCannotStartEvenWithConsent() async {
        let backend = FakeRuntimeBackend(plan: plan())
        let supervisor = NollieRuntimeSupervisor(backend: backend)
        let id = backend.plan.installationID
        await #expect(throws: C.Failure.unavailable) {
            try await supervisor.start(installationID: id, token: token, consent: .init(installationID: id))
        }
        #expect(await backend.prepareCount == 0)
    }
    #endif
}

private actor FakeRuntimeBackend: NollieRuntimeBackend {
    typealias C = NollieRuntimeContract
    let plan: C.Plan
    let preparationFailure: C.Failure?
    let failGatewayLaunch: Bool
    let neverReady: Bool
    let healthDelay: Duration
    let crashAfterReady: Bool
    let rejectSecondPreparation: Bool
    var healthCalls = 0
    var prepareCount = 0
    var launched: [C.Role] = []
    var stopped: [C.Child] = []
    var active: Set<C.Child> = []
    init(plan: C.Plan, preparationFailure: C.Failure? = nil, failGatewayLaunch: Bool = false, neverReady: Bool = false, healthDelay: Duration = .zero, crashAfterReady: Bool = false, rejectSecondPreparation: Bool = false) {
        self.plan = plan; self.preparationFailure = preparationFailure
        self.crashAfterReady = crashAfterReady; self.rejectSecondPreparation = rejectSecondPreparation
        self.failGatewayLaunch = failGatewayLaunch; self.neverReady = neverReady; self.healthDelay = healthDelay
    }
    func prepare(installationID: UUID) throws -> C.Plan {
        prepareCount += 1
        healthCalls = 0
        if rejectSecondPreparation && prepareCount > 1 { throw C.Failure.preparationChanged }
        if let preparationFailure { throw preparationFailure }
        return plan
    }
    func launch(_ role: C.Role, plan: C.Plan, token: String) throws -> C.Child {
        if role == .gateway && failGatewayLaunch { throw C.Failure.launchFailed }
        launched.append(role)
        let child = C.Child(id: UUID(), pid: role == .api ? 123 : 124, role: role)
        active.insert(child)
        return child
    }
    func health(_ child: C.Child, plan: C.Plan, token: String) async throws -> C.Health {
        if healthDelay > .zero { try await Task.sleep(for: healthDelay) }
        healthCalls += 1
        if crashAfterReady && healthCalls > 2 { return .exited(1) }
        return neverReady ? .starting : .ready(port: child.role == .api ? 23456 : nil)
    }
    func stop(_ child: C.Child) { if active.remove(child) != nil { stopped.append(child) } }
    func release() { for child in active { stopped.append(child) }; active = [] }
}
#endif
