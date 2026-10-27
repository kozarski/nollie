import XCTest

/// The gateway marks a bot's files with `MEDIA:` lines. Those are plumbing: a new chat shows
/// the picture or a card, never the line itself, live, after a reload and in the lists.
final class MediaLineUITests: DemoCase {
    private func noMediaWords(_ place: String, file: StaticString = #filePath, line: UInt = #line) {
        let raw = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", "MEDIA:", "MEDIA:"))
        XCTAssertEqual(raw.count, 0, "\(place) shows a MEDIA line: \(raw.allElementsBoundByIndex.map(\.label))", file: file, line: line)
    }

    func testANewChatNeverShowsAMediaLine() throws {
        try beginSideChat(saying: "clean up the disk")
        expectShown(buttonNamed("Allow once"), within: 60, "no approval came up")
        press("Allow once")
        expectShown(text("4.2 GB freed"), within: 60, "the reply did not finish")
        pause(2)
        look("media-new-chat")
        noMediaWords("the new chat")
    }

    /// Bold, code, a space after the colon and a quoted name with spaces: all ways the gateway
    /// itself accepts, so each must turn into a picture or a card.
    func testMediaMarksWrittenEveryWayTheGatewayAcceptsBecomeMedia() throws {
        try beginSideChat(saying: "media marks please")
        expectShown(text("from this morning"), within: 60, "the reply did not finish")
        let cards = app.descendants(matching: .any).matching(identifier: "file.card")
        XCTAssertTrue(poll(15) { cards.count == 2 }, "expected two file cards, found \(cards.count)")
        pause(2)
        look("media-marks")
        noMediaWords("the new chat")
        // Two pictures side by side must not push the thread wider than the screen.
        XCTAssertLessThanOrEqual(find("chat.more").frame.maxX, app.frame.maxX, "the chat is wider than the screen")
        app.swipeDown(velocity: .slow)
        look("media-marks-top")
        noMediaWords("the thread above")
    }
}
