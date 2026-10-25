import Foundation
import Testing
@testable import Nollie
@testable import NollieCore

/// Signing in again from what was remembered: the prompts, the retries and what gets forgotten.
@MainActor @Suite struct RememberedSignInFlowTests {
    private let secret = RememberedFixtures.secret

    // MARK: the happy path and its refusals

    @Test func aListUnreadableAtLaunchIsReadWhenTheNeedArises() async throws {
        let rig = try SignInRig(startLocked: true)
        #expect(rig.coordinator.decision(for: rig.home, asked: false) == .askPerson(.nothingRemembered))
        rig.gatewayAccepts()

        let whileLocked = await rig.again()
        #expect(whileLocked == nil)
        #expect(rig.check.asked.isEmpty)

        rig.backend.unreadable = false
        let afterUnlock = await rig.again()
        #expect(afterUnlock?.accessToken == "a")
        #expect(rig.check.asked.count == 1)
    }

    @Test func anEndedSessionIsRenewedAfterTheOwnerCheck() async throws {
        let rig = try SignInRig()
        let used = Tally<RememberedSignIn>()
        rig.coordinator.signIn = { _, remembered, _ in
            used.add(remembered)
            return GatewaySecrets(accessToken: "new-access", refreshToken: "new-refresh")
        }
        let access = CloudflareAccess(clientId: "id", clientSecret: "secret")
        let renewed = try #require(await rig.coordinator.signInAgain(rig.home, access: access))
        #expect(renewed.accessToken == "new-access")
        #expect(renewed.refreshToken == "new-refresh")
        #expect(renewed.access == access, "the gateway's own Access headers are carried over")
        #expect(used.entries == [secret])
        #expect(rig.check.asked == ["Sign in to Home"])
        #expect(rig.backend.readsWithContext == 1)
    }

    @Test func cancellingFallsBackToThePromptAndSilencesAutomaticAttempts() async throws {
        let rig = try SignInRig()
        rig.check.willPass = false
        let reached = Tally<Int>()
        rig.coordinator.signIn = { _, _, _ in reached.add(1); return GatewaySecrets(accessToken: "a") }

        for _ in 1...2 { let outcome = await rig.again(); #expect(outcome == nil) }
        #expect(rig.check.asked.count == 1, "a cancelled check is not repeated unprompted")
        #expect(reached.count == 0)
        #expect(rig.coordinator.vault.contains(rig.home.id), "cancelling keeps the sign-in")

        // The button on the Sign In sheet tries again and explains why it failed.
        await #expect(throws: RememberedSignInError.cancelled) {
            try await rig.coordinator.signInWithRemembered(rig.home, access: CloudflareAccess())
        }
        rig.check.willPass = true
        let viaButton = try await rig.coordinator.signInWithRemembered(rig.home, access: CloudflareAccess())
        #expect(viaButton.accessToken == "a")
        #expect(!rig.coordinator.declined.contains(rig.home.id))
        #expect(rig.coordinator.decision(for: rig.home, asked: false) == .useRemembered)
    }

    @Test func anotherAddressNeverReceivesThePassword() async throws {
        let rig = try SignInRig(remembering: false)
        let moved = RememberedFixtures.connection(at: try GatewayURL.normalize("https://elsewhere.example.net"))
        try rig.coordinator.vault.remember(secret, for: moved.id)
        rig.gatewayMustNotBeCalled("the password went to a different address")

        #expect(await rig.again(moved) == nil)
        #expect(!rig.coordinator.vault.contains(moved.id), "useless at the new address, so forgotten")

        try rig.coordinator.vault.remember(RememberedFixtures.secret, for: moved.id)
        await #expect(throws: RememberedSignInError.moved) {
            try await rig.coordinator.signInWithRemembered(moved, access: CloudflareAccess())
        }
        #expect(!rig.coordinator.vault.contains(moved.id))
    }

    @Test func aSignInSavedBeforeAddressesWereRecordedIsNeverSent() async throws {
        let rig = try SignInRig(remembering: false)
        rig.gatewayMustNotBeCalled("an address-less sign-in was sent")
        let oldJSON = Data(#"{"provider":"basic","username":"river-at-home","password":"plum-tree-lantern"}"#.utf8)
        #expect(try JSONDecoder().decode(RememberedSignIn.self, from: oldJSON).gateway == nil)
        try rig.backend.write(oldJSON, account: RememberedSignInVault.account(rig.home.id))
        rig.coordinator.vault.reload()
        await #expect(throws: RememberedSignInError.moved) {
            try await rig.coordinator.signInWithRemembered(rig.home, access: CloudflareAccess())
        }
        #expect(!rig.coordinator.vault.contains(rig.home.id))
    }

    @Test func aPasswordTheGatewayRefusesIsForgotten() async throws {
        let rig = try SignInRig()
        rig.coordinator.signIn = { _, _, _ in throw HermesAPIError.unauthorized("Invalid credentials") }
        #expect(await rig.again() == nil)
        #expect(!rig.coordinator.vault.contains(rig.home.id))
    }

    @Test func aFailureToConnectLeavesItForNextTime() async throws {
        let rig = try SignInRig()
        rig.coordinator.signIn = { _, _, _ in throw HermesAPIError.transport("offline") }
        #expect(await rig.again() == nil)
        #expect(rig.coordinator.vault.contains(rig.home.id))
        #expect(rig.coordinator.decision(for: rig.home, asked: false) == .askPerson(.declined))
    }

    @Test func nothingHappensInTheBackgroundOrForABrowserSignIn() async throws {
        let rig = try SignInRig()
        let browser = RememberedFixtures.connection(.oauth, name: "Office")
        try rig.coordinator.vault.remember(secret, for: browser.id)
        rig.gatewayMustNotBeCalled("signed in when it should have waited")

        rig.coordinator.canPromptNow = { false }
        #expect(await rig.again() == nil)
        rig.coordinator.canPromptNow = { true }
        #expect(await rig.again(browser) == nil)
        #expect(rig.check.asked.isEmpty)
        #expect(rig.coordinator.decision(for: rig.home, asked: false) == .useRemembered, "not now is not never")
    }

    @Test func callsThatPileUpShareOnePrompt() async throws {
        let rig = try SignInRig()
        rig.check.hold = .milliseconds(200)
        rig.gatewayAccepts()
        async let first = rig.again()
        async let second = rig.again()
        let both = await [first, second]
        #expect(both.compactMap(\.?.accessToken) == ["a", "a"])
        #expect(rig.check.asked.count == 1)
    }

    // MARK: coming back to the app

    @Test func comingBackOnlyMendsARefreshTheGatewayTurnedDown() async throws {
        let rig = try SignInRig()
        rig.coordinator.signIn = { _, _, _ in
            Issue.record("signed in for a socket problem a sign-in cannot mend")
            return GatewaySecrets()
        }
        let socketOnly = await rig.returningRuntime(refreshTurnedDown: false)
        #expect(!socketOnly.refreshRefused)
        #expect(await rig.coordinator.signInAgainOnReturn(socketOnly) == nil)

        let stillOpening = await rig.returningRuntime(refreshTurnedDown: true)
        stillOpening.socketState = .connecting
        #expect(await rig.coordinator.signInAgainOnReturn(stillOpening) == nil)
        #expect(rig.check.asked.isEmpty)
        #expect(rig.coordinator.decision(for: rig.home, asked: false) == .useRemembered)

        rig.gatewayAccepts()
        let expired = await rig.returningRuntime(refreshTurnedDown: true)
        #expect(expired.refreshRefused)
        #expect(await rig.coordinator.signInAgainOnReturn(expired)?.accessToken == "a")
        #expect(rig.check.asked == ["Sign in to Home"])
    }

    @Test func aRefusedRefreshIsMendedOnReturnHoweverSoonItFollowsAnother() async throws {
        let rig = try SignInRig()
        rig.gatewayAccepts()
        #expect(await rig.again()?.accessToken == "a")

        // The session ends again two minutes on, while the app is away.
        rig.clock.advance(120)
        rig.coordinator.canPromptNow = { false }
        #expect(await rig.again() == nil)
        #expect(rig.check.asked.count == 1)

        // Five minutes after the first attempt the app is in the foreground again.
        rig.clock.advance(180)
        rig.coordinator.canPromptNow = { true }
        let runtime = await rig.returningRuntime(refreshTurnedDown: true)
        #expect(await rig.coordinator.signInAgainOnReturn(runtime)?.accessToken == "a")
        #expect(rig.check.asked.count == 2)

        rig.clock.advance(180)
        #expect(await rig.again()?.accessToken == "a")
        #expect(rig.check.asked.count == 3)
    }

    @Test func aGatewayThatKeepsEndingSessionsIsNotAnsweredEveryMinute() async throws {
        let rig = try SignInRig()
        let reached = Tally<Int>()
        rig.coordinator.signIn = { _, _, _ in reached.add(1); return GatewaySecrets(accessToken: "a") }
        let runtime = await rig.returningRuntime(refreshTurnedDown: true)
        let co = rig.coordinator

        #expect(await rig.again() != nil)
        rig.clock.advance(30)
        #expect(await rig.again() == nil)
        #expect(await co.signInAgainOnReturn(runtime) == nil)
        #expect(co.decision(for: rig.home, asked: false) == .askPerson(.tooSoon))
        #expect(!co.declined.contains(rig.home.id), "held back is not turned down")

        rig.clock.advance(30)
        #expect(await co.signInAgainOnReturn(runtime) != nil)
        rig.clock.advance(60)
        #expect(await rig.again() != nil)

        // Three attempts within ten minutes: no automatic retry until the oldest is ten minutes old.
        rig.clock.advance(60)
        #expect(await rig.again() == nil)
        rig.clock.advance(6 * 60 + 59)
        #expect(await co.signInAgainOnReturn(runtime) == nil)
        #expect(co.decision(for: rig.home, asked: false) == .askPerson(.tooSoon))
        #expect(rig.check.asked.count == 3)
        #expect(reached.count == 3)
        #expect(co.vault.contains(rig.home.id), "waiting is not forgetting")

        // The button always works and does not use up any of the allowance.
        let pressed = try await co.signInWithRemembered(rig.home, access: CloudflareAccess())
        #expect(pressed.accessToken == "a")
        #expect(reached.count == 4)
        rig.clock.advance(1)
        #expect(co.decision(for: rig.home, asked: false) == .useRemembered)
        #expect(await rig.again() != nil)
        #expect(co.decision(for: rig.home, asked: false) == .askPerson(.tooSoon))

        // Each gateway has its own allowance.
        let office = RememberedFixtures.connection(name: "Office")
        try co.vault.remember(secret, for: office.id)
        #expect(co.decision(for: office, asked: false) == .useRemembered)

        // Signing in by hand starts afresh.
        co.didSignIn(rig.home.id)
        #expect(co.decision(for: rig.home, asked: false) == .useRemembered)
    }

    // MARK: the runtime's own refresh

    @Test func theRuntimeTriesTheRememberedSignInWhenItsRefreshIsTurnedDown() async throws {
        // Nothing saved means no refresh token, so renewal is refused at once without a request.
        let (store, savedID, runtime) = try RememberedFixtures.deadEndRuntime(called: "test remembered sign-in")
        defer { store.delete(id: savedID) }
        runtime.socketEnabled = false
        #expect(!runtime.refreshRefused)

        await #expect(throws: HermesAPIError.self) { try await runtime.refreshSession() }
        #expect(runtime.refreshRefused, "without the hook, the session has ended for good")

        let consulted = Tally<String>()
        runtime.signInAgain = { chosen, _ in consulted.add(chosen.name); return nil }
        await #expect(throws: HermesAPIError.self) { try await runtime.refreshSession() }
        #expect(runtime.refreshRefused)

        let foreign = CloudflareAccess(clientId: "other", clientSecret: "other")
        runtime.signInAgain = { _, _ in
            GatewaySecrets(accessToken: "fresh", refreshToken: "r2", provider: "basic", access: foreign)
        }
        try await runtime.refreshSession()
        #expect(!runtime.refreshRefused)
        #expect(runtime.secrets.accessToken == "fresh")
        #expect(runtime.secrets.refreshToken == "r2")
        #expect(runtime.secrets.access == CloudflareAccess(), "the gateway keeps its own Access headers")
        #expect(consulted.entries == ["test remembered sign-in"])
        #if os(iOS)
        if RememberedFixtures.hostHasKeychain { #expect(store.secrets(for: savedID).accessToken == "fresh") }
        #endif

        // A session without a refresh token is turned away again; a manual sign-in removes the mark.
        runtime.signInAgain = nil
        for (typed, shouldBeRefused) in [("typed", true), ("typed-again", false)] {
            await runtime.replaceSecrets(GatewaySecrets(accessToken: typed, provider: "basic"))
            if shouldBeRefused { await #expect(throws: HermesAPIError.self) { try await runtime.refreshSession() } }
            #expect(runtime.refreshRefused == shouldBeRefused)
        }
    }

    /// When the runtime signs in again while its socket stands refused, nothing else would open
    /// the socket: the return to the app only signs in after a refused refresh, which this just mended.
    @Test func aRuntimeSignInReopensTheSocketItFindsRefused() async throws {
        let (store, savedID, runtime) = try RememberedFixtures.deadEndRuntime(called: "test socket opened again")
        defer { store.delete(id: savedID) }
        let renewals = Tally<Int>()
        let accept: @MainActor (GatewayConnection, GatewaySecrets) async -> GatewaySecrets? = { _, _ in
            renewals.add(1)
            return GatewaySecrets(accessToken: "fresh", provider: "basic")
        }
        runtime.signInAgain = accept

        // Never opened, or closed deliberately, so it remains closed.
        try await runtime.refreshSession()
        try await Task.sleep(for: .milliseconds(300))
        #expect(runtime.socketState == .idle)
        #expect(await runtime.socket.state == .idle)

        // Refused, and the sign-in does not work: it stays refused.
        runtime.socketState = .authRejected("The gateway turned down the WebSocket credential (4401).")
        runtime.signInAgain = { _, _ in nil }
        await #expect(throws: HermesAPIError.self) { try await runtime.refreshSession() }
        try await Task.sleep(for: .milliseconds(300))
        #expect(await runtime.socket.state == .idle)

        // Refused, and the sign-in works: the socket opens again.
        runtime.signInAgain = accept
        try await runtime.refreshSession()
        #expect(renewals.count == 2)
        #expect(!runtime.refreshRefused)
        var reopened = false
        for _ in 0..<50 where !reopened {
            if case .authRejected = runtime.socketState {} else if runtime.socketState != .idle { reopened = true }
            if !reopened { try await Task.sleep(for: .milliseconds(100)) }
        }
        #expect(reopened, "the socket stayed \(runtime.socketState)")
        #expect(await runtime.socket.state != .idle)
        await runtime.stop()
    }
}
