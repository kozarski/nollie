import Testing
@testable import Nollie

/// The counter behind "Writing summaries, 2 of 5".
@Suite struct SummaryRunTests {
    @Test func aRunCountsUpAndTheNextOneStartsOverFromZero() {
        var run = SummaryProgress()
        #expect(!run.isWorking)
        #expect(run.fraction == 0)

        for _ in 1...3 { run.queued() }
        #expect(run.isWorking)
        #expect(run.total == 3 && run.done == 0)
        #expect(run.current == 1, "the first of three is the one being written")

        run.finished()
        #expect(run.current == 2)
        #expect(abs(run.fraction - 1.0 / 3.0) < 0.0001)

        // A chat scrolled into view midway joins the same run.
        run.queued()
        #expect(run.total == 4 && run.done == 1)

        for _ in 1...3 { run.finished() }
        #expect(!run.isWorking)
        #expect(run.fraction == 1)
        #expect(run.current == 4)

        // Finishing more than were queued stays at the end.
        run.finished()
        #expect(run.done == 4)

        // Once idle, the next chat begins a fresh run instead of reading "5 of 5".
        run.queued()
        #expect(run.total == 1 && run.done == 0 && run.isWorking)
    }
}
