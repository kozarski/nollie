import XCTest

/// Creates only a synthetic task in the local mock, then removes that exact task.
@MainActor
final class SchedulesNavigationUITests: XCTestCase {
    private var app: XCUIApplication!

    private struct Jobs: Decodable, Sendable {
        enum Schedule: Decodable, Sendable {
            case recurring(String)
            case once(String)

            private enum CodingKeys: CodingKey { case kind, run_at }
            init(from decoder: Decoder) throws {
                if let value = try? decoder.singleValueContainer().decode(String.self) {
                    self = .recurring(value)
                } else {
                    let object = try decoder.container(keyedBy: CodingKeys.self)
                    guard try object.decode(String.self, forKey: .kind) == "once" else {
                        throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Expected a one-time schedule"))
                    }
                    self = .once(try object.decode(String.self, forKey: .run_at))
                }
            }
        }
        struct Job: Decodable, Sendable {
            let job_id: String
            let name: String
            let profile: String
            let prompt: String?
            let schedule: Schedule
            let deliver: String
            let enabled: Bool?
            let state: String?
        }
        let jobs: [Job]
    }

    private func mockBaseURL() throws -> URL {
        let environment = ProcessInfo.processInfo.environment
        guard let address = environment["HERMES_E2E_URL"], let url = URL(string: address),
              url.scheme == "http", ["127.0.0.1", "localhost", "::1"].contains(url.host ?? ""),
              environment["HERMES_E2E_TOKEN"] == "mock-token" else {
            throw XCTSkip("Schedules checks need the local mock gateway")
        }
        return url
    }

    private nonisolated static func request(_ base: URL, path: String = "api/cron/jobs", method: String = "GET") async throws -> Data {
        var request = URLRequest(url: base.appendingPathComponent(path))
        request.httpMethod = method
        request.timeoutInterval = 10
        request.setValue("Bearer mock-token", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        return data
    }

    private func element(_ id: String) -> XCUIElement {
        switch id {
        case "schedules.create.name": app.textFields.matching(identifier: id).firstMatch
        case "schedules.create.prompt": app.textViews.matching(identifier: id).firstMatch
        default: app.buttons.matching(identifier: id).firstMatch
        }
    }

    private func saveButton(file: StaticString = #filePath, line: UInt = #line) -> XCUIElement {
        // Toolbar wrappers can share the ID but do not expose the button's enabled state.
        let button = app.buttons.matching(identifier: "schedules.create.save").firstMatch
        XCTAssertTrue(button.waitForExistence(timeout: 15), "Missing Save button", file: file, line: line)
        return button
    }

    @discardableResult
    private func visible(_ id: String, timeout: TimeInterval = 15,
                         file: StaticString = #filePath, line: UInt = #line) throws -> XCUIElement {
        let target = element(id)
        if target.exists, target.isHittable { return target }
        XCTAssertTrue(target.waitForExistence(timeout: timeout), "Missing \(id)", file: file, line: line)
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "hittable == true"), object: target)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: timeout), .completed,
                       "\(id) is not reachable", file: file, line: line)
        return target
    }

    private func shot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func launch(_ base: URL, developerMode: Bool) throws {
        let bundle = ProcessInfo.processInfo.environment["HERMES_E2E_BUNDLE"] ?? "com.coreykozarski.nollie.demo"
        guard bundle.hasSuffix(".demo") else { throw XCTSkip("Schedules checks run only in the demo copy") }
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        XCUIDevice.shared.appearance = .light
        app = XCUIApplication(bundleIdentifier: bundle)
        app.launchArguments = [
            "-nollie-demo-gateway", base.absoluteString, "mock-token", "Studio",
            "-launchTab", "chats", "-companionPromptShown", "YES",
            "-notificationsSetupCardDone", "YES", "-bots.animate", "NO", "-bots.pinned", "-",
            "-nollie.developerMode", developerMode ? "YES" : "NO",
        ]
        app.launch()
    }

    private func assertDraft(_ expected: String, file: StaticString = #filePath, line: UInt = #line) {
        let composer = app.textViews["composer.text"].firstMatch
        if composer.value as? String == expected { return }
        let matches = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", expected), object: composer)
        XCTAssertEqual(XCTWaiter.wait(for: [matches], timeout: 10), .completed,
                       "Asking Nollie must preserve the main chat's unsent draft", file: file, line: line)
    }

    func testNormalSchedulesOpensNollieWithoutSendingOrReplacingItsDraft() async throws {
        let base = try mockBaseURL()
        try launch(base, developerMode: false)
        try visible("bots.row.default", timeout: 30).tap()
        _ = try visible("chat.more", timeout: 30)
        let composer = app.textViews["composer.text"].firstMatch
        XCTAssertTrue(composer.waitForExistence(timeout: 15))
        var draft = composer.value as? String ?? ""
        if draft.isEmpty {
            composer.tap()
            XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 10))
            for character in "Keep my reminder draft." {
                composer.typeText(String(character)); draft.append(character); assertDraft(draft)
            }
        }
        let messagesPath = "api/sessions/20260921_154212_a1b2c3/messages"
        let messagesBefore = try await Self.request(base, path: messagesPath)
        let jobsBefore = try await Self.request(base)
        try visible("chat.back").tap()
        try visible("bots.row.work").tap()
        try visible("chat.more", timeout: 30).tap()
        try visible("botmenu.schedules").tap()
        XCTAssertEqual(try visible("schedules.new").label, "Ask Nollie")

        try visible("schedules.task.morning-brief").tap()
        let edit = try visible("schedules.edit")
        let editable = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: edit)
        XCTAssertEqual(XCTWaiter.wait(for: [editable], timeout: 15), .completed)
        XCTAssertFalse(app.textViews["schedules.edit.prompt"].exists)
        XCTAssertFalse(app.buttons["schedules.edit.save"].exists)
        XCTAssertTrue(app.buttons["schedules.delete"].exists)
        XCTAssertFalse(app.staticTexts["Raw JSON"].exists)
        shot("schedules-simple-summary")
        edit.tap()
        XCTAssertTrue(app.textViews["schedules.edit.prompt"].waitForExistence(timeout: 10))
        try visible("schedules.edit.repeat").tap()
        for option in ["Every day", "Weekdays", "Weekends", "Weekly"] {
            XCTAssertTrue(app.buttons[option].firstMatch.waitForExistence(timeout: 5))
        }
        app.buttons["Weekly"].firstMatch.tap()
        _ = try visible("schedules.edit.day")
        XCTAssertFalse(app.staticTexts["Cron"].exists)
        XCTAssertFalse(app.staticTexts["Raw JSON"].exists)
        shot("schedules-simple-edit")
        try visible("schedules.edit.cancel").tap()
        let jobsAfterCancel = try await Self.request(base)
        XCTAssertEqual(jobsAfterCancel, jobsBefore, "Cancelling edits must preserve the existing schedule")
        app.navigationBars["Morning brief"].buttons["Schedules"].firstMatch.tap()
        try visible("schedules.new").tap()
        let main = try visible("chat.titlePill", timeout: 30)
        XCTAssertTrue(main.label.contains("default"), "Schedules should return to the lead assistant, not Work")
        XCTAssertFalse(app.buttons["schedules.create.save"].exists)
        XCTAssertFalse(app.buttons["schedules.new"].exists)
        assertDraft(draft)
        shot("schedules-ask-nollie")

        // The same action must also close a bot sheet when the main chat is already underneath it.
        try visible("chat.more").tap()
        try visible("botmenu.schedules").tap()
        try visible("schedules.new").tap()
        _ = try visible("chat.more")
        assertDraft(draft)
        XCTAssertFalse(app.buttons["schedules.new"].exists)
        let messagesAfter = try await Self.request(base, path: messagesPath)
        let jobsAfter = try await Self.request(base)
        XCTAssertEqual(messagesAfter, messagesBefore, "Opening Nollie must not send a message")
        XCTAssertEqual(jobsAfter, jobsBefore, "Opening Nollie must not create or change a schedule")
    }

    func testSchedulesShowsEveryBotAndCreatesForTheChosenBot() async throws {
        let base = try mockBaseURL()
        let title = "Demo schedule \(UUID().uuidString.prefix(8))"
        let prompt = "List the synthetic demo tasks."
        addTeardownBlock {
            let data = try await Self.request(base)
            let jobs = try JSONDecoder().decode(Jobs.self, from: data).jobs
            for job in jobs where job.name == title && job.job_id.hasPrefix("demo-cron-") {
                _ = try await Self.request(base, path: "api/cron/jobs/" + job.job_id, method: "DELETE")
            }
        }

        try launch(base, developerMode: true)
        // Schedules is in each bot's menu (the chat list's top pill is the Board and New Bot).
        try visible("bots.row.default", timeout: 30).tap()
        try visible("chat.more", timeout: 30).tap()
        try visible("botmenu.schedules").tap()
        _ = try visible("schedules.close")
        _ = try visible("schedules.task.morning-brief")
        _ = try visible("schedules.task.dep-audit")
        shot("schedules-all-bots")
        let beforeCancel = try JSONDecoder().decode(Jobs.self, from: await Self.request(base)).jobs

        try visible("schedules.new").tap()
        XCTAssertFalse(saveButton().isEnabled)
        shot("schedules-new-empty")
        let discardedName = try visible("schedules.create.name")
        discardedName.tap()
        discardedName.typeText(title)
        let discardedPrompt = try visible("schedules.create.prompt")
        discardedPrompt.tap()
        discardedPrompt.typeText(prompt)
        XCTAssertTrue(saveButton().isEnabled)
        try visible("schedules.create.cancel").tap()
        _ = try visible("schedules.task.morning-brief")
        let afterCancel = try JSONDecoder().decode(Jobs.self, from: await Self.request(base)).jobs
        XCTAssertEqual(Set(afterCancel.map(\.job_id)), Set(beforeCancel.map(\.job_id)), "Cancel must not create a task")
        XCTAssertFalse(afterCancel.contains { $0.name == title })

        try visible("schedules.new").tap()
        try visible("schedules.create.bot").tap()
        try visible("schedules.create.bot.work").tap()
        let name = try visible("schedules.create.name")
        name.tap()
        name.typeText(title)
        let instructions = try visible("schedules.create.prompt")
        instructions.tap()
        instructions.typeText(prompt)
        let create = saveButton()
        XCTAssertTrue(create.isEnabled)
        shot("schedules-create")
        create.tap()

        _ = try visible("schedules.new")
        let jobs = try JSONDecoder().decode(Jobs.self, from: await Self.request(base)).jobs
        let created = try XCTUnwrap(jobs.first { $0.name == title })
        XCTAssertEqual(created.profile, "work", "Create must use the chosen bot's profile query")
        XCTAssertEqual(created.prompt, prompt)
        guard case .once(let timestamp) = created.schedule else {
            XCTFail("A new task should run once unless the user chooses a repeat")
            return
        }
        let runAt = try XCTUnwrap(ISO8601DateFormatter().date(from: timestamp))
        XCTAssertGreaterThan(runAt, Date())
        XCTAssertLessThan(runAt, Date().addingTimeInterval(48 * 3600))
        XCTAssertEqual(created.deliver, "bot-chat", "Scheduled results must return to the chosen bot's conversation")
        XCTAssertTrue(jobs.contains { $0.job_id == "morning-brief" && $0.profile == "default" })
        XCTAssertTrue(jobs.contains { $0.job_id == "dep-audit" && $0.profile == "work" })
        XCTAssertTrue(try visible("schedules.task." + created.job_id).label.contains(title))
        shot("schedules-created")
        try visible("schedules.task." + created.job_id).tap()
        let pauseResume = try visible("schedules.pauseResume")
        let readyToPause = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true AND label == 'Pause checks'"), object: pauseResume)
        XCTAssertEqual(XCTWaiter.wait(for: [readyToPause], timeout: 15), .completed)
        pauseResume.tap()
        let paused = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == 'Resume checks' AND enabled == true"), object: pauseResume)
        XCTAssertEqual(XCTWaiter.wait(for: [paused], timeout: 15), .completed)
        var changed = try JSONDecoder().decode(Jobs.self, from: await Self.request(base)).jobs.first { $0.job_id == created.job_id }
        XCTAssertEqual(changed?.enabled, false)
        XCTAssertEqual(changed?.state, "paused")
        XCTAssertFalse(app.buttons["cron.runNow"].isEnabled, "Run now must not silently resume a paused task")
        XCTAssertFalse(app.staticTexts["Raw JSON"].exists)
        XCTAssertFalse(app.staticTexts["Cron"].exists)
        shot("schedules-paused")
        pauseResume.tap()
        let resumed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == 'Pause checks' AND enabled == true"), object: pauseResume)
        XCTAssertEqual(XCTWaiter.wait(for: [resumed], timeout: 15), .completed)
        changed = try JSONDecoder().decode(Jobs.self, from: await Self.request(base)).jobs.first { $0.job_id == created.job_id }
        XCTAssertEqual(changed?.enabled, true)
        XCTAssertEqual(changed?.state, "active")
        XCTAssertEqual(changed?.prompt, prompt)
        shot("schedules-resumed")
        let back = app.navigationBars[title].buttons["Schedules"].firstMatch
        XCTAssertTrue(back.waitForExistence(timeout: 10))
        back.tap()
        try visible("schedules.close").tap()
        _ = try visible("chat.more")
        XCTAssertFalse(element("schedules.close").exists)
    }
}
