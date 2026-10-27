#if os(macOS)
import Foundation

/// Owns one installation at a time. Child handles are created in this process only;
/// saved PIDs are never adopted or used for signalling.
actor NollieRuntimeSupervisor {
    typealias Contract = NollieRuntimeContract
    private let backend: any NollieRuntimeBackend
    private let pollInterval: Duration
    private let startupPolls: Int
    private let monitorInterval: Duration
    private let restartDelays: [Duration]
    private var generation = UUID()
    private var children: [Contract.Child] = []
    private var monitor: Task<Void, Never>?
    private var current = Contract.Snapshot()
    private var recentRestarts: [ContinuousClock.Instant] = []
    private var operationActive = false
    private var stopping = false

    init(backend: any NollieRuntimeBackend, pollInterval: Duration = .milliseconds(250), startupPolls: Int = 240,
         monitorInterval: Duration = .seconds(1), restartDelays: [Duration] = [.seconds(1), .seconds(3), .seconds(10)]) {
        self.backend = backend
        self.pollInterval = pollInterval
        self.startupPolls = startupPolls
        self.monitorInterval = monitorInterval
        self.restartDelays = restartDelays
    }
    func snapshot() -> Contract.Snapshot { current }

    func start(installationID: UUID, token: String, consent: Contract.StartConsent?) async throws -> Contract.Snapshot {
        #if !NOLLIE_DIRECT
        throw Contract.Failure.unavailable
        #else
        guard consent?.installationID == installationID else { throw Contract.Failure.consentRequired }
        guard Contract.validToken(token) else { throw Contract.Failure.identityMismatch }
        guard !operationActive, !stopping, children.isEmpty, monitor == nil else { throw Contract.Failure.alreadyRunning }
        operationActive = true
        defer { operationActive = false }
        let epoch = UUID()
        generation = epoch
        recentRestarts = []
        current = .init(phase: .validating, installationID: installationID)
        do {
            let plan = try await launchPair(installationID: installationID, token: token, epoch: epoch)
            try check(epoch)
            monitor = Task { await self.watch(plan: plan, token: token, epoch: epoch) }
            return current
        } catch {
            if generation == epoch {
                await stopChildren()
                guard generation == epoch else { throw Contract.Failure.cancelled }
                current.phase = .failed
                current.endpoint = nil
                current.failure = (error as? Contract.Failure) ?? .launchFailed
            }
            throw error
        }
        #endif
    }

    func stop() async {
        stopping = true
        defer { stopping = false }
        generation = UUID()
        monitor?.cancel()
        monitor = nil
        current = .init(phase: .stopped, installationID: current.installationID)
        await stopChildren()
    }

    private func check(_ epoch: UUID) throws {
        guard generation == epoch, !Task.isCancelled else { throw Contract.Failure.cancelled }
    }
    private func launchPair(installationID: UUID, token: String, epoch: UUID) async throws -> Contract.Plan {
        let plan = try await backend.prepare(installationID: installationID)
        try check(epoch)
        current.keysLeftInFiles = plan.keysLeftInFiles
        current.phase = current.restartCount == 0 ? .starting : .restarting
        for role in [Contract.Role.api, .gateway] {
            try check(epoch)
            let child = try await backend.launch(role, plan: plan, token: token)
            guard generation == epoch, !Task.isCancelled else {
                await backend.stop(child)
                await backend.release()
                throw Contract.Failure.cancelled
            }
            children.append(child)
        }
        for _ in 0..<startupPolls {
            try check(epoch)
            var ready = 0
            var port: Int?
            for child in children {
                let health = try await backend.health(child, plan: plan, token: token)
                try check(epoch)
                switch health {
                case .starting: break
                case .ready(let value): ready += 1; if child.role == .api { port = value }
                case .exited: throw Contract.Failure.childExited
                }
            }
            if ready == 2, let port {
                current.phase = .ready
                current.endpoint = URL(string: "http://127.0.0.1:\(port)")
                current.failure = nil
                return plan
            }
            try await Task.sleep(for: pollInterval)
        }
        throw Contract.Failure.startupTimedOut
    }
    private func stopChildren() async {
        let owned = children
        children = []
        for child in owned.reversed() { await backend.stop(child) }
        await backend.release()
    }
    private func watch(plan: Contract.Plan, token: String, epoch: UUID) async {
        var plan = plan
        while generation == epoch, !Task.isCancelled {
            do {
                try await Task.sleep(for: monitorInterval)
                try check(epoch)
                for child in children {
                    guard case .ready = try await backend.health(child, plan: plan, token: token) else {
                        throw Contract.Failure.childExited
                    }
                    try check(epoch)
                }
            } catch {
                guard generation == epoch, !Task.isCancelled else { return }
                current.endpoint = nil
                await stopChildren()
                guard generation == epoch, !Task.isCancelled else { return }
                let now = ContinuousClock.now
                recentRestarts = recentRestarts.filter { now - $0 < .seconds(600) }
                guard recentRestarts.count < min(3, restartDelays.count) else {
                    current.phase = .failed; current.failure = .restartLimit; monitor = nil; return
                }
                recentRestarts.append(now)
                current.restartCount += 1
                current.phase = .restarting
                do {
                    try await Task.sleep(for: restartDelays[recentRestarts.count - 1])
                    try check(epoch)
                    plan = try await launchPair(installationID: plan.installationID, token: token, epoch: epoch)
                } catch {
                    guard generation == epoch, !Task.isCancelled else { return }
                    await stopChildren()
                    guard generation == epoch, !Task.isCancelled else { return }
                    current.phase = .failed; current.endpoint = nil
                    current.failure = (error as? Contract.Failure) ?? .launchFailed
                    monitor = nil
                    return
                }
            }
        }
    }
}
#endif
