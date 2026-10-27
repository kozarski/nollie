import XCTest

/// Common base class for the UI flows. A flow opens the iPhone demo build and points it at the mock
/// gateway named in the runner's environment, then behaves as a user would. All shared tooling is
/// here: launching, element lookup, waiting, typing, screenshots, and the mock's control calls.
///
/// Settings arrive from `Tools/dev/verify.py` as TEST_RUNNER_ environment entries (the HERMES_E2E_
/// URL, TOKEN and BUNDLE ones). If either the mock or the demo build is missing a flow skips,
/// though for the golden flows a skip fails the entire run.
@MainActor
class DemoCase: XCTestCase {
    enum Look: String, CaseIterable {
        case light, dark
        var uiAppearance: XCUIDevice.Appearance { self == .dark ? .dark : .light }
    }

    /// The running app. Set by `startDemo`.
    var app: XCUIApplication!

    /// Where the mock gateway listens, for the control routes a flow calls itself.
    private(set) var mockAddress = ""

    /// On the first failed check, writes out what was on screen so the failure can be read without
    /// running the flow again.
    override func record(_ issue: XCTIssue) {
        if let app, app.state == .runningForeground, !reportedScreen {
            reportedScreen = true
            // One snapshot of the whole screen, keyboard keys left out.
            let seen = app.debugDescription.split(separator: "\n").filter { line in
                !line.contains("Key,") && !line.contains("Padding-")
            }.prefix(260)
            print("SCREEN-AT-FAILURE\n" + seen.joined(separator: "\n"))
            shot("FAILED-" + name.filter { $0.isLetter || $0.isNumber })
        }
        super.record(issue)
    }
    private var reportedScreen = false

    // MARK: Starting the app

    /// Checks that the runner points at a local mock gateway and the demo copy, or skips the flow.
    @discardableResult
    func requireMock() throws -> (address: String, bundle: String) {
        let env = ProcessInfo.processInfo.environment
        guard let address = env["HERMES_E2E_URL"], let url = URL(string: address), url.scheme == "http",
              ["127.0.0.1", "localhost", "::1"].contains(url.host ?? ""), env["HERMES_E2E_TOKEN"] == "mock-token" else {
            throw XCTSkip("Needs the local mock gateway (HERMES_E2E_URL, HERMES_E2E_TOKEN=mock-token)")
        }
        let bundle = env["HERMES_E2E_BUNDLE"].flatMap { $0.isEmpty ? nil : $0 } ?? "com.coreykozarski.nollie.demo"
        guard bundle.hasSuffix(".demo") else { throw XCTSkip("Runs only in the demo copy") }
        mockAddress = address
        continueAfterFailure = false
        return (address, bundle)
    }

    /// Launches the demo copy fresh, with the mock gateway saved and the first-run cards out of the
    /// way. `extra` adds launch flags; `withGateway: false` starts with nothing saved (onboarding).
    /// Returns once the bots list is up, unless `waitForBots` is off.
    func startDemo(_ extra: [String] = [], look: Look = .light, portrait: Bool = true,
                   withGateway: Bool = true, waitForBots: Bool = true) throws {
        let (address, bundle) = try requireMock()
        app?.terminate()
        if portrait { XCUIDevice.shared.orientation = .portrait }
        XCUIDevice.shared.appearance = look.uiAppearance
        app = XCUIApplication(bundleIdentifier: bundle)
        // Face ID before a yes to sending would wait on a system prompt no test answers; unit tests cover it.
        var flags = ["-companionPromptShown", "YES", "-colorSchemePreference", look.rawValue, "-approvals.ownerCheck", "NO"]
        if withGateway {
            flags += ["-nollie-demo-gateway", address, "mock-token", "Studio",
                      "-notificationsSetupCardDone", "YES", "-bots.animate", "NO"] + Self.weeklyCardPutAway
        }
        app.launchArguments = flags + extra
        app.launch()
        addTeardownBlock { [weak self] in self?.app?.terminate() }
        if withGateway, waitForBots {
            XCTAssertTrue(find("bots.list").waitForExistence(timeout: 30), "the bots list did not come up")
        }
    }

    /// The weekly note's card opens the main chat's thread and moves the first messages down, so a
    /// flow about something else starts with it put away, like the other first-run cards. A flow about
    /// the note leaves this flag out.
    static let weeklyCardPutAway = ["-nollie.weekly.putAway", "<date>2099-01-01T00:00:00Z</date>"]

    /// Posts a control call to the local mock gateway and waits for its answer, without the main actor:
    /// safe in any tear-down, even after a failure stopped the flow. Nothing happens without the mock.
    nonisolated static func resetMock(_ path: String, _ body: [String: Any]) {
        let env = ProcessInfo.processInfo.environment
        guard let address = env["HERMES_E2E_URL"], let base = URL(string: address), base.scheme == "http",
              ["127.0.0.1", "localhost", "::1"].contains(base.host ?? ""), env["HERMES_E2E_TOKEN"] == "mock-token" else { return }
        var request = URLRequest(url: base.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.timeoutInterval = 8
        request.setValue("Bearer mock-token", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        let answered = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: request) { _, _, _ in answered.signal() }.resume()
        _ = answered.wait(timeout: .now() + 10)
    }

    /// Runs `body` once in light and once in dark, each on a fresh launch (the app is ended after).
    func inBothLooks(_ body: (Look) throws -> Void) rethrows {
        for look in Look.allCases {
            try body(look)
            app?.terminate()
        }
    }

    // MARK: Finding things

    /// The first element of any kind with this accessibility identifier.
    func find(_ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "identifier == %@", id)).firstMatch
    }

    /// The chat's text field.
    var chatField: XCUIElement { app.textViews["composer.text"].firstMatch }

    /// A button by its exact label, for the things that carry no identifier (menu items, dialogs).
    func buttonNamed(_ label: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label == %@", label)).firstMatch
    }

    /// Waits for an element and fails with these words when it never turns up.
    @discardableResult
    func expectShown(_ element: XCUIElement, within seconds: TimeInterval = 15, _ words: String,
                     file: StaticString = #filePath, line: UInt = #line) -> XCUIElement {
        XCTAssertTrue(element.waitForExistence(timeout: seconds), words, file: file, line: line)
        return element
    }

    /// The first element of any kind whose label contains these words (case sensitive).
    func labelled(_ words: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", words)).firstMatch
    }

    /// The first static text whose label contains these words.
    func text(_ words: String) -> XCUIElement {
        app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", words)).firstMatch
    }

    /// Static texts whose label contains these words, as a query (for counting).
    func texts(_ words: String) -> XCUIElementQuery {
        app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", words))
    }

    /// The first of a query's elements that is on screen and can be touched, once one is.
    func touchable(_ query: XCUIElementQuery, timeout: TimeInterval = 10) -> XCUIElement? {
        var found: XCUIElement?
        poll(timeout, every: 0.25) {
            found = query.allElementsBoundByIndex.first { $0.exists && $0.isHittable }
            return found != nil
        }
        return found
    }

    /// An element with this identifier that is on screen and can be touched. Fails the flow when it
    /// never is.
    @discardableResult
    func ready(_ id: String, timeout: TimeInterval = 15, file: StaticString = #filePath, line: UInt = #line) -> XCUIElement {
        let target = find(id)
        XCTAssertTrue(target.waitForExistence(timeout: timeout), "\(id) is not there", file: file, line: line)
        poll(timeout, every: 0.25) { target.isHittable }
        XCTAssertTrue(target.isHittable, "\(id) is there but cannot be touched", file: file, line: line)
        return target
    }

    func tap(_ id: String, timeout: TimeInterval = 15, file: StaticString = #filePath, line: UInt = #line) {
        ready(id, timeout: timeout, file: file, line: line).tap()
    }

    /// Taps the first button with this exact label (menu items and dialog buttons have no identifier).
    func press(_ label: String, timeout: TimeInterval = 10, file: StaticString = #filePath, line: UInt = #line) {
        let button = app.buttons.matching(NSPredicate(format: "label == %@", label)).firstMatch
        XCTAssertTrue(button.waitForExistence(timeout: timeout), "no \"\(label)\" button", file: file, line: line)
        button.tap()
    }

    /// Swipes up until the element can be touched (a list builds its lower rows only when they are near).
    func scrollTo(_ id: String, swipes: Int = 8, file: StaticString = #filePath, line: UInt = #line) -> XCUIElement {
        let target = find(id)
        for _ in 0..<swipes where !(target.exists && target.isHittable) { app.swipeUp(velocity: .slow) }
        XCTAssertTrue(target.exists && target.isHittable, "could not scroll to \(id)", file: file, line: line)
        return target
    }

    /// Turns a switch (the control inside its row when the row wraps it).
    func flip(_ toggle: XCUIElement) {
        let knob = toggle.switches.firstMatch
        (knob.exists ? knob : toggle).tap()
    }

    // MARK: Waiting

    /// Calls `condition` until it is true or the time is up; true when it held.
    @discardableResult
    func poll(_ seconds: TimeInterval, every step: TimeInterval = 0.3, _ condition: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(step))
        }
        return condition()
    }

    /// Lets the app run for a moment (animations, settling).
    func pause(_ seconds: TimeInterval) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    /// Waits for an element to satisfy an NSPredicate (for example `value == '1'`).
    @discardableResult
    func wait(for element: XCUIElement, _ format: String, timeout: TimeInterval = 15) -> Bool {
        let met = XCTNSPredicateExpectation(predicate: NSPredicate(format: format), object: element)
        return XCTWaiter.wait(for: [met], timeout: timeout) == .completed
    }

    // MARK: Chats

    /// Opens a bot's main chat from the bots list.
    func openBot(_ name: String = "default") {
        tap("bots.row.\(name)", timeout: 30)
        XCTAssertTrue(find("composer.text").waitForExistence(timeout: 30), "the \(name) chat did not open")
    }

    /// From an open chat, a fresh side chat with the same bot, through the chat's menu.
    func startSideChat() {
        tap("chat.more", timeout: 30)
        tap("botmenu.sideChat")
        XCTAssertTrue(find("composer.text").waitForExistence(timeout: 30), "the side chat did not open")
    }

    /// Types into the chat's composer. A busy simulator now and then drops a key, so the text is
    /// checked and typed again when it is not what was meant.
    @discardableResult
    func typeMessage(_ words: String) -> XCUIElement {
        let composer = expectShown(chatField, within: 30, "no composer")
        composer.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 10), "the keyboard did not come up")
        pause(0.4)
        // An empty field reads as its placeholder ("Message Nollie"); a draft left by an earlier flow
        // comes back with the chat and is cleared first.
        func typedNow() -> String {
            let now = composer.value as? String ?? ""
            return now == composer.placeholderValue || now.hasPrefix("Message ") ? "" : now
        }
        for _ in 0..<3 {
            let leftover = typedNow()
            if !leftover.isEmpty {
                // The caret goes to the end of the old words first, then they are deleted back to nothing.
                composer.coordinate(withNormalizedOffset: CGVector(dx: 0.97, dy: 0.5)).tap()
                composer.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: leftover.count + 2))
            }
            composer.typeText(words)
            if typedNow() == words { break }
        }
        XCTAssertEqual(typedNow(), words, "the message was not typed as written")
        return composer
    }

    /// Types a message and sends it.
    func send(_ words: String) {
        typeMessage(words)
        tap("composer.send", timeout: 10)
    }

    /// Sends the message and waits for the turn to start. If the text is still in the field because
    /// the first tap hit the button mid-change, it taps again.
    func sendAndWait(_ words: String, forText first: String) {
        let composer = typeMessage(words)
        for _ in 0..<3 {
            let unsent = (composer.value as? String)?.isEmpty == false
            guard unsent, let button = touchable(app.buttons.matching(identifier: "composer.send"), timeout: 5) else { break }
            button.tap()
            if text(first).waitForExistence(timeout: 10) { break }
        }
        XCTAssertTrue(text(first).exists, "the turn did not start (no \"\(first)\")")
    }

    /// The usual start of a thread flow: the demo copy, the default bot, a fresh side chat and a first
    /// message sent.
    func beginSideChat(saying words: String, extra: [String] = [], look: Look = .light) throws {
        try startDemo(extra, look: look)
        openBot("default")
        startSideChat()
        send(words)
    }

    /// A side chat whose first turn is a long run, waited for until its report is whole.
    func beginLongThread(steps: Int = 30, extra: [String] = [], look: Look = .light) throws {
        try beginSideChat(saying: "marathon \(steps)", extra: extra, look: look)
        XCTAssertTrue(text("Nothing else needed attention").waitForExistence(timeout: TimeInterval(steps) * 3 + 60),
                      "the long run never finished")
        pause(1.5)
    }

    /// Where the thread shows: under the header's title and above the composer, in screen points.
    var threadBand: ClosedRange<CGFloat> {
        let top = find("chat.titlePill").frame.maxY
        let bottom = chatField.frame.minY
        return top...max(top, bottom)
    }

    /// Moves the thread toward its start (the finger goes down) or toward its end (the finger goes up).
    func scrollThread(towardStart: Bool, times: Int = 1) {
        for _ in 0..<times {
            let from = CGVector(dx: 0.5, dy: towardStart ? 0.3 : 0.7)
            let to = CGVector(dx: 0.5, dy: towardStart ? 0.7 : 0.3)
            drag(from: from, to: to)
        }
    }

    /// Every piece of static text on screen with its frame, from one snapshot of the screen (asking
    /// element by element takes minutes on a long thread).
    func staticTextsOnScreen() -> [(label: String, frame: CGRect)] {
        guard let screen = try? app.snapshot() else { return [] }
        var found: [(String, CGRect)] = []
        func collect(_ node: XCUIElementSnapshot) {
            if node.elementType == .staticText, !node.label.isEmpty { found.append((node.label, node.frame)) }
            node.children.forEach(collect)
        }
        collect(screen)
        return found
    }

    /// The topmost bit of real text that sits fully inside the thread band, with where it stands.
    /// Only words that belong to one place count: no times, no repeated step cards, no counters.
    func topmostThreadText() -> (label: String, minY: CGFloat)? {
        let band = threadBand
        let all = staticTextsOnScreen()
        let counts = Dictionary(all.map { ($0.label, 1) }, uniquingKeysWith: +)
        return all
            .filter { entry in
                entry.label.count > 8 && !entry.label.hasPrefix("Today") && !entry.label.hasPrefix("Ran ")
                    && !entry.label.hasPrefix("Running") && counts[entry.label] == 1
                    && entry.frame.minY >= band.lowerBound + 4 && entry.frame.maxY <= band.upperBound - 4 && entry.frame.height > 0
            }
            .min { $0.frame.minY < $1.frame.minY }
            .map { (label: $0.label, minY: $0.frame.minY) }
    }

    /// Where the text with this label stands now (nil when it is not drawn).
    func minY(ofText label: String) -> CGFloat? {
        staticTextsOnScreen().first { $0.label == label }?.frame.minY
    }

    /// Pulls the keyboard down by dragging the thread down into it, as a person does.
    func dismissKeyboard() {
        guard app.keyboards.firstMatch.exists else { return }
        drag(from: CGVector(dx: 0.5, dy: 0.22), to: CGVector(dx: 0.5, dy: 0.98))
        pause(1)
    }

    /// Taps a point of the screen, given as fractions of its width and height.
    func tapAt(_ x: CGFloat, _ y: CGFloat) {
        app.coordinate(withNormalizedOffset: CGVector(dx: x, dy: y)).tap()
    }

    /// Presses an element and drags it to a point (or another element), as a person moves a card.
    func dragElement(_ element: XCUIElement, to target: XCUICoordinate, hold: TimeInterval = 0.6) {
        element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: hold, thenDragTo: target)
    }

    /// Slides across an element sideways by this many points (negative goes left).
    func slide(_ element: XCUIElement, by points: CGFloat) {
        let start = element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: points, dy: 0)))
    }

    /// A moment for a menu or sheet to finish drawing, then its picture.
    func look(_ name: String, after settle: TimeInterval = 0.8) {
        pause(settle)
        shot(name)
    }

    /// Drags a point on screen to another, by the fractions of the window.
    func drag(from start: CGVector, to end: CGVector) {
        app.coordinate(withNormalizedOffset: start).press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: end))
    }

    // MARK: The Board

    /// Opens the Board from the bots list.
    func openBoard() {
        tap("chats.board", timeout: 30)
        XCTAssertTrue(find("board.list").waitForExistence(timeout: 20), "the Board did not open")
    }

    /// A card on the Board whose words contain these.
    func boardCard(_ words: String) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'board.task.' AND label CONTAINS %@", words)).firstMatch
    }

    /// Pages the lanes sideways until a card with these words can be touched.
    @discardableResult
    func pageToCard(_ words: String) -> XCUIElement {
        let card = boardCard(words)
        let list = find("board.list").frame
        let y = list.minY + 70
        for turn in 0..<6 where !(card.exists && card.isHittable) {
            // Right, then left again, so all three lanes are visited.
            let toTheRight = turn < 3
            let from = CGVector(dx: list.minX + list.width * (toTheRight ? 0.15 : 0.85), dy: y)
            let to = CGVector(dx: list.minX + list.width * (toTheRight ? 0.85 : 0.15), dy: y)
            app.coordinate(withNormalizedOffset: .zero).withOffset(from)
                .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: .zero).withOffset(to))
            pause(0.6)
        }
        XCTAssertTrue(card.exists && card.isHittable, "no card on the Board with \"\(words)\"")
        return card
    }

    // MARK: Pictures

    /// Attaches a screenshot to the result, and also saves a PNG when HERMES_E2E_SHOTS points at a folder.
    func shot(_ name: String) {
        let screenshot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        guard let folder = ProcessInfo.processInfo.environment["HERMES_E2E_SHOTS"], !folder.isEmpty else { return }
        let directory = URL(fileURLWithPath: folder, isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? screenshot.pngRepresentation.write(to: directory.appendingPathComponent("\(name).png"))
    }

    /// Keeps what the screen holds, as text, with the test result: for a picture where something is missing.
    func keepTree(_ name: String) {
        let attachment = XCTAttachment(string: app.debugDescription)
        attachment.name = name + ".txt"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    // MARK: The mock gateway's control routes

    /// One call to the mock, answered as JSON (an empty body asks with GET, anything else posts).
    /// Fails the flow when the mock does not answer 200.
    @discardableResult
    func mock(_ path: String, _ body: [String: Any]? = nil, method: String? = nil) -> [String: Any] {
        guard let url = URL(string: mockAddress + path) else {
            XCTFail("no address for the mock")
            return [:]
        }
        var request = URLRequest(url: url)
        request.httpMethod = method ?? (body == nil ? "GET" : "POST")
        request.timeoutInterval = 8
        request.setValue("Bearer mock-token", forHTTPHeaderField: "Authorization")
        if let body {
            request.httpBody = try? JSONSerialization.data(withJSONObject: body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let answer = MockAnswer()
        let arrived = expectation(description: "the mock answered \(path)")
        URLSession.shared.dataTask(with: request) { data, response, _ in
            answer.status = (response as? HTTPURLResponse)?.statusCode ?? 0
            answer.json = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
            arrived.fulfill()
        }.resume()
        XCTWaiter().wait(for: [arrived], timeout: 10)
        XCTAssertEqual(answer.status, 200, "the mock refused \(path)")
        return answer.json
    }

    /// The mock's reply, handed from the URL session's queue to the flow (the expectation orders them).
    private final class MockAnswer: @unchecked Sendable {
        var status = 0
        var json: [String: Any] = [:]
    }
}
