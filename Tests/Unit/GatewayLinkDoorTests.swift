#if os(macOS)
import Foundation
import Testing
@testable import NollieCore

/// The new gateway client and the Nollie Link door, which only forwards methods it knows from a linked phone.
struct GatewayLinkDoorTests {
    @Test func theDoorForwardsTheClientsOwnCalls() {
        for method in GatewayMachine.ownMethods {
            let params: GatewayJSON = method == GatewayWire.Calls.sessionEventsSince.name
                ? ["session_id": "s1", "last_seen": 3] : [:]
            let frame = GatewayFrame.call(id: 1, method: method, params: params)
            #expect(LinkDoorRPC.decide(Data(frame.utf8)) == .forward, "\(method)")
        }
    }

    @Test func theDoorForwardsAnswersAndDeclines() {
        let answer = GatewayFrame.reply(to: "srq-1", result: ["choice": "once"])
        let notShown = GatewayFrame.reply(to: "srq-2", error: GatewayRPCError(code: GatewayRPCError.notShown, message: "x"))
        let unknown = GatewayFrame.reply(to: "srq-3", error: GatewayRPCError(code: GatewayRPCError.unknownMethod, message: "x"))
        for frame in [answer, notShown, unknown] {
            #expect(LinkDoorRPC.decide(Data(frame.utf8)) == .forward, "\(frame)")
        }
    }
}
#endif
