#if os(macOS)
import AppKit
import Testing
@testable import Nollie

/// On the Mac, "away" means the computer is about to sleep and "back" means it just woke up. A Mac
/// reopened after a closed lid used to hang until the heartbeat found its socket dead.
@MainActor @Suite struct SleepWakeAwayTests {
    private final class Heard { var calls: [Bool] = [] }

    /// A watcher on a private notification center, and what it has reported so far.
    @MainActor private struct Setup {
        let center = NotificationCenter()
        let heard = Heard()
        let watcher: MacSleepAway

        init() {
            let heard = self.heard
            watcher = MacSleepAway { heard.calls.append($0) }
        }

        func post(_ names: Notification.Name...) { names.forEach { center.post(name: $0, object: nil) } }
    }

    @Test func sleepMeansAwayAndWakeMeansBack() {
        let setup = Setup()
        setup.watcher.start(center: setup.center)
        #expect(setup.watcher.isObserving)

        setup.post(NSWorkspace.willSleepNotification, NSWorkspace.didWakeNotification)
        #expect(setup.heard.calls == [true, false])

        // A dimmed screen or another app coming forward is not being away.
        setup.post(NSWorkspace.screensDidSleepNotification, NSApplication.didResignActiveNotification)
        #expect(setup.heard.calls == [true, false])

        setup.watcher.stop(center: setup.center)
        setup.post(NSWorkspace.willSleepNotification)
        #expect(!setup.watcher.isObserving && setup.heard.calls == [true, false])
    }

    @Test func startingTwiceListensOnce() {
        let setup = Setup()
        for _ in 1...2 { setup.watcher.start(center: setup.center) }
        setup.post(NSWorkspace.didWakeNotification)
        #expect(setup.heard.calls == [false])
        setup.watcher.stop(center: setup.center)
    }
}
#endif
