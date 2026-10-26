import XCTest

/// Adds a ready-made helper from the gallery and takes it back, only against the local mock gateway.
@MainActor
final class HelperGalleryUITests: XCTestCase {
    private var app: XCUIApplication!

    private nonisolated static func request(_ base: URL, _ path: String, post: Bool = false) async throws -> [String: Any] {
        var request = URLRequest(url: base.appendingPathComponent(path))
        request.timeoutInterval = 10
        request.setValue("Bearer mock-token", forHTTPHeaderField: "Authorization")
        if post {
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = Data("{}".utf8)
        }
        let (data, _) = try await URLSession.shared.data(for: request)
        return try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
    }

    private nonisolated static func members(_ base: URL) async throws -> [String] {
        let roster = try await request(base, "api/plugins/nollie-crew/crew")
        return (roster["members"] as? [[String: Any]] ?? []).compactMap { $0["profile"] as? String }
    }

    private func launch() async throws -> URL {
        let environment = ProcessInfo.processInfo.environment
        guard let address = environment["HERMES_E2E_URL"], let base = URL(string: address),
              base.scheme == "http", ["127.0.0.1", "localhost", "::1"].contains(base.host ?? ""),
              environment["HERMES_E2E_TOKEN"] == "mock-token" else {
            throw XCTSkip("Gallery checks need the local mock gateway")
        }
        let bundle = environment["HERMES_E2E_BUNDLE"] ?? "com.coreykozarski.nollie.demo"
        guard bundle.hasSuffix(".demo") else { throw XCTSkip("Gallery checks run only in the demo copy") }
        _ = try await Self.request(base, "api/_mock/profile-creation", post: true)
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        app = XCUIApplication(bundleIdentifier: bundle)
        app.launchArguments = [
            "-nollie-demo-gateway", address, "mock-token", "Studio", "-launchTab", "chats",
            "-companionPromptShown", "YES", "-notificationsSetupCardDone", "YES",
            "-bots.animate", "NO", "-nollie.developerMode", "NO",
        ]
        app.launch()
        addTeardownBlock { [app] in app?.terminate() }
        let newBot = app.buttons["chats.newBot"].firstMatch
        XCTAssertTrue(newBot.waitForExistence(timeout: 30))
        newBot.tap()
        return base
    }

    func testOneTapAddsAHelperAndUndoTakesItBack() async throws {
        let base = try await launch()
        let add = app.buttons["gallery.add.planner"].firstMatch
        XCTAssertTrue(add.waitForExistence(timeout: 15))
        add.tap()

        let undo = app.buttons["gallery.undo.planner"].firstMatch
        XCTAssertTrue(undo.waitForExistence(timeout: 15))
        let members = try await Self.members(base)
        XCTAssertEqual(members, ["planner"])
        XCTAssertTrue(app.buttons["gallery.done"].firstMatch.exists)

        undo.tap()
        XCTAssertTrue(app.buttons["gallery.add.planner"].firstMatch.waitForExistence(timeout: 15))
        let after = try await Self.members(base)
        XCTAssertEqual(after, [])
    }
}
