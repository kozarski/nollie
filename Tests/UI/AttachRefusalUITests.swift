import XCTest

/// A PDF sent to a gateway that has no way to read PDFs. The person is told what is missing and
/// what still works, the gateway's own words stay with it for anyone who needs them, and the message
/// itself still goes. Needs the mock started with --no-pdf-tools; the flow skips on any other.
final class AttachRefusalUITests: DemoCase {
    func testAPdfTheGatewayCannotReadIsExplainedPlainly() throws {
        try startDemo(["-nollie-test-stage", "report.pdf"])
        openBot("default")
        startSideChat()
        XCTAssertTrue(labelled("report.pdf").waitForExistence(timeout: 10), "the staged PDF is not shown over the composer")

        send("card: summarize the report")
        XCTAssertTrue(text("card: summarize the report").waitForExistence(timeout: 20), "the message itself did not go")

        let explanation = text("missing the tool it reads PDFs")
        guard explanation.waitForExistence(timeout: 20) else {
            throw XCTSkip("The mock took the PDF, so it was not started with --no-pdf-tools")
        }
        XCTAssertTrue(text("Pictures and text files").exists, "nothing said about what can still be sent")
        XCTAssertTrue(text("pdftoppm is not installed").exists, "the gateway's own words were dropped")
        shot("attach-refusal")
    }
}
