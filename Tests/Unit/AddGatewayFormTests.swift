import Foundation
import Testing
@testable import Nollie
@testable import NollieCore

/// The Add Gateway form when the address does not suit the connection type picked: it offers
/// the type that does in one tap, and says what Save is waiting for rather than just greying.
@MainActor @Suite struct AddGatewayFormTests {
    private typealias Kind = GatewayFormView.ConnectionKind
    private func suggestion(_ address: String, chosen: Kind) throws -> Kind? {
        Kind.suggested(for: try GatewayURL.normalize(address), chosen: chosen)
    }

    @Test func aPublicAddressUnderLocalOrTailscaleOffersOther() throws {
        let publicAddress = "https://bots.example.org"
        #expect(try suggestion(publicAddress, chosen: .local) == .other)
        #expect(try suggestion(publicAddress, chosen: .tailscale) == .other)
        #expect(try suggestion(publicAddress, chosen: .other) == nil)
        #expect(try suggestion(publicAddress, chosen: .cloudflare) == nil)
    }

    @Test func aPrivateOrTailnetAddressUnderOtherOffersTheMatchingType() throws {
        let lan = "http://10.0.0.7:9119", tailnet = "http://studio.tail9876.ts.net:9119"
        #expect(try suggestion(lan, chosen: .other) == .local)
        #expect(try suggestion(tailnet, chosen: .other) == .tailscale)
        // Already the right type, or close enough: nothing to offer.
        #expect(try suggestion(lan, chosen: .local) == nil)
        #expect(try suggestion(tailnet, chosen: .tailscale) == nil)
        #expect(try suggestion(tailnet, chosen: .local) == nil)
    }

    @Test func saveSaysWhatItIsWaitingFor() {
        func blocker(named: Bool, urlOK: Bool = true, canTest: Bool = true, passed: Bool = true) -> String? {
            GatewayFormView.saveBlocker(named: named, urlOK: urlOK, canTest: canTest, testPassed: passed)
        }
        #expect(blocker(named: true) == nil)
        #expect(blocker(named: false)?.hasPrefix("To save:") == true && blocker(named: false)?.contains("name") == true)
        #expect(blocker(named: true, passed: false)?.contains("Test Connection") == true)
        #expect(blocker(named: true, canTest: false, passed: false)?.contains("sign-in") == true)
        let everything = blocker(named: false, urlOK: false, canTest: false, passed: false) ?? ""
        #expect(everything.contains("address") && everything.contains("name"))
    }
}
