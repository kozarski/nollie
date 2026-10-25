import XCTest

/// Dragging a Board card between lanes. On an iPad in landscape all three lanes are side by side:
/// a new task dragged from Pending to Blocked asks why, keeps the reason on its card, and moves
/// the counts. The task is deleted afterwards. Skips on a phone, where the lanes are paged.
final class BoardDragUITests: DemoCase {
    private let title = "Dragged test task"

    /// The number in a lane's heading ("Blocked 3" reads as one element).
    private func laneCount(_ lane: String) -> Int {
        let heading = find("board.group.\(lane)")
        guard heading.exists else { return -1 }
        return heading.label.split(separator: " ").compactMap { Int($0) }.last ?? -1
    }

    func testDraggingATaskToBlockedAsksWhyAndCountsIt() throws {
        try requireMock()
        guard UIDevice.current.userInterfaceIdiom == .pad else { throw XCTSkip("The lanes sit side by side only on an iPad") }

        let made = mock("/api/plugins/kanban/tasks", ["title": title, "assignee": "default"])
        let id = (made["task"] as? [String: Any])?["id"] as? String ?? ""
        XCTAssertFalse(id.isEmpty, "the mock made no task")
        addTeardownBlock { [self] in _ = mock("/api/plugins/kanban/tasks/\(id)", nil, method: "DELETE") }

        turnToLandscape()
        try startDemo(portrait: false)
        openBoard()

        let card = find("board.task.\(id)")
        XCTAssertTrue(card.waitForExistence(timeout: 20), "the new task is not on the Board")
        let blockedBefore = laneCount("blocked")
        let attentionBefore = Int(find("chats.board.reviewCount").label) ?? 0

        let lane = find("board.group.blocked").coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 6))
        dragElement(card, to: lane)

        XCTAssertTrue(app.alerts["Block this task"].waitForExistence(timeout: 10), "no question about why")
        let reason = app.alerts.textFields.firstMatch
        reason.tap()
        reason.typeText("Waiting for the export")
        app.alerts.buttons["Block"].tap()

        XCTAssertTrue(poll(20) { self.laneCount("blocked") == blockedBefore + 1 }, "the Blocked count did not go up")
        XCTAssertTrue(text("Waiting for the export").waitForExistence(timeout: 10), "the reason is not on the card")
        XCTAssertEqual(Int(find("chats.board.reviewCount").label) ?? 0, attentionBefore + 1, "the attention count did not go up")
        shot("board-drag-blocked")
    }

    private func turnToLandscape() {
        XCUIDevice.shared.orientation = .landscapeLeft
        addTeardownBlock { XCUIDevice.shared.orientation = .portrait }
    }
}
