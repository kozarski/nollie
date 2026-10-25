import XCTest

/// A reply that names files gets a card under it for each one, and none for a folder.
/// The plumbing line is not in the words, a card opens a preview named for the file, and
/// once it has been fetched the card tells its size.
final class FileCardsUITests: DemoCase {
    func testAReplyWithTwoFilesShowsTwoCards() throws {
        try beginSideChat(saying: "files for the report please")
        XCTAssertTrue(text("The report is ready").waitForExistence(timeout: 30), "no reply")
        XCTAssertTrue(text("raw numbers").exists, "the link's words are missing")
        XCTAssertFalse(text("MEDIA:").exists, "the file line is shown as words")

        let cards = app.descendants(matching: .any).matching(identifier: "file.card")
        XCTAssertTrue(poll(15) { cards.count == 2 }, "expected two file cards, found \(cards.count)")
        let pdf = cards.element(matching: NSPredicate(format: "label CONTAINS %@", "report.pdf"))
        XCTAssertTrue(pdf.exists, "no card for report.pdf")
        XCTAssertTrue(cards.element(matching: NSPredicate(format: "label CONTAINS %@", "raw numbers.csv")).exists, "no card for the CSV")

        pdf.tap()
        // The system's preview, titled with the file's name without its extension.
        let preview = app.navigationBars["report"]
        XCTAssertTrue(preview.waitForExistence(timeout: 30), "no preview named for the file")
        shot("file-card-preview")
        find("QLOverlayDoneButtonAccessibilityIdentifier").tap()
        XCTAssertTrue(poll(15) { !preview.exists }, "the preview stayed after Close")

        let sized = cards.element(matching: NSPredicate(format: "label CONTAINS %@ AND NOT label CONTAINS %@", "report.pdf", "to download"))
        XCTAssertTrue(sized.waitForExistence(timeout: 15), "the card does not show a size after opening")
    }
}
