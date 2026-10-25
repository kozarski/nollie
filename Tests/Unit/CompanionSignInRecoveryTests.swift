import Foundation
import Testing
@testable import Nollie
import NollieCore

@MainActor
struct CompanionSignInRecoveryTests {
    private let now = Date(timeIntervalSince1970: 10_000)

    private func heartbeat(at: Double = 10_000, connected: Bool = false,
                           error: String? = "HTTP 401 Unauthorized (sign-in rejected)") -> PushSetupModel.CompanionHeartbeat {
        PushSetupModel.CompanionHeartbeat(version: "1.0.40", updatedAt: at, connected: connected, error: error)
    }

    @Test func freshRejectionInvalidatesSavedSignIn() {
        var state = CompanionSignInState()
        state.observe(heartbeat(), at: now)
        #expect(state.rejected)
        // An unchanged file does not make a known rejected credential usable again as it ages.
        state.observe(heartbeat(), at: now.addingTimeInterval(90))
        #expect(state.rejected)
    }

    @Test(arguments: ["HTTP 401 Unauthorized", "HTTP 403 Forbidden", "WebSocket closed: 4401", "sign-in rejected"])
    func recognizesAuthenticationFailures(error: String) {
        #expect(CompanionSignInState.isSignInRejection(heartbeat(error: error)))
    }

    @Test(arguments: ["Connection refused", "connecting…", "HTTP 403 (Cloudflare refused it)", "HTTP 401 cf-access denied"])
    func networkAndAccessFailuresDoNotDemandAnotherPassword(error: String) {
        #expect(!CompanionSignInState.isSignInRejection(heartbeat(error: error)))
    }

    @Test func oldOrFutureStatusDoesNotRejectCurrentSavedSignIn() {
        for timestamp in [9_939.0, 10_006.0, .infinity, .nan] {
            var state = CompanionSignInState()
            state.observe(heartbeat(at: timestamp), at: now)
            #expect(!state.rejected)
        }
    }

    @Test func signingInKeepsOldProcessErrorsSeparateUntilInstallation() {
        var state = CompanionSignInState()
        state.observe(heartbeat(), at: now)
        state.signedIn(after: 10_000)
        #expect(!state.rejected)
        #expect(state.needsInstall)
        state.observe(heartbeat(at: 10_030), at: now.addingTimeInterval(30))
        #expect(!state.rejected)
        #expect(!state.accepts(heartbeat(at: 10_030, connected: true, error: nil), at: now.addingTimeInterval(30)))
    }

    @Test func installWaitsForNewHeartbeatAfterTheReloadWindow() {
        var state = CompanionSignInState()
        state.signedIn(after: 10_000)
        state.installed(after: 10_005, at: now.addingTimeInterval(5))
        #expect(!state.needsInstall)
        state.observe(heartbeat(at: 10_005), at: now.addingTimeInterval(20))
        state.observe(heartbeat(at: 10_010), at: now.addingTimeInterval(20))
        #expect(!state.rejected)
        #expect(state.waitingForHeartbeat(heartbeat(at: 10_010), at: now.addingTimeInterval(20)))
        state.observe(heartbeat(at: 10_016), at: now.addingTimeInterval(20))
        #expect(state.rejected)
        #expect(!state.waitingForHeartbeat(heartbeat(at: 10_016), at: now.addingTimeInterval(20)))
    }

    @Test func successfulReplacementCanConnectWithoutOldFailureSticking() {
        var state = CompanionSignInState()
        state.observe(heartbeat(), at: now)
        state.signedIn(after: 10_000)
        state.installed(after: 10_000, at: now)
        let connected = heartbeat(at: 10_011, connected: true, error: nil)
        state.observe(connected, at: now.addingTimeInterval(11))
        #expect(!state.rejected)
        #expect(state.accepts(connected, at: now.addingTimeInterval(11)))
        // Rereading the earlier file cannot undo the newer credential's successful connection.
        state.observe(heartbeat(), at: now.addingTimeInterval(12))
        #expect(!state.rejected)
    }

    @Test func anotherRejectedReplacementStillOffersRecovery() {
        var state = CompanionSignInState()
        state.signedIn(after: 10_000)
        state.installed(after: 10_000, at: now)
        state.observe(heartbeat(at: 10_011), at: now.addingTimeInterval(11))
        #expect(state.rejected)
        state.signedIn(after: 10_011)
        #expect(!state.rejected)
        #expect(state.needsInstall)
    }

    @Test func reopeningSetupKeepsTheReplacementPendingUntilItIsInstalled() throws {
        let suite = "CompanionSignInRecoveryTests." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let connectionID = UUID()
        var state = CompanionSignInState()
        state.signedIn(after: 10_000)
        state.save(connectionID: connectionID, defaults: defaults)

        var reopened = CompanionSignInState.restore(connectionID: connectionID, defaults: defaults)
        reopened.observe(heartbeat(at: 10_020), at: now.addingTimeInterval(20))
        #expect(reopened.needsInstall)
        #expect(!reopened.rejected)
        #expect(!CompanionSignInState.restore(connectionID: UUID(), defaults: defaults).needsInstall)

        reopened.installed(after: 10_020, at: now.addingTimeInterval(20))
        reopened.save(connectionID: connectionID, defaults: defaults)
        var afterInstall = CompanionSignInState.restore(connectionID: connectionID, defaults: defaults)
        afterInstall.observe(heartbeat(at: 10_020), at: now.addingTimeInterval(25))
        #expect(!afterInstall.needsInstall)
        #expect(!afterInstall.rejected)
        #expect(afterInstall.waitingForHeartbeat(heartbeat(at: 10_020), at: now.addingTimeInterval(25)))
        afterInstall.observe(heartbeat(at: 10_031, connected: true, error: nil), at: now.addingTimeInterval(31))
        #expect(!afterInstall.rejected)
        #expect(!afterInstall.waitingForHeartbeat(heartbeat(at: 10_031, connected: true, error: nil), at: now.addingTimeInterval(31)))
    }

    @Test func modelBlocksRejectedCacheAndKeepsAppleSetupOnNewSignIn() {
        let setup = PushSetupModel()
        setup.keyData = Data("synthetic-key".utf8)
        setup.keyFileName = "test.p8"
        setup.keyID = "TESTKEY123"
        setup.teamID = "TESTTEAM12"
        setup.gatewayURL = "https://example.invalid"
        setup.companionSecrets = GatewaySecrets(accessToken: "old-test-token", provider: "basic")
        setup.heartbeat = heartbeat(at: Date().timeIntervalSince1970)
        #expect(setup.credential(authMode: .password) == .needsSignIn)
        #expect(setup.startAdvice.contains("Sign in again"))

        setup.acceptCompanionSignIn(GatewaySecrets(accessToken: "new-test-token", provider: "basic"))
        #expect(setup.credential(authMode: .password) == .ready(provider: "basic"))
        #expect(setup.signInNeedsInstall)
        #expect(!setup.companionHealthy)
        #expect(!setup.installedOnGateway)
        #expect(setup.keyData == Data("synthetic-key".utf8))
        #expect(setup.keyFileName == "test.p8")
        #expect(setup.keyID == "TESTKEY123")
        #expect(setup.teamID == "TESTTEAM12")
        #expect(setup.gatewayURL == "https://example.invalid")
    }

    @Test func emptyTokenIsNotASavedSignIn() {
        let setup = PushSetupModel()
        setup.companionSecrets = GatewaySecrets(accessToken: "")
        #expect(setup.credential(authMode: .password) == .needsSignIn)
        #expect(setup.credential(authMode: .sessionToken) == .sessionToken)
    }
}
