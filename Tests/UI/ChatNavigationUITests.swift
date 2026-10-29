import XCTest

/// Chats stays home while Board, Settings and a bot's computer open around it.
/// Uses only the demo copy and the local mock gateway, without sending a message.
@MainActor
final class ChatNavigationUITests: XCTestCase {
    private var app: XCUIApplication!

    /// One mock gateway serves every flow in a run, so a case that stops early still leaves no helper
    /// using the computer for the flows after it.
    override func tearDownWithError() throws {
        DemoCase.resetMock("api/_mock/computer-preview", ["state": "idle", "active": false, "held": false])
        try super.tearDownWithError()
    }

    private func launch(_ extra: [String] = []) throws {
        let env = ProcessInfo.processInfo.environment
        guard let address = env["HERMES_E2E_URL"],
              let url = URL(string: address), url.scheme == "http",
              ["127.0.0.1", "localhost", "::1"].contains(url.host ?? ""),
              env["HERMES_E2E_TOKEN"] == "mock-token" else {
            throw XCTSkip("Needs the local mock gateway and HERMES_E2E_TOKEN=mock-token")
        }
        let bundle = env["HERMES_E2E_BUNDLE"] ?? "com.coreykozarski.nollie.demo"
        guard bundle.hasSuffix(".demo") else {
            throw XCTSkip("Navigation checks run only in the demo copy")
        }
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        XCUIDevice.shared.appearance = .light
        app = XCUIApplication(bundleIdentifier: bundle)
        app.launchArguments = [
            "-nollie-demo-gateway", address, "mock-token", "Studio",
            "-companionPromptShown", "YES", "-notificationsSetupCardDone", "YES",
            "-bots.animate", "NO",
        ] + DemoCase.weeklyCardPutAway + extra
        app.launch()
        _ = try visible("bots.list", timeout: 30)
        _ = try visible("bots.row.work", timeout: 30)
    }

    /// Pages the Board's lanes the way a person does, across the lane headings: a swipe that
    /// starts on a card belongs to the card.
    private func swipeLanes(left: Bool) {
        let list = element("board.list").frame
        let y = list.minY + 70
        let origin = app.coordinate(withNormalizedOffset: .zero)
        let near = origin.withOffset(CGVector(dx: list.minX + list.width * 0.15, dy: y))
        let far = origin.withOffset(CGVector(dx: list.minX + list.width * 0.85, dy: y))
        if left { far.press(forDuration: 0.05, thenDragTo: near) } else { near.press(forDuration: 0.05, thenDragTo: far) }
    }

    private func element(_ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    @discardableResult
    private func visible(_ id: String, timeout: TimeInterval = 10,
                         file: StaticString = #filePath, line: UInt = #line) throws -> XCUIElement {
        let target = element(id)
        if target.exists, target.isHittable { return target }
        XCTAssertTrue(target.waitForExistence(timeout: timeout), "Missing \(id)", file: file, line: line)
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "hittable == true"), object: target)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: timeout), .completed,
                       "\(id) is not reachable", file: file, line: line)
        return target
    }

    private func tap(_ id: String, file: StaticString = #filePath, line: UInt = #line) throws {
        try visible(id, file: file, line: line).tap()
    }

    private func scrollTo(_ id: String, file: StaticString = #filePath, line: UInt = #line) throws -> XCUIElement {
        let target = element(id)
        for _ in 0..<10 {
            if target.exists, target.isHittable { return target }
            app.swipeUp(velocity: .slow)
        }
        return try visible(id, timeout: 3, file: file, line: line)
    }

    private func shot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func assertDraft(_ text: String, file: StaticString = #filePath, line: UInt = #line) {
        let field = app.textViews["composer.text"].firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 15), "The conversation did not return", file: file, line: line)
        let restored = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", text), object: field)
        XCTAssertEqual(XCTWaiter.wait(for: [restored], timeout: 10), .completed,
                       "The unsent message changed while another page was open", file: file, line: line)
    }

    func testAnOldHomePreferenceStillOpensChatsAndBoardComesBack() throws {
        try launch(["-launchTab", "dashboard"])
        _ = try visible("chats.settings")
        _ = try visible("chats.board", timeout: 30)
        XCTAssertFalse(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'tab.'")).firstMatch.exists,
                       "The old tab bar is still in Chats")
        XCTAssertEqual(app.tabBars.count, 0)
        let board = try visible("chats.board")
        let helpBadge = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == '4 tasks needing your help'"), object: board)
        XCTAssertEqual(XCTWaiter.wait(for: [helpBadge], timeout: 15), .completed,
                       "Board should count four tasks needing help, excluding routine review")
        shot("navigation-chats")

        try tap("chats.board")
        _ = try visible("board.close")
        let blocked = try visible("board.group.blocked", timeout: 20)
        XCTAssertTrue(blocked.label.contains("Blocked"))
        let blockedTask = try visible("board.task.k-104", timeout: 20)
        XCTAssertTrue(blockedTask.label.contains("Weekly dependency audit"))
        shot("navigation-board")
        try tap("board.close")
        _ = try visible("chats.settings")
        _ = try visible("bots.row.work")
        XCTAssertFalse(element("board.close").exists)
    }

    func testThreeBoardLanesKeepCompletedAndBlockedTasksReachable() throws {
        try launch(["-launchTab", "chats"])
        try tap("chats.board")
        let blocked = try visible("board.group.blocked", timeout: 20)
        let navigationBar = app.navigationBars.firstMatch
        XCTAssertLessThan(blocked.frame.minY - navigationBar.frame.maxY, 60,
                          "The Board should start just below its toolbar")
        let firstCard = try visible("board.task.k-104")
        let laneSettled = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            self.app.frame.contains(firstCard.frame)
        }, object: firstCard)
        XCTAssertEqual(XCTWaiter.wait(for: [laneSettled], timeout: 10), .completed,
                       "The selected Board lane must show the whole card")
        shot("board-blocked")
        swipeLanes(left: true)
        _ = try visible("board.group.done")
        _ = try visible("board.task.k-106")
        shot("board-done")
        swipeLanes(left: false)
        swipeLanes(left: false)
        _ = try visible("board.group.pending")
        let reviewTask = try visible("board.task.k-105")
        XCTAssertTrue(reviewTask.label.contains("Write up the disk cleanup"),
                      "Routine review should remain reachable in Pending")
        shot("board-pending")
    }

    func testDiscussTaskKeepsItsContextAndReturnsWithoutSendingAMessage() throws {
        try launch(["-launchTab", "chats"])
        try tap("bots.row.default")
        let composer = app.textViews["composer.text"].firstMatch
        XCTAssertTrue(composer.waitForExistence(timeout: 20))
        let originalDraft = try XCTUnwrap(composer.value as? String)
        let originalBot = try visible("chat.titlePill").label
        try tap("chat.back")
        try tap("chats.board")
        _ = try visible("board.group.blocked", timeout: 20)
        swipeLanes(left: false)
        try tap("board.task.k-101")
        try tap("task.openChat")

        let context = try visible("chat.boardContext", timeout: 20)
        XCTAssertTrue(context.staticTexts["Speed up the nightly export job"].exists)
        XCTAssertTrue(context.staticTexts["Added an index on created_at; running the export again to measure it."].exists)
        XCTAssertTrue(context.staticTexts.matching(NSPredicate(format: "label CONTAINS 'Running'")).firstMatch.exists)
        XCTAssertEqual(try visible("chat.titlePill").label, originalBot,
                       "The task's assignee must not replace the owner of its source chat")
        assertDraft(originalDraft)
        let contextVisible = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            let card = context.frame
            let title = self.element("chat.titlePill").frame
            let composer = self.app.textViews["composer.text"].firstMatch.frame
            return card.height > 80 && self.app.frame.contains(card)
                && card.minY >= title.maxY && card.maxY < composer.minY
                && self.element("chat.boardContext.return").isHittable
        }, object: context)
        XCTAssertEqual(XCTWaiter.wait(for: [contextVisible], timeout: 10), .completed,
                       "The task context must fit below the contact header and above the composer")
        let contextFrame = context.frame
        for text in ["Speed up the nightly export job", "Added an index on created_at; running the export again to measure it."] {
            let label = context.staticTexts[text]
            XCTAssertTrue(label.isHittable && contextFrame.contains(label.frame), "Task context text is not visible")
        }
        let layout = XCTAttachment(string: context.debugDescription)
        layout.name = "board-task-context-layout"
        layout.lifetime = .keepAlways
        add(layout)
        shot("board-task-chat-context")

        try tap("chat.boardContext.return")
        _ = try visible("task.openChat", timeout: 20)
        XCTAssertTrue(app.navigationBars["Speed up the nightly export job"].exists,
                      "Back to task must reopen the same task's details")
        shot("board-task-return")
    }

    func testComputerAndSettingsKeepTheConversationDraft() throws {
        try launch(["-launchTab", "chats"])
        try tap("bots.row.work")
        let field = app.textViews["composer.text"].firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 20))
        field.tap()
        let marker = "Unsent navigation check \(UUID().uuidString.prefix(8))"
        field.typeText(marker)
        let draft = try XCTUnwrap(field.value as? String)
        XCTAssertTrue(draft.contains(marker))

        try tap("bot.computer")
        let control = try visible("profile.systemControl")
        XCTAssertTrue(control.label.contains("Allow Mac control"))
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: control)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 10), .completed,
                       "Mac access should remain available when this chat has no screen")
        let unavailable = try visible("computer.unavailable")
        let checked = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label != 'Checking computer…'"), object: unavailable)
        XCTAssertEqual(XCTWaiter.wait(for: [checked], timeout: 10), .completed)
        XCTAssertTrue([
            "No virtual computer connected to this chat yet.",
            "Preview unavailable. Reconnecting…",
            "Computer preview is unavailable on this gateway.",
        ].contains(unavailable.label), "The empty computer state should explain why no screen is shown")
        XCTAssertFalse(element("computer.preview").exists, "A chat without a screen should not show an empty preview box")
        XCTAssertFalse(element("computer.frame").exists)
        XCTAssertTrue(app.navigationBars["Computer"].exists)
        shot("navigation-computer")
        try tap("computer.done")
        assertDraft(draft)

        try tap("chat.back")
        try tap("chats.settings")
        _ = try visible("settings.done")
        XCTAssertTrue(app.navigationBars["Settings"].exists)
        shot("navigation-settings")
        try tap("settings.done")
        try tap("bots.row.work")
        assertDraft(draft)
        shot("navigation-draft-restored")
    }

    func testComputerPreviewChangesPausesAndNeverGrantsControl() async throws {
        _ = try await computerMock(["state": "live", "active": true, "reset_log": true])
        try launch(["-launchTab", "chats"])
        try tap("bots.row.default")
        let computer = try visible("bot.computer", timeout: 20)
        let active = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == 'In use'"), object: computer)
        await fulfillment(of: [active], timeout: 20)
        computer.tap()
        _ = try visible("computer.active")
        let status = try visible("computer.preview.status", timeout: 20)
        let live = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == 'Live'"), object: status)
        await fulfillment(of: [live], timeout: 10)
        let screen = try visible("computer.frame")
        let firstFrame = try XCTUnwrap(screen.value as? String)
        let changed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value != %@", firstFrame), object: screen)
        await fulfillment(of: [changed], timeout: 8)
        shot("computer-live")

        try tap("computer.pause")
        let paused = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == 'Preview paused'"), object: status)
        await fulfillment(of: [paused], timeout: 5)
        let pausedFrame = try XCTUnwrap(screen.value as? String)
        let pausedLog = try await computerMock()
        // Wait longer than the two-second poll interval to prove Pause stops requests.
        try await Task.sleep(for: .seconds(3))
        let afterPause = try await computerMock()
        XCTAssertEqual(afterPause.requests.count, pausedLog.requests.count)
        XCTAssertEqual(screen.value as? String, pausedFrame)
        XCTAssertEqual(afterPause.writes, 0, "Watching a screen must not grant computer access")
        shot("computer-paused")

        _ = try await computerMock(["state": "stale", "active": false])
        try tap("computer.pause")
        let lastScreen = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == 'Last screen'"), object: status)
        await fulfillment(of: [lastScreen], timeout: 10)
        let inactive = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: element("computer.active"))
        await fulfillment(of: [inactive], timeout: 10)
        shot("computer-last-screen")
        let log = try await computerMock()
        XCTAssertGreaterThanOrEqual(log.requests.count, 3)
        XCTAssertTrue(log.requests.allSatisfy { $0.profile == "default" && $0.sessionID == "20260921_154212_a1b2c3" },
                      "The preview must stay with this bot and conversation")
        XCTAssertEqual(log.writes, 0, "Previewing and pausing must not change the desktop lease")

        try tap("computer.done")
        _ = try visible("bot.computer")
        let closedLog = try await computerMock()
        try await Task.sleep(for: .seconds(3))
        let afterClose = try await computerMock()
        XCTAssertEqual(afterClose.requests.count, closedLog.requests.count,
                       "Closing Computer should stop its preview requests")
        _ = try await computerMock(["state": "idle", "active": false])
    }

    private struct ComputerMockSnapshot: Decodable {
        struct Request: Decodable {
            let profile: String
            let sessionID: String
            enum CodingKeys: String, CodingKey { case profile; case sessionID = "session_id" }
        }
        let requests: [Request]
        let writes: Int
        let held: Bool?
        let controlWrites: Int?
        enum CodingKeys: String, CodingKey { case requests, writes, held; case controlWrites = "control_writes" }
    }

    /// Watch, take over and hand back, once in each look for the design record.
    func testWatchTakeOverAndHandBack() async throws {
        for look in ["light", "dark"] {
            try await watchTakeOverAndHandBack(look: look)
            app.terminate()
        }
    }

    private func watchTakeOverAndHandBack(look: String) async throws {
        _ = try await computerMock(["state": "live", "active": true, "reset_log": true, "held": false])
        try launch(["-launchTab", "chats", "-nollie-demo-biometry", "yes", "-colorSchemePreference", look])
        try tap("bots.row.default")
        let pill = try visible("chat.watch", timeout: 20)
        XCTAssertEqual(pill.label, "Watch")
        shot("watch-pill-\(look)")

        pill.tap()
        let badge = try visible("watch.badge", timeout: 20)
        let live = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == 'Live'"), object: badge)
        await fulfillment(of: [live], timeout: 10)
        _ = try visible("watch.frame")
        XCTAssertTrue(element("watch.pointer").waitForExistence(timeout: 5), "The helper's character marks where it acted")
        XCTAssertTrue(element("watch.helper").exists)
        XCTAssertTrue(try visible("watch.stop").isHittable, "Stop is one tap away")
        let watched = try await computerMock()
        XCTAssertEqual(watched.controlWrites, 0, "Watching never takes over")
        XCTAssertEqual(watched.writes, 0, "Watching never changes Mac control")
        shot("watch-live-\(look)")

        try tap("watch.takeOver")
        let held = try visible("watch.held", timeout: 10)
        XCTAssertTrue(held.label.hasPrefix("You have the computer. ") && held.label.hasSuffix(" is waiting."), held.label)
        _ = try visible("watch.handBack")
        let taken = try await computerMock()
        XCTAssertEqual(taken.held, true)
        XCTAssertEqual(taken.controlWrites, 1)
        XCTAssertEqual(taken.writes, 0, "Take over never changes config or Mac control")
        shot("watch-taken-over-\(look)")

        // Closed while holding it: the chat keeps the way back.
        try tap("watch.close")
        let kept = try visible("chat.watch", timeout: 10)
        XCTAssertEqual(kept.value as? String, "You have the computer")
        shot("watch-pill-held-\(look)")
        kept.tap()
        try tap("watch.handBack")
        _ = try visible("watch.takeOver", timeout: 10)
        let back = try await computerMock()
        XCTAssertEqual(back.held, false)
        XCTAssertEqual(back.controlWrites, 2)

        _ = try await computerMock(["state": "stale"])
        let stale = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label BEGINSWITH 'Last seen'"), object: element("watch.badge"))
        await fulfillment(of: [stale], timeout: 10)
        shot("watch-stale-\(look)")
        try tap("watch.close")
        _ = try await computerMock(["state": "idle", "active": false, "held": false])
    }

    private func computerMock(_ payload: [String: Any]? = nil) async throws -> ComputerMockSnapshot {
        let env = ProcessInfo.processInfo.environment
        guard let address = env["HERMES_E2E_URL"], let base = URL(string: address), base.scheme == "http",
              ["127.0.0.1", "localhost", "::1"].contains(base.host ?? ""),
              env["HERMES_E2E_TOKEN"] == "mock-token" else {
            throw XCTSkip("Computer preview checks need the local mock gateway")
        }
        var request = URLRequest(url: base.appendingPathComponent("api/_mock/computer-preview"))
        request.timeoutInterval = 10
        if let payload {
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        return try JSONDecoder().decode(ComputerMockSnapshot.self, from: data)
    }

    func testHomeAndChatsLinksReturnFromSettings() throws {
        try launch(["-launchTab", "chats"])
        let originalProcess = try processIdentity()
        for destination in ["home", "chats"] {
            try tap("chats.settings")
            _ = try visible("settings.done")
            app.open(try XCTUnwrap(URL(string: "nollie://" + destination)))
            XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10),
                          "The link should return to the installed demo copy")
            XCTAssertEqual(try processIdentity(), originalProcess,
                           "The link must reach the running app to check sheet dismissal")
            _ = try visible("chats.settings")
            _ = try visible("bots.row.work")
            XCTAssertFalse(element("settings.done").exists,
                           "The \(destination) link left Settings open")
        }
    }

    private func processIdentity() throws -> String {
        let description = app.debugDescription
        let range = try XCTUnwrap(description.range(of: #"pid:\s*\d+"#, options: .regularExpression),
                                  "The app snapshot must identify its process: \(description.prefix(240))")
        let identity = String(description[range])
        XCTContext.runActivity(named: "Navigation demo process " + identity) { _ in }
        return identity
    }

    func testAdvancedOpensTheHermesDashboardAndReturnsToSettings() throws {
        try launch(["-launchTab", "chats", "-nollie.developerMode", "YES"])
        try tap("chats.settings")
        try scrollTo("settings.row.advanced").tap()
        _ = try visible("advanced.dashboard")
        XCTAssertTrue(app.navigationBars["Advanced"].exists)
        for id in ["companion", "status", "troubleshooting"] {
            let row = try scrollTo("advanced.row." + id)
            XCTAssertTrue(row.isEnabled, "Advanced's \(id) row is disabled with a connected gateway")
        }
        for id in ["model", "tools", "skills", "mcp", "approvals", "config", "env", "sessions", "profile", "plugins", "channels", "system"] {
            XCTAssertFalse(element("advanced.row." + id).exists, "A Hermes admin screen is still in Advanced: \(id)")
        }
        shot("navigation-advanced-controls")
        let back = app.navigationBars["Advanced"].buttons["Settings"].firstMatch
        XCTAssertTrue(back.waitForExistence(timeout: 10))
        back.tap()
        try tap("settings.done")
        _ = try visible("bots.row.work")
        _ = try visible("chats.board")
    }

    func testSettingsGroupsKeepEverydayControlsTogether() throws {
        try launch(["-launchTab", "chats", "-nollie.developerMode", "NO"])
        try tap("chats.settings")
        for id in ["bots", "appearance", "notifications", "icloud", "voice", "gateways", "about"] {
            _ = try scrollTo("settings.row." + id)
        }
        for id in ["advanced", "models", "security", "siri", "summaries", "status", "troubleshooting"] {
            XCTAssertFalse(element("settings.row." + id).exists, "A duplicate or technical root route is visible: \(id)")
        }
        shot("settings-simple-root")

        // The privacy page holds the actual controls, not another category menu.
        for _ in 0..<4 { app.swipeDown(velocity: .slow) }
        try scrollTo("settings.row.icloud").tap()
        _ = try visible("security.lock")
        _ = try scrollTo("security.approvals")
        XCTAssertFalse(element("cloud.enabled").exists, "iCloud sync is still on the privacy page")
        shot("settings-privacy")
        app.navigationBars.buttons["Settings"].firstMatch.tap()

        try scrollTo("settings.row.voice").tap()
        _ = try scrollTo("siri.spotlight")
        shot("settings-siri-and-shortcuts")
        app.navigationBars.buttons["Settings"].firstMatch.tap()

        try scrollTo("settings.row.gateways").tap()
        _ = try visible("settings.setup")
        _ = try visible("settings.connection.models")
        shot("settings-connection-and-setup")
        app.navigationBars.buttons["Settings"].firstMatch.tap()
        try tap("settings.done")
        _ = try visible("chats.settings")
    }
}
