import XCTest

/// Rows in the thread never overlap. Three turns in a row full of tool cards, and the thread is
/// measured over and over while they stream, while they settle, and while it is scrolled both ways.
final class ThreadLayoutUITests: DemoCase {
    private var measurements = 0
    private var mostToolCards = 0

    /// Lines the thread's rows up by their tops; each must begin below where the row before it ends.
    private func checkRowsDoNotOverlap(_ moment: String) {
        // One snapshot of the whole screen: rows measured one by one move while the thread does.
        guard let screen = try? app.snapshot() else { return }
        var frames: [(id: String, frame: CGRect)] = []
        func collect(_ node: XCUIElementSnapshot) {
            if node.identifier.hasPrefix("thread.row."), node.frame.height > 1, node.frame.width > 1 {
                frames.append((node.identifier, node.frame))
            }
            node.children.forEach(collect)
        }
        collect(screen)
        frames.sort { $0.frame.minY < $1.frame.minY }
        mostToolCards = max(mostToolCards, frames.filter { $0.id == "thread.row.tool" }.count)
        for (above, below) in zip(frames, frames.dropFirst()) {
            XCTAssertLessThanOrEqual(above.frame.maxY, below.frame.minY + 0.5,
                                     "\(moment): \(above.id) ends at \(above.frame.maxY) but \(below.id) starts at \(below.frame.minY)")
        }
        measurements += 1
    }

    /// Watches the thread while `done` has not yet become true, up to `seconds`.
    private func watch(_ moment: String, until done: () -> Bool, seconds: TimeInterval) {
        poll(seconds, every: 0.4) {
            self.checkRowsDoNotOverlap(moment)
            return done()
        }
    }

    func testRowsNeverOverlapThroughThreeToolTurns() throws {
        try startDemo()
        openBot("default")
        startSideChat()

        for turn in 1...3 {
            send("tools run number \(turn)")
            var sawWork = false
            watch("turn \(turn) streaming", until: {
                let working = self.find("thread.typing").exists || self.find("composer.stop").exists
                sawWork = sawWork || working
                return sawWork && !working
            }, seconds: 90)
            XCTAssertTrue(sawWork && text("their own disk at 61%").exists, "turn \(turn) never finished")
            for _ in 0..<5 {
                pause(0.5)
                checkRowsDoNotOverlap("turn \(turn) settling")
            }
        }

        for _ in 0..<6 {
            scrollThread(towardStart: true)
            checkRowsDoNotOverlap("scrolling up")
        }
        for _ in 0..<8 {
            scrollThread(towardStart: false)
            checkRowsDoNotOverlap("scrolling down")
        }

        XCTAssertGreaterThan(measurements, 30, "too few measurements to mean anything (\(measurements))")
        XCTAssertGreaterThan(mostToolCards, 6, "never more than six tool cards on screen (\(mostToolCards))")
        shot("thread-layout")
    }
}
