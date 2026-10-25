import XCTest

/// Nollie's cards in the default bot's main chat on the new chat view: the night shift card and its share picture,
/// then the rehearsal card turned on, in light and dark. Each launch starts from fresh posts at the end of the
/// chat (`POST /api/_mock/night-shift`). Uses only the demo copy and the local mock gateway.
@MainActor
final class NightShiftUITests: XCTestCase {
    private var app: XCUIApplication!

    private func launch(dark: Bool) throws {
        let env = ProcessInfo.processInfo.environment
        guard let address = env["HERMES_E2E_URL"], let url = URL(string: address), url.scheme == "http",
              ["127.0.0.1", "localhost", "::1"].contains(url.host ?? ""), env["HERMES_E2E_TOKEN"] == "mock-token" else {
            throw XCTSkip("Needs the local mock gateway and HERMES_E2E_TOKEN=mock-token")
        }
        let bundle = env["HERMES_E2E_BUNDLE"] ?? "com.coreykozarski.nollie.demo"
        guard bundle.hasSuffix(".demo") else { throw XCTSkip("Runs only in the demo copy") }
        continueAfterFailure = false
        try resetPosts(address)
        XCUIDevice.shared.orientation = .portrait
        XCUIDevice.shared.appearance = dark ? .dark : .light
        app = XCUIApplication(bundleIdentifier: bundle)
        app.launchArguments = ["-nollie-demo-gateway", address, "mock-token", "Studio",
                               "-companionPromptShown", "YES", "-notificationsSetupCardDone", "YES", "-bots.animate", "NO",
                               "-nollie.developerMode", "YES", "-nollie.newChatView", "YES",
                               "-colorSchemePreference", dark ? "dark" : "light"]
        app.launch()
    }

    /// Both posts as new, stamped just after the main chat's newest row.
    private func resetPosts(_ address: String) throws {
        var request = URLRequest(url: try XCTUnwrap(URL(string: address + "/api/_mock/night-shift")))
        request.httpMethod = "POST"
        request.timeoutInterval = 5
        let done = expectation(description: "posts reset")
        var status = 0
        URLSession.shared.dataTask(with: request) { _, response, _ in
            status = (response as? HTTPURLResponse)?.statusCode ?? 0
            done.fulfill()
        }.resume()
        wait(for: [done], timeout: 8)
        XCTAssertEqual(status, 200, "the mock gateway reset its posts")
    }

    private func any(_ id: String) -> XCUIElement { app.descendants(matching: .any).matching(identifier: id).firstMatch }

    private func text(containing words: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", words)).firstMatch
    }

    private func shot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// Scrolls the chat until `element` is wholly on screen between the header and the composer.
    private func reveal(_ element: XCUIElement, in list: XCUIElement, _ what: String) {
        // A cell off screen is not in the tree yet: scroll towards the newest end until it is.
        for _ in 0..<10 where !element.waitForExistence(timeout: 3) {
            let low = list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.7))
            low.press(forDuration: 0.05, thenDragTo: list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.35)))
        }
        XCTAssertTrue(element.waitForExistence(timeout: 30), "\(what) is in the chat")
        for _ in 0..<12 {
            let frame = element.frame, room = list.frame
            // Clear of the header above and the composer below.
            if element.isHittable, frame.minY >= room.minY + 120, frame.maxY <= room.maxY - 100 { return }
            // A short drag with no fling, towards the middle of the room.
            let middle = list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            let dy = max(min(room.midY - frame.midY, 280), -280)
            middle.press(forDuration: 0.05, thenDragTo: middle.withOffset(CGVector(dx: 0, dy: dy)))
        }
        XCTAssertTrue(element.isHittable, "\(what) can be reached")
    }

    func testNightShiftAndRehearsalCards() throws {
        for dark in [false, true] {
            try launch(dark: dark)
            let scheme = dark ? "dark" : "light"
            let row = any("bots.row.default")
            XCTAssertTrue(row.waitForExistence(timeout: 30))
            row.tap()
            let list = any("conversation.list")
            XCTAssertTrue(list.waitForExistence(timeout: 20), "the main chat opens on the new screen")

            // The night shift card, its counts and its receipts.
            let night = any("post.nightShift")
            reveal(night, in: list, "the night shift card")
            XCTAssertTrue(text(containing: "Night shift").exists)
            XCTAssertTrue(app.staticTexts["2 runs · 5 actions · 1 stopped"].exists, "the counts")
            XCTAssertTrue(text(containing: "Export health check").exists, "the second run")
            let stopped = app.descendants(matching: .any)
                .matching(NSPredicate(format: "label == %@", "Tried to use the screen for screenshot. Stopped: schedules never use your Mac's screen.")).firstMatch
            XCTAssertTrue(stopped.exists, "the stopped action reads as one sentence")
            shot("night-shift-\(scheme)")

            // Share: the picture to be shared, then closed again.
            // A tall card can leave its top under the header: bring the button itself into view.
            let share = any("post.nightShift.share")
            reveal(share, in: list, "the Share button")
            share.tap()
            let preview = any("share.preview")
            XCTAssertTrue(preview.waitForExistence(timeout: 15), "the share picture")
            XCTAssertTrue(any("share.send").exists, "the Share button")
            XCTAssertGreaterThan(preview.frame.height, 300, "the picture is drawn at full size")
            shot("night-shift-share-\(scheme)")
            any("share.close").tap()
            XCTAssertTrue(preview.waitForNonExistence(timeout: 10), "the sheet closes")

            // The rehearsal card, then Turn on.
            let rehearsal = any("post.rehearsal")
            reveal(rehearsal, in: list, "the rehearsal card")
            XCTAssertTrue(text(containing: "Nightly export").exists, "the schedule's title")
            XCTAssertTrue(app.staticTexts["Would have"].exists && app.staticTexts["Looked at"].exists)
            let turnOn = any("post.rehearsal.turnOn")
            XCTAssertTrue(any("post.rehearsal.keepOff").exists)
            reveal(turnOn, in: list, "Turn on")
            shot("rehearsal-\(scheme)")
            turnOn.tap()
            let done = any("post.rehearsal.done")
            XCTAssertTrue(done.waitForExistence(timeout: 15), "the add-on's answer replaces the buttons")
            XCTAssertEqual(done.label, "On. It runs for real from now on.")
            XCTAssertFalse(any("post.rehearsal.turnOn").exists, "no second Turn on")
            reveal(done, in: list, "the answer")
            shot("rehearsal-on-\(scheme)")
            app.terminate()
        }
    }
}
