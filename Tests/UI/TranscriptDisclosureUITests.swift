import XCTest

/// The seeded Work conversation can disclose bot messages without leaving the chat.
@MainActor
final class TranscriptDisclosureUITests: XCTestCase {
    private var app: XCUIApplication!

    private func launch() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let address = environment["HERMES_E2E_URL"], let url = URL(string: address),
              url.scheme == "http", ["127.0.0.1", "localhost", "::1"].contains(url.host ?? ""),
              environment["HERMES_E2E_TOKEN"] == "mock-token" else {
            throw XCTSkip("Needs the local mock gateway and HERMES_E2E_TOKEN=mock-token")
        }
        let bundle = environment["HERMES_E2E_BUNDLE"] ?? "com.coreykozarski.nollie.demo"
        guard bundle.hasSuffix(".demo") else { throw XCTSkip("Disclosure checks run only in the demo copy") }
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        XCUIDevice.shared.appearance = .light
        app = XCUIApplication(bundleIdentifier: bundle)
        app.launchArguments = [
            "-nollie-demo-gateway", address, "mock-token", "Studio",
            "-launchTab", "chats", "-companionPromptShown", "YES",
            "-notificationsSetupCardDone", "YES", "-bots.animate", "NO",
            "-chat.showToolCalls", "YES", "-chat.showToolOutput", "YES",
            "-chat.groupSteps", "YES", "-chat.currentStepOnly", "NO", "-chat.collapseAfterTurn", "NO",
        ]
        app.launch()
        let work = app.descendants(matching: .any).matching(identifier: "bots.row.work").firstMatch
        XCTAssertTrue(work.waitForExistence(timeout: 30))
        work.tap()
        XCTAssertTrue(app.textViews["composer.text"].waitForExistence(timeout: 20))
    }

    private func wait(_ predicate: String, on element: XCUIElement, timeout: TimeInterval = 10,
                      file: StaticString = #filePath, line: UInt = #line) {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: predicate), object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: timeout), .completed, file: file, line: line)
    }

    private func shot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func element(_ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    private func reveal(_ element: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(element.waitForExistence(timeout: 10), file: file, line: line)
        for _ in 0..<4 {
            let upper = app.buttons["chat.titlePill"].firstMatch.frame.maxY + 8
            let lower = app.textViews["composer.text"].firstMatch.frame.minY - 16
            // A partly covered button can be hittable through the composer. Test a header
            // the person can actually see before checking that it remains in place.
            if element.isHittable, element.frame.minY >= upper, element.frame.maxY <= lower { return }
            if element.frame.minY < upper { app.swipeDown(velocity: .slow) }
            else { app.swipeUp(velocity: .slow) }
        }
        XCTAssertTrue(element.isHittable, "The disclosure is not reachable", file: file, line: line)
        XCTAssertLessThanOrEqual(element.frame.maxY, app.textViews["composer.text"].firstMatch.frame.minY - 16,
                                 "The disclosure is still covered by the composer", file: file, line: line)
    }

    private func assertHeaderStaysVisible(_ element: XCUIElement, near originalY: CGFloat,
                                         file: StaticString = #filePath, line: UInt = #line) {
        // Observe beyond the disclosure animation and its delayed geometry updates.
        let settledAfter = Date().addingTimeInterval(0.8)
        let settled = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            Date() >= settledAfter && element.isHittable && abs(element.frame.minY - originalY) < 24
        }, object: element)
        let result = XCTWaiter.wait(for: [settled], timeout: 6)
        XCTAssertEqual(result, .completed,
                       "Disclosure header moved from \(originalY) to \(element.frame.minY); hittable: \(element.isHittable)",
                       file: file, line: line)
    }

    func testMessagePillExpandsAndCollapsesWithoutOpeningAnotherChat() throws {
        try launch()
        let notices = app.buttons.matching(identifier: "bot.message.default.toggle")
        XCTAssertTrue(notices.firstMatch.waitForExistence(timeout: 20))
        let notice = try XCTUnwrap(notices.allElementsBoundByIndex.last(where: { $0.isHittable }))
        let title = app.buttons["chat.titlePill"].firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 10))
        let originalTitle = title.label
        let composer = app.textViews["composer.text"].firstMatch
        let originalDraft = composer.value as? String
        let body = app.staticTexts["bot.message.default.body"].firstMatch
        wait("value == 'Collapsed'", on: notice)
        XCTAssertFalse(body.exists)
        XCTAssertFalse(app.buttons["show message"].exists)
        shot("message-pill-collapsed")

        notice.tap()
        wait("value == 'Expanded'", on: notice)
        XCTAssertTrue(body.waitForExistence(timeout: 10))
        XCTAssertTrue(body.label.contains("nightly export"))
        XCTAssertTrue(composer.exists, "Opening a message must keep the conversation composer")
        XCTAssertEqual(title.label, originalTitle, "The message pill opened another bot's chat")
        XCTAssertEqual(composer.value as? String, originalDraft)
        XCTAssertFalse(app.buttons["hide message"].exists)
        shot("message-pill-expanded")

        notice.tap()
        wait("value == 'Collapsed'", on: notice)
        wait("exists == false", on: body)
        XCTAssertTrue(composer.exists)
        XCTAssertEqual(title.label, originalTitle)
        XCTAssertEqual(composer.value as? String, originalDraft)
        shot("message-pill-collapsed-again")
    }

    func testActivityKeepsEachStepsDetailsInsideItsDisclosure() throws {
        try launch()
        let run = app.buttons["thread.steps"].firstMatch
        XCTAssertTrue(run.waitForExistence(timeout: 20), "Start the local mock with --activity-demo")
        wait("value BEGINSWITH 'Collapsed, 3 steps'", on: run)
        let title = app.buttons["chat.titlePill"].firstMatch
        let originalTitle = title.label
        let terminal = app.buttons["activity.step.h-5-4"].firstMatch
        let terminalDetails = element("activity.details.h-5-4")
        let readDetails = element("activity.details.h-3-2")
        let searchDetails = element("activity.details.h-4-3")
        XCTAssertFalse(terminal.exists)
        shot("activity-collapsed")

        reveal(run)
        let runY = run.frame.minY
        run.tap()
        wait("value BEGINSWITH 'Expanded, 3 steps'", on: run)
        XCTAssertTrue(app.buttons["activity.step.h-3-2"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["activity.step.h-4-3"].exists)
        XCTAssertTrue(terminal.exists)
        XCTAssertFalse(terminalDetails.exists)
        XCTAssertFalse(readDetails.exists)
        XCTAssertFalse(searchDetails.exists)
        assertHeaderStaysVisible(run, near: runY)
        shot("activity-steps")

        reveal(terminal)
        let terminalY = terminal.frame.minY
        shot("activity-terminal-before-expansion")
        terminal.tap()
        wait("value == 'Expanded, Completed'", on: terminal)
        XCTAssertTrue(terminalDetails.waitForExistence(timeout: 10))
        XCTAssertTrue(terminalDetails.staticTexts["python3 -m pytest tests/test_export.py -q"].exists)
        XCTAssertTrue(terminalDetails.staticTexts["3 passed in 0.42s\nExport checks passed."].exists)
        XCTAssertFalse(readDetails.exists, "Only the chosen step should expand")
        XCTAssertFalse(searchDetails.exists, "Only the chosen step should expand")
        XCTAssertEqual(title.label, originalTitle)
        XCTAssertTrue(app.textViews["composer.text"].exists)
        assertHeaderStaysVisible(terminal, near: terminalY)
        shot("activity-terminal-details")

        let full = app.buttons["activity.full.h-5-4"].firstMatch
        reveal(full)
        full.tap()
        let fullText = app.textViews.matching(NSPredicate(format: "value CONTAINS %@", "3 passed in 0.42s")).firstMatch
        XCTAssertTrue(fullText.waitForExistence(timeout: 10), "Full details must include the raw output")
        let fullValue = try XCTUnwrap(fullText.value as? String)
        XCTAssertTrue(fullValue.contains("\"cwd\""), "Full details must keep the working directory argument")
        XCTAssertTrue(fullValue.contains("~/Projects/exports"))
        XCTAssertTrue(fullValue.contains("\"timeout\""), "Full details must keep the timeout argument")
        XCTAssertTrue(fullValue.contains("30"))
        shot("activity-full-details")
        app.buttons["Done"].firstMatch.tap()
        wait("exists == false", on: fullText)

        reveal(terminal)
        terminal.tap()
        wait("value == 'Collapsed, Completed'", on: terminal)
        wait("exists == false", on: terminalDetails)
        XCTAssertTrue(app.buttons["activity.step.h-3-2"].exists)
        reveal(run)
        run.tap()
        wait("value BEGINSWITH 'Collapsed, 3 steps'", on: run)
        wait("exists == false", on: terminal)
        XCTAssertEqual(title.label, originalTitle)
        XCTAssertTrue(app.textViews["composer.text"].exists)
        shot("activity-collapsed-again")
    }
}
