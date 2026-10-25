import Foundation
import Testing
@testable import Nollie

@Suite struct DisclosureScrollAnchorTests {
    @Test func expansionCompensatesOnlyForMovementOfTheTappedHeader() {
        let anchor = DisclosureScrollAnchor(id: "step", top: 250)
        #expect(anchor.offset(current: 400, headerTop: 250, minimum: 0, maximum: 2_000) == 400)
        #expect(anchor.offset(current: 400, headerTop: 170, minimum: 0, maximum: 2_000) == 320)
        #expect(anchor.offset(current: 400, headerTop: 310, minimum: 0, maximum: 2_000) == 460)
        // Adding more output below the header does not move the viewport to the output's end.
        #expect(anchor.offset(current: 400, headerTop: 250, minimum: 0, maximum: 20_000) == 400)
    }

    @Test func compensationHonorsTheNativeScrollInsetsAndRange() {
        let anchor = DisclosureScrollAnchor(id: "step", top: 200)
        #expect(anchor.offset(current: 10, headerTop: 0, minimum: -96, maximum: 1_000) == -96)
        #expect(anchor.offset(current: 980, headerTop: 400, minimum: -96, maximum: 1_000) == 1_000)
        #expect(anchor.offset(current: 0, headerTop: 500, minimum: 0, maximum: 0) == 0)
    }

    @Test func eventsKeepTheConversationScopeEvenWhenHistoryRowIDsMatch() throws {
        let first = try #require(TranscriptDisclosureEvent(notification: Notification(name: .hermesRevealRow,
            userInfo: ["id": "h-1", "top": CGFloat(120), "began": true, "scope": "gateway:work:chat-one"])))
        let second = try #require(TranscriptDisclosureEvent(notification: Notification(name: .hermesRevealRow,
            userInfo: ["id": "h-1", "top": CGFloat(160), "scope": "gateway:work:chat-two"])))
        #expect(first.id == second.id)
        #expect(first.scope != second.scope)
        #expect(first.began)
        #expect(!second.began)
    }

    @Test func incompleteAndNonfiniteGeometryIsIgnored() {
        for info: [String: Any] in [[:], ["id": "step"], ["top": CGFloat(10)],
                                  ["id": "step", "top": CGFloat.nan], ["id": "step", "top": CGFloat.infinity]] {
            #expect(TranscriptDisclosureEvent(notification: Notification(name: .hermesRevealRow, userInfo: info)) == nil)
        }
    }
}
