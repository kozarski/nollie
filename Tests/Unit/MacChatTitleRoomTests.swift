#if os(macOS)
import Foundation
import Testing
@testable import Nollie

// The Mac chat header in the window's toolbar: a side chat's title gives way to the bot's name,
// so a narrow window never shows "Defa…" or hides the whole header behind ».

@Suite struct MacChatTitleRoomTests {
    @Test func wideWindowKeepsTheUsualCap() {
        #expect(MacChatTitleRoom.cap(column: 920, name: 100, watch: false) == MacChatTitleRoom.widest)
    }

    @Test func narrowWindowShortensTheTitle() throws {
        let cap = try #require(MacChatTitleRoom.cap(column: 476, name: 100, watch: false))
        #expect(cap < MacChatTitleRoom.widest)
        // Name, chevron and title together leave the trailing buttons their room on both sides.
        #expect(100 + MacChatTitleRoom.chevron + cap + 2 * MacChatTitleRoom.side(watch: false) <= 476)
    }

    @Test func watchTakesRoomFromTheTitle() {
        let without = MacChatTitleRoom.cap(column: 600, name: 100, watch: false) ?? 0
        let with = MacChatTitleRoom.cap(column: 600, name: 100, watch: true) ?? 0
        #expect(with < without)
    }

    @Test func tooLittleRoomLeavesTheTitleOut() {
        #expect(MacChatTitleRoom.cap(column: 476, name: 100, watch: true) == nil)
        #expect(MacChatTitleRoom.cap(column: 300, name: 180, watch: false) == nil)
    }

    @Test func unmeasuredColumnKeepsTheOldRule() {
        #expect(MacChatTitleRoom.cap(column: 0, name: 0, watch: false) == MacChatTitleRoom.widest)
    }
}
#endif
