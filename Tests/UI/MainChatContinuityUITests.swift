import XCTest

/// A long main chat that Hermes shortens carries on in place: one quiet "summarized" row above the
/// reply, no advice to start a new chat, and none of Hermes's own compression lines.
final class MainChatContinuityUITests: DemoCase {
    func testACompressedChatCarriesOnQuietly() throws {
        try requireMock()
        try inBothLooks { look in
            try startDemo(look: look)
            openBot("default")

            send("compress")
            let reply = text("Carrying on")
            XCTAssertTrue(reply.waitForExistence(timeout: 30), "the reply did not arrive in the same chat")

            let summarized = texts("Earlier messages summarized")
            XCTAssertEqual(summarized.count, 1, "one quiet row, however many progress lines Hermes sends")
            XCTAssertLessThan(summarized.firstMatch.frame.minY, reply.frame.minY, "the row belongs above the reply it came before")
            let hermesWords = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS '/new' OR label CONTAINS 'Compacting'"))
            XCTAssertEqual(hermesWords.count, 0, "Hermes's own compression lines must never show")
            shot("main-chat-compressed-\(look)")
        }
    }
}
