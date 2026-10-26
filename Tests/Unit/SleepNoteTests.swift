import Foundation
import Testing
@testable import Nollie
@testable import NollieCore

// Sleep notes: what the Night shift card and a schedule's page say when the Mac was asleep or off while work was
// due. Never that a run ran when it didn't. See Docs/specs/night-shift.md.

/// "1:10" style times in UTC, so the words don't depend on where the tests run.
private let snClock: SleepNote.Clock = { date in
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    let parts = calendar.dateComponents([.hour, .minute], from: date)
    return String(format: "%d:%02d", parts.hour!, parts.minute!)
}

/// 2026-10-21 at `hour`:`minute` UTC.
private func snAt(_ hour: Int, _ minute: Int = 0) -> Date {
    Date(timeIntervalSince1970: 1_792_540_800 + TimeInterval(hour * 3600 + minute * 60))
}

private func snGap(_ from: Date, _ to: Date, _ kind: ConversationPost.SleepGap.Kind = .asleep) -> ConversationPost.SleepGap {
    ConversationPost.SleepGap(from: from, to: to, kind: kind)
}

@Suite struct SleepNoteWordingTests {
    @Test func theLineSaysWhenAndWhatWaited() {
        let night = [snGap(snAt(1, 10), snAt(6, 40))]
        #expect(SleepNote.line(gaps: night, waited: 2, skipped: 0, clock: snClock)
                == "Your Mac was asleep from 1:10 to 6:40, so two runs waited until it woke.")
        #expect(SleepNote.line(gaps: night, waited: 1, skipped: 0, clock: snClock)
                == "Your Mac was asleep from 1:10 to 6:40, so one run waited until it woke.")
        #expect(SleepNote.line(gaps: night, waited: 0, skipped: 3, clock: snClock)
                == "Your Mac was asleep from 1:10 to 6:40, so three runs were skipped.")
        #expect(SleepNote.line(gaps: night, waited: 1, skipped: 1, clock: snClock)
                == "Your Mac was asleep from 1:10 to 6:40. One run waited until it woke and one was skipped.")
        #expect(SleepNote.line(gaps: night, waited: 0, skipped: 0, clock: snClock) == "Your Mac was asleep from 1:10 to 6:40.")
        #expect(SleepNote.line(gaps: night, waited: 14, skipped: 0, clock: snClock)
                == "Your Mac was asleep from 1:10 to 6:40, so 14 runs waited until it woke.")
        #expect(SleepNote.line(gaps: [], waited: 2, skipped: 1) == nil)
    }

    @Test func offOrWithoutHermesSayTheirOwnWords() {
        #expect(SleepNote.line(gaps: [snGap(snAt(1), snAt(5), .off)], waited: 1, skipped: 0, clock: snClock)
                == "Your Mac was off from 1:00 to 5:00, so one run waited until it was back on.")
        #expect(SleepNote.line(gaps: [snGap(snAt(1), snAt(2), .stopped)], waited: 0, skipped: 2, clock: snClock)
                == "Your crew wasn't running from 1:00 to 2:00, so two runs were skipped.")
    }

    @Test func twoStretchesByTimeAndMoreByHowLong() {
        let two = [snGap(snAt(3, 15), snAt(6, 40)), snGap(snAt(1, 10), snAt(2))]
        #expect(SleepNote.line(gaps: two, waited: 0, skipped: 0, clock: snClock)
                == "Your Mac was asleep from 1:10 to 2:00 and from 3:15 to 6:40.")
        let mixed = [snGap(snAt(1), snAt(2), .off), snGap(snAt(3), snAt(6))]
        #expect(SleepNote.line(gaps: mixed, waited: 2, skipped: 0, clock: snClock)
                == "Your Mac was asleep or off for about 4 hours in all, so two runs waited until it was back.")
        let three = [snGap(snAt(1), snAt(1, 20)), snGap(snAt(2), snAt(2, 10)), snGap(snAt(3), snAt(3, 10), .stopped)]
        #expect(SleepNote.line(gaps: three, waited: 0, skipped: 0, clock: snClock)
                == "Your crew couldn't run for 40 minutes in all.")
    }

    @Test func theCardCountsOnlyRunsThatWaitedForTheMacAndEveryMissedTime() {
        let late = ConversationPost.Run(id: "cron:a:1", bot: "default", botName: "Nollie", title: "Morning brief", outcome: .done,
                                        startedAt: snAt(6, 41), dueAt: snAt(2), late: true)
        // Late, but due before the Mac slept: Hermes was busy, not asleep.
        let busy = ConversationPost.Run(id: "cron:b:1", bot: "default", botName: "Nollie", title: "Backup", outcome: .done,
                                        startedAt: snAt(0, 40), dueAt: snAt(0, 10), late: true)
        let onTime = ConversationPost.Run(id: "cron:c:1", bot: "work", botName: "Work", title: "Export", outcome: .done,
                                          startedAt: snAt(0, 1), dueAt: snAt(0))
        let card = ConversationPost.NightShift(runs: [onTime, busy, late], sleep: [snGap(snAt(1, 10), snAt(6, 40))],
                                               missed: [.init(bot: "work", botName: "Work", jobId: "h", title: "Hourly", count: 3)])
        #expect(SleepNote.line(for: card, clock: snClock)
                == "Your Mac was asleep from 1:10 to 6:40. One run waited until it woke and three were skipped.")
        #expect(SleepNote.line(for: ConversationPost.NightShift(runs: [late]), clock: snClock) == nil)
    }

    @Test func aSchedulesLastRunSaysWhyItWasLate() {
        let gaps = [snGap(snAt(5, 10), snAt(7, 40))]
        #expect(SleepNote.scheduleLine(due: snAt(7), ran: snAt(7, 41), gaps: gaps, clock: snClock)
                == "Your Mac was asleep at 7:00, so this ran at 7:41.")
        #expect(SleepNote.scheduleLine(due: snAt(7), ran: snAt(7, 41), gaps: [snGap(snAt(6), snAt(7, 30), .off)], clock: snClock)
                == "Your Mac was off at 7:00, so this ran at 7:41.")
        #expect(SleepNote.scheduleLine(due: snAt(7), ran: snAt(7, 41), gaps: [], clock: snClock)
                == "Due at 7:00. It ran late, at 7:41.")
        #expect(SleepNote.scheduleLine(due: snAt(7), ran: snAt(7, 4), gaps: gaps, clock: snClock) == nil)
    }
}

@Suite struct SleepNoteWireTests {
    @Test func theCardBringsItsGapsDueTimesAndMissedSchedules() throws {
        let json = try GatewayJSON.parse(Data("""
        {"id": "night-2026-10-21", "kind": "night_shift", "at": 1792562400,
         "window": {"from": 1792519200, "to": 1792562400}, "counts": {"runs": 1, "actions": 0},
         "sleep": [{"from": 1792545000, "to": 1792564800, "kind": "asleep"}, {"from": 5, "to": 4, "kind": "asleep"},
                   {"from": 1, "to": 2, "kind": "napping"}],
         "missed": [{"bot": "work", "bot_name": "Work", "job_id": "c71d02", "title": "Hourly price check",
                     "first_due": 1792548000, "last_due": 1792555200, "count": 3}, {"bot": "work", "count": 0}],
         "runs": [{"id": "cron:a:1", "kind": "schedule", "bot": "default", "bot_name": "Nollie", "title": "Morning brief",
                   "outcome": "done", "started_at": 1792564860, "finished_at": 1792564928, "actions": [], "more": 0,
                   "due_at": 1792548000, "late": true},
                  {"id": "cron:b:1", "bot": "work", "title": "Export", "actions": []}]}
        """.utf8))
        let card = try #require(ConversationPost(wire: json)?.nightShift)
        #expect(card.sleep == [snGap(Date(timeIntervalSince1970: 1_792_545_000), Date(timeIntervalSince1970: 1_792_564_800))])
        #expect(card.missed.map(\.count) == [3])
        #expect(card.missed.first?.firstDue == Date(timeIntervalSince1970: 1_792_548_000))
        #expect(card.runs.map(\.late) == [true, false])
        #expect(card.runs.first?.dueAt == Date(timeIntervalSince1970: 1_792_548_000))
        #expect(card.runs.last?.dueAt == nil)
    }

    @Test func aCardFromAnOlderAddOnHasNoSleepAndSaysNothing() throws {
        let json = try GatewayJSON.parse(Data(#"{"id": "night-1", "kind": "night_shift", "at": 1, "runs": []}"#.utf8))
        let card = try #require(ConversationPost(wire: json)?.nightShift)
        #expect(card.sleep.isEmpty && card.missed.isEmpty)
        #expect(SleepNote.line(for: card) == nil)
    }

    @Test func gapsAreAskedOfTheMainBotSinceATime() async throws {
        final class Asked: @unchecked Sendable { var path = ""; var query: [URLQueryItem] = [] }
        let asked = Asked()
        let source = HermesSleepGaps { path, query in
            asked.path = path
            asked.query = query
            return Data(#"{"version": 1, "gaps": [{"from": 10, "to": 20, "kind": "off"}, {"from": 30}]}"#.utf8)
        }
        let gaps = try await source.gaps(since: Date(timeIntervalSince1970: 5))
        #expect(asked.path == "/api/plugins/nollie-workflow/sleep")
        #expect(asked.query == [URLQueryItem(name: "since", value: "5"), URLQueryItem(name: "profile", value: "default")])
        #expect(gaps == [snGap(Date(timeIntervalSince1970: 10), Date(timeIntervalSince1970: 20), .off)])
    }
}

@Suite struct SleepNoteCardTests {
    @Test func aRunThatWaitedSaysWhenItWasDue() {
        let late = ConversationPost.Run(id: "cron:a:1", bot: "default", botName: "Nollie", title: "Morning brief", outcome: .done,
                                        startedAt: snAt(6, 41), finishedAt: snAt(6, 42), dueAt: snAt(2), late: true)
        #expect(NightShiftWords.runLine(late).hasSuffix("· Due \(snAt(2).formatted(.dateTime.hour().minute()))"))
        var onTime = late
        onTime.late = false
        #expect(!NightShiftWords.runLine(onTime).contains("Due"))
    }

    @Test func aMissedScheduleSaysHowOftenAndWhen() {
        let time = { (date: Date) in date.formatted(.dateTime.hour().minute()) }
        let three = ConversationPost.Missed(bot: "work", botName: "", jobId: "h", title: "Hourly", firstDue: snAt(2), lastDue: snAt(4),
                                            count: 3)
        #expect(NightShiftWords.missedLine(three) == "Work · Didn't run 3 times · \(time(snAt(2))) to \(time(snAt(4)))")
        let once = ConversationPost.Missed(bot: "work", botName: "Scout", jobId: "d", title: "Daily", firstDue: snAt(3), lastDue: snAt(3),
                                           count: 1)
        #expect(NightShiftWords.missedLine(once) == "Scout · Didn't run · Due \(time(snAt(3)))")
    }

    @Test func theSharedPictureKeepsTheNoteAndHidesMissedTitlesPersonalParts() {
        let card = ConversationPost.NightShift(
            runs: [], sleep: [snGap(snAt(1, 10), snAt(6, 40))],
            missed: [.init(bot: "work", botName: "Work", jobId: "h", title: "Prices for sam@example.com", count: 2)])
        let picture = NightShiftShareModel(card)
        #expect(picture.sleep == SleepNote.line(for: card))
        #expect(picture.runs.map(\.id) == ["missed:work:h"])
        #expect(!picture.words.joined(separator: " ").contains("sam@example.com"))
    }

    @Test func aScheduleRecordSaysWhenItsLastRunWasLate() {
        func record(kind: String = "catch_up", due: String = "2026-09-22T07:00:00Z", sent: String = "2026-09-22T07:41:00Z",
                    ran: String = "2026-09-22T07:42:00Z") -> JSONValue {
            .object(["last_run_at": .string(ran),
                     "last_dispatch": .object(["kind": .string(kind), "scheduled_at": .string(due), "dispatched_at": .string(sent)])])
        }
        let late = ScheduledWork.lateRun(record())
        #expect(late?.due == CronSchedule.onceDate("2026-09-22T07:00:00Z"))
        #expect(late?.ran == CronSchedule.onceDate("2026-09-22T07:41:00Z"))
        #expect(ScheduledWork.lateRun(record(kind: "on_time")) == nil)
        // Run now since: the dispatch belongs to an older run.
        #expect(ScheduledWork.lateRun(record(ran: "2026-09-22T19:00:00Z")) == nil)
        #expect(ScheduledWork.lateRun(.object([:])) == nil)
    }
}
