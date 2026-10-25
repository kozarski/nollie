#if os(macOS)
import Foundation
import Observation
import NollieCore
import Security
import ServiceManagement

enum ManagedRuntimePackaging {
    static let helperPath = "Contents/Helpers/Nollie Runtime.app"
    static let programPath = helperPath + "/Contents/MacOS/Nollie Runtime"

    static func isValid(bundleURL: URL = Bundle.main.bundleURL,
                        validateSignature: (URL) -> Bool = validSignature) -> Bool {
        let root = bundleURL.resolvingSymlinksInPath()
        let plist = root.appendingPathComponent("Contents/Library/LaunchAgents/" + NollieRuntimeIPCConfiguration.plistName)
        let helper = root.appendingPathComponent(helperPath, isDirectory: true)
        let executable = root.appendingPathComponent(programPath)
        let info = helper.appendingPathComponent("Contents/Info.plist")
        guard isRegularFile(plist), isRegularFile(info), isRegularFile(executable),
              FileManager.default.isExecutableFile(atPath: executable.path),
              let agent = readPlist(plist), let metadata = readPlist(info),
              agent["Label"] as? String == NollieRuntimeIPCConfiguration.machService,
              agent["BundleProgram"] as? String == programPath,
              agent["Program"] == nil, agent["ProgramArguments"] == nil, agent["EnvironmentVariables"] == nil,
              let services = agent["MachServices"] as? [String: Bool],
              services == [NollieRuntimeIPCConfiguration.machService: true, NollieLiveRelayConfiguration.machService: true],
              metadata["CFBundleIdentifier"] as? String == NollieRuntimeIPCConfiguration.machService,
              metadata["CFBundleExecutable"] as? String == "Nollie Runtime",
              metadata["CFBundlePackageType"] as? String == "APPL" else { return false }
        return validateSignature(helper)
    }

    private static func isRegularFile(_ url: URL) -> Bool {
        guard url.standardizedFileURL == url.resolvingSymlinksInPath(),
              let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]) else { return false }
        return values.isRegularFile == true && values.isSymbolicLink != true
    }

    private static func readPlist(_ url: URL) -> [String: Any]? {
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size <= 65_536, let data = try? Data(contentsOf: url), data.count <= 65_536 else { return nil }
        return (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any]
    }

    private static func validSignature(_ helper: URL) -> Bool {
        var code: SecStaticCode?
        var requirement: SecRequirement?
        guard SecStaticCodeCreateWithPath(helper as CFURL, [], &code) == errSecSuccess,
              SecRequirementCreateWithString(NollieRuntimeIPCConfiguration.helperRequirement as CFString, [], &requirement) == errSecSuccess,
              let code, let requirement else { return false }
        return SecStaticCodeCheckValidity(code, [], requirement) == errSecSuccess
    }
}

@MainActor
struct ManagedRuntimeServiceControl {
    var status: () -> SMAppService.Status
    var register: () throws -> Void
    var unregister: () async throws -> Void

    #if NOLLIE_DIRECT
    static let system = Self(
        status: { SMAppService.agent(plistName: NollieRuntimeIPCConfiguration.plistName).status },
        register: { try SMAppService.agent(plistName: NollieRuntimeIPCConfiguration.plistName).register() },
        unregister: { try await SMAppService.agent(plistName: NollieRuntimeIPCConfiguration.plistName).unregister() }
    )
    #else
    static let system = Self(status: { .notFound }, register: { throw ManagedRuntimeFailure.unavailable },
                             unregister: { throw ManagedRuntimeFailure.unavailable })
    #endif
}

enum ManagedRuntimeOperation: Sendable {
    case start(UUID), status, stop
    case linkOffer, linkStatus, linkCancel, linkRemove(UUID), linkAway(Data)
    case cuaSetupStart, cuaSetupStatus, cuaWake, prepareRemoval
    var timeout: Duration {
        switch self {
        case .start: .seconds(75)
        case .cuaWake: .seconds(30)
        case .prepareRemoval: .seconds(120)
        case .stop: .seconds(15)
        case .status, .linkOffer, .linkStatus, .linkCancel, .linkRemove, .linkAway, .cuaSetupStart, .cuaSetupStatus: .seconds(8)
        }
    }
}

struct ManagedRuntimeReply: Sendable {
    let data: Data
    let token: String?
}

enum ManagedRuntimeFailure: Error {
    case unavailable, disconnected, timedOut, invalidResponse, verificationFailed
}

@MainActor
final class ManagedRuntimeDeadline<Value: Sendable> {
    private var continuation: CheckedContinuation<Value, any Error>?
    private var work: Task<Void, Never>?
    private var timer: Task<Void, Never>?
    private var finished = false

    static func run(after duration: Duration, operation: @escaping @MainActor () async throws -> Value) async throws -> Value {
        let deadline = ManagedRuntimeDeadline()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                deadline.continuation = continuation
                deadline.work = Task { [weak deadline] in
                    do { let value = try await operation(); deadline?.finish(.success(value)) }
                    catch { deadline?.finish(.failure(error)) }
                }
                deadline.timer = Task { [weak deadline] in
                    do { try await Task.sleep(for: duration) } catch { return }
                    deadline?.finish(.failure(ManagedRuntimeFailure.timedOut))
                }
            }
        } onCancel: { Task { @MainActor in deadline.finish(.failure(CancellationError())) } }
    }

    private func finish(_ result: Result<Value, any Error>) {
        guard !finished else { return }
        finished = true
        work?.cancel(); work = nil
        timer?.cancel(); timer = nil
        let pending = continuation; continuation = nil
        pending?.resume(with: result)
    }
}

/// Objective-C invokes these callbacks on XPC queues. Their explicit Sendable
/// types keep the callback itself off the main actor, before scheduling completion.
struct ManagedRuntimeCallbacks: Sendable {
    let interrupted: @Sendable () -> Void
    let invalidated: @Sendable () -> Void
    let proxyError: @Sendable (any Error) -> Void
    let reply: @Sendable (Data, String?) -> Void
    let statusReply: @Sendable (Data) -> Void

    nonisolated init(complete: @escaping @MainActor @Sendable (Result<ManagedRuntimeReply, any Error>) -> Void) {
        let disconnected: @Sendable () -> Void = {
            Task { @MainActor in complete(.failure(ManagedRuntimeFailure.disconnected)) }
        }
        let receive: @Sendable (Data, String?) -> Void = { data, token in
            Task { @MainActor in complete(.success(.init(data: data, token: token))) }
        }
        interrupted = disconnected
        invalidated = disconnected
        proxyError = { _ in disconnected() }
        reply = receive
        statusReply = { receive($0, nil) }
    }
}

/// One bounded request. Completion and teardown stay on the main actor and happen
/// once, including when reply, cancellation and invalidation arrive together.
@MainActor
final class ManagedRuntimeRequest {
    typealias Connect = @MainActor (ManagedRuntimeOperation, ManagedRuntimeCallbacks) -> (@MainActor () -> Void)
    private var disconnect: (@MainActor () -> Void)?
    private var continuation: CheckedContinuation<ManagedRuntimeReply, any Error>?
    private var timeout: Task<Void, Never>?
    private var finished = false

    static func send(_ operation: ManagedRuntimeOperation) async throws -> ManagedRuntimeReply {
        try await send(operation, connect: openConnection)
    }

    static func send(_ operation: ManagedRuntimeOperation, connect: Connect) async throws -> ManagedRuntimeReply {
        #if NOLLIE_DIRECT
        let request = ManagedRuntimeRequest()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                request.begin(operation, continuation: continuation, connect: connect)
            }
        } onCancel: {
            Task { @MainActor in request.finish(.failure(CancellationError())) }
        }
        #else
        throw ManagedRuntimeFailure.unavailable
        #endif
    }

    private func begin(_ operation: ManagedRuntimeOperation,
                       continuation: CheckedContinuation<ManagedRuntimeReply, any Error>, connect: Connect) {
        self.continuation = continuation
        timeout = Task { [weak self] in
            do { try await Task.sleep(for: operation.timeout) } catch { return }
            self?.finish(.failure(ManagedRuntimeFailure.timedOut))
        }
        let callbacks = ManagedRuntimeCallbacks { [weak self] in self?.finish($0) }
        disconnect = connect(operation, callbacks)
    }

    private static func openConnection(_ operation: ManagedRuntimeOperation,
                                       callbacks: ManagedRuntimeCallbacks) -> (@MainActor () -> Void) {
        let connection = NSXPCConnection(machServiceName: NollieRuntimeIPCConfiguration.machService)
        connection.remoteObjectInterface = NSXPCInterface(with: NollieRuntimeIPC.self)
        connection.setCodeSigningRequirement(NollieRuntimeIPCConfiguration.helperRequirement)
        connection.interruptionHandler = callbacks.interrupted
        connection.invalidationHandler = callbacks.invalidated
        connection.resume()
        let disconnect: @MainActor () -> Void = {
            connection.invalidationHandler = nil
            connection.interruptionHandler = nil
            connection.invalidate()
        }
        guard let proxy = connection.remoteObjectProxyWithErrorHandler(callbacks.proxyError) as? NollieRuntimeIPC else {
            callbacks.invalidated(); return disconnect
        }
        switch operation {
        case .start(let id): proxy.start(installationID: id.uuidString, withReply: callbacks.reply)
        case .status: proxy.status(withReply: callbacks.statusReply)
        case .stop: proxy.stop(withReply: callbacks.statusReply)
        case .linkOffer: proxy.linkOffer(withReply: callbacks.statusReply)
        case .linkStatus: proxy.linkStatus(withReply: callbacks.statusReply)
        case .linkCancel: proxy.linkCancelOffer(withReply: callbacks.statusReply)
        case .linkRemove(let id): proxy.linkRemove(deviceID: id.uuidString, withReply: callbacks.statusReply)
        case .linkAway(let request): proxy.linkAway(request: request, withReply: callbacks.statusReply)
        case .cuaSetupStart: proxy.cuaSetupStart(withReply: callbacks.statusReply)
        case .cuaSetupStatus: proxy.cuaSetupStatus(withReply: callbacks.statusReply)
        case .cuaWake: proxy.cuaWake(withReply: callbacks.statusReply)
        case .prepareRemoval: proxy.prepareRemoval(withReply: callbacks.statusReply)
        }
        return disconnect
    }

    private func finish(_ result: Result<ManagedRuntimeReply, any Error>) {
        guard !finished else { return }
        finished = true
        timeout?.cancel(); timeout = nil
        let close = disconnect; disconnect = nil
        close?()
        let pending = continuation
        continuation = nil
        pending?.resume(with: result)
    }
}

/// Only manages Nollie's own packaged service. Inspection never registers it or starts
/// a runtime, and a running process does not imply a working authenticated connection.
@MainActor @Observable
final class ManagedRuntimeClient {
    enum State: Equatable { case unavailable, off, requiresApproval, starting, needsVerification, ready, stopped, failed }
    private(set) var state: State = .off
    private(set) var message = "Background service is off."
    private(set) var isBusy = false
    private(set) var isRegistered = false
    private(set) var endpoint: URL?
    private(set) var sessionToken: String?
    private var verifiedInstallationID: UUID?
    @ObservationIgnored private let service: ManagedRuntimeServiceControl
    @ObservationIgnored private let request: (ManagedRuntimeOperation) async throws -> ManagedRuntimeReply
    @ObservationIgnored private let verify: (URL, String) async throws -> Bool
    @ObservationIgnored private let isPackaged: () -> Bool
    let isAvailable: Bool

    var canConnect: Bool { state == .ready && endpoint != nil && sessionToken != nil }

    static func readStatus() async throws -> NollieRuntimeIPCResponse {
        guard NativeSetupPlan.directAvailable, !DemoMode.isOn else { throw ManagedRuntimeFailure.unavailable }
        return try decode(try await ManagedRuntimeRequest.send(.status))
    }

    init(service: ManagedRuntimeServiceControl = .system,
         request: @escaping (ManagedRuntimeOperation) async throws -> ManagedRuntimeReply = ManagedRuntimeRequest.send,
         verify: @escaping (URL, String) async throws -> Bool = ManagedRuntimeClient.verifyConnection,
         isPackaged: @escaping () -> Bool = { ManagedRuntimePackaging.isValid() },
         isAvailable: Bool = NativeSetupPlan.directAvailable && !DemoMode.isOn) {
        self.service = service; self.request = request; self.verify = verify
        self.isPackaged = isPackaged; self.isAvailable = isAvailable
    }

    func refresh(installationID: UUID?) async {
        guard !isBusy else { return }
        guard isAvailable else { clearConnection(); state = .unavailable; message = "Background setup needs the direct Mac edition."; return }
        let status = service.status()
        isRegistered = status == .enabled || status == .requiresApproval
        guard isPackaged() else { missingPackage(); return }
        guard status == .enabled else { applyRegistration(status); return }
        guard let installationID else {
            clearConnection(); state = .needsVerification; message = "Prepare or select your Nollie setup first."; return
        }
        isBusy = true
        defer { isBusy = false }
        do {
            let response = try Self.decode(try await request(.status))
            try Task.checkCancellation()
            apply(response, installationID: installationID)
        } catch is CancellationError { return }
        catch { fail("Could not check the background service. Try again.") }
    }

    func start(installationID: UUID) async {
        guard isAvailable, !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        clearConnection()
        state = .starting; message = "Starting your assistant's background service."
        guard isPackaged() else { missingPackage(); return }
        do {
            if service.status() != .enabled && service.status() != .requiresApproval { try service.register() }
            let registration = service.status()
            isRegistered = registration == .enabled || registration == .requiresApproval
            guard registration == .enabled else { applyRegistration(registration); return }
            let reply = try await request(.start(installationID))
            let response = try Self.decode(reply)
            try Task.checkCancellation()
            guard response.error == nil, response.snapshot.phase == .ready,
                  response.snapshot.installationID == installationID,
                  response.snapshot.enabledInstallationID == installationID,
                  let endpoint = response.snapshot.endpoint, Self.isAllowedEndpoint(endpoint),
                  let token = reply.token, NollieRuntimeContract.validToken(token) else {
                apply(response, installationID: installationID)
                if state != .failed { fail("The service has not returned a verified connection yet. Check again or retry.") }
                return
            }
            message = "Checking the secure connection."
            guard try await verify(endpoint, token) else { throw ManagedRuntimeFailure.verificationFailed }
            try Task.checkCancellation()
            self.endpoint = endpoint; sessionToken = token; verifiedInstallationID = installationID
            state = .ready; message = "Connection verified. Model and computer setup come next."
        } catch is CancellationError {
            clearConnection(); state = .needsVerification; message = "Setup continues in the background. Check the connection when you're ready."
        } catch {
            fail("The background connection could not be verified. Check its status, then try again.")
        }
    }

    func stop() async {
        guard isAvailable, !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        clearConnection()
        var stopped = service.status() != .enabled
        if service.status() == .enabled {
            if let reply = try? await request(.stop), let response = try? Self.decode(reply) {
                stopped = response.error == nil && response.snapshot.phase == .stopped && response.snapshot.enabledInstallationID == nil
            }
        }
        do {
            if service.status() == .enabled || service.status() == .requiresApproval {
                let unregister = service.unregister
                try await ManagedRuntimeDeadline<Void>.run(after: .seconds(15)) { try await unregister() }
            }
            let status = service.status()
            isRegistered = status == .enabled || status == .requiresApproval
            if isRegistered {
                fail("macOS has not disabled the service yet. Check Login Items, then try again.")
            } else if stopped {
                state = .off; message = "Background service is off. Your setup files are kept."
            } else {
                state = .stopped; message = "Background service is unregistered. Its last stop could not be confirmed; your setup files are kept."
            }
        } catch { fail("Could not turn off the background service. Try again. Your setup files are kept.") }
    }

    func openApprovalSettings() {
        #if NOLLIE_DIRECT
        guard isAvailable else { return }
        SMAppService.openSystemSettingsLoginItems()
        #endif
    }

    static func isAllowedEndpoint(_ url: URL) -> Bool {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.scheme == "http", parts.host == "127.0.0.1", let port = parts.port,
              (1024...65535).contains(port), parts.user == nil, parts.password == nil,
              parts.query == nil, parts.fragment == nil, parts.path.isEmpty || parts.path == "/" else { return false }
        return true
    }

    private static func decode(_ reply: ManagedRuntimeReply) throws -> NollieRuntimeIPCResponse {
        guard reply.data.count <= 65_536 else { throw ManagedRuntimeFailure.invalidResponse }
        let response = try JSONDecoder().decode(NollieRuntimeIPCResponse.self, from: reply.data)
        guard response.version == 1 else { throw ManagedRuntimeFailure.invalidResponse }
        return response
    }

    private func apply(_ response: NollieRuntimeIPCResponse, installationID: UUID) {
        let snapshot = response.snapshot
        guard response.error == nil, snapshot.phase != .failed else { fail("The background service needs attention. Retry after checking the setup files."); return }
        if let selected = snapshot.installationID, selected != installationID {
            fail("Another Nollie setup is running. Turn off its background service before starting this one."); return
        }
        switch snapshot.phase {
        case .ready:
            guard snapshot.enabledInstallationID == installationID, let url = snapshot.endpoint, Self.isAllowedEndpoint(url) else {
                fail("The service returned an unexpected connection. No connection was saved."); return
            }
            if verifiedInstallationID == installationID && endpoint == url && sessionToken != nil {
                state = .ready; message = "Connection verified. Model and computer setup come next."
            } else {
                clearConnection(); state = .needsVerification; message = "The service is running. Verify its connection to continue."
            }
        case .validating, .starting, .restarting:
            clearConnection(); state = .starting; message = "The background service is starting. Check again shortly."
        case .stopped:
            clearConnection(); state = .stopped; message = "Background service is stopped. Your setup files are kept."
        case .failed: break
        }
    }

    private func applyRegistration(_ status: SMAppService.Status) {
        clearConnection()
        switch status {
        case .requiresApproval:
            state = .requiresApproval; message = "Allow Nollie Runtime in System Settings > General > Login Items, then check again."
        case .notFound, .notRegistered:
            state = .off; message = "Background service is ready to start."
        default:
            state = .off; message = "Background service is off."
        }
    }

    private func clearConnection() { endpoint = nil; sessionToken = nil; verifiedInstallationID = nil }
    private func fail(_ message: String) { clearConnection(); state = .failed; self.message = message }
    private func missingPackage() {
        clearConnection(); state = .unavailable
        message = "This build is missing a valid signed background service."
    }

    private static func verifyConnection(_ endpoint: URL, token: String) async throws -> Bool {
        let gateway = try GatewayURL.normalize(endpoint.absoluteString)
        let connection = GatewayConnection(name: "Nollie on this Mac", gateway: gateway, authMode: .sessionToken)
        return try await withThrowingTaskGroup(of: Bool.self) { group in
            group.addTask {
                await ConnectionTester.run(connection: connection, secrets: .init(sessionToken: token), progress: { _ in }).succeeded
            }
            group.addTask {
                try await Task.sleep(for: .seconds(45))
                throw ManagedRuntimeFailure.timedOut
            }
            defer { group.cancelAll() }
            return try await group.next() ?? false
        }
    }
}
#endif
