import Foundation
import SwiftUI
import Testing
@testable import Nollie
@testable import NollieCore

/// The assistant Nollie runs on this Mac comes back by itself after an update or at login: the
/// connection asks every few seconds while it starts, tries at once when told it is ready, fetches
/// the credential again if Hermes refuses it, and only after the whole wait offers Try again.
@Suite struct ManagedReconnectTests {

    // MARK: The rules

    @Test func whileTheAssistantMayBeStartingTheWaitsStayShort() {
        #expect(ManagedReconnect.delay(attempt: 1, waited: 0) == 1)
        #expect(ManagedReconnect.delay(attempt: 2, waited: 2) == 2)
        for attempt in 1...200 {
            let waited = Double(attempt) * 0.9
            guard waited < ManagedReconnect.patience else { break }
            #expect(ManagedReconnect.delay(attempt: attempt, waited: waited) <= 3)
        }
    }

    @Test func afterTheWholeWaitTheWaitsGrowButNeverPastHalfAMinute() {
        let patience = ManagedReconnect.patience
        #expect(ManagedReconnect.delay(attempt: 60, waited: patience) == 10)
        #expect(ManagedReconnect.delay(attempt: 70, waited: patience + 119) == 10)
        #expect(ManagedReconnect.delay(attempt: 80, waited: patience + 120) == 30)
        #expect(ManagedReconnect.delay(attempt: 500, waited: 86_400) == 30)
    }

    @Test func theWaitLastsAtLeastThreeMinutes() {
        #expect(ManagedReconnect.patience >= 180)
    }

    @Test func onlyTheAssistantOnThisMacEverWaits() {
        #expect(ManagedReconnect.wait(isManaged: false, isOpen: false, waited: 500) == .none)
        #expect(ManagedReconnect.wait(isManaged: true, isOpen: true, waited: 500) == .none)
        #expect(ManagedReconnect.wait(isManaged: true, isOpen: false, waited: nil) == .starting)
        #expect(ManagedReconnect.wait(isManaged: true, isOpen: false, waited: 0) == .starting)
        #expect(ManagedReconnect.wait(isManaged: true, isOpen: false, waited: ManagedReconnect.patience - 1) == .starting)
        #expect(ManagedReconnect.wait(isManaged: true, isOpen: false, waited: ManagedReconnect.patience) == .unreachable)
    }

    @Test func aReadyServiceNudgesOnlyTheConnectionWaitingForIt() {
        let mine = UUID()
        #expect(ManagedReconnect.shouldNudge(waitingFor: mine, isOpen: false, ready: mine))
        #expect(!ManagedReconnect.shouldNudge(waitingFor: mine, isOpen: true, ready: mine))
        #expect(!ManagedReconnect.shouldNudge(waitingFor: mine, isOpen: false, ready: UUID()))
        #expect(!ManagedReconnect.shouldNudge(waitingFor: nil, isOpen: false, ready: mine))
        #expect(!ManagedReconnect.shouldNudge(waitingFor: mine, isOpen: false, ready: nil))
    }

    @Test func aGatewayElsewhereKeepsItsOwnLadder() {
        let standard = ReconnectPolicy.standard
        #expect(standard.afterRefusal == nil)
        #expect(standard.delay(1, 0) == 1 && standard.delay(8, 400) == 30)
        let managed = ReconnectPolicy.managed {}
        #expect(managed.afterRefusal != nil)
        #expect(managed.delay(8, 30) == 3)
    }

    // MARK: The runtime

    @MainActor @Test func theRuntimeSaysStartingThenCantReachAndTryAgainStartsTheWaitOver() async throws {
        let runtime = try ChatFixtures.runtime(named: "managed-wait")
        runtime.socketEnabled = false
        runtime.judgeManagedWait()
        #expect(runtime.managedWait == .none)

        runtime.managedEndpointResolver = { throw HermesAPIError.transport("not yet") }
        let began = Date()
        runtime.judgeManagedWait(now: began)
        #expect(runtime.managedWait == .starting)
        runtime.judgeManagedWait(now: began.addingTimeInterval(ManagedReconnect.patience - 1))
        #expect(runtime.managedWait == .starting)
        runtime.judgeManagedWait(now: began.addingTimeInterval(ManagedReconnect.patience + 1))
        #expect(runtime.managedWait == .unreachable)

        await runtime.retryNow()
        #expect(runtime.managedWait == .starting)
    }

    // MARK: The socket

    private static func address(_ listener: StalledSocketTests.QuietListener) -> URL {
        URL(string: "ws://127.0.0.1:\(listener.port)/api/ws")!
    }

    private static func socket(_ provider: @escaping GatewaySocket.URLProvider, states: Guarded<[SocketState]>) -> GatewaySocket {
        GatewaySocket(urlProvider: provider, onEvent: { _ in },
                      onState: { state in states.withLock { $0.append(state) } },
                      onServerRequest: { _ in nil }, onReconnected: {})
    }

    /// Waits up to five seconds for `condition`.
    private static func eventually(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !condition() {
            guard ContinuousClock.now < deadline else { throw SocketError.timeout("condition") }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    @Test func tryingNowEndsALongPauseAndConnects() async throws {
        let listener = try StalledSocketTests.QuietListener(greeting: StalledSocketTests.hello)
        defer { listener.shutDown() }
        let address = Self.address(listener)
        let ready = Guarded(false), states = Guarded<[SocketState]>([])
        let socket = Self.socket({
            guard ready.withLock({ $0 }) else { throw HermesAPIError.transport("not yet") }
            return (address, [:])
        }, states: states)
        await socket.use(ReconnectPolicy(delay: { _, _ in 60 }))
        await socket.connect()
        try await Self.eventually {
            states.withLock { $0.contains { if case .reconnecting(_, let pause) = $0 { pause > 0 } else { false } } }
        }

        ready.withLock { $0 = true }
        await socket.retryNow()
        // Well inside the minute the pause would have lasted.
        try await socket.waitUntilReady(timeout: 5)
        #expect(await socket.state == .open)
        await socket.disconnect()
    }

    @Test func tryingNowWhileOpenChangesNothing() async throws {
        let listener = try StalledSocketTests.QuietListener(greeting: StalledSocketTests.hello)
        defer { listener.shutDown() }
        let address = Self.address(listener)
        let asked = Guarded(0), states = Guarded<[SocketState]>([])
        let socket = Self.socket({ asked.withLock { $0 += 1 }; return (address, [:]) }, states: states)
        await socket.connect()
        try await socket.waitUntilReady(timeout: 5)
        await socket.retryNow()
        try await Task.sleep(for: .milliseconds(200))
        #expect(await socket.state == .open)
        #expect(asked.withLock { $0 } == 1)
        await socket.disconnect()
    }

    @Test func aRefusedCredentialForTheAssistantOnThisMacIsFetchedAgainAndTheSocketKeepsTrying() async throws {
        let listener = try StalledSocketTests.QuietListener(greeting: StalledSocketTests.hello)
        defer { listener.shutDown() }
        let address = Self.address(listener)
        let fetched = Guarded(0), states = Guarded<[SocketState]>([])
        let socket = Self.socket({
            // Hermes turns the old credential down until the service is asked for the current one.
            guard fetched.withLock({ $0 }) > 0 else { throw HermesAPIError.unauthorized("refused") }
            return (address, [:])
        }, states: states)
        await socket.use(.managed { fetched.withLock { $0 += 1 } })
        await socket.connect()
        // A failed attempt lets go of anyone waiting for ready, so watch the state instead.
        try await Self.eventually { states.withLock { $0.last == .open } }
        #expect(fetched.withLock { $0 } == 1)
        // Never "sign in again": nobody signs in to the assistant on this Mac.
        #expect(!states.withLock { $0.contains { if case .authRejected = $0 { true } else { false } } })
        await socket.disconnect()
    }

    @Test func aGatewaySomeoneSignsInToStopsAtARefusalUntilAskedToTryAgain() async throws {
        let listener = try StalledSocketTests.QuietListener(greeting: StalledSocketTests.hello)
        defer { listener.shutDown() }
        let address = Self.address(listener)
        let allowed = Guarded(false), states = Guarded<[SocketState]>([])
        let socket = Self.socket({
            guard allowed.withLock({ $0 }) else { throw HermesAPIError.unauthorized("refused") }
            return (address, [:])
        }, states: states)
        await socket.connect()
        try await Self.eventually {
            states.withLock { $0.contains { if case .authRejected = $0 { true } else { false } } }
        }
        allowed.withLock { $0 = true }
        await socket.retryNow()
        try await socket.waitUntilReady(timeout: 5)
        await socket.disconnect()
    }
}

/// Pictures of the model sheet's top while the assistant on this Mac is on its way back, and once
/// it couldn't be reached. Glass is off: ImageRenderer can't draw Liquid Glass.
@MainActor @Suite struct ManagedReconnectPictureTests {
    private static let defaults: UserDefaults = {
        let d = UserDefaults(suiteName: "nollie.design-snapshots")!
        d.set(false, forKey: GlassAppearance.enabledKey)
        return d
    }()

    @Test func theModelSheetWhileTheAssistantStartsAndWhenItCantBeReached() {
        let starting = VStack(spacing: 12) {
            ModelsHero(state: .starting)
            ProgressView().controlSize(.small)
        }
        let unreachable = VStack(spacing: 12) {
            ModelsHero(state: .unreachable)
            AssistantTryAgainButton()
        }
        for (name, view) in [("starting", AnyView(starting)), ("unreachable", AnyView(unreachable))] {
            for scheme in [ColorScheme.light, .dark] {
                let renderer = ImageRenderer(content: view.padding(28).frame(width: 420)
                    .background(scheme == .dark ? Color.black : Color.white)
                    .environment(\.colorScheme, scheme)
                    .defaultAppStorage(Self.defaults)
                    .environment(AppModel.shared))
                renderer.scale = 2
                guard let image = renderer.uiImage, let data = image.pngData() else { Issue.record("no picture for \(name)"); continue }
                let file = "model-sheet-\(name)-\(scheme == .dark ? "dark" : "light").png"
                Attachment.record(data, named: file)
            }
        }
    }
}
