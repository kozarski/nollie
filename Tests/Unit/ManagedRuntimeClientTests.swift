#if os(macOS)
import Foundation
import ServiceManagement
import Testing
@testable import Nollie

@MainActor
struct ManagedRuntimeClientTests {
    #if NOLLIE_DIRECT
    enum XPCFailureCallback: CaseIterable, Sendable { case error, interrupted, invalidated }

    @Test(arguments: XPCFailureCallback.allCases)
    func backgroundXPCErrorsFinishOnTheMainActor(_ callback: XPCFailureCallback) async {
        var disconnects = 0
        do {
            _ = try await ManagedRuntimeRequest.send(.status, connect: { _, callbacks in
                DispatchQueue(label: "nollie.fixture.xpc." + UUID().uuidString).async {
                    dispatchPrecondition(condition: .notOnQueue(.main))
                    switch callback {
                    case .error: callbacks.proxyError(NSError(domain: "NollieFixture", code: 1))
                    case .interrupted: callbacks.interrupted()
                    case .invalidated: callbacks.invalidated()
                    }
                }
                return {
                    MainActor.assertIsolated()
                    disconnects += 1
                }
            })
            Issue.record("A disconnected request must fail")
        } catch ManagedRuntimeFailure.disconnected {
            #expect(disconnects == 1)
        } catch { Issue.record("Unexpected request failure: \(error)") }
    }

    @Test(arguments: [true, false])
    func backgroundXPCRepliesPreserveTheirPayload(_ includesToken: Bool) async throws {
        let data = Data("fixture response".utf8)
        var disconnects = 0
        let response = try await ManagedRuntimeRequest.send(.status, connect: { _, callbacks in
            DispatchQueue(label: "nollie.fixture.xpc." + UUID().uuidString).async {
                dispatchPrecondition(condition: .notOnQueue(.main))
                if includesToken { callbacks.reply(data, "fixture") }
                else { callbacks.statusReply(data) }
            }
            return {
                MainActor.assertIsolated()
                disconnects += 1
            }
        })
        #expect(response.data == data && response.token == (includesToken ? "fixture" : nil))
        #expect(disconnects == 1)
    }

    @Test func competingXPCEventsAndCancellationTearDownOnlyOnce() async throws {
        let (callbacksStream, callbacksWriter) = AsyncStream<ManagedRuntimeCallbacks>.makeStream()
        var disconnects = 0
        let request = Task {
            try await ManagedRuntimeRequest.send(.status, connect: { _, callbacks in
                callbacksWriter.yield(callbacks)
                callbacksWriter.finish()
                return { MainActor.assertIsolated(); disconnects += 1 }
            })
        }
        var iterator = callbacksStream.makeAsyncIterator()
        let callbacks = try #require(await iterator.next())
        request.cancel()
        do {
            _ = try await request.value
            Issue.record("A cancelled request must fail")
        } catch is CancellationError { }
        #expect(disconnects == 1)
        // XPC can deliver already-enqueued events after invalidation. These use
        // the same production callbacks after the continuation has been consumed.
        await withCheckedContinuation { continuation in
            DispatchQueue(label: "nollie.fixture.xpc." + UUID().uuidString).async {
                dispatchPrecondition(condition: .notOnQueue(.main))
                callbacks.proxyError(NSError(domain: "NollieFixture", code: 2))
                callbacks.invalidated()
                callbacks.interrupted()
                callbacks.reply(Data("late".utf8), nil)
                continuation.resume()
            }
        }
        #expect(disconnects == 1)
    }
    #endif

    @MainActor private final class Service {
        var status: SMAppService.Status = .notRegistered
        var afterRegistration: SMAppService.Status = .enabled
        var registered = 0
        var unregistered = 0
        var control: ManagedRuntimeServiceControl {
            .init(status: { self.status }, register: {
                self.registered += 1; self.status = self.afterRegistration
            }, unregister: { self.unregistered += 1; self.status = .notRegistered })
        }
    }

    private let endpoint = URL(string: "http://127.0.0.1:19241")!
    private let token = String(repeating: "a", count: 64)

    private func reply(_ id: UUID, phase: NollieRuntimeIPCSnapshot.Phase = .ready,
                       endpoint: URL? = nil, token: String? = nil) -> ManagedRuntimeReply {
        let snapshot = NollieRuntimeIPCSnapshot(phase: phase, installationID: phase == .stopped ? nil : id,
            endpoint: endpoint ?? self.endpoint, enabledInstallationID: phase == .stopped ? nil : id)
        return .init(data: NollieRuntimeIPCResponse(snapshot: snapshot).encoded(), token: token)
    }

    @Test func inspectionNeverRegistersOrStartsAService() async {
        let service = Service()
        var requests = 0
        let client = ManagedRuntimeClient(service: service.control, request: { _ in
            requests += 1; throw ManagedRuntimeFailure.disconnected
        }, verify: { _, _ in Issue.record("Inspection must not verify credentials"); return false }, isPackaged: { true }, isAvailable: true)
        await client.refresh(installationID: UUID())
        #expect(service.registered == 0 && requests == 0)
        #expect(client.state == .off && !client.canConnect)
    }

    @Test func aRunningProcessNeedsExplicitCredentialVerification() async {
        let id = UUID(), service = Service()
        service.status = .enabled
        var starts = 0
        let client = ManagedRuntimeClient(service: service.control, request: { operation in
            if case .start = operation { starts += 1 }
            return reply(id)
        }, verify: { _, _ in Issue.record("Inspection must not fetch credentials"); return false }, isPackaged: { true }, isAvailable: true)
        await client.refresh(installationID: id)
        #expect(starts == 0 && service.registered == 0)
        #expect(client.state == .needsVerification && !client.canConnect && client.sessionToken == nil)
    }

    @Test func aPackagedUnregisteredServiceIsNotMissingAndStartsOnlyOnRequest() async {
        let id = UUID(), service = Service()
        service.status = .notFound
        var requests = 0
        let client = ManagedRuntimeClient(service: service.control, request: { operation in
            requests += 1
            guard case .start(let requested) = operation, requested == id else { throw ManagedRuntimeFailure.invalidResponse }
            return reply(id, token: token)
        }, verify: { _, _ in true }, isPackaged: { true }, isAvailable: true)
        await client.refresh(installationID: id)
        #expect(client.state == .off && !client.canConnect)
        #expect(requests == 0 && service.registered == 0)
        await client.start(installationID: id)
        #expect(requests == 1 && service.registered == 1 && client.canConnect)
    }

    @Test func freshRegistrationCanRequireApprovalWithoutStartingRuntime() async {
        let service = Service()
        service.status = .notFound
        service.afterRegistration = .requiresApproval
        var requests = 0
        let client = ManagedRuntimeClient(service: service.control, request: { _ in
            requests += 1; throw ManagedRuntimeFailure.disconnected
        }, verify: { _, _ in false }, isPackaged: { true }, isAvailable: true)
        await client.start(installationID: UUID())
        #expect(service.registered == 1 && requests == 0)
        #expect(client.state == .requiresApproval && !client.canConnect)
    }

    @Test func missingOrInvalidPackagingNeverRegisters() async {
        let service = Service()
        service.status = .notFound
        var requests = 0
        let client = ManagedRuntimeClient(service: service.control, request: { _ in
            requests += 1; throw ManagedRuntimeFailure.disconnected
        }, verify: { _, _ in false }, isPackaged: { false }, isAvailable: true)
        await client.refresh(installationID: UUID())
        #expect(client.state == .unavailable)
        await client.start(installationID: UUID())
        #expect(client.state == .unavailable && !client.canConnect)
        #expect(service.registered == 0 && requests == 0)
    }

    @Test func packagingRequiresTheExactLaunchAgentAndSignedHelper() throws {
        let fixture = try PackagingFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        #expect(ManagedRuntimePackaging.isValid(bundleURL: fixture.root, validateSignature: { _ in true }))
        #expect(!ManagedRuntimePackaging.isValid(bundleURL: fixture.root, validateSignature: { _ in false }))
        #expect(!ManagedRuntimePackaging.isValid(bundleURL: fixture.root))
        try fixture.writeAgent(program: "/usr/bin/other")
        #expect(!ManagedRuntimePackaging.isValid(bundleURL: fixture.root, validateSignature: { _ in true }))
        try fixture.writeAgent()
        try FileManager.default.removeItem(at: fixture.executable)
        #expect(!ManagedRuntimePackaging.isValid(bundleURL: fixture.root, validateSignature: { _ in true }))
    }

    private struct PackagingFixture {
        let root: URL
        let executable: URL
        let plist: URL
        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("nollie-package-fixture-" + UUID().uuidString)
            executable = root.appendingPathComponent(ManagedRuntimePackaging.programPath)
            plist = root.appendingPathComponent("Contents/Library/LaunchAgents/" + NollieRuntimeIPCConfiguration.plistName)
            try FileManager.default.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: plist.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("fixture".utf8).write(to: executable)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
            let info: [String: String] = ["CFBundleIdentifier": NollieRuntimeIPCConfiguration.machService,
                                        "CFBundleExecutable": "Nollie Runtime", "CFBundlePackageType": "APPL"]
            try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
                .write(to: root.appendingPathComponent(ManagedRuntimePackaging.helperPath + "/Contents/Info.plist"))
            try writeAgent()
        }
        func writeAgent(program: String = ManagedRuntimePackaging.programPath) throws {
            let agent: [String: Any] = ["Label": NollieRuntimeIPCConfiguration.machService, "BundleProgram": program,
                                       "MachServices": [NollieRuntimeIPCConfiguration.machService: true,
                                                        NollieLiveRelayConfiguration.machService: true]]
            try PropertyListSerialization.data(fromPropertyList: agent, format: .xml, options: 0).write(to: plist)
        }
    }

    @Test func macOSApprovalIsNotSuccessfulSetup() async {
        let service = Service()
        service.afterRegistration = .requiresApproval
        var requests = 0
        let client = ManagedRuntimeClient(service: service.control, request: { _ in
            requests += 1; throw ManagedRuntimeFailure.disconnected
        }, verify: { _, _ in false }, isPackaged: { true }, isAvailable: true)
        await client.start(installationID: UUID())
        #expect(service.registered == 1 && requests == 0)
        #expect(client.state == .requiresApproval && client.isRegistered && !client.canConnect)
    }

    @Test func successfulStartRequiresTheAuthenticatedHandshake() async {
        let id = UUID(), service = Service()
        var verified = false
        let client = ManagedRuntimeClient(service: service.control, request: { operation in
            guard case .start(let requested) = operation, requested == id else { throw ManagedRuntimeFailure.invalidResponse }
            return reply(id, token: token)
        }, verify: { url, suppliedToken in
            #expect(url == endpoint && suppliedToken == token)
            verified = true; return true
        }, isPackaged: { true }, isAvailable: true)
        await client.start(installationID: id)
        #expect(verified && client.canConnect && client.state == .ready)
        #expect(client.endpoint == endpoint && service.registered == 1)
    }

    @Test func aFailedHandshakeDoesNotKeepCredentials() async {
        let id = UUID(), service = Service()
        let client = ManagedRuntimeClient(service: service.control, request: { _ in reply(id, token: token) },
                                          verify: { _, _ in false }, isPackaged: { true }, isAvailable: true)
        await client.start(installationID: id)
        #expect(client.state == .failed && !client.canConnect)
        #expect(client.endpoint == nil && client.sessionToken == nil)
    }

    @Test func anotherInstallationCannotSupplyTheConnection() async {
        let service = Service()
        var verified = false
        let client = ManagedRuntimeClient(service: service.control, request: { _ in reply(UUID(), token: token) },
            verify: { _, _ in verified = true; return true }, isPackaged: { true }, isAvailable: true)
        await client.start(installationID: UUID())
        #expect(!verified && client.state == .failed && client.sessionToken == nil)
    }

    @Test func untrustedEndpointNeverReceivesTheCredential() async {
        let id = UUID(), service = Service()
        var verified = false
        let client = ManagedRuntimeClient(service: service.control, request: { _ in
            reply(id, endpoint: URL(string: "https://example.com")!, token: token)
        }, verify: { _, _ in verified = true; return true }, isPackaged: { true }, isAvailable: true)
        await client.start(installationID: id)
        #expect(!verified && !client.canConnect && client.sessionToken == nil)
    }

    @Test(arguments: [String(repeating: "A", count: 64), String(repeating: "a", count: 63),
                      String(repeating: "a", count: 65), String(repeating: "a", count: 63) + " "])
    func onlyTheHelpersCredentialFormatIsAccepted(_ malformed: String) async {
        let id = UUID(), service = Service()
        var verified = false
        let client = ManagedRuntimeClient(service: service.control, request: { _ in reply(id, token: malformed) },
            verify: { _, _ in verified = true; return true }, isPackaged: { true }, isAvailable: true)
        await client.start(installationID: id)
        #expect(!verified && client.state == .failed && client.sessionToken == nil)
    }

    @Test(arguments: ["https://127.0.0.1:19241", "http://localhost:19241", "http://127.0.0.1:80",
                      "http://127.0.0.1:19241/path", "http://127.0.0.1:19241?key=value",
                      "http://user:password@127.0.0.1:19241", "http://127.0.0.1:19241#fragment"])
    func endpointValidationIsStrict(_ value: String) {
        #expect(!ManagedRuntimeClient.isAllowedEndpoint(URL(string: value)!))
        #expect(ManagedRuntimeClient.isAllowedEndpoint(endpoint))
    }

    @Test func disableStopsThenUnregistersAndClearsConnection() async {
        let id = UUID(), service = Service()
        var stopped = false
        let client = ManagedRuntimeClient(service: service.control, request: { operation in
            if case .stop = operation { stopped = true; return reply(id, phase: .stopped) }
            return reply(id, token: token)
        }, verify: { _, _ in true }, isPackaged: { true }, isAvailable: true)
        await client.start(installationID: id)
        await client.stop()
        #expect(stopped && service.unregistered == 1 && !client.isRegistered)
        #expect(client.state == .off && client.endpoint == nil && client.sessionToken == nil)
    }

    @Test func unsupportedEditionsNeverRegisterOrContactTheHelper() async {
        let service = Service()
        let client = ManagedRuntimeClient(service: service.control, request: { _ in
            Issue.record("An unavailable client must not use IPC"); throw ManagedRuntimeFailure.unavailable
        }, verify: { _, _ in false }, isAvailable: false)
        await client.refresh(installationID: UUID())
        await client.start(installationID: UUID())
        await client.stop()
        #expect(service.registered == 0 && service.unregistered == 0)
        #expect(client.state == .unavailable && !client.canConnect)
    }
}
#endif
