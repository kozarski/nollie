import XCTest

/// Watch plays the helper's computer as live video from the mock gateway's `/nollie/live`: the
/// Live badge, the picture and the helper's pointer, how late the picture is, nothing polled while
/// it plays, the stream closed in the background and opened again on return, and "Last seen" when
/// the computer's picture stops being current. Uses only the demo copy and the local mock gateway.
@MainActor
final class LiveStreamUITests: XCTestCase {
    private var app: XCUIApplication!
    private var address = ""

    /// One mock gateway serves every flow in a run, so a case that stops early still leaves no helper
    /// using the computer for the flows after it.
    override func tearDownWithError() throws {
        DemoCase.resetMock("api/_mock/computer-preview", ["state": "idle", "active": false, "held": false])
        try super.tearDownWithError()
    }

    func testWatchPlaysTheLivePicture() async throws {
        for look in ["light", "dark"] {
            try await watchLive(look: look)
            app.terminate()
        }
    }

    private func watchLive(look: String) async throws {
        _ = try await mock(["state": "live", "active": true, "reset_log": true, "held": false])
        try launch(look: look)
        try tap("bots.row.default")
        try tap("chat.watch", timeout: 20)

        let badge = try visible("watch.badge", timeout: 20)
        let frame = element("watch.frame")
        let video = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == 'Live picture'"), object: frame)
        await fulfillment(of: [video], timeout: 15)
        let live = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == 'Live'"), object: badge)
        await fulfillment(of: [live], timeout: 10)
        XCTAssertTrue(element("watch.pointer").waitForExistence(timeout: 5), "The helper's pointer rides on the video")

        // How late the picture is, read from the demo copy's stats over a few seconds.
        let stats = element("watch.stats")
        XCTAssertTrue(stats.waitForExistence(timeout: 5))
        var samples: [Int] = []
        var last = ""
        for _ in 0..<12 {
            let value = stats.value as? String ?? ""
            if value != last, let ms = Self.number("latency", in: value) { samples.append(ms) }
            last = value
            try await Task.sleep(for: .milliseconds(500))
        }
        XCTAssertFalse(samples.isEmpty, "No latency reading: \(last)")
        let sorted = samples.sorted()
        let median = sorted[sorted.count / 2]
        let summary = "Live picture on the simulator (\(look)): latency median \(median) ms, " +
            "min \(sorted.first ?? 0) ms, max \(sorted.last ?? 0) ms over \(samples.count) readings; last stats \(last)"
        let note = XCTAttachment(string: summary)
        note.name = "live-latency-\(look)"
        note.lifetime = .keepAlways
        add(note)
        XCTAssertLessThan(median, 500, summary)

        let playing = try await mock()
        XCTAssertEqual(playing.liveOpen, 1, "One stream for one Watch screen")
        XCTAssertGreaterThan(playing.liveFrames, 20, "Frames keep coming")
        XCTAssertNotNil(playing.lastReport, "The viewer reports once a second")
        let polled = playing.requests.count
        try await Task.sleep(for: .seconds(3))
        let later = try await mock()
        XCTAssertEqual(later.requests.count, polled, "Nothing is polled while the live picture plays")
        XCTAssertEqual(later.writes, 0, "Watching never changes Mac control")
        XCTAssertEqual(later.controlWrites, 0, "Watching never takes over")
        shot("live-video-\(look)")

        // In the background the stream closes; back in front it plays again.
        XCUIDevice.shared.press(.home)
        try await until("the stream closes in the background") { try await self.mock().liveOpen == 0 }
        app.activate()
        let again = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == 'Live'"), object: element("watch.badge"))
        await fulfillment(of: [again], timeout: 20)
        try await until("the stream opens again") { try await self.mock().liveOpen == 1 }

        // A saved sign-in is typed: the picture goes, the badge says why, and it comes back after.
        _ = try await mock(["state": "paused"])
        let held = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == 'Paused while a sign-in is typed'"),
                                             object: element("watch.badge"))
        await fulfillment(of: [held], timeout: 10)
        let pausedFrame = element("watch.frame")
        XCTAssertTrue(!pausedFrame.exists || pausedFrame.value as? String != "Live picture", "No live picture during a sign-in")
        shot("live-sign-in-paused-\(look)")
        _ = try await mock(["state": "live"])
        let back = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == 'Live'"), object: element("watch.badge"))
        await fulfillment(of: [back], timeout: 20)

        // The computer's picture stops being current: the badge says so.
        _ = try await mock(["state": "stale"])
        let stale = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label BEGINSWITH 'Last seen'"), object: element("watch.badge"))
        await fulfillment(of: [stale], timeout: 10)
        shot("live-stale-\(look)")

        try tap("watch.close")
        try await until("closing Watch closes the stream") { try await self.mock().liveOpen == 0 }
        _ = try await mock(["state": "idle", "active": false, "held": false])
    }

    // MARK: Helpers

    private struct Snapshot: Decodable {
        struct Request: Decodable { let profile: String }
        struct Report: Decodable { let got: Int; let shown: Int }
        let requests: [Request]
        let writes: Int
        let controlWrites: Int?
        let liveOpen: Int
        let liveFrames: Int
        let lastReport: Report?
        enum CodingKeys: String, CodingKey {
            case requests, writes
            case controlWrites = "control_writes", liveOpen = "live_open", liveFrames = "live_frames"
            case lastReport = "last_report"
        }
    }

    private static func number(_ key: String, in text: String) -> Int? {
        guard let range = text.range(of: key + "=") else { return nil }
        return Int(text[range.upperBound...].prefix { $0.isNumber })
    }

    private func launch(look: String) throws {
        let env = ProcessInfo.processInfo.environment
        guard let address = env["HERMES_E2E_URL"], let url = URL(string: address), url.scheme == "http",
              ["127.0.0.1", "localhost", "::1"].contains(url.host ?? ""),
              env["HERMES_E2E_TOKEN"] == "mock-token" else {
            throw XCTSkip("Needs the local mock gateway and HERMES_E2E_TOKEN=mock-token")
        }
        let bundle = env["HERMES_E2E_BUNDLE"] ?? "com.coreykozarski.nollie.demo"
        guard bundle.hasSuffix(".demo") else { throw XCTSkip("Uses the demo copy only") }
        continueAfterFailure = false
        self.address = address
        XCUIDevice.shared.orientation = .portrait
        app = XCUIApplication(bundleIdentifier: bundle)
        app.launchArguments = ["-nollie-demo-gateway", address, "mock-token", "Studio",
                               "-companionPromptShown", "YES", "-notificationsSetupCardDone", "YES",
                               "-bots.animate", "NO", "-launchTab", "chats", "-colorSchemePreference", look] + DemoCase.weeklyCardPutAway
        app.launch()
        _ = try visible("bots.row.default", timeout: 30)
    }

    private func mock(_ payload: [String: Any]? = nil) async throws -> Snapshot {
        let env = ProcessInfo.processInfo.environment
        guard let base = URL(string: address.isEmpty ? env["HERMES_E2E_URL"] ?? "" : address), base.scheme == "http" else {
            throw XCTSkip("Needs the local mock gateway")
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
        return try JSONDecoder().decode(Snapshot.self, from: data)
    }

    private func until(_ what: String, timeout: TimeInterval = 10, _ check: () async throws -> Bool) async throws {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if try await check() { return }
            try await Task.sleep(for: .milliseconds(250))
        }
        XCTFail("Timed out waiting: \(what)")
    }

    private func element(_ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    @discardableResult
    private func visible(_ id: String, timeout: TimeInterval = 10) throws -> XCUIElement {
        let target = element(id)
        XCTAssertTrue(target.waitForExistence(timeout: timeout), "Missing \(id)")
        return target
    }

    private func tap(_ id: String, timeout: TimeInterval = 10) throws {
        let target = try visible(id, timeout: timeout)
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "hittable == true"), object: target)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: timeout), .completed, "\(id) is not reachable")
        target.tap()
    }

    private func shot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
