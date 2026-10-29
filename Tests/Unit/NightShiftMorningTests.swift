import Foundation
import SwiftUI
import Testing
@testable import Nollie
@testable import NollieCore

// The morning's Night shift capsule at the top of Nollie's main chat on the chat view people get: one a morning,
// until put away, and the whole card behind it. See Docs/specs/night-shift.md.

@Suite struct NightShiftMorningRuleTests {
    private static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/London")!
        return calendar
    }

    private static func at(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute))!
    }

    private func shows(_ posted: Date?, now: Date, putAway: Date? = nil) -> Bool {
        NightShiftMorning.cardShows(postedAt: posted, now: now, putAway: putAway, calendar: Self.calendar)
    }

    @Test func thisMorningsCardShowsAllDay() {
        let posted = Self.at(29, 7, 2)
        #expect(shows(posted, now: Self.at(29, 7, 3)))
        #expect(shows(posted, now: Self.at(29, 13)))
        #expect(shows(posted, now: Self.at(29, 23, 59)))
    }

    @Test func yesterdaysCardStaysOutOfTheChat() {
        #expect(!shows(Self.at(28, 7), now: Self.at(29, 0, 30)))
        #expect(!shows(Self.at(28, 7), now: Self.at(29, 9)))
    }

    @Test func noCardNoCapsule() {
        #expect(!shows(nil, now: Self.at(29, 9)))
    }

    @Test func puttingItAwayLastsUntilTheNextMorningsCard() {
        let today = Self.at(29, 7)
        #expect(!shows(today, now: Self.at(29, 9), putAway: today), "put away")
        #expect(!shows(today, now: Self.at(29, 22), putAway: today), "for the rest of the day")
        #expect(shows(Self.at(30, 7), now: Self.at(30, 8), putAway: today), "the next morning's card shows again")
    }

    /// The card put away is kept by its own time, so a phone whose clock runs behind the Mac's never brings it back.
    @Test func anotherDevicesClockDoesNotBringItBack() {
        let posted = Self.at(29, 7, 0)
        #expect(!shows(posted, now: Self.at(29, 6, 58), putAway: posted))
    }

    @Test func aTestRunCanKeepItAwayForGood() {
        let never = Date(timeIntervalSince1970: 4_070_908_800) // 2099
        #expect(!shows(Self.at(29, 7), now: Self.at(29, 8), putAway: never))
    }
}

@MainActor @Suite struct NightShiftMorningModelTests {
    private func defaults() -> UserDefaults {
        let name = "nollie.tests.night-morning." + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    private func post(_ id: String, at: Date, runs: Int = 2, held: Int = 0) -> ConversationPost {
        ConversationPost(id: id, at: at, kind: .nightShift(.init(from: at.addingTimeInterval(-12 * 3600), to: at,
                                                                  counts: .init(runs: runs, actions: 5, held: held))))
    }

    @Test func showsTodaysCardAndPutsItAwayForTheMorning() {
        let store = defaults()
        let now = Date()
        let summary = CrewSummaryModel(defaults: store)
        #expect(!summary.nightCardShows(now: now), "nothing read yet")
        summary.show(post("night-today", at: now.addingTimeInterval(-60)))
        #expect(summary.nightCardShows(now: now))
        summary.putNightAway()
        #expect(!summary.nightCardShows(now: now))
        #expect(summary.night != nil, "the card itself stays for Settings › Night shift")

        // Remembered on this device: a new start of the app keeps it away.
        let again = CrewSummaryModel(defaults: store)
        again.show(post("night-today", at: now.addingTimeInterval(-60)))
        #expect(!again.nightCardShows(now: now))
        // The next card shows.
        again.show(post("night-later", at: now.addingTimeInterval(-30)))
        #expect(again.nightCardShows(now: now))
    }

    @Test func putAwayWithNoCardChangesNothing() {
        let store = defaults()
        let summary = CrewSummaryModel(defaults: store)
        summary.putNightAway()
        #expect(store.object(forKey: CrewSummaryModel.nightPutAwayKey) == nil)
    }

    @Test func theNewestNightIsTheOneShown() {
        let now = Date()
        let rehearsal = rehearsalSample()
        let newest = CrewSummaryModel.newestNight([post("old", at: now.addingTimeInterval(-86_400)), rehearsal,
                                                   post("new", at: now.addingTimeInterval(-600))])
        #expect(newest?.id == "new")
        #expect(CrewSummaryModel.newestNight([rehearsal]) == nil, "a rehearsal is not a night")
    }

    /// The Mac out of reach for a moment never takes the morning's card away.
    @Test func aFailedReadKeepsTheCardShown() async throws {
        let connection = GatewayConnection(name: "Night tests", gateway: try GatewayURL.normalize("http://127.0.0.1:9", pathPrefix: nil),
                                           authMode: .sessionToken)
        let runtime = GatewayRuntime(connection: connection, store: ConnectionStore())
        let summary = CrewSummaryModel(defaults: defaults())
        await summary.loadNight(runtime, force: true)
        #expect(summary.night == nil)
        summary.show(post("night-today", at: Date().addingTimeInterval(-60)))
        await summary.loadNight(runtime, force: true)
        #expect(summary.night != nil)
        #expect(summary.nightCardShows())
    }

    /// The capsule's few words: the same answer as Settings' tile.
    @Test func theCapsuleSaysTheNightInAFewWords() {
        #expect(CrewSummaryWords.night(.init(counts: .init())) == "A quiet night")
        #expect(CrewSummaryWords.night(.init(counts: .init(runs: 3, actions: 7))) == "3 jobs overnight")
        #expect(CrewSummaryWords.night(.init(counts: .init(runs: 3, actions: 7, held: 2))) == "2 things wait for you")
    }
}
