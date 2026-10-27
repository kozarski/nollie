import Foundation
import Testing
@testable import NollieCore

/// Sharing a helper at home, on the phone's side: the code for someone at home, the household copy's
/// name, the owner's ask card, and the saved link. What a phone may reach is the Mac's call
/// (`LinkDoorFamilyTests`); these check the phone reads its answers correctly.
struct FamilySharingTests {
    private let pin = Data(repeating: 7, count: 32)
    private let secret = Data(repeating: 9, count: 32)

    private func offer(invite: NollieLinkInvite?) throws -> NollieLinkOffer {
        try NollieLinkOffer(macName: "Studio", pin: pin, port: 52345, hosts: ["192.168.1.20", "studio.local"],
                            installTag: "0123456789abcdef", secret: secret, expiresAt: Date().addingTimeInterval(100), invite: invite)
    }

    private func payload(_ code: String) throws -> [String: Any] {
        let encoded = String(code.dropFirst(NollieLinkOffer.prefix.count))
        let data = try #require(NollieLinkOffer.decodeBase64URL(encoded))
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func code(_ fields: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys])
        return NollieLinkOffer.prefix + NollieLinkOffer.base64URL(data)
    }

    @Test func aCodeForSomeoneAtHomeIsVersionTwoAndSaysWhoSharesWhat() throws {
        let invite = try #require(NollieLinkInvite(owner: "Corey", helpers: ["Scout"]))
        let made = try offer(invite: invite)
        let fields = try payload(made.urlString)
        #expect(fields["v"] as? Int == 2)
        #expect((fields["f"] as? [String: Any])?["o"] as? String == "Corey")
        let scanned = try NollieLinkOffer.parse(made.urlString)
        #expect(scanned.invite == invite)
        #expect(scanned.pin == pin)

        // An ordinary code stays version 1, with exactly its old keys, so older phones read it.
        let plain = try offer(invite: nil)
        let old = try payload(plain.urlString)
        #expect(old["v"] as? Int == 1)
        #expect(Set(old.keys) == ["v", "n", "k", "p", "h", "t", "s", "e"])
        #expect(try NollieLinkOffer.parse(plain.urlString).invite == nil)
    }

    @Test func versionsAndTheirKeysMustAgree() throws {
        var fields = try payload(try offer(invite: NollieLinkInvite(owner: "Corey", helpers: ["Scout"])).urlString)
        // Version 2 without who shares, or version 1 carrying it, is not a code.
        var missing = fields
        missing["f"] = nil
        #expect(throws: NollieLinkError.invalidOffer) { try NollieLinkOffer.parse(try code(missing)) }
        var mixed = fields
        mixed["v"] = 1
        #expect(throws: NollieLinkError.invalidOffer) { try NollieLinkOffer.parse(try code(mixed)) }
        var future = fields
        future["v"] = 3
        #expect(throws: NollieLinkError.invalidOffer) { try NollieLinkOffer.parse(try code(future)) }
        // Names the phone would show must be plain: no hidden direction marks, not too many helpers.
        fields["f"] = ["o": "Corey\u{202E}", "b": ["Scout"]]
        #expect(throws: NollieLinkError.invalidOffer) { try NollieLinkOffer.parse(try code(fields)) }
        fields["f"] = ["o": "Corey", "b": [String](repeating: "Scout", count: 9)]
        #expect(throws: NollieLinkError.invalidOffer) { try NollieLinkOffer.parse(try code(fields)) }
        fields["f"] = ["o": "Corey", "b": [String]()]
        #expect(throws: NollieLinkError.invalidOffer) { try NollieLinkOffer.parse(try code(fields)) }
    }

    @Test func helpersAreListedInPlainWords() {
        #expect(NollieLinkInvite(owner: "Corey", helpers: ["Scout"])?.helperList == "Scout")
        #expect(NollieLinkInvite(owner: "Corey", helpers: ["Scout", "Fern"])?.helperList == "Scout and Fern")
        #expect(NollieLinkInvite(owner: "", helpers: ["Scout", "Fern", "Juniper"])?.helperList == "Scout, Fern and Juniper")
        #expect(NollieLinkInvite(owner: "Corey", helpers: [" Scout"]) == nil)
    }

    @Test func theHouseholdCopyIsNamedForThePersonInHermessGrammar() {
        #expect(NollieFamilyClient.copyName(helper: "career", person: "Sam") == "career-sam")
        #expect(NollieFamilyClient.copyName(helper: "career", person: "Zoë Ann") == "career-zoeann")
        #expect(NollieFamilyClient.copyName(helper: "career", person: "🙂") == "career-home")
        let long = NollieFamilyClient.copyName(helper: String(repeating: "a", count: 64), person: "Alexandria-Rose")
        #expect(long.count <= 64)
        #expect(long.hasSuffix("-alexandriarose"))
        for name in [long, NollieFamilyClient.copyName(helper: "x", person: "Mum")] {
            #expect(name.range(of: #"\A[a-z0-9][a-z0-9_-]{0,63}\z"#, options: .regularExpression) != nil, "\(name)")
        }
    }

    @Test func anAskReadsAsAnApprovalWithOnlyAllowOnceAndDeny() throws {
        let raw = Data(#"""
        {"members":[{"id":"6f9619ff-8b86-d011-b42d-00c04fc964ff","person":"Sam","device":"Sam's iPhone","helpers":["career-sam"],"small":false,"linkedAt":1761400000}],
         "asks":[{"id":"srq-0123456789ab","person":"Sam","helper":"career-sam","chat":"20261026_1_ab","small":false,"at":1761480000,
                  "request":{"request_id":"ap-1","description":"Send an email to Grandma","pattern_key":"plugin_rule:nollie-ask-first:send:1","choices":["once","session","always","deny"],"tool_name":"mcp__gmail__send_email"}}]}
        """#.utf8)
        let overview = try JSONCoding.decoder.decode(NollieFamilyOverview.self, from: raw)
        #expect(overview.members.first?.person == "Sam")
        let ask = try #require(overview.asks.first)
        let approval = ask.approval
        #expect(approval.requestId == "ap-1")
        #expect(approval.description == "Send an email to Grandma")
        #expect(approval.patternKey == "plugin_rule:nollie-ask-first:send:1")
        #expect(approval.toolName == "mcp__gmail__send_email")
        // Never Session or Always for someone else's ask.
        #expect(approval.offeredChoices == ["once", "deny"])
        #expect(approval.sessionId == "20261026_1_ab")
    }

    @Test func theDoorsCodeFieldsBecomeAnOffer() throws {
        let fields = NollieFamilyCode(macName: "Studio", pin: NollieLinkOffer.base64URL(pin), port: 52345, hosts: ["192.168.1.20"],
                                      tag: "0123456789abcdef", secret: NollieLinkOffer.base64URL(secret),
                                      expiresAt: Date().addingTimeInterval(110).timeIntervalSince1970, owner: "Corey", helpers: ["Scout"])
        let made = try NollieFamilyClient.offer(from: fields)
        #expect(made.invite?.owner == "Corey")
        #expect(try NollieLinkOffer.parse(made.urlString).invite?.helpers == ["Scout"])
        var bad = fields
        bad.helpers = []
        #expect(throws: (any Error).self) { try NollieFamilyClient.offer(from: bad) }
    }

    @Test func aSavedLinkRemembersItJoinedAsSomeoneAtHome() throws {
        var link = LinkedMac(macName: "Studio", pin: pin, port: 52345, hosts: ["192.168.1.20"], installTag: "0123456789abcdef", deviceID: UUID())
        let older = try JSONDecoder().decode(LinkedMac.self, from: try JSONEncoder().encode(link))
        #expect(older.sharedBy == nil)
        link.sharedBy = "Corey"
        let saved = try JSONDecoder().decode(LinkedMac.self, from: try JSONEncoder().encode(link))
        #expect(saved.sharedBy == "Corey")
    }

    @Test func whoThisDeviceIsReadsFromTheDoor() throws {
        let member = try JSONCoding.decoder.decode(NollieFamilyMe.self, from: Data(#"{"role":"member","owner":"Corey","person":"Sam","helpers":["career-sam"],"small":false}"#.utf8))
        #expect(member.isMember && member.owner == "Corey" && member.helpers == ["career-sam"])
        let owner = try JSONCoding.decoder.decode(NollieFamilyMe.self, from: Data(#"{"role":"owner"}"#.utf8))
        #expect(!owner.isMember)
    }
}
