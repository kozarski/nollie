import XCTest

/// Scheduled turns that end in the gateway's "say nothing" markers stay out of sight: the bot's row
/// shows the one real reply, its chat shows only that, and nothing is marked new. The same words in a
/// person's own message are just words. Needs the mock started with --silence-demo.
final class SilenceResultUITests: DemoCase {
    private func requireSilenceDemo() throws {
        try requireMock()
        guard mock("/api/_mock/silence")["enabled"] as? Bool == true else {
            throw XCTSkip("The mock was not started with --silence-demo")
        }
    }

    func testSilentTurnsLeaveOnlyTheRealReply() throws {
        try requireSilenceDemo()
        try startDemo()

        let row = find("bots.row.default")
        XCTAssertTrue(row.waitForExistence(timeout: 30))
        let preview = row.value as? String ?? ""
        XCTAssertTrue(preview.contains("Your report is ready."), "the row does not show the real reply: \(preview)")
        XCTAssertFalse(preview.contains("NO_REPLY") || preview.contains("[SILENT]"), "a marker leaked into the row")

        openBot("default")
        let reply = text("Your report is ready.")
        XCTAssertTrue(reply.waitForExistence(timeout: 20), "the real reply is not in the chat")
        XCTAssertFalse(find("thread.row.note").exists, "a quiet marker row showed")
        XCTAssertEqual(app.descendants(matching: .any).matching(identifier: "thread.row.reply").count, 1, "more than the one reply is shown")
        XCTAssertFalse(text("Board follow-through").exists || text("Price check").exists, "a silent scheduled turn left a heading")
        XCTAssertFalse(text("NO_REPLY").exists || text("[SILENT]").exists)
        XCTAssertLessThanOrEqual(reply.frame.maxY, chatField.frame.minY, "the reply sits under the composer")
        shot("silence-default-chat")

        tap("chat.back")
        XCTAssertTrue(find("bots.list").waitForExistence(timeout: 10))
        XCTAssertFalse((find("bots.row.default").value as? String ?? "").contains("new message"), "the row is marked new")
    }

    func testTheMarkersTypedByAPersonAreShownAsWritten() throws {
        try requireSilenceDemo()
        try startDemo()
        openBot("work")
        for words in ["[SILENT]", "NO_REPLY", "The marker [SILENT] is literal text.", "Your reminder is set."] {
            XCTAssertTrue(text(words).waitForExistence(timeout: 20), "\"\(words)\" is missing from the chat")
        }
        shot("silence-work-chat")
    }
}
