import XCTest

/// The morning's Night shift in the chat people get (the chat view release builds open): a capsule at the top of
/// Nollie's main chat, the whole card behind it with a Why? on each step, and its cross putting it away until the
/// next morning's card, in light and dark. Each look starts from a fresh card stamped now
/// (`POST /api/_mock/night-shift`). Uses only the demo copy and the local mock gateway.
final class NightShiftMorningUITests: DemoCase {
    /// Shows the capsule whatever an earlier run put away.
    private static let nothingPutAway = ["-nollie.nightShift.putAway", "<date>2000-01-01T00:00:00Z</date>"]

    func testTheMorningCardInTheMainChat() throws {
        try requireMock()
        try inBothLooks { look in
            Self.resetMock("api/_mock/night-shift", [:])
            try startDemo(Self.nothingPutAway, look: look, nightCard: true)
            openBot("default")

            // The capsule: calm, a few words, at the top of the thread.
            let capsule = expectShown(find("night.card"), within: 30, "the morning's capsule in the main chat")
            XCTAssertTrue(capsule.label.contains("Night shift"), "it is named: \(capsule.label)")
            XCTAssertEqual(capsule.value as? String, "2 jobs overnight", "the night in a few words")
            XCTAssertTrue(find("night.card.putAway").exists, "it can be put away")
            XCTAssertFalse(find("post.nightShift").exists, "only the capsule shows in the chat, not the whole card")
            shot("night-capsule-\(look)")

            // The whole card, with a Why? beside each step.
            capsule.tap()
            expectShown(find("night.page"), within: 15, "the full Night shift view")
            expectShown(find("post.nightShift"), "the whole card")
            let whys = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'post.nightShift.why.' AND NOT identifier ENDSWITH '.text'"))
            let why = try XCTUnwrap(touchable(whys, timeout: 15), "a Why? beside a step")
            XCTAssertGreaterThanOrEqual(whys.count, 5, "one Why? for each step of both runs")
            shot("night-sheet-\(look)")
            let answerID = why.identifier + ".text"
            why.tap()
            let answer = expectShown(find(answerID), "the answer to Why?")
            XCTAssertFalse(answer.label.isEmpty, "the answer has words")
            shot("night-why-\(look)")
            tap("night.done")
            XCTAssertTrue(find("night.page").waitForNonExistence(timeout: 10), "Done closes the view")

            // Put away: gone now, and still gone on the next launch, until the next morning's card.
            tap("night.card.putAway")
            XCTAssertTrue(find("night.card").waitForNonExistence(timeout: 10), "the cross puts it away")
            shot("night-capsule-away-\(look)")
            try startDemo(look: look, nightCard: true)
            openBot("default")
            pause(6)
            XCTAssertFalse(find("night.card").exists, "a card put away stays away for the morning")
        }
    }
}
