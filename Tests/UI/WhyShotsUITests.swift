import XCTest

/// Pictures of "Why?" opened on the night shift card, the rehearsal card and a Papertrail entry, in light and dark.
/// Uses only the demo copy and the local mock gateway. Not a golden flow: it proves the look, the words are in
/// NollieTests/WhyTests.
final class WhyShotsUITests: DemoCase {
    /// Both posts as new, stamped just after the main chat's newest row.
    private func resetPosts() throws {
        let (address, _) = try requireMock()
        var request = URLRequest(url: try XCTUnwrap(URL(string: address + "/api/_mock/night-shift")))
        request.httpMethod = "POST"
        request.timeoutInterval = 5
        let done = expectation(description: "posts reset")
        URLSession.shared.dataTask(with: request) { _, _, _ in done.fulfill() }.resume()
        wait(for: [done], timeout: 8)
    }

    /// Scrolls the chat until `element` sits clear of the header and the composer.
    private func reveal(_ element: XCUIElement, in list: XCUIElement) {
        for _ in 0..<10 where !element.waitForExistence(timeout: 3) {
            let low = list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.7))
            low.press(forDuration: 0.05, thenDragTo: list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.35)))
        }
        XCTAssertTrue(element.waitForExistence(timeout: 20))
        for _ in 0..<12 {
            let frame = element.frame, room = list.frame
            if element.isHittable, frame.minY >= room.minY + 120, frame.maxY <= room.maxY - 140 { return }
            let middle = list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            let dy = max(min(room.midY - frame.midY, 280), -280)
            middle.press(forDuration: 0.05, thenDragTo: middle.withOffset(CGVector(dx: 0, dy: dy)))
        }
    }

    func testWhyOnTheNightShiftAndRehearsalCards() throws {
        try inBothLooks { look in
            try resetPosts()
            try startDemo(["-nollie.developerMode", "YES", "-nollie.newChatView", "YES"], look: look)
            find("bots.row.default").tap()
            let list = find("conversation.list")
            XCTAssertTrue(list.waitForExistence(timeout: 20), "the main chat opens on the new screen")

            // The Always on the morning brief, and the screen the export check was stopped from using.
            let always = find("post.nightShift.why.cron:morning-brief:e-80.2")
            reveal(always, in: list)
            always.tap()
            XCTAssertTrue(find("post.nightShift.why.cron:morning-brief:e-80.2.text").waitForExistence(timeout: 5), "the answer opens")
            let stopped = find("post.nightShift.why.cron:export-health:e-41.1")
            reveal(stopped, in: list)
            stopped.tap()
            XCTAssertTrue(find("post.nightShift.why.cron:export-health:e-41.1.text").waitForExistence(timeout: 5))
            reveal(find("post.nightShift.why.cron:export-health:e-41.1.text"), in: list)
            pause(1)
            shot("why-night-shift-\(look.rawValue)")

            let held = find("post.rehearsal.why.held.1")
            reveal(held, in: list)
            held.tap()
            XCTAssertTrue(find("post.rehearsal.why.held.1.text").waitForExistence(timeout: 5))
            reveal(find("post.rehearsal.why.held.1.text"), in: list)
            pause(1)
            shot("why-rehearsal-\(look.rawValue)")
        }
    }

    func testWhyOnPapertrail() throws {
        try inBothLooks { look in
            try startDemo(["-nollie-demo-tab", "chats", "-nollie-demo-bot-page", "settings"], look: look, waitForBots: false)
            let tab = find("profile.tab.papertrail")
            XCTAssertTrue(tab.waitForExistence(timeout: 30), "no Papertrail tab")
            let stayed = find("papertrail.stayed")
            for _ in 0..<3 {
                pause(1)
                if !tab.isHittable { find("profile.tabs").swipeLeft() }
                tab.tap()
                if stayed.waitForExistence(timeout: 8) { break }
            }
            let why = find("papertrail.why.0")
            for _ in 0..<4 where !why.isHittable { app.swipeUp(velocity: .slow) }
            why.tap()
            XCTAssertTrue(find("papertrail.why.0.text").waitForExistence(timeout: 5), "the answer opens")
            let second = find("papertrail.why.1")
            if second.isHittable { second.tap() }
            pause(1)
            shot("why-papertrail-\(look.rawValue)")
            // An entry kept before reasons were: the honest fallback.
            let old = find("papertrail.why.9")
            for _ in 0..<8 where !old.isHittable { app.swipeUp(velocity: .slow) }
            if old.isHittable {
                old.tap()
                XCTAssertTrue(find("papertrail.why.9.text").waitForExistence(timeout: 5))
                pause(1)
                shot("why-papertrail-old-\(look.rawValue)")
            }
        }
    }
}
