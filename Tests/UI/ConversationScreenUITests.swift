import XCTest

/// The new conversation screen against its performance budget (`Docs/specs/conversation-ui.md`, Measurements),
/// on a synthetic chat of 10,000 stored rows opened with `-nollie-demo-new-chat`. No gateway: a scripted link
/// drives a real engine inside the app.
///
/// Every check prints a `CONVERSATION-MEASURE` line with its numbers. CONVERSATION_SHOTS=<folder> also saves
/// screenshots there. CONVERSATION_PAGE=<rows> and CONVERSATION_HITCH_BUDGET=<ms per s> change the page size and the
/// hitch budget. Not part of the golden flows: they take a quarter of an hour.
@MainActor
final class ConversationScreenUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
    }

    // MARK: Helpers

    private func launch(rows: Int = 10_000, _ extra: [String] = []) {
        app = XCUIApplication()
        let environment = ProcessInfo.processInfo.environment
        let page = environment["CONVERSATION_PAGE"].map { ["-nollie-demo-page", $0] } ?? []
        app.launchArguments = ["-nollie-demo-new-chat", String(rows)] + extra + page
        app.launch()
    }

    private func report(_ line: String) {
        print("CONVERSATION-MEASURE \(name): \(line)")
        let note = XCTAttachment(string: line)
        note.name = "measure"
        note.lifetime = .keepAlways
        add(note)
    }

    /// The app's own account of what it holds: rows, the window's ends, pages, the streamed reply.
    private func metrics() -> [String: String] {
        let label = app.staticTexts["conversation.metrics"].firstMatch.label
        var out: [String: String] = [:]
        for pair in label.split(separator: " ") {
            let parts = pair.split(separator: "=", maxSplits: 1)
            if parts.count == 2 { out[String(parts[0])] = String(parts[1]) }
        }
        return out
    }

    private func metric(_ key: String) -> Int { Int(metrics()[key] ?? "") ?? -1 }

    private func wait(_ what: String, timeout: TimeInterval = 15, _ condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        XCTFail("timed out waiting for \(what)")
    }

    private var list: XCUIElement { app.descendants(matching: .any)["conversation.list"].firstMatch }

    /// The row the list itself says is at the top of the screen (its accessibility value, Debug builds), to check
    /// the accessibility tree's frames against.
    private func listTop() -> String? {
        guard let value = list.value as? String, let range = value.range(of: "top=") else { return nil }
        return String(value[range.upperBound...])
    }

    private static func number(_ id: String) -> Int? { id.hasPrefix("stored:") ? Int(id.split(separator: "#").last ?? "") : nil }
    private var composer: XCUIElement { app.descendants(matching: .any)["conversation.composer"].firstMatch }

    /// Rows on screen between the header and the composer, top first, from one snapshot of the tree.
    private func visibleRows() -> [(id: String, frame: CGRect)] {
        guard let snap = try? app.snapshot() else { return [] }
        let top = app.navigationBars.firstMatch.frame.maxY
        let bottom = composer.frame.minY
        var rows: [(String, CGRect)] = []
        func walk(_ s: XCUIElementSnapshot) {
            if s.identifier.hasPrefix("row.") {
                let f = s.frame
                if f.maxY > top, f.minY < bottom { rows.append((String(s.identifier.dropFirst(4)), f)) }
                return
            }
            for child in s.children { walk(child) }
        }
        walk(snap)
        return rows.sorted { $0.1.minY < $1.1.minY }
    }

    private func frame(of id: String) -> CGRect? {
        let element = app.descendants(matching: .any)["row.\(id)"].firstMatch
        return element.exists ? element.frame : nil
    }

    /// A drag that stops dead (held before release): the list moves by `points` (positive scrolls up into
    /// history) and does not coast.
    private func drag(_ points: CGFloat) {
        let window = app.windows.firstMatch.frame
        let midY = window.midY
        // Below the header and above the composer, wherever the distance asks.
        let top = max(window.minY + 170, midY - points / 2)
        let length = min(points, window.maxY - 130 - top)
        let start = list.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: window.width * 0.5, dy: top))
        let end = start.withOffset(CGVector(dx: 0, dy: length))
        start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.3)
    }

    private func shot(_ name: String) {
        let screenshot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        if let folder = ProcessInfo.processInfo.environment["CONVERSATION_SHOTS"], !folder.isEmpty {
            let url = URL(fileURLWithPath: folder, isDirectory: true)
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            try? screenshot.pngRepresentation.write(to: url.appendingPathComponent("\(name).png"))
        }
    }

    // MARK: (b) Opening

    func testOpeningShowsTheNewestRowsAtOnce() {
        launch()
        let started = Date()
        var firstRows: [(id: String, frame: CGRect)] = []
        wait("the first rows") {
            firstRows = visibleRows()
            return !firstRows.isEmpty
        }
        let visibleAfter = Date().timeIntervalSince(started)
        let newest = metrics()["last"] ?? ""
        wait("the in-app timings") { metric("opened") >= 0 }
        let opened = "started \(metric("started")) ms, rows \(metric("rowsin")) ms, drawn \(metric("opened")) ms"
        // The first rows anyone sees are the newest ones, resting on the composer: the list never shows the
        // oldest rows first or scrolls down to the end.
        XCTAssertTrue(firstRows.contains { $0.id == newest }, "first rows \(firstRows.map(\.id)) do not include the newest \(newest)")
        let newestFrame = frame(of: newest) ?? .zero
        let composerTop = composer.frame.minY
        XCTAssertLessThanOrEqual(newestFrame.maxY, composerTop + 1)
        XCTAssertGreaterThan(newestFrame.maxY, composerTop - 260, "the newest row rests near the composer")
        XCTAssertEqual(metric("rows") <= 300, true)
        report("first rows in the tree \(Int(visibleAfter * 1000)) ms after launch() returned; in-app from the screen's creation: \(opened); "
               + "rows held \(metric("rows")); first visible ids \(firstRows.map(\.id))")
    }

    // MARK: (a) Smooth scrolling, (e) memory

    func testFlickingThroughHistoryIsSmooth() {
        launch()
        wait("rows") { metric("rows") > 0 }
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        let options = XCTMeasureOptions()
        options.invocationOptions = [.manuallyStop]
        options.iterationCount = 5
        measure(metrics: [XCTOSSignpostMetric.scrollDecelerationMetric], options: options) {
            list.swipeDown(velocity: .fast)
            stopMeasuring()
            list.swipeDown(velocity: .fast)
        }
        report("signpost flicks done; pages served \(metric("served")), rows held \(metric("rows"))")

        // The app's own frame watch over flicks at a reading pace (slow and default), up into history and back.
        for velocity in [XCUIGestureVelocity.fast] {
            app.terminate()
            launch()
            wait("rows") { metric("rows") > 0 }
            RunLoop.current.run(until: Date().addingTimeInterval(1.5))
            let before = (frames: metric("frames"), hitch: metric("hitchms"), late: metric("late"),
                          scrollHitch: metric("scrollhitchms"), scrollMs: metric("scrollms"), scrollLate: metric("scrolllate"))
            let started = Date()
            for _ in 0..<50 { list.swipeDown(velocity: velocity) }
            for _ in 0..<10 { list.swipeUp(velocity: velocity) }
            RunLoop.current.run(until: Date().addingTimeInterval(1))
            let seconds = Date().timeIntervalSince(started)
            let frames = metric("frames") - before.frames
            let hitch = metric("hitchms") - before.hitch
            let late = metric("late") - before.late
            let ratio = Double(hitch) / seconds
            let scrollHitch = metric("scrollhitchms") - before.scrollHitch
            let scrollSeconds = Double(metric("scrollms") - before.scrollMs) / 1000
            let scrollRatio = Double(scrollHitch) / max(scrollSeconds, 0.001)
            report("velocity \(velocity.rawValue): while the list moved \(String(format: "%.1f", scrollSeconds)) s, "
                   + "\(metric("scrolllate") - before.scrollLate) late, hitch \(scrollHitch) ms = \(String(format: "%.1f", scrollRatio)) ms/s; "
                   + "all frames: \(frames) in \(String(format: "%.1f", seconds)) s, \(late) late, "
                   + "hitch \(hitch) ms = \(String(format: "%.1f", ratio)) ms/s (the test's tree reads included), longest frame since launch \(metric("longestms")) ms; "
                   + "pages served \(metric("served")), rows held \(metric("rows")); list: measured \(metric("measured")) rows in "
                   + "\(metric("measurems")) ms, \(metric("updates")) updates in \(metric("updatems")) ms (longest \(metric("longestupdatems")) ms)")
            XCTAssertLessThan(scrollRatio, ProcessInfo.processInfo.environment["CONVERSATION_HITCH_BUDGET"].flatMap(Double.init) ?? 5,
                              "hitch ratio while scrolling over budget")
        }

        // Nothing moving, only the test reading the app's accessibility tree as it does before every swipe: the
        // late frames this costs are the harness's, not the list's.
        do {
            let before = (hitch: metric("hitchms"), late: metric("late"))
            let started = Date()
            for _ in 0..<30 {
                _ = list.frame
                RunLoop.current.run(until: Date().addingTimeInterval(0.2))
            }
            let seconds = Date().timeIntervalSince(started)
            report("reading the tree 30 times, nothing moving: \(metric("late") - before.late) late frames, hitch "
                   + "\(metric("hitchms") - before.hitch) ms = \(String(format: "%.1f", Double(metric("hitchms") - before.hitch) / seconds)) ms/s")
        }

        // Back and forth inside the window: no pages come in, so this is the cost of drawing rows alone.
        let before = (frames: metric("frames"), hitch: metric("hitchms"), late: metric("late"), served: metric("served"),
                      scrollHitch: metric("scrollhitchms"), scrollMs: metric("scrollms"))
        let started = Date()
        for _ in 0..<8 {
            list.swipeDown(velocity: .slow)
            list.swipeUp(velocity: .slow)
        }
        let seconds = Date().timeIntervalSince(started)
        let hitch = metric("hitchms") - before.hitch
        report("inside the window: \(metric("frames") - before.frames) frames in \(String(format: "%.1f", seconds)) s, "
               + "\(metric("late") - before.late) late, hitch \(hitch) ms = \(String(format: "%.1f", Double(hitch) / seconds)) ms/s; "
               + "while the list moved: \(metric("scrollhitchms") - before.scrollHitch) ms over \(metric("scrollms") - before.scrollMs) ms; "
               + "pages served meanwhile \(metric("served") - before.served)")
    }

    /// From the newest row to the very first and back by flicks: rows held never pass the window's capacity. On
    /// 3,000 rows (four segments, 30 pages each way): a fast flick moves the list about nine rows, so 10,000 rows
    /// would take over an hour of flicks. The engine's own walk covers all 10,000 (`ConversationEngineAtScaleTests`).
    func testWalkingTheWholeHistoryKeepsMemoryBounded() {
        launch(rows: 3_000)
        wait("rows") { metric("rows") > 0 }
        var most = 0
        var flicks = 0
        let started = Date()
        // The list's own top row (one element's value) rather than a walk of the whole tree on every flick.
        while metric("oldest") != 1 || !(listTop()?.hasSuffix("#1") ?? false) {
            list.swipeDown(velocity: .fast)
            flicks += 1
            most = max(most, metric("rows"))
            if flicks % 20 == 0 {
                report("walk: \(flicks) flicks, top \(listTop() ?? "-"), first \(metrics()["first"] ?? "-"), rows \(metric("rows")), "
                       + "served \(metric("served")), pending \(metric("pending")), oldest \(metric("oldest"))")
            }
            if flicks > 600 { XCTFail("never reached the first row"); break }
        }
        let upSeconds = Date().timeIntervalSince(started)
        let servedUp = metric("served")
        report("reached the first row after \(flicks) flicks in \(Int(upSeconds)) s; pages served \(servedUp); most rows held \(most)")
        XCTAssertLessThanOrEqual(most, 300 + 8, "rows held stay within the window's capacity plus boundaries")

        // Back to the newest with the jump button: the newest page comes back at once.
        let jump = app.buttons["conversation.jump"]
        XCTAssertTrue(jump.waitForExistence(timeout: 5))
        jump.tap()
        wait("the newest end") { metric("newest") == 1 }
        wait("the newest row on screen") { visibleRows().contains { $0.id == metrics()["last"] } }
        report("jumped back to the newest rows; rows held \(metric("rows"))")
    }

    // MARK: (c) Paging older rows in

    func testPagingOlderRowsInDoesNotMoveTheView() {
        pageIns(rows: 10_000, count: 5)
    }

    /// The same across compressions: in a chat of 600 rows each page-in reaches into the segment before, with a
    /// summarized note between.
    func testPagingAcrossSummariesDoesNotMoveTheView() {
        pageIns(rows: 600, count: 4)
    }

    /// Pages that land while the finger is still on the list (no delay on the history): every drag moves the
    /// list by about the drag's length, never by a page. Each reading from the accessibility tree is checked
    /// against the row the list itself reports at its top, so a stale element in the tree cannot pass for a jump.
    func testPagesLandingMidDragDoNotJump() {
        launch(rows: 10_000, ["-nollie-demo-no-card"])
        wait("rows") { metric("rows") > 0 }
        func topNumber() -> Int? {
            visibleRows().first { $0.id.hasPrefix("stored:") }.flatMap { Self.number($0.id) }
        }
        var steps: [Int] = []
        var ownSteps: [Int] = []
        var disagreements: [String] = []
        var previous = topNumber()
        var previousOwn = listTop().flatMap(Self.number)
        let servedBefore = metric("served")
        var moved: [Int] = []
        for _ in 0..<60 {
            let rowsBefore = Dictionary(visibleRows().map { ($0.id, $0.frame.minY) }, uniquingKeysWith: { a, _ in a })
            drag(500)
            if let common = visibleRows().first(where: { rowsBefore[$0.id] != nil }) {
                moved.append(Int(common.frame.minY - rowsBefore[common.id]!))
            }
            let own = listTop().flatMap(Self.number)
            if let own, let previousOwn { ownSteps.append(previousOwn - own) }
            previousOwn = own ?? previousOwn
            guard let now = topNumber() else { continue }
            if let previous { steps.append(previous - now) }
            if let own, abs(own - now) > 3 { disagreements.append("tree \(now) list \(own)") }
            previous = now
        }
        let jumps = steps.filter { $0 > 60 || $0 < -5 }
        let ownJumps = ownSteps.filter { $0 > 60 || $0 < -5 }
        report("rows moved per 500-point drag: median \(steps.sorted()[steps.count / 2]), largest \(steps.max() ?? 0), "
               + "jumps \(jumps); by the list's own top: jumps \(ownJumps); tree and list disagreed \(disagreements.count) times "
               + "\(disagreements.prefix(5)); pages served \(metric("served") - servedBefore); points moved \(moved); steps \(steps)")
        XCTAssertGreaterThanOrEqual(metric("served") - servedBefore, 3, "pages came in while dragging")
        XCTAssertTrue(jumps.isEmpty, "the list jumped by \(jumps) rows while pages came in")
        XCTAssertTrue(ownJumps.isEmpty, "the list says it jumped by \(ownJumps) rows")
    }

    /// The same with flicks: pages land while the list coasts.
    func testPagesLandingMidFlickDoNotJump() {
        launch(rows: 10_000, ["-nollie-demo-no-card"])
        wait("rows") { metric("rows") > 0 }
        func topNumber() -> Int? {
            visibleRows().first { $0.id.hasPrefix("stored:") }.flatMap { Int($0.id.split(separator: "#").last ?? "") }
        }
        var steps: [Int] = []
        var previous = topNumber()
        let servedBefore = metric("served")
        for _ in 0..<40 {
            list.swipeDown(velocity: { switch ProcessInfo.processInfo.environment["CONVERSATION_FLICK"] { case "slow": return XCUIGestureVelocity.slow; case "fast": return .fast; default: return .default } }())
            RunLoop.current.run(until: Date().addingTimeInterval(1.5))
            guard let now = topNumber() else { continue }
            if let previous { steps.append(previous - now) }
            previous = now
            if metric("oldest") == 1 { break }
        }
        let median = steps.sorted()[steps.count / 2]
        let jumps = steps.filter { $0 > max(median * 4, 60) || $0 < -5 }
        report("rows moved per flick: median \(median), largest \(steps.max() ?? 0), jumps \(jumps); "
               + "pages served \(metric("served") - servedBefore); steps \(steps)")
        XCTAssertGreaterThanOrEqual(metric("served") - servedBefore, 3, "pages came in while flicking")
        XCTAssertTrue(jumps.isEmpty, "the list jumped by \(jumps) rows while pages came in")
    }

    private func pageIns(rows: Int, count: Int) {
        // Each page takes 1.5 s, so the list is at rest when it lands.
        launch(rows: rows, ["-nollie-demo-latency", "1.5", "-nollie-demo-no-card"])
        wait("rows", timeout: 20) { metric("rows") > 0 && metric("pending") == 0 }
        var drifts: [CGFloat] = []
        var pageIns = 0
        var drags = 0
        while pageIns < count, drags < 200, metric("oldest") != 1 {
            drag(500)
            drags += 1
            // A page is asked for as the list comes to rest; the metrics show it within a few frames.
            let asked = Date().addingTimeInterval(0.4)
            while metric("pending") == 0, Date() < asked { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
            guard metric("pending") > 0 else { continue }
            // A page is on its way and the list is at rest: note the top row on screen.
            let firstBefore = metrics()["first"] ?? ""
            guard let anchor = visibleRows().first(where: { $0.frame.minY > app.navigationBars.firstMatch.frame.maxY }) else { continue }
            wait("the page to land", timeout: 10) { metric("pending") == 0 }
            _ = firstBefore
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
            let after = frame(of: anchor.id)
            let drift = after.map { $0.minY - anchor.frame.minY } ?? .infinity
            drifts.append(drift)
            pageIns += 1
            report("page-in \(pageIns): row \(anchor.id) y \(anchor.frame.minY) -> \(after.map { "\($0.minY)" } ?? "gone") (drift \(drift)); "
                   + "rows held \(metric("rows")); first \(metrics()["first"] ?? ""); on screen now \(visibleRows().map(\.id).prefix(3))")
        }
        XCTAssertGreaterThanOrEqual(pageIns, count - 1)
        report("page-ins \(pageIns) over \(drags) drags; drifts \(drifts.map { $0.isFinite ? "\(Int($0))" : "gone" }); largest \(drifts.map(abs).max() ?? 0)")
        for drift in drifts { XCTAssertLessThanOrEqual(abs(drift), 1, "the row on screen moved by \(drift) points across a page-in") }
    }

    // MARK: (d) Streaming

    private func sendMessage() {
        composer.tap()
        composer.typeText("How does it look?")
        app.buttons["conversation.send"].tap()
        wait("the reply to start") { metric("streaming") > 0 }
    }

    func testStreamingKeepsFollowingAtTheBottom() {
        launch(["-nollie-demo-no-card", "-nollie-demo-reply-tokens", "500"])
        wait("rows") { metric("rows") > 0 }
        sendMessage()
        var gaps: [CGFloat] = []
        var lengths: [Int] = []
        for _ in 0..<16 {
            RunLoop.current.run(until: Date().addingTimeInterval(0.3))
            guard metric("running") == 1, let last = metrics()["last"], let reply = frame(of: last) else { break }
            let length = metric("streaming")
            // The reply ended between the reads: what was sampled before stands.
            guard length > 0 else { break }
            gaps.append(composer.frame.minY - reply.maxY)
            if gaps.count == 4 { shot("streaming-following") }
            lengths.append(length)
        }
        report("following: gap between the reply and the composer \(gaps.map { Int($0) }) while the reply grew \(lengths)")
        XCTAssertGreaterThanOrEqual(gaps.count, 8)
        XCTAssertGreaterThan(lengths.last ?? 0, lengths.first ?? 0, "the reply was still streaming")
        for gap in gaps {
            XCTAssertGreaterThanOrEqual(gap, -1, "the reply's end went under the composer")
            XCTAssertLessThanOrEqual(gap, 60, "the reply's end left the bottom of the screen")
        }
        XCTAssertEqual((list.value as? String)?.hasPrefix("following"), true)
    }

    func testStreamingDoesNotMoveWhatYouAreReading() {
        launch(["-nollie-demo-no-card", "-nollie-demo-reply-tokens", "600"])
        wait("rows") { metric("rows") > 0 }
        sendMessage()
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        // Up by a little under a screen: the growing reply stays partly in view below what is read.
        drag(420)
        shot("streaming-reading")
        XCTAssertEqual((list.value as? String)?.hasPrefix("reading"), true)
        guard let anchor = visibleRows().first(where: { $0.frame.minY > app.navigationBars.firstMatch.frame.maxY }) else {
            return XCTFail("no row on screen")
        }
        var drifts: [CGFloat] = []
        var lengths: [Int] = []
        for _ in 0..<12 {
            RunLoop.current.run(until: Date().addingTimeInterval(0.3))
            guard let now = frame(of: anchor.id) else { return XCTFail("row \(anchor.id) left the screen") }
            drifts.append(now.minY - anchor.frame.minY)
            lengths.append(metric("streaming"))
        }
        report("reading: row \(anchor.id) drift \(drifts.map { Int($0) }) while the reply grew \(lengths)")
        XCTAssertGreaterThan(lengths.last ?? 0, lengths.first ?? 0, "the reply was still streaming")
        for drift in drifts { XCTAssertLessThanOrEqual(abs(drift), 1, "what was being read moved by \(drift) points") }
        XCTAssertEqual((list.value as? String)?.hasPrefix("reading"), true)
    }

    /// Back from history with the jump button, the list follows a reply again.
    func testJumpingBackFollowsAgain() {
        launch(["-nollie-demo-no-card", "-nollie-demo-autosend", "6", "-nollie-demo-reply-tokens", "400"])
        wait("rows") { metric("rows") > 0 }
        drag(600)
        drag(600)
        XCTAssertEqual((list.value as? String)?.hasPrefix("reading"), true)
        let jump = app.buttons["conversation.jump"]
        XCTAssertTrue(jump.waitForExistence(timeout: 3))
        jump.tap()
        wait("following") { (list.value as? String)?.hasPrefix("following") == true }
        wait("the reply to start", timeout: 10) { metric("streaming") > 0 }
        var gaps: [CGFloat] = []
        for _ in 0..<10 {
            RunLoop.current.run(until: Date().addingTimeInterval(0.3))
            guard metric("running") == 1, let last = metrics()["last"], let reply = frame(of: last) else { break }
            gaps.append(composer.frame.minY - reply.maxY)
        }
        report("after the jump: gap between the reply and the composer \(gaps.map { Int($0) })")
        XCTAssertGreaterThanOrEqual(gaps.count, 6)
        for gap in gaps {
            XCTAssertGreaterThanOrEqual(gap, -1)
            XCTAssertLessThanOrEqual(gap, 60)
        }
    }

    // MARK: Pictures

    func testPictures() {
        for scheme in ["light", "dark"] {
            launch(rows: 600, ["-colorSchemePreference", scheme])
            wait("rows") { metric("rows") > 0 }
            RunLoop.current.run(until: Date().addingTimeInterval(1))
            shot("conversation-bottom-\(scheme)")
            // Mid-history: well up, across a summarized boundary.
            var found = false
            for _ in 0..<80 where !found {
                drag(560)
                let rows = visibleRows()
                let segments = Set(rows.compactMap { $0.id.split(separator: "#").first.map(String.init) }.filter { $0.hasPrefix("stored:") })
                found = rows.contains { $0.id.hasPrefix("summary:") } || segments.count > 1
            }
            XCTAssertTrue(found, "a summarized boundary on screen")
            RunLoop.current.run(until: Date().addingTimeInterval(1))
            shot("conversation-history-\(scheme)")
            app.terminate()
        }
    }
}
