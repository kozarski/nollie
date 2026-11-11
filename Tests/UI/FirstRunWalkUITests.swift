import XCTest

/// Walks the iPhone and iPad first run as a new person does, from "Meet Nollie." to a working chat, and
/// keeps a picture of every screen. Runs on the demo copy against the mock gateway (the demo copy keeps
/// credentials in memory, so a manual connection saves), installed fresh before each case.
/// `NOLLIE_WALK_SIZE` (a content size category such as `UICTContentSizeCategoryAccessibilityXXXL`) and
/// `NOLLIE_WALK_LOOK` (`dark`) vary the run, and `NOLLIE_SHOTS` names a folder to write the pictures to.
@MainActor
final class FirstRunWalkUITests: DemoCase {
    private var prefix = ""

    /// A first run: no gateway and, on a fresh install, no setup under way. The intro is already seen.
    private func launchFresh(_ extra: [String] = []) throws {
        let (_, bundle) = try requireMock()
        let env = ProcessInfo.processInfo.environment
        let look: Look = env["NOLLIE_WALK_LOOK"] == "dark" ? .dark : .light
        XCUIDevice.shared.appearance = look.uiAppearance
        XCUIDevice.shared.orientation = env["NOLLIE_WALK_LANDSCAPE"] == "1" ? .landscapeLeft : .portrait
        app = XCUIApplication(bundleIdentifier: bundle)
        // A launch argument would pin the saved setup progress, so a fresh install stands for a first run.
        var flags = ["-nollie.onboarding.welcomeIntroSeen", "YES", "-companionPromptShown", "YES", "-approvals.ownerCheck", "NO",
                     "-colorSchemePreference", look.rawValue]
        let size = env["NOLLIE_WALK_SIZE"] ?? ""
        if !size.isEmpty { flags += ["-UIPreferredContentSizeCategoryName", size] }
        app.launchArguments = flags + extra
        app.launch()
        addTeardownBlock { [weak self] in self?.app?.terminate() }
        let frame = app.windows.firstMatch.frame
        let device = frame.width >= 700 ? (frame.height > frame.width ? "ipad" : "ipadland") : (frame.height < 700 ? "se" : "phone")
        prefix = "\(device)-\(look.rawValue)-\(size.isEmpty ? "std" : "ax")-"
    }

    private func snap(_ name: String, settle: TimeInterval = 0.8) {
        pause(settle)
        let picture = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: picture)
        attachment.name = prefix + name
        attachment.lifetime = .keepAlways
        add(attachment)
        if let folder = ProcessInfo.processInfo.environment["NOLLIE_SHOTS"], !folder.isEmpty {
            try? picture.pngRepresentation.write(to: URL(fileURLWithPath: folder).appendingPathComponent(prefix + name + ".png"))
        }
    }

    /// An element with this identifier once it can be touched. At the largest text sizes setup's buttons
    /// follow the words in the scroll, so this scrolls to them as a person would.
    @discardableResult
    private func reach(_ id: String, timeout: TimeInterval = 15) -> XCUIElement {
        let target = find(id)
        // A form builds only the rows near the screen, so a row further down may not exist yet.
        _ = target.waitForExistence(timeout: timeout)
        // A form in a sheet scrolls on its own surface (on an iPad the sheet sits in the middle).
        let form = app.collectionViews.firstMatch
        let surface: XCUIElement = form.exists && form.isHittable ? form : app
        for turn in 0..<12 where !(target.exists && target.isHittable) {
            if turn < 7 { surface.swipeUp(velocity: .slow) } else { surface.swipeDown(velocity: .slow) }
        }
        XCTAssertTrue(target.exists && target.isHittable, "\(id) cannot be reached")
        return target
    }

    /// Runs the form's connection test and waits until Save can be used.
    private func testUntilItPasses() {
        putKeyboardAway()
        reach("gateway.test", timeout: 2).tap()
        XCTAssertTrue(wait(for: find("gateway.save"), "enabled == true", timeout: 40), "the connection test did not pass")
    }

    /// Return on the last field puts a phone's keyboard away, so the rows under it can be reached. An
    /// iPad's form sheet leaves room above its keyboard; there, after a typed Return, the runner waited its
    /// full two minutes for the app to settle before every later step, so it is left alone.
    private func putKeyboardAway() {
        guard app.windows.firstMatch.frame.width < 700, app.keyboards.firstMatch.exists else { return }
        app.typeText("\n")
    }

    /// The system alert on top (camera, notifications, local network), if one shows.
    private func systemAlert(within seconds: TimeInterval = 6) -> XCUIElement? {
        let alert = XCUIApplication(bundleIdentifier: "com.apple.springboard").alerts.firstMatch
        return alert.waitForExistence(timeout: seconds) ? alert : nil
    }

    /// Types into a form field wherever it is, scrolling either way to reach it.
    private func enter(_ id: String, _ words: String) {
        let field = find(id)
        _ = field.waitForExistence(timeout: 3)
        // A form builds only the rows near the screen, so a field above or below may not exist yet.
        for turn in 0..<10 where !(field.exists && field.isHittable) {
            if turn < 5 { app.swipeDown(velocity: .slow) } else { app.swipeUp(velocity: .slow) }
        }
        XCTAssertTrue(field.exists && field.isHittable, "\(id) cannot be reached")
        field.tap()
        // A tap that lands while the form is still settling gives no focus; tap again.
        if !wait(for: field, "hasKeyboardFocus == true", timeout: 2) { field.tap() }
        if let old = field.value as? String, !old.isEmpty, old != field.placeholderValue {
            field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: old.count))
        }
        field.typeText(words)
    }

    func testWalkTheSetupToAWorkingChat() throws {
        try launchFresh()
        snap("01-welcome-top", settle: 1)
        let start = reach("onboarding.continue", timeout: 30)
        XCTAssertEqual(start.label, "Get started")
        snap("01-welcome")
        start.tap()

        // The phone's one setup page: how it finds the Mac. Back returns to the welcome.
        XCTAssertTrue(find("onboarding.connectManually").waitForExistence(timeout: 10))
        snap("02-home")
        reach("onboarding.back").tap()
        XCTAssertEqual(reach("onboarding.continue").label, "Get started")
        reach("onboarding.continue").tap()

        // Scan QR code opens the scanner sheet (a preview in the demo copy).
        reach("onboarding.continue").tap()
        XCTAssertTrue(find("pairing.close").waitForExistence(timeout: 10))
        snap("03-scan")
        tap("pairing.close")

        // Connect manually, by address, against the mock.
        reach("onboarding.connectManually").tap()
        XCTAssertTrue(find("gateway.save").waitForExistence(timeout: 10), "the gateway form did not open")
        snap("04-manual-form")
        reach("gateway.name").tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 10))
        snap("05-manual-form-keyboard")
        enter("gateway.name", "Studio")
        enter("gateway.url", mockAddress)
        enter("gateway.sessionToken", "mock-token")
        snap("06-manual-form-filled")
        testUntilItPasses()
        snap("07-manual-form-passed")
        tap("gateway.save")

        // Ready: connected, notifications asked here.
        poll(20) { self.find("onboarding.continue").label == "Start chatting" }
        snap("08-ready")
        let allow = app.buttons.matching(NSPredicate(format: "label == 'Allow'")).firstMatch
        if allow.waitForExistence(timeout: 5), allow.isHittable {
            allow.tap()
            if let alert = systemAlert() {
                snap("09-notifications-ask")
                let yes = alert.buttons["Allow"]
                (yes.exists ? yes : alert.buttons.element(boundBy: 1)).tap()
            }
            snap("10-ready-allowed")
        }
        reach("onboarding.continue").tap()
        XCTAssertTrue(chatField.waitForExistence(timeout: 30), "the main chat did not open")
        snap("11-first-chat", settle: 2)
    }

    func testSkipSetupAndComeBack() throws {
        try launchFresh()
        reach("onboarding.skip", timeout: 30).tap()
        pause(2)
        snap("20-skipped")
        print("TREE-SKIPPED\n" + app.debugDescription)
        press("Set up Nollie")
        XCTAssertTrue(find("onboarding.connectManually").waitForExistence(timeout: 10), "Set up Nollie did not go back to setup")
        snap("22-back-in-setup")
        // Something to ask before the Mac is ready.
        let quick = find("quickAnswer.open")
        if quick.exists, quick.isHittable {
            quick.tap()
            snap("23-quick-question", settle: 1.5)
            if app.keyboards.firstMatch.exists { snap("24-quick-question-keyboard") }
        }
    }

    func testWrongAddressAndWrongToken() throws {
        try launchFresh()
        reach("onboarding.continue", timeout: 30).tap()
        reach("onboarding.connectManually").tap()
        XCTAssertTrue(find("gateway.save").waitForExistence(timeout: 10))
        enter("gateway.name", "Studio")
        enter("gateway.url", "http://192.168.4.254:9119")
        enter("gateway.sessionToken", "mock-token")
        putKeyboardAway()
        reach("gateway.test").tap()
        pause(25)
        snap("30-unreachable-address")
        enter("gateway.url", mockAddress)
        enter("gateway.sessionToken", "wrong-token")
        putKeyboardAway()
        reach("gateway.test").tap()
        pause(8)
        snap("31-wrong-token")
        enter("gateway.url", "hermes.local:9119/v1")
        snap("32-odd-address")
    }

    /// The Ready step on its own, connected to the mock: for the largest text sizes, where typing into the
    /// manual form is slow to drive, and for a quick look at any size.
    func testReadyStepPicture() throws {
        try requireMock()
        try launchFresh(["-nollie-demo-gateway", mockAddress, "mock-token", "Studio", "-nollie-show-welcome",
                         "-nollie-demo-onboarding-step", "ready"])
        poll(30) { self.find("onboarding.continue").label == "Start chatting" }
        snap("08-ready", settle: 2)
        if typeSize() { app.swipeUp(velocity: .slow); snap("08-ready-scrolled") }
    }

    private func typeSize() -> Bool { !(ProcessInfo.processInfo.environment["NOLLIE_WALK_SIZE"] ?? "").isEmpty }

    /// The mock is stopped from outside while this waits on the Ready step: the pictures show what a
    /// person sees when the Mac goes to sleep mid-setup.
    func testReadyWhileTheMacGoesAway() throws {
        try launchFresh()
        reach("onboarding.continue", timeout: 30).tap()
        reach("onboarding.connectManually").tap()
        enter("gateway.name", "Studio")
        enter("gateway.url", mockAddress)
        enter("gateway.sessionToken", "mock-token")
        testUntilItPasses()
        tap("gateway.save")
        poll(20) { self.find("onboarding.continue").label == "Start chatting" }
        for second in stride(from: 0, to: 60, by: 10) {
            snap(String(format: "40-ready-away-%02d", second), settle: 10)
        }
        reach("onboarding.continue").tap()
        snap("41-after-tap", settle: 6)
    }

    // MARK: The real app's scanner and Nollie Link codes

    /// A Nollie Link code as the Mac draws it, for a made-up Mac at `host`, running out at `expires`.
    private func linkCode(host: String, expires: Date) -> URL {
        func b64(_ data: Data) -> String {
            data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
        }
        let payload: [String: Any] = ["v": 1, "n": "Studio Mac", "k": b64(Data(repeating: 7, count: 32)), "p": 7420,
                                      "h": [host], "t": "0123456789abcdef", "s": b64(Data(repeating: 9, count: 32)),
                                      "e": Int(expires.timeIntervalSince1970)]
        let json = try! JSONSerialization.data(withJSONObject: payload, options: .sortedKeys)
        return URL(string: "https://nollie.app/pair#" + b64(json))!
    }

    /// The real app (not the demo copy, whose scanner is a picture): the scanner, the camera ask, and codes
    /// opened as links: one for a Mac that is not there, one that ran out, one that is not a code at all.
    func testRealScannerAndLinkCodes() throws {
        try requireMock()
        let env = ProcessInfo.processInfo.environment
        let look: Look = env["NOLLIE_WALK_LOOK"] == "dark" ? .dark : .light
        XCUIDevice.shared.appearance = look.uiAppearance
        XCUIDevice.shared.orientation = env["NOLLIE_WALK_LANDSCAPE"] == "1" ? .landscapeLeft : .portrait
        app = XCUIApplication(bundleIdentifier: "com.coreykozarski.nollie")
        var flags = ["-nollie.onboarding.welcomeIntroSeen", "YES", "-companionPromptShown", "YES", "-colorSchemePreference", look.rawValue]
        if let size = env["NOLLIE_WALK_SIZE"], !size.isEmpty { flags += ["-UIPreferredContentSizeCategoryName", size] }
        app.launchArguments = flags
        app.launch()
        addTeardownBlock { [weak self] in self?.app?.terminate() }
        let frame = app.windows.firstMatch.frame
        let device = frame.width >= 700 ? (frame.height > frame.width ? "ipad" : "ipadland") : (frame.height < 700 ? "se" : "phone")
        prefix = "real-\(device)-\(look.rawValue)-\((env["NOLLIE_WALK_SIZE"] ?? "").isEmpty ? "std" : "ax")-"

        reach("onboarding.continue", timeout: 30).tap()
        reach("onboarding.continue").tap()
        XCTAssertTrue(find("pairing.close").waitForExistence(timeout: 10))
        snap("50-scan")
        if find("pairing.camera.allow").exists {
            reach("pairing.camera.allow").tap()
            if let alert = systemAlert() {
                snap("51-camera-ask")
                let yes = alert.buttons["Allow"]
                (yes.exists ? yes : alert.buttons.element(boundBy: 1)).tap()
            }
            snap("52-camera-after", settle: 3)
        }
        tap("pairing.close")

        app.open(linkCode(host: "10.255.255.1", expires: Date().addingTimeInterval(110)))
        XCTAssertTrue(find("link.confirm").waitForExistence(timeout: 10), "the code did not open the link sheet")
        snap("53-link-confirm")
        reach("link.confirm").tap()
        if let alert = systemAlert(within: 4) {
            snap("54-local-network-ask")
            let yes = alert.buttons["Allow"]
            (yes.exists ? yes : alert.buttons.element(boundBy: 1)).tap()
        }
        snap("55-link-finding", settle: 1)
        poll(40) { self.find("pairing.issue").exists }
        snap("56-link-unreachable")
        tap("pairing.close")

        app.open(linkCode(host: "10.255.255.1", expires: Date().addingTimeInterval(-600)))
        snap("57-link-expired", settle: 3)
        if find("pairing.close").exists { tap("pairing.close") }
        app.open(URL(string: "https://nollie.app/pair#bm90LWEtY29kZQ")!)
        snap("58-link-garbled", settle: 3)
    }
}
