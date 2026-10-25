import AVFoundation
import Foundation
import Testing
import UserNotifications
@testable import Nollie

/// Holds a request open, as a system prompt on screen would, until the test lets it finish.
@MainActor
private final class PromptGate {
    private var waiting: CheckedContinuation<Void, Never>?
    private var isOpen = false

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { waiting = $0 }
    }

    func open() {
        isOpen = true
        waiting?.resume()
        waiting = nil
    }
}

/// A stand-in for one permission: what the system would say, and how often Nollie asked.
@MainActor
private final class FakeSystemAnswer {
    var state: PermissionState
    var answerWhenAsked: PermissionState
    var reads = 0
    var asks = 0
    var openedSettings = 0
    /// Held open to model the prompt being on screen.
    var gate: PromptGate?

    init(_ state: PermissionState, answerWhenAsked: PermissionState = .granted) {
        self.state = state
        self.answerWhenAsked = answerWhenAsked
    }

    var client: PermissionClient {
        PermissionClient(
            read: { [self] in reads += 1; return state },
            request: { [self] in
                asks += 1
                if let gate { await gate.wait() }
                state = answerWhenAsked
                return state
            },
            openSettings: { [self] in openedSettings += 1 })
    }
}

@MainActor
struct PermissionCenterTests {
    @Test func lookingNeverAsks() async {
        let notifications = FakeSystemAnswer(.notAsked)
        let network = FakeSystemAnswer(.notAsked)
        let center = PermissionCenter(clients: [.notifications: notifications.client, .localNetwork: network.client])
        await center.refresh()
        await center.refresh(.notifications)
        #expect(center.state(.notifications) == .notAsked)
        #expect(center.hasRead)
        #expect(notifications.asks == 0 && network.asks == 0)
        #expect(notifications.reads == 2 && network.reads == 1)
    }

    @Test func allowAsksOnceAndTheTickFollows() async {
        let fake = FakeSystemAnswer(.notAsked)
        let center = PermissionCenter(clients: [.notifications: fake.client])
        #expect(await center.ask(.notifications) == .granted)
        #expect(center.state(.notifications) == .granted)
        // Once on, pressing again asks nothing.
        #expect(await center.ask(.notifications) == .granted)
        #expect(fake.asks == 1)
    }

    @Test func aRefusalIsKeptAndNeverAskedAgain() async {
        let fake = FakeSystemAnswer(.notAsked, answerWhenAsked: .denied)
        let center = PermissionCenter(clients: [.camera: fake.client])
        #expect(await center.ask(.camera) == .denied)
        #expect(await center.ask(.camera) == .denied)
        #expect(fake.asks == 1)
        center.openSettings(.camera)
        #expect(fake.openedSettings == 1)
    }

    @Test(arguments: [PermissionState.granted, .denied, .unavailable])
    func anAnsweredPermissionIsLeftAlone(state: PermissionState) async {
        let fake = FakeSystemAnswer(state)
        let center = PermissionCenter(clients: [.microphone: fake.client])
        #expect(await center.ask(.microphone) == state)
        #expect(fake.asks == 0)
    }

    @Test func twoPressesShowOnePrompt() async {
        let fake = FakeSystemAnswer(.notAsked)
        let gate = PromptGate()
        fake.gate = gate
        let center = PermissionCenter(clients: [.notifications: fake.client])
        let first = Task { await center.ask(.notifications) }
        await Task.yield()
        while fake.asks == 0 { await Task.yield() }
        #expect(center.asking.contains(.notifications))
        #expect(await center.ask(.notifications) == .notAsked)
        gate.open()
        #expect(await first.value == .granted)
        #expect(fake.asks == 1)
        #expect(center.asking.isEmpty)
    }

    @Test func aPermissionWithNoWayToAskIsOnlyRead() async {
        let fake = FakeSystemAnswer(.denied)
        let center = PermissionCenter(clients: [.liveActivities: fake.client])
        #expect(!PermissionKind.liveActivities.canAsk)
        #expect(await center.ask(.liveActivities) == .notAsked)
        #expect(fake.asks == 0)
    }

    @Test func aKindThisDeviceLacksIsNotAvailable() async {
        let center = PermissionCenter(clients: [.notifications: FakeSystemAnswer(.granted).client])
        #expect(center.isAvailable(.notifications))
        #expect(!center.isAvailable(.accessibility))
        #expect(await center.ask(.accessibility) == .notAsked)
    }

    @Test func unansweredCountsOnlyWhatAwaitsAnAnswer() async {
        let center = PermissionCenter(clients: [
            .notifications: FakeSystemAnswer(.notAsked).client,
            .localNetwork: FakeSystemAnswer(.granted).client,
            .camera: FakeSystemAnswer(.denied).client,
        ])
        await center.refresh()
        #expect(center.unanswered(PermissionKind.allCases) == 1)
    }

    // MARK: What each device lists

    @Test func theMacDownloadAsksForTheMacOnlyPermissionsInSettings() {
        let mac = PermissionKind.listed(isMac: true, direct: true)
        #expect(mac == [.notifications, .localNetwork, .microphone, .accessibility, .screenRecording])
        #expect(!mac.contains(.camera))
    }

    @Test func theStoreMacHasNoLinkAndNoComputer() {
        #expect(PermissionKind.listed(isMac: true, direct: false) == [.notifications, .microphone])
    }

    @Test func thePhoneNeverListsTheMacPermissions() {
        let phone = PermissionKind.listed(isMac: false, direct: true)
        #expect(!phone.contains(.accessibility) && !phone.contains(.screenRecording))
        #expect(phone.contains(.camera) && phone.contains(.liveActivities))
    }

    @Test func setupAsksForNotificationsAndTheLinkOnly() {
        #expect(PermissionKind.inSetup == [.notifications, .localNetwork])
        #expect(!PermissionKind.inSetup.contains(.accessibility))
        #expect(!PermissionKind.inSetup.contains(.screenRecording))
        #expect(!PermissionKind.inSetup.contains(.camera))
    }

    @Test func everyPermissionSaysWhyInOneShortPlainLine() {
        for kind in PermissionKind.allCases {
            #expect(!kind.reason.isEmpty && kind.reason.count < 70, "\(kind.rawValue): \(kind.reason)")
            #expect(!kind.reason.contains("\u{2014}") && !kind.title.contains("\u{2014}"))
            #expect(kind.reason.hasSuffix("."))
        }
    }

    // MARK: Settings summary

    @Test func theSettingsRowCountsWhatIsOffOnceRead() async {
        let center = PermissionCenter(clients: [
            .notifications: FakeSystemAnswer(.granted).client,
            .camera: FakeSystemAnswer(.denied).client,
            .microphone: FakeSystemAnswer(.notAsked).client,
        ])
        let kinds: [PermissionKind] = [.notifications, .camera, .microphone, .accessibility]
        #expect(PermissionsSummary.rowWord(kinds, in: center) == nil)
        await center.refresh()
        #expect(PermissionsSummary.off(kinds, in: center) == [.camera, .microphone])
        #expect(PermissionsSummary.rowWord(kinds, in: center) == "2 off")
    }

    @Test func nothingOffSaysNothing() async {
        let center = PermissionCenter(clients: [.notifications: FakeSystemAnswer(.granted).client])
        await center.refresh()
        #expect(PermissionsSummary.rowWord([.notifications], in: center) == nil)
    }

    // MARK: The system's words

    @Test func notificationAnswersMapToStates() {
        #expect(PermissionClient.map(UNAuthorizationStatus.notDetermined) == .notAsked)
        #expect(PermissionClient.map(UNAuthorizationStatus.denied) == .denied)
        #expect(PermissionClient.map(UNAuthorizationStatus.authorized) == .granted)
        #expect(PermissionClient.map(UNAuthorizationStatus.provisional) == .granted)
    }

    @Test func microphoneAnswersMapToStates() {
        #expect(PermissionClient.map(AVAudioApplication.recordPermission.undetermined) == .notAsked)
        #expect(PermissionClient.map(AVAudioApplication.recordPermission.granted) == .granted)
        #expect(PermissionClient.map(AVAudioApplication.recordPermission.denied) == .denied)
    }

    @Test func notificationsGoThroughThePushRegistrarSoAYesStillRegisters() async {
        var status = UNAuthorizationStatus.notDetermined
        var requests = 0
        var registrations = 0
        let push = PushRegistrar(installID: UUID().uuidString, authorizationClient: NotificationAuthorizationClient(
            status: { status }, request: { requests += 1; status = .authorized; return true },
            register: { registrations += 1 }))
        let client = PermissionClient.notifications(push)
        #expect(await client.read() == .notAsked)
        #expect(requests == 0 && registrations == 0)
        #expect(await client.request() == .granted)
        #expect(requests == 1 && registrations == 1)
    }
}

/// The Local Network answer is written down; the network is only used when asked, or to look
/// again once there is an answer to look at.
@MainActor
struct LocalNetworkAccessTests {
    private final class Uses: @unchecked Sendable {
        var count = 0
        var answers: [LocalNetworkAccess.Answer]
        init(_ answers: [LocalNetworkAccess.Answer]) { self.answers = answers }
        func next() -> LocalNetworkAccess.Answer { count += 1; return answers.isEmpty ? .undecided : answers.removeFirst() }
    }

    private func access(_ answers: LocalNetworkAccess.Answer...) -> (LocalNetworkAccess, Uses, UserDefaults) {
        let defaults = UserDefaults(suiteName: "nollie.test.localnetwork.\(UUID().uuidString)")!
        let uses = Uses(answers)
        return (LocalNetworkAccess(defaults: defaults, probe: { _ in uses.next() }), uses, defaults)
    }

    @Test func beforeTheFirstAllowTheNetworkIsNotTouched() async {
        let (access, uses, _) = access(.granted)
        #expect(await access.read() == .notAsked)
        #expect(uses.count == 0)
    }

    @Test func allowShowsThePromptOnceAndRemembersYes() async {
        let (access, uses, defaults) = access(.granted, .granted)
        #expect(await access.request() == .granted)
        #expect(access.remembered == .granted)
        #expect(defaults.string(forKey: LocalNetworkAccess.answerKey) == "granted")
        // A later look is the quiet one.
        #expect(await access.read() == .granted)
        #expect(uses.count == 2)
    }

    @Test func aNoIsRememberedAndAChangeInSettingsIsSeen() async {
        let (access, _, _) = access(.denied, .granted)
        #expect(await access.request() == .denied)
        #expect(await access.read() == .granted)
        #expect(access.remembered == .granted)
    }

    @Test func aLookThatSeesNothingKeepsWhatWasKnown() async {
        let (access, _, _) = access(.denied, .undecided)
        _ = await access.request()
        #expect(await access.read() == .denied)
    }

    @Test func anUnansweredPromptDoesNotCountAsAsked() async {
        let (access, _, _) = access(.undecided, .undecided)
        #expect(await access.request() == .notAsked)
        // So nothing looks again by itself until Allow is pressed.
        #expect(await access.read() == .notAsked)
    }

    @Test func theCenterReadsLocalNetworkFromItsClient() async {
        let (access, uses, _) = access(.granted)
        let center = PermissionCenter(clients: [.localNetwork: .localNetwork(access)])
        await center.refresh()
        #expect(center.state(.localNetwork) == .notAsked)
        #expect(uses.count == 0)
        #expect(await center.ask(.localNetwork) == .granted)
        #expect(uses.count == 1)
    }
}

#if os(macOS)
@MainActor
struct MacComputerPermissionClientTests {
    @Test func askingIsRememberedAndAStillOffPermissionOffersSettings() async {
        let permissions = ComputerPermissions()
        var prompts: [ComputerPermissions.Kind] = []
        permissions.read = { _ in false }
        permissions.request = { prompts.append($0) }
        let client = PermissionClient.computer(.screenRecording, permissions)
        #expect(await client.read() == .notAsked)
        #expect(await client.request() == .denied)
        #expect(await client.read() == .denied)
        #expect(prompts == [.screenRecording])
    }

    @Test func aPermissionAlreadyOnIsGrantedWithoutAnyPrompt() async {
        let permissions = ComputerPermissions()
        var prompts = 0
        permissions.read = { _ in true }
        permissions.request = { _ in prompts += 1 }
        let center = PermissionCenter(clients: [.accessibility: .computer(.accessibility, permissions)])
        #expect(await center.ask(.accessibility) == .granted)
        #expect(prompts == 0)
    }
}
#endif
