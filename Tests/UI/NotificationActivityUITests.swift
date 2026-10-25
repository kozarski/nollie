import XCTest

/// A background worker belongs to its assignee even when a different bot dispatched it.
/// Reads only the opt-in local fixture and never sends a message or changes Mac access.
@MainActor
final class NotificationActivityUITests: XCTestCase {
    private var app: XCUIApplication!
    private let workSession = "20260930_221000_work01"

    private struct Workers: Decodable {
        struct Worker: Decodable {
            let task_id: String
            let profile: String
            let task_assignee: String
            let task_status: String
            let worker_pid: Int
        }
        let workers: [Worker]
    }

    private struct History: Decodable, Equatable {
        struct Message: Decodable, Equatable {
            let id: Int
            let role: String
            let content: String
            let display_kind: String?
        }
        let messages: [Message]
    }

    private nonisolated static func get(_ base: URL, path: String) async throws -> Data {
        let url = try XCTUnwrap(URL(string: path, relativeTo: base))
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        request.setValue("Bearer mock-token", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        return data
    }

    private func launch() throws -> URL {
        let environment = ProcessInfo.processInfo.environment
        guard let address = environment["HERMES_E2E_URL"], let base = URL(string: address),
              base.scheme == "http", ["127.0.0.1", "localhost", "::1"].contains(base.host ?? ""),
              environment["HERMES_E2E_TOKEN"] == "mock-token" else {
            throw XCTSkip("Activity checks need the local mock gateway")
        }
        let bundle = environment["HERMES_E2E_BUNDLE"] ?? "com.coreykozarski.nollie.demo"
        guard bundle.hasSuffix(".demo") else { throw XCTSkip("Activity checks run only in the demo copy") }
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        XCUIDevice.shared.appearance = .light
        app = XCUIApplication(bundleIdentifier: bundle)
        app.launchArguments = [
            "-nollie-demo-gateway", address, "mock-token", "Studio", "-launchTab", "chats",
            "-companionPromptShown", "YES", "-notificationsSetupCardDone", "YES",
            "-bots.animate", "NO", "-nollie.developerMode", "NO",
        ]
        app.launch()
        addTeardownBlock { [app] in app?.terminate() }
        return base
    }

    private func element(_ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    @discardableResult
    private func visible(_ id: String, timeout: TimeInterval = 15,
                         file: StaticString = #filePath, line: UInt = #line) -> XCUIElement {
        let target = element(id)
        if target.exists, target.isHittable { return target }
        XCTAssertTrue(target.waitForExistence(timeout: timeout), "Missing \(id)", file: file, line: line)
        wait(NSPredicate(format: "hittable == true"), on: target, timeout: timeout, file: file, line: line)
        return target
    }

    private func wait(_ predicate: NSPredicate, on target: XCUIElement, timeout: TimeInterval = 15,
                      file: StaticString = #filePath, line: UInt = #line) {
        let expected = XCTNSPredicateExpectation(predicate: predicate, object: target)
        XCTAssertEqual(XCTWaiter.wait(for: [expected], timeout: timeout), .completed, file: file, line: line)
    }

    private func shot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testAssignedWorkerAppearsWithoutOpeningBoardAndMachinePromptsStayHidden() async throws {
        let base = try launch()
        let workers = try JSONDecoder().decode(Workers.self, from: await Self.get(base, path: "/api/plugins/kanban/workers/active?board=default"))
        let worker = try XCTUnwrap(workers.workers.first { $0.task_id == "k-101" })
        XCTAssertEqual(worker.profile, "default", "Start an isolated mock with --notification-activity-demo")
        XCTAssertEqual(worker.task_assignee, "work")
        XCTAssertEqual(worker.task_status, "running")
        XCTAssertGreaterThan(worker.worker_pid, 0)
        let historyPath = "/api/sessions/\(workSession)/messages?profile=work"
        let before = try JSONDecoder().decode(History.self, from: await Self.get(base, path: historyPath))
        XCTAssertEqual(before.messages.filter { $0.display_kind == "internal_notification" }.count, 2)
        XCTAssertTrue(before.messages.contains { $0.content == "[SILENT]" }, "Raw control history must still exist")

        // No Board page is opened: the initial chat list must independently find workers.
        let work = visible("bots.row.work", timeout: 30)
        wait(NSPredicate(format: "value CONTAINS %@", "Working on a task"), on: work, timeout: 30)
        XCTAssertFalse((element("bots.row.default").value as? String ?? "").contains("Working on a task"),
                       "The dispatcher must not inherit its worker's activity")
        shot("notification-activity-sidebar")
        work.tap()

        let useful = app.staticTexts["The export checks passed. The schedule is still paused."].firstMatch
        XCTAssertTrue(useful.waitForExistence(timeout: 20), "Useful machine-triggered replies must remain visible")
        XCTAssertTrue(app.staticTexts["Please check the export when it is ready."].exists,
                      "The original human request must remain visible")
        for hidden in ["[SILENT]", "max_runtime=0s", "Synthetic worker check completed"] {
            XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", hidden)).firstMatch.exists,
                           "Trusted internal control text leaked into the conversation")
        }
        XCTAssertEqual(app.otherElements.matching(identifier: "thread.row.reply").count, 2)
        let composer = app.textViews["composer.text"].firstMatch
        XCTAssertTrue(composer.exists)
        let draft = try XCTUnwrap(composer.value as? String)
        wait(NSPredicate(format: "value == %@", "Working on a task"), on: visible("chat.titlePill"))
        shot("notification-activity-chat")

        let computer = visible("bot.computer")
        XCTAssertNotEqual(computer.value as? String, "In use", "A worker alone does not prove computer input")
        computer.tap()
        let activity = visible("computer.activity.status")
        wait(NSPredicate(format: "label == %@", "Working on a task"), on: activity)
        let preview = visible("computer.preview.status", timeout: 20)
        wait(NSPredicate(format: "label == 'Live'"), on: preview)
        _ = visible("computer.frame")
        XCTAssertFalse(element("computer.active").exists, "A live preview alone must not claim computer use")
        shot("notification-activity-computer")

        visible("computer.done").tap()
        wait(NSPredicate(format: "value == %@", draft), on: composer)
        let after = try JSONDecoder().decode(History.self, from: await Self.get(base, path: historyPath))
        XCTAssertEqual(after, before, "Viewing background activity must not send messages or rewrite raw history")
    }
}
