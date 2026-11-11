#if os(iOS)
import Foundation
import Testing
@testable import Nollie
import NollieCore

/// A pairing code opened as a link always leads somewhere: the confirmation, or the reason it can't be used.
struct PairingLinkTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func linkCode(expiresIn seconds: TimeInterval) throws -> URL {
        try NollieLinkOffer(macName: "Studio Mac", pin: Data(repeating: 7, count: 32), port: 7420, hosts: ["192.168.1.20"],
                            installTag: "0123456789abcdef", secret: Data(repeating: 9, count: 32),
                            expiresAt: now.addingTimeInterval(seconds), now: now.addingTimeInterval(min(0, seconds))).url
    }

    @Test func aCurrentLinkCodeOpensTheConfirmation() throws {
        guard case .link(let offer) = PairingLink.read(try linkCode(expiresIn: 100), now: now) else {
            Issue.record("a current code was not read as one")
            return
        }
        #expect(offer.macName == "Studio Mac")
    }

    @Test func aLinkCodeThatRanOutSaysSo() throws {
        let read = PairingLink.read(try linkCode(expiresIn: -300), now: now)
        guard case .unusable(let reason) = read else {
            Issue.record("an expired code was not reported")
            return
        }
        #expect(reason == NollieLinkError.expired.localizedDescription)
    }

    @Test func aCutShortLinkCodeSaysItIsNotACode() throws {
        let read = PairingLink.read(URL(string: "https://nollie.app/pair#bm90LWEtY29kZQ")!, now: now)
        guard case .unusable(let reason) = read else {
            Issue.record("a garbled code was not reported")
            return
        }
        #expect(reason == NollieLinkError.invalidOffer.localizedDescription)
    }

    @Test func aCodeHandedOverByTheWebPageOpensTheConfirmation() throws {
        let link = try linkCode(expiresIn: 100).absoluteString
        let handed = try #require(URL(string: NollieLinkOffer.appPrefix + link.dropFirst(NollieLinkOffer.prefix.count)))
        guard case .link(let offer) = PairingLink.read(handed, now: now) else {
            Issue.record("a code handed over by the web page was not read as one")
            return
        }
        #expect(offer.macName == "Studio Mac")
        #expect(offer == (try NollieLinkOffer.parse(link, now: now)))
    }

    @Test func aBrokenWebPageCodeSaysItIsNotACode() throws {
        let link = try linkCode(expiresIn: 100).absoluteString
        let fragment = String(link.dropFirst(NollieLinkOffer.prefix.count))
        for raw in ["nollie://pair-link", "nollie://pair-link#", "nollie://pair-link?x=1#" + fragment,
                    "nollie://pair-link/x#" + fragment, "nollie://pair-link#bm90LWEtY29kZQ"] {
            guard case .unusable(let reason) = PairingLink.read(try #require(URL(string: raw)), now: now) else {
                Issue.record("\(raw.prefix(30)) was not reported")
                continue
            }
            #expect(reason == NollieLinkError.invalidOffer.localizedDescription)
        }
        let expired = try linkCode(expiresIn: -300).absoluteString
        let late = try #require(URL(string: NollieLinkOffer.appPrefix + expired.dropFirst(NollieLinkOffer.prefix.count)))
        guard case .unusable(let reason) = PairingLink.read(late, now: now) else {
            Issue.record("an expired code from the web page was not reported")
            return
        }
        #expect(reason == NollieLinkError.expired.localizedDescription)
    }

    @Test func aGarbledPairingInvitationSaysWhy() {
        let read = PairingLink.read(URL(string: "nollie://pair#e30")!, now: now)
        guard case .unusable(let reason) = read else {
            Issue.record("a garbled invitation was not reported")
            return
        }
        #expect(reason == DevicePairingError.invalidInvitation.localizedDescription)
        #expect(!reason.contains("an Nollie"))
    }

    @Test func otherLinksAreNotPairingCodes() {
        #expect(PairingLink.read(URL(string: "nollie://chat/abc")!, now: now) == nil)
        #expect(PairingLink.read(URL(string: "https://nollie.app/privacy")!, now: now) == nil)
        #expect(PairingLink.read(URL(string: "otherapp://pair#e30")!, now: now) == nil)
    }
}
#endif
