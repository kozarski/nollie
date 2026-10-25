import Foundation
import Testing
import UserNotifications
@testable import Nollie

@MainActor
struct PushAuthorizationTests {
    @Test func aReplyFromALockedPhoneAsksToUnlockFirst() {
        #expect(LocalNotifier.replyOptions.contains(.authenticationRequired))
    }

    @Test func returningFromSettingsRegistersNewPermissionOnlyOnce() async {
        let system = AuthorizationProbe(status: .denied)
        let push = system.registrar()
        await push.refreshAuthorization()
        #expect(push.authorization == .denied)
        #expect(system.registrations == 0)

        system.status = .authorized
        await push.refreshAuthorization()
        #expect(push.authorization == .authorized)
        #expect(system.registrations == 1)
        await push.refreshAuthorization()
        await push.registerForRemoteNotificationsIfAuthorized()
        #expect(system.registrations == 1)
        #expect(system.requests == 0)

        system.status = .denied
        await push.refreshAuthorization()
        system.status = .authorized
        await push.refreshAuthorization()
        #expect(system.registrations == 2)
    }

    @Test(arguments: [UNAuthorizationStatus.notDetermined, .denied])
    func foregroundChecksNeverPrompt(status: UNAuthorizationStatus) async {
        let system = AuthorizationProbe(status: status)
        let push = system.registrar()
        await push.refreshAuthorization()
        await push.registerForRemoteNotificationsIfAuthorized()
        #expect(push.authorization == status)
        #expect(system.requests == 0)
        #expect(system.registrations == 0)
    }

    @Test(arguments: [UNAuthorizationStatus.authorized, .provisional])
    func existingPermissionRegistersOnLaunchWithoutPrompt(status: UNAuthorizationStatus) async {
        let system = AuthorizationProbe(status: status)
        let push = system.registrar()
        await push.registerForRemoteNotificationsIfAuthorized()
        #expect(await push.requestAuthorization())
        #expect(system.registrations == 1)
        #expect(system.requests == 0)
    }

    @Test func overlappingActivationChecksShareOneSettingsQuery() async {
        let system = AuthorizationProbe(status: .authorized)
        let gate = SuspensionGate()
        system.nextReadGate = gate
        let push = system.registrar()
        let first = Task { await push.refreshAuthorization() }
        await gate.waitUntilEntered()
        let second = await startedTask { await push.refreshAuthorization() }
        #expect(system.reads == 1)
        gate.open()
        await first.value
        await second.value
        #expect(system.reads == 1)
        #expect(system.registrations == 1)
    }

    @Test func overlappingPermissionRequestsShareTheSystemPrompt() async {
        let system = AuthorizationProbe(status: .notDetermined)
        let gate = SuspensionGate()
        system.requestGate = gate
        let push = system.registrar()
        let first = Task { await push.requestAuthorization() }
        await gate.waitUntilEntered()
        let second = await startedTask { await push.requestAuthorization() }
        #expect(system.requests == 1)
        gate.open()
        #expect(await first.value)
        #expect(await second.value)
        #expect(push.authorization == .authorized)
        #expect(system.requests == 1)
        #expect(system.registrations == 1)
    }

    @Test func decliningPermissionDoesNotPromptAgainOrRegister() async {
        let system = AuthorizationProbe(status: .notDetermined)
        system.requestStatus = .denied
        let push = system.registrar()
        #expect(!(await push.requestAuthorization()))
        #expect(push.authorization == .denied)
        #expect(!(await push.requestAuthorization()))
        await push.refreshAuthorization()
        #expect(system.requests == 1)
        #expect(system.registrations == 0)
    }

    @Test func grantedPromptRefreshesPastAnOlderActivationQuery() async {
        let system = AuthorizationProbe(status: .notDetermined)
        let prompt = SuspensionGate()
        system.requestGate = prompt
        let push = system.registrar()
        let request = Task { await push.requestAuthorization() }
        await prompt.waitUntilEntered()

        let staleRead = SuspensionGate()
        system.nextReadGate = staleRead
        let activation = Task { await push.refreshAuthorization() }
        await staleRead.waitUntilEntered()
        prompt.open()
        staleRead.open()
        #expect(await request.value)
        await activation.value
        #expect(push.authorization == .authorized)
        #expect(system.registrations == 1)
        #expect(system.requests == 1)
    }

    @Test func failedAPNsRegistrationCanRetryOnNextActivation() async {
        let system = AuthorizationProbe(status: .authorized)
        let push = system.registrar()
        await push.refreshAuthorization()
        push.didFailToRegister(NSError(domain: "PushAuthorizationTests", code: 1))
        await push.refreshAuthorization()
        #expect(system.registrations == 2)
        #expect(system.requests == 0)
    }

    private func startedTask<Value: Sendable>(_ operation: @escaping @MainActor () async -> Value) async -> Task<Value, Never> {
        var task: Task<Value, Never>!
        await withCheckedContinuation { (started: CheckedContinuation<Void, Never>) in
            task = Task { @MainActor in
                started.resume()
                return await operation()
            }
        }
        return task
    }
}

@MainActor
private final class AuthorizationProbe {
    var status: UNAuthorizationStatus
    var reads = 0
    var requests = 0
    var registrations = 0
    var requestStatus: UNAuthorizationStatus = .authorized
    var nextReadGate: SuspensionGate?
    var requestGate: SuspensionGate?

    init(status: UNAuthorizationStatus) { self.status = status }

    func registrar() -> PushRegistrar {
        PushRegistrar(installID: UUID().uuidString,
            authorizationClient: NotificationAuthorizationClient(
                status: { [self] in
                    reads += 1
                    let snapshot = status
                    let gate = nextReadGate
                    nextReadGate = nil
                    await gate?.suspend()
                    return snapshot
                },
                request: { [self] in
                    requests += 1
                    await requestGate?.suspend()
                    status = requestStatus
                    return status == .authorized || status == .provisional
                },
                register: { [self] in registrations += 1 }))
    }
}

@MainActor
private final class SuspensionGate {
    private var entered = false
    private var isOpen = false
    private var waitingForEntry: CheckedContinuation<Void, Never>?
    private var suspended: CheckedContinuation<Void, Never>?

    func suspend() async {
        entered = true
        waitingForEntry?.resume()
        waitingForEntry = nil
        guard !isOpen else { return }
        await withCheckedContinuation { suspended = $0 }
    }

    func waitUntilEntered() async {
        guard !entered else { return }
        await withCheckedContinuation { waitingForEntry = $0 }
    }

    func open() {
        isOpen = true
        suspended?.resume()
        suspended = nil
    }
}
