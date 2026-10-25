import XCTest

/// Exercises display preferences and saved-message routes only in the local demo.
@MainActor
final class NotificationPreviewUITests: XCTestCase {
    private var app: XCUIApplication!

    private func configure() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let address = environment["HERMES_E2E_URL"], let url = URL(string: address),
              url.scheme == "http", ["127.0.0.1", "localhost", "::1"].contains(url.host ?? ""),
              environment["HERMES_E2E_TOKEN"] == "mock-token" else {
            throw XCTSkip("Notification preview checks need the local mock gateway")
        }
        let bundle = environment["HERMES_E2E_BUNDLE"] ?? "com.coreykozarski.nollie.demo"
        guard bundle.hasSuffix(".demo") else {
            throw XCTSkip("Notification preview checks run only in the demo copy")
        }
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        XCUIDevice.shared.appearance = .light
        app = XCUIApplication(bundleIdentifier: bundle)
        app.launchArguments = [
            "-nollie-demo-gateway", address, "mock-token", "Studio", "-launchTab", "chats",
            "-companionPromptShown", "YES", "-notificationsSetupCardDone", "YES",
            "-bots.animate", "NO", "-nollie.developerMode", "NO",
        ]
        // Do not pass notifications.showMessagePreviews here: a launch override would
        // hide whether changing the switch was actually saved between processes.
    }

    @discardableResult
    private func visible(_ element: XCUIElement, timeout: TimeInterval = 15,
                         file: StaticString = #filePath, line: UInt = #line) -> XCUIElement {
        if element.exists, element.isHittable { return element }
        XCTAssertTrue(element.waitForExistence(timeout: timeout), file: file, line: line)
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "hittable == true"), object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: timeout), .completed, file: file, line: line)
        return element
    }

    private var previews: XCUIElement { app.switches["notifications.previews"].firstMatch }

    private func openNotifications() {
        visible(app.buttons["chats.settings"].firstMatch, timeout: 30).tap()
        visible(app.buttons["settings.row.notifications"].firstMatch).tap()
        visible(previews)
        XCTAssertTrue(previews.label.contains("Hide notification details"))
    }

    private func assertPreview(_ enabled: Bool, file: StaticString = #filePath, line: UInt = #line) {
        let expected = enabled ? "0" : "1"
        if previews.value as? String == expected { return }
        let matches = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", expected), object: previews)
        XCTAssertEqual(XCTWaiter.wait(for: [matches], timeout: 10), .completed,
                       "The message preview choice was not retained", file: file, line: line)
    }

    private func setPreview(_ enabled: Bool) {
        visible(previews)
        let value = previews.value as? String
        XCTAssertTrue(value == "0" || value == "1", "Expected the actual preview switch")
        if value != (enabled ? "0" : "1") {
            // SwiftUI exposes both the whole labelled row and its native switch. The
            // row's centre is the label, so target the switch inside its measured bounds.
            let row = previews.frame
            let controls = app.switches.allElementsBoundByIndex.filter {
                $0.frame.width > 0 && $0.frame.width < row.width && row.contains($0.frame)
            }
            XCTAssertEqual(controls.count, 1, "Expected one native preview switch within the labelled row")
            guard let control = controls.first else { return }
            visible(control).tap()
        }
        assertPreview(enabled)
    }

    private func shot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func assertDraft(_ expected: String, file: StaticString = #filePath, line: UInt = #line) {
        let composer = app.textViews["composer.text"].firstMatch
        if composer.value as? String == expected { return }
        let matches = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", expected), object: composer)
        XCTAssertEqual(XCTWaiter.wait(for: [matches], timeout: 10), .completed,
                       "Opening a saved reply must preserve the unsent draft", file: file, line: line)
    }

    private func processIdentity() throws -> String {
        let description = app.debugDescription
        let range = try XCTUnwrap(description.range(of: #"pid:\s*\d+"#, options: .regularExpression),
                                  "The demo snapshot must identify its running process")
        return String(description[range])
    }

    private func openRoute(_ address: String, process: String) throws {
        app.open(try XCTUnwrap(URL(string: address)))
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
        XCTAssertEqual(try processIdentity(), process, "The notification must reach the already-running demo")
    }

    private func assertFocusedReply(contains text: String, excludes other: String,
                                    file: StaticString = #filePath, line: UInt = #line) {
        let target = app.descendants(matching: .any).matching(identifier: "notification.message.target").firstMatch
        visible(target, file: file, line: line)
        let matching = target.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
        XCTAssertTrue(matching.waitForExistence(timeout: 10), "The highlighted row is not the requested saved reply", file: file, line: line)
        XCTAssertFalse(target.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", other)).firstMatch.exists,
                       "The route substituted another reply", file: file, line: line)
        XCTAssertFalse(app.descendants(matching: .any).matching(identifier: "notification.message.unavailable").firstMatch.exists,
                       file: file, line: line)
    }

    private nonisolated static func messages(_ base: URL, session: String) async throws -> Data {
        var request = URLRequest(url: base.appendingPathComponent("api/sessions/\(session)/messages"))
        request.timeoutInterval = 10
        request.setValue("Bearer mock-token", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        return data
    }

    func testMessagePreviewChoicePersistsWithoutEnablingAlerts() throws {
        try configure()
        app.launch()
        openNotifications()
        setPreview(true)
        setPreview(false)

        app.terminate()
        app.launch()
        openNotifications()
        assertPreview(false)
        shot("notification-previews-disabled")

        setPreview(true)
        app.terminate()
        app.launch()
        openNotifications()
        assertPreview(true)
        shot("notification-previews-enabled")
    }

    func testHistoricalNotificationFindsExactReplyWithoutSendingOrReplacingDraft() async throws {
        try configure()
        let base = try XCTUnwrap(URL(string: ProcessInfo.processInfo.environment["HERMES_E2E_URL"] ?? ""))
        let work = "20260930_221000_work01"
        let historical = "20260921_093355_d4e5f6"
        let workBefore = try await Self.messages(base, session: work)
        let historyBefore = try await Self.messages(base, session: historical)
        app.launch()
        visible(app.descendants(matching: .any).matching(identifier: "bots.row.work").firstMatch, timeout: 30).tap()
        let composer = visible(app.textViews["composer.text"].firstMatch, timeout: 30)
        var draft = composer.value as? String ?? ""
        if draft.isEmpty {
            composer.tap()
            XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 10))
            for character in "Keep my unsent notification draft." {
                composer.typeText(String(character)); draft.append(character); assertDraft(draft)
            }
        }
        let process = try processIdentity()
        let route = "nollie://demo-notification?session=\(historical)&profile=default&row="
        let older = "I'll look at what's filling the disk"
        let later = "4.2 GB freed"
        try openRoute(route + "2", process: process)
        assertFocusedReply(contains: older, excludes: later)
        shot("notification-historical-reply")

        try openRoute(route + "5", process: process)
        assertFocusedReply(contains: later, excludes: older)
        try openRoute(route + "2", process: process)
        assertFocusedReply(contains: older, excludes: later)
        shot("notification-repeat-exact-reply")

        try openRoute(route + "999999", process: process)
        visible(app.descendants(matching: .any).matching(identifier: "notification.message.unavailable").firstMatch)
        XCTAssertFalse(app.descendants(matching: .any).matching(identifier: "notification.message.target").firstMatch.exists,
                       "A missing reply must not highlight a different message")
        shot("notification-missing-reply")

        try openRoute("nollie://chat/\(work)?profile=work", process: process)
        visible(app.textViews["composer.text"].firstMatch)
        assertDraft(draft)
        XCTAssertFalse(app.descendants(matching: .any).matching(identifier: "thread.typing").firstMatch.exists)
        let workAfter = try await Self.messages(base, session: work)
        let historyAfter = try await Self.messages(base, session: historical)
        XCTAssertEqual(workAfter, workBefore, "Notification navigation must not send the existing draft")
        XCTAssertEqual(historyAfter, historyBefore, "Opening an older reply must not add a message")
        shot("notification-draft-preserved")
    }
}
