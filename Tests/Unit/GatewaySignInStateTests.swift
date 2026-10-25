import AuthenticationServices
import Foundation
import Testing
@testable import Nollie
@testable import NollieCore

/// Which gateways this device still has to sign in to, and the way a browser sign-in ends.
@Suite struct GatewaySignInStateTests {
    private func gateway(_ mode: AuthMode) throws -> GatewayConnection {
        let office = try GatewayURL.normalize("https://hermes.example.net")
        var connection = GatewayConnection(name: "Office", gateway: office, authMode: .sessionToken)
        connection.authMode = mode
        return connection
    }

    @Test func browserAndPasswordSignInsStayOnTheDeviceTheyWereMadeOn() throws {
        for mode in [AuthMode.oauth, .password] {
            #expect(try gateway(mode).lacksCredentials(GatewaySecrets()))
        }
        #expect(!(try gateway(.oauth).lacksCredentials(GatewaySecrets(accessToken: "a", refreshToken: "r"))))
    }

    @Test func aSessionTokenIsMissingOnlyWhenItNeverCame() throws {
        let token = try gateway(.sessionToken)
        #expect(token.lacksCredentials(GatewaySecrets()))
        #expect(token.lacksCredentials(GatewaySecrets(sessionToken: "  ")))
        #expect(!token.lacksCredentials(GatewaySecrets(sessionToken: "t")))
    }

    @Test func cloudflareAccessValuesAloneAreNotASignIn() throws {
        var secrets = GatewaySecrets()
        secrets.access = CloudflareAccess(clientId: "id", clientSecret: "secret")
        #expect(try gateway(.oauth).lacksCredentials(secrets))
    }

    @MainActor @Test func onlyTheGatewaysThatLackOneAreAskedFor() throws {
        let withToken = try gateway(.sessionToken), viaBrowser = try gateway(.oauth), withPassword = try gateway(.password)
        let waiting = GatewaySignIn.pending([withToken, viaBrowser, withPassword]) { entry in
            entry.id == withToken.id ? GatewaySecrets(sessionToken: "t") : GatewaySecrets()
        }
        #expect(waiting.map(\.id) == [viaBrowser.id, withPassword.id])
        #expect(GatewaySignIn.usesBrowser(viaBrowser))
        #expect(!GatewaySignIn.usesBrowser(withPassword))
    }

    @MainActor @Test func aPairedGatewayWantsANewCodeNotTheBrowser() throws {
        var paired = try gateway(.oauth)
        paired.authProvider = DevicePairingClient.provider
        #expect(DevicePairingRecovery.needsPairing(paired))
        #expect(!GatewaySignIn.usesBrowser(paired))
        #expect(!DevicePairingRecovery.needsPairing(try gateway(.oauth)))
    }

    /// The web authentication session answers on whatever thread the system picks. Its handler
    /// used to be tied to the main actor, which crashed the Mac app when the browser returned.
    @MainActor @Test func theBrowserMayReportBackOnAnyThread() async {
        let outcome: Result<(code: String, state: String), Error> = await withCheckedContinuation { waiting in
            let report = NativeAuthClient.sessionEnded { outcome in waiting.resume(returning: outcome) }
            let closedByPerson = ASWebAuthenticationSessionError(.canceledLogin)
            DispatchQueue.global().async { report(nil, closedByPerson) }
        }
        guard case .failure(let error) = outcome, case NativeAuthError.cancelled = error else {
            Issue.record("a dismissed browser window should count as cancelled, but the result was \(outcome)")
            return
        }
    }
}
