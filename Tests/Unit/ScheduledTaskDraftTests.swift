import Foundation
import Testing
@testable import Nollie
@testable import NollieCore

@Suite struct ScheduledTaskDraftTests {
    @Test func creationRequiresTheSubmittedTaskAndOwner() {
        var draft = ScheduledTaskDraft()
        draft.profile = "work"
        draft.name = "Price check"
        draft.prompt = "Check the synthetic item's price."
        draft.repetition = .daily
        let payload = draft.payload()
        var record = payload.objectValue ?? [:]
        record["id"] = "new-watch"
        record["profile"] = "work"
        record["schedule"] = .object(["kind": "cron", "expr": payload["schedule"] ?? .null])
        #expect(draft.confirmsCreation(.object(record), payload: payload))
        for field in ["id", "profile", "name", "prompt", "schedule", "deliver"] {
            var changed = record
            changed[field] = .string(field == "id" ? "" : "another-value")
            #expect(!draft.confirmsCreation(.object(changed), payload: payload), "Rejected mismatched \(field)")
            changed.removeValue(forKey: field)
            #expect(!draft.confirmsCreation(.object(changed), payload: payload), "Rejected missing \(field)")
        }
        record.removeValue(forKey: "profile")
        record["profile_name"] = "work"
        #expect(draft.confirmsCreation(.object(record), payload: payload))
    }

    @Test func oneTimeCreationMatchesTheInstantInsteadOfItsSpelling() {
        var draft = ScheduledTaskDraft()
        draft.profile = "default"; draft.name = "Follow up"; draft.prompt = "Check the demo task."
        draft.onceAt = CronSchedule.onceDate("2026-11-05T14:30:00Z")!
        let payload = draft.payload()
        var record = payload.objectValue ?? [:]
        record["id"] = "once-watch"; record["profile"] = "default"
        record["schedule"] = .object(["kind": "once", "run_at": "2026-11-05T09:30:00-05:00"])
        #expect(draft.confirmsCreation(.object(record), payload: payload))
        record["schedule"] = .object(["kind": "once", "run_at": "2026-11-05T09:31:00-05:00"])
        #expect(!draft.confirmsCreation(.object(record), payload: payload))
    }

    @Test func anUnconfirmedCreateCannotBeSentTwiceFromTheSameSheet() {
        var submission = ScheduledTaskSubmission()
        #expect(!submission.hasSubmitted)
        let first = submission.begin()
        #expect(first)
        #expect(submission.hasSubmitted)
        let second = submission.begin()
        let third = submission.begin()
        #expect(!second)
        #expect(!third)
    }

    @Test func aScheduleSheetCannotFollowAReplacedRuntimeOrActWhileLocked() {
        let original = NSObject()
        let replacement = NSObject()
        #expect(ScheduledWork.allows(expected: original, current: original, locked: false, cancelled: false))
        #expect(!ScheduledWork.allows(expected: original, current: replacement, locked: false, cancelled: false))
        #expect(!ScheduledWork.allows(expected: original, current: nil, locked: false, cancelled: false))
        #expect(!ScheduledWork.allows(expected: original, current: original, locked: true, cancelled: false))
        #expect(!ScheduledWork.allows(expected: original, current: original, locked: false, cancelled: true))
        let sameIDOtherOwner: JSONValue = ["id": "watch", "profile": "work", "enabled": true]
        #expect(!ScheduledWork.confirms(sameIDOtherOwner, jobID: "watch", profile: "default"))
        #expect(ScheduledWork.confirms(sameIDOtherOwner, jobID: "watch", profile: "work"))
        #expect(!ScheduledWork.confirms(["id": "watch"], jobID: "watch", profile: "work"))
    }

    @Test func serverDetailsNeverBecomeScheduleFeedback() {
        let raw = "fixture-token /private/example/config.yaml"
        for error in [HermesAPIError.http(status: 500, detail: raw), .transport(raw), .decoding(raw)] {
            #expect(!ScheduledWork.failureMessage(error).contains(raw))
            #expect(!CronRun.plainWords(error).contains(raw))
        }
    }

    @Test(arguments: ScheduledTaskDraft.Starter.allCases)
    func startersNeedARealSubjectAndStoppingRule(_ starter: ScheduledTaskDraft.Starter) {
        var draft = ScheduledTaskDraft()
        draft.profile = "work"
        draft.use(starter)
        #expect(!draft.canCreate)
        draft.subject = "A useful test topic"
        #expect(!draft.canCreate)
        draft.stopRule = "After 30 days"
        #expect(draft.canCreate)
        let prompt = draft.payload()["prompt"]?.stringValue ?? ""
        #expect(prompt.contains("A useful test topic"))
        #expect(prompt.contains("After 30 days"))
        #expect(prompt.contains("return [SILENT]"))
        #expect(prompt.contains("do not create duplicate schedules"))
        #expect(prompt.contains("Never claim the schedule is paused without confirmation"))
        #expect(draft.payload()["deliver"]?.stringValue == "bot-chat")
        #expect(draft.repetition == (starter == .weekend ? .weekly : .daily))
        draft.stopRule = " \n "
        #expect(!draft.canCreate)
    }

    @Test func creationRequiresABotNameAndPrompt() {
        var draft = ScheduledTaskDraft()
        #expect(!draft.canCreate)
        draft.name = "Morning brief"
        draft.prompt = "  \n "
        draft.profile = "work"
        #expect(!draft.canCreate)
        draft.prompt = "Summarize today's tasks."
        #expect(draft.canCreate)
        draft.profile = ""
        #expect(!draft.canCreate)
    }

    @Test func recurrenceUsesChosenWallClockAndProfileStaysOutOfThePayload() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        var draft = ScheduledTaskDraft()
        draft.name = "  Morning brief \n"
        draft.prompt = "\nSummarize today's tasks.  "
        draft.profile = "work"
        draft.time = calendar.date(from: DateComponents(year: 2026, month: 10, day: 15, hour: 7, minute: 35))!
        for (repetition, expected) in [(ScheduledTaskDraft.Repetition.daily, "*"), (.weekdays, "1-5"), (.weekends, "0,6"), (.weekly, "2")] {
            draft.repetition = repetition
            draft.weekday = 2
            #expect(draft.schedule(calendar: calendar) == "35 7 * * \(expected)")
        }
        let payload = draft.payload(calendar: calendar)
        #expect(payload["name"]?.stringValue == "Morning brief")
        #expect(payload["prompt"]?.stringValue == "Summarize today's tasks.")
        #expect(payload["deliver"]?.stringValue == "bot-chat", "The chosen bot must bring scheduled results back to its conversation")
        #expect(payload["profile"] == nil, "The owner is sent as the API profile query, not an ignored JSON field")
    }

    @Test func onceIsTheDefaultAndMustBeInTheFuture() {
        var draft = ScheduledTaskDraft()
        #expect(draft.repetition == .once)
        draft.name = "Follow up"
        draft.prompt = "Ask how the demo project is going."
        draft.profile = "work"
        let now = Date(timeIntervalSince1970: 10_000)
        draft.onceAt = now.addingTimeInterval(60)
        #expect(draft.canCreate(at: now))
        draft.onceAt = now
        #expect(!draft.canCreate(at: now))
        draft.onceAt = now.addingTimeInterval(-60)
        #expect(!draft.canCreate(at: now))
        draft.repetition = .daily
        #expect(draft.canCreate(at: now), "A recurring task does not use the one-time date")
    }

    @Test func onceKeepsTheChosenInstantAcrossTimeZones() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "America/New_York"))
        var draft = ScheduledTaskDraft()
        draft.onceAt = try #require(calendar.date(from: DateComponents(year: 2026, month: 11, day: 5, hour: 9, minute: 30)))
        #expect(draft.schedule(calendar: calendar) == "2026-11-05T14:30:00Z")
        calendar.timeZone = try #require(TimeZone(identifier: "Asia/Tokyo"))
        #expect(draft.schedule(calendar: calendar) == "2026-11-05T14:30:00Z")
        #expect(CronSchedule.onceDate(draft.schedule()) == draft.onceAt)
        #expect(draft.payload()["schedule"]?.stringValue == "2026-11-05T14:30:00Z")
    }

    @Test func gatewayOnceScheduleIsReadableAndRetainsItsOffset() throws {
        let timestamp = "2026-11-05T09:30:00.123456-05:00"
        let schedule: JSONValue = .object(["kind": .string("once"), "run_at": .string(timestamp),
                                          "display": .string("once at 2026-11-05 09:30")])
        let expression = try #require(CronSchedule.expression(of: schedule))
        #expect(expression == timestamp)
        let instant = try #require(CronSchedule.onceDate(expression))
        #expect(CronSchedule.onceExpression(instant) == "2026-11-05T14:30:00Z")
        #expect(CronSchedule.describe(expression).hasPrefix("Once, "))
        #expect(!CronSchedule.describe(expression).contains("run_at"))
        #expect(CronSchedule.onceDate("0 9 * * *") == nil)
    }
}
