#if os(macOS) && NOLLIE_DIRECT
import Testing
@testable import Nollie

/// A Stop from the phone acts once per press, never for a press from before Nollie opened, and
/// again after Nollie Runtime restarts and counts from one.
@Suite struct LinkStopWatcherTests {
    @Test func aStopCountsOnce() {
        #expect(!LinkStopWatcher.isNew(3, after: nil))
        #expect(!LinkStopWatcher.isNew(3, after: 3))
        #expect(LinkStopWatcher.isNew(4, after: 3))
        #expect(LinkStopWatcher.isNew(1, after: 0))
        #expect(LinkStopWatcher.isNew(1, after: 7))
        #expect(!LinkStopWatcher.isNew(0, after: 7))
    }

    @Test func theMacSaysWhatStopped() {
        #expect(LinkStopWatcher.summary(paused: 0) == "Nollie ended its task on this Mac and stopped its replies.")
        #expect(LinkStopWatcher.summary(paused: 1).hasSuffix("paused 1 schedule. Resume it in Schedules."))
        #expect(LinkStopWatcher.summary(paused: 3).contains("paused 3 schedules"))
        for n in 0...3 { #expect(!LinkStopWatcher.summary(paused: n).contains("\u{2014}")) }
    }
}
#endif
