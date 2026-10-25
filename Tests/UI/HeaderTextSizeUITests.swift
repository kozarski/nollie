import XCTest

/// At the largest accessibility text size, with a long chat title, the header still fits: Back keeps
/// clear of the edge, the title plate sits between the controls and inside the other edge, the menu
/// circle stays on screen, and Back still leaves the chat.
final class HeaderTextSizeUITests: DemoCase {
    func testALongTitleAtTheLargestTextSizeFitsTheHeader() throws {
        try startDemo(["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"])
        openBot("default")
        // The main chat's own title is long enough to be cut short at this size.
        XCTAssertTrue(poll(10) { self.find("chat.titlePill").label.contains("Disk cleanup") }, "the main chat has no long title")

        let edge = app.windows.firstMatch.frame
        let back = find("chat.back").frame
        let plate = find("chat.titlePill").frame
        let more = find("chat.more").frame
        XCTAssertGreaterThanOrEqual(back.minX, 12, "Back crowds the leading edge")
        XCTAssertGreaterThanOrEqual(plate.minX, back.maxX, "the title plate starts before Back ends")
        XCTAssertLessThanOrEqual(plate.maxX, edge.maxX - 12, "the title plate runs to the trailing edge")
        XCTAssertLessThanOrEqual(more.maxX, edge.maxX, "the menu circle leaves the screen")
        shot("header-large-text")

        tap("chat.back")
        XCTAssertTrue(find("bots.list").waitForExistence(timeout: 10), "Back did not leave the chat")
    }
}
