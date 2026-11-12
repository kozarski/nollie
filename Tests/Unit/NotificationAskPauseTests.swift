import Foundation
import Testing
@testable import Nollie

/// Setup offers notifications on its own step. Whoever passed there is not asked again by the Stay in
/// the loop sheet for a few days.
struct NotificationAskPauseTests {
    private let now = Date(timeIntervalSince1970: 1_794_000_000)

    @Test func neverOfferedInSetupMayBeAskedAtOnce() {
        #expect(NotificationAskPause.mayAsk(now: now, offeredAt: nil))
    }

    @Test func offeredInSetupWaitsAFewDays() {
        #expect(!NotificationAskPause.mayAsk(now: now, offeredAt: now.addingTimeInterval(-30)), "Seconds after setup")
        #expect(!NotificationAskPause.mayAsk(now: now, offeredAt: now.addingTimeInterval(-86_400)), "Not that day, nor the next")
        #expect(!NotificationAskPause.mayAsk(now: now, offeredAt: now.addingTimeInterval(-3 * 86_400 + 60)))
        #expect(NotificationAskPause.mayAsk(now: now, offeredAt: now.addingTimeInterval(-3 * 86_400)))
        #expect(NotificationAskPause.mayAsk(now: now, offeredAt: now.addingTimeInterval(-10 * 86_400)))
    }

    @Test func setupShowingItsRowIsWhatStartsThePause() throws {
        let suite = "nollie.tests.notificationAskPause.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(NotificationAskPause.mayAsk(now: now, defaults: defaults))
        NotificationAskPause.noteOffered(now: now, defaults: defaults)
        #expect(!NotificationAskPause.mayAsk(now: now.addingTimeInterval(5), defaults: defaults))
        #expect(NotificationAskPause.mayAsk(now: now.addingTimeInterval(4 * 86_400), defaults: defaults))
    }
}
