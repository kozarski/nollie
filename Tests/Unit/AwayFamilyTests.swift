import Foundation
import Testing
@testable import Nollie
@testable import NollieCore

/// Away through iCloud is for the owner's own phones. Someone a helper is shared with (a member)
/// never swaps keys, never has a channel, never sees the page or the switch, and the Mac never
/// listens to them. The door's side is in LinkDoorFamilyAwayTests.
@MainActor
struct AwayFamilyTests {
    private func runtime(sharedBy: String?) throws -> GatewayRuntime {
        var link = LinkedMac(macName: "Studio", pin: Data(repeating: 7, count: 32), port: 52_345, hosts: ["192.168.1.20"],
                             installTag: "0123456789abcdef", deviceID: UUID())
        link.sharedBy = sharedBy
        link.awayKey = AwayKey().publicKey
        var connection = GatewayConnection(name: "Studio", gateway: try GatewayURL.normalize("https://192.168.1.20:52345"), authMode: .sessionToken)
        connection.linkedMac = link
        return GatewayRuntime(connection: connection, store: ConnectionStore())
    }

    @Test func aMembersPhoneHasNoChannelAndNeverSwapsKeys() async throws {
        let member = try runtime(sharedBy: "Corey")
        #expect(member.awayChannel == nil)
        #expect(await member.swapAwayKeys() == false)
    }

    @Test func thePageAndItsSwitchStayHiddenOnAMembersPhone() {
        #expect(AwayFromHomeView.shows(reach: .away, isMember: false))
        #expect(AwayFromHomeView.shows(reach: .home, isMember: false))
        for reach in [NollieLinkReach.home, .tailnet, .away] {
            #expect(!AwayFromHomeView.shows(reach: reach, isMember: true))
        }
        #expect(!AwayFromHomeView.shows(reach: nil, isMember: false))
    }

    #if os(iOS)
    @Test func aMembersPhoneNeverCarriesThroughICloud() async throws {
        let phone = AwayPhone(defaults: UserDefaults(suiteName: "away-family-\(UUID().uuidString)")!)
        await phone.refresh(try runtime(sharedBy: "Corey"), isMember: true)
        #expect(phone.state == .unavailable)
        #expect(!phone.isOn)
        #expect(phone.courier == nil)
        #expect(!(await phone.stop()))
    }
    #endif

    #if os(macOS)
    @Test func theMacListensOnlyToItsOwnersPhones() {
        let owner = AwayKey().publicKey
        let member = AwayKey().publicKey
        let devices = [
            NollieLinkIPCDevice(id: UUID(), name: "Corey's iPhone", linkedAt: .now, awayKey: AwayBase64URL.encode(owner)),
            // A member whose key was somehow handed on: still never heard.
            NollieLinkIPCDevice(id: UUID(), name: "Sam's iPhone", linkedAt: .now, awayKey: AwayBase64URL.encode(member), person: "Sam"),
            NollieLinkIPCDevice(id: UUID(), name: "Old iPad", linkedAt: .now),
            NollieLinkIPCDevice(id: UUID(), name: "Odd", linkedAt: .now, awayKey: "not a key"),
        ]
        let phones = AwayMacBridge.awayPhones(devices)
        #expect(phones.map(\.name) == ["Corey's iPhone"])
        #expect(phones.first?.key == owner)
    }

    @Test func aMemberWhoSwappedBeforeIsNoLongerHeardByTheDesk() async throws {
        let cloud = FakeAwayCloud()
        let handler = FakeDeskHandler()
        let macKey = AwayKey()
        let samKey = AwayKey()
        let desk = AwayDesk(macKey: macKey, cloud: cloud, handler: handler)
        // Sam swapped keys as an owner's phone, then was made a member: the Mac's list no longer has them.
        desk.setPhones(AwayMacBridge.awayPhones([NollieLinkIPCDevice(id: UUID(), name: "Sam's iPhone", linkedAt: .now,
                                                                     awayKey: AwayBase64URL.encode(samKey.publicKey), person: "Sam")]))
        let sam = AwayCourier(channel: try AwayChannel(own: samKey, side: .phone, otherPublic: macKey.publicKey), cloud: cloud)
        try await sam.send(bot: "default", chat: nil, text: "Hello")
        try await sam.stop()
        #expect(try await desk.collect() == 0)
        #expect(handler.sends.isEmpty && handler.stops.isEmpty)
        #expect(try await sam.collect().isEmpty, "nothing is answered")
    }
    #endif
}
