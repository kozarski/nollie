import XCTest

/// Links this simulator to a real Mac with a code saved from that Mac, handed to the app the way the
/// Camera hands it over. Runs only when `NOLLIE_PAIR_LINK_FILE` names a file that holds the code (the
/// https link behind the QR code in "Use Nollie on your iPhone", or its `nollie://pair-link#` form).
/// `NOLLIE_SHOTS` names a folder for a picture of each step. Both reach the test through xcodebuild with
/// the TEST_RUNNER_ prefix. It drives the app under test, or the copy named in `NOLLIE_PAIR_BUNDLE`.
/// It removes nothing, and the code is never printed: it is only read from the file and opened.
@MainActor
final class PairRealMacUITests: DemoCase {
    private var shots: URL?

    func testPairWithACodeFromAFile() throws {
        let env = ProcessInfo.processInfo.environment
        guard let path = env["NOLLIE_PAIR_LINK_FILE"], !path.isEmpty else {
            throw XCTSkip("Name a file holding a pairing code from a real Mac in NOLLIE_PAIR_LINK_FILE")
        }
        if let folder = env["NOLLIE_SHOTS"], !folder.isEmpty {
            shots = URL(fileURLWithPath: folder, isDirectory: true)
            try? FileManager.default.createDirectory(at: shots!, withIntermediateDirectories: true)
        }
        continueAfterFailure = false

        // A fresh launch: whatever was running ends first. Nothing saved is cleared.
        let bundle = env["NOLLIE_PAIR_BUNDLE"] ?? ""
        app = bundle.isEmpty ? XCUIApplication() : XCUIApplication(bundleIdentifier: bundle)
        XCUIDevice.shared.orientation = .portrait
        app.launchArguments = ["-nollie.onboarding.welcomeIntroSeen", "YES", "-companionPromptShown", "YES"]
        app.launch()
        addTeardownBlock { [weak self] in self?.app?.terminate() }
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 20), "Nollie did not open")
        snap("1-opened")

        // The Mac hides its code whenever Nollie for Mac stops being in front, so the code may be saved to
        // the file only after this app is up. Wait for it.
        var contents = ""
        _ = poll(120) {
            contents = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
            return !contents.isEmpty
        }
        let raw = contents.trimmingCharacters(in: .whitespacesAndNewlines)
        // Only the shape is checked here; the app does the real reading. Nothing about the code is echoed.
        guard raw.hasPrefix("https://nollie.app/pair#") || raw.hasPrefix("nollie://pair-link#"), let link = URL(string: raw) else {
            XCTFail("The file named in NOLLIE_PAIR_LINK_FILE holds no pairing code")
            return
        }

        openQuietly(link)
        let confirm = app.buttons["link.confirm"]
        let issue = find("pairing.issue")
        let shown = poll(30) { confirm.exists || issue.exists }
        if issue.exists {
            snap("2-code-refused")
            XCTFail("Nollie refused the code: \(issue.label)")
            return
        }
        XCTAssertTrue(shown, "The link sheet did not open")
        snap("2-link-sheet")

        XCTAssertTrue(confirm.isHittable, "Link can't be tapped")
        confirm.tap()
        snap("3-linking", settle: 0.4)

        // Up to 90 seconds for the link to finish and the chats to come up.
        let deadline = Date().addingTimeInterval(90)
        let connected = find("pairing.connected")
        let linked = poll(90) { connected.exists || (issue.exists && !find("pairing.progress").exists) }
        if !connected.exists {
            snap("4-not-linked")
            XCTFail(linked ? "Linking stopped: \(issue.label)" : "Not linked after 90 seconds")
            return
        }
        snap("4-linked")

        let done = app.buttons["pairing.done"]
        if done.waitForExistence(timeout: 5) { done.tap() }
        // A first link ends on setup's last step: Start chatting leads to the chats.
        let start = find("onboarding.continue")
        if poll(10, { start.exists && start.label == "Start chatting" }) {
            snap("5-ready")
            start.tap()
        }
        let chats = find("bots.list")
        let mainChat = find("chats.mainChat")
        let left = max(5, deadline.timeIntervalSinceNow)
        XCTAssertTrue(poll(left) { chats.exists || mainChat.exists }, "The chats did not come up after linking")
        snap("6-chats", settle: 1.5)
    }

    /// After a link: opens Nollie as it is, goes on to the chats if setup's last step is showing, and opens the
    /// main chat. Skipped unless NOLLIE_PAIR_LINK_FILE is set, so it only runs beside the test above.
    func testTheChatsOfALinkedMac() throws {
        let env = ProcessInfo.processInfo.environment
        guard env["NOLLIE_PAIR_LINK_FILE"]?.isEmpty == false else { throw XCTSkip("Runs after a real link") }
        if let folder = env["NOLLIE_SHOTS"], !folder.isEmpty { shots = URL(fileURLWithPath: folder, isDirectory: true) }
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-companionPromptShown", "YES"]
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 20), "Nollie did not open")
        let start = find("onboarding.continue")
        if poll(15, { start.exists && start.label == "Start chatting" }) {
            snap("5-ready")
            start.tap()
        }
        let chats = find("bots.list"), mainChat = find("chats.mainChat")
        XCTAssertTrue(poll(60) { chats.exists || mainChat.exists }, "The chats did not come up")
        snap("6-chats", settle: 2)
        if mainChat.exists { mainChat.tap(); snap("7-main-chat", settle: 3) }
    }

    /// XCTest prints every step it takes, an opened link in full. The code must not reach the console, so
    /// the runner's output is shut off for this one step and comes back straight after.
    private func openQuietly(_ link: URL) {
        fflush(stdout)
        fflush(stderr)
        let out = dup(STDOUT_FILENO), err = dup(STDERR_FILENO), silent = Darwin.open("/dev/null", O_WRONLY)
        dup2(silent, STDOUT_FILENO)
        dup2(silent, STDERR_FILENO)
        app.open(link)
        fflush(stdout)
        fflush(stderr)
        dup2(out, STDOUT_FILENO)
        dup2(err, STDERR_FILENO)
        [out, err, silent].forEach { close($0) }
    }

    /// One picture, kept with the result and written to `NOLLIE_SHOTS` when it names a folder.
    private func snap(_ name: String, settle: TimeInterval = 0.8) {
        pause(settle)
        let picture = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: picture)
        attachment.name = "pair-real-mac-" + name
        attachment.lifetime = .keepAlways
        add(attachment)
        if let shots {
            try? picture.pngRepresentation.write(to: shots.appendingPathComponent("pair-real-mac-\(name).png"))
        }
    }
}
