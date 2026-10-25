import Foundation
import Testing
@testable import Nollie
@testable import NollieCore

/// The Run now button for a scheduled task. It reads Running… from the first tap, sends exactly one
/// run however many times it is tapped while the gateway is busy, then reads Started or Finished,
/// or shows the gateway's error in everyday language. The gateway completes the whole task before
/// replying, so the wait is a long one.
@Suite struct RunNowButtonTests {
    private let jobID = "weekly-digest"
    private let lastRunBefore = "2026-10-01T06:30:00Z"
    private let lastRunAfter = "2026-10-08T06:30:00Z"
    private let noAnswer = "No answer from your assistant. Check the task before trying again."

    /// The gateway's record for the task.
    private func record(ranAt: String?, status: String? = "ok", claimed: Bool = false, execution: String? = nil) -> JSONValue {
        var fields: [String: JSONValue] = ["job_id": .string(jobID), "name": .string("Weekly digest")]
        if let ranAt { fields["last_run_at"] = .string(ranAt) }
        if let status { fields["last_status"] = .string(status) }
        if claimed { fields["fire_claim"] = ["at": "2026-10-08T06:30:05Z", "by": "box:7"] }
        if let execution { fields["latest_execution"] = .object(["status": .string(execution)]) }
        return .object(fields)
    }

    /// A button that has just been tapped.
    private func tapped() -> CronRun {
        var run = CronRun()
        _ = run.begin()
        return run
    }

    private let timeout = HermesAPIError.transport("The request timed out.")

    /// What the button shows, in one line: its title, whether it is locked, and whether it reports a problem.
    private func look(_ run: CronRun) -> String {
        let problem = run.note.map { $0.isProblem ? "problem" : "note" } ?? "no note"
        return "\(run.title) | \(run.isBusy ? "locked" : "free") | \(problem)"
    }

    // MARK: pressing it

    @Test func theFirstTapShowsRunningAndLocksTheButton() {
        var run = CronRun()
        #expect(look(run) == "Run now | free | no note")
        let accepted = run.begin()
        #expect(accepted)
        #expect(run.phase == .running)
        #expect(look(run) == "Running… | locked | note")
        #expect(run.symbol == nil, "a spinner shows instead")
    }

    @Test func furtherTapsDuringARunSendNothing() {
        var run = tapped()
        let extra = [run.begin(), run.begin()]
        #expect(extra == [false, false])
        #expect(run.attempt == 1 && run.phase == .running)
        // The confirmation counts as part of the run.
        run.answered(record(ranAt: lastRunAfter), lastRunBefore: lastRunBefore, jobID: jobID)
        let accepted = run.begin()
        #expect(accepted == false && run.attempt == 1)
    }

    @Test func theConfirmationFadesAndANewRunMayStart() {
        var run = tapped()
        let firstAttempt = run.attempt
        run.answered(nil, lastRunBefore: lastRunBefore, jobID: jobID)
        run.settle(attempt: firstAttempt)
        #expect(run.phase == .idle && run.title == "Run now")
        let again = run.begin()
        #expect(again && run.attempt == firstAttempt + 1)
        // A fade-out left over from the first run must not cut the second short.
        run.settle(attempt: firstAttempt)
        #expect(run.phase == .running)
    }

    // MARK: how it ended

    @Test func aFinishedRunSaysFinishedWithItsResult() {
        var run = tapped()
        run.answered(record(ranAt: lastRunAfter, status: "ok"), lastRunBefore: lastRunBefore, jobID: jobID)
        #expect(run.phase == .finished(result: "ok"))
        #expect(look(run) == "Finished | locked | note")
        #expect(run.symbol == "checkmark.circle" && run.note?.text == "Last result: ok.")
    }

    @Test func aFinishedRunThatWentWrongSaysSo() {
        var run = tapped()
        run.answered(record(ranAt: lastRunAfter, status: "delivery_failed"), lastRunBefore: lastRunBefore, jobID: jobID)
        #expect(run.symbol == "exclamationmark.circle")
        #expect(run.phase == .finished(result: "delivery failed"))
        #expect((run.note?.text, run.note?.isProblem) == ("Last result: delivery failed.", true))
    }

    @Test func anAcceptedRunWithNoSignOfProgressIsOnlyRequested() {
        let quiet: [(JSONValue, String?)] = [(record(ranAt: lastRunBefore), lastRunBefore), (.object([:]), nil)]
        for (answer, before) in quiet {
            var run = tapped()
            run.answered(answer, lastRunBefore: before, jobID: jobID)
            #expect(run.phase == .requested)
            #expect(run.title == "Requested")
        }
    }

    @Test func aNewTimeAlongsideAnOpenClaimIsNotTheOldSuccessFinishing() {
        var run = tapped()
        run.answered(record(ranAt: lastRunAfter, status: "ok", claimed: true), lastRunBefore: lastRunBefore, jobID: jobID)
        #expect(run.phase == .started)
        for unfinished in [record(ranAt: lastRunAfter, status: "running"), record(ranAt: lastRunAfter, status: nil)] {
            #expect(CronRun.ranSince(lastRunBefore, unfinished) == false)
        }
    }

    @Test func aRecordOfAnotherTaskConfirmsNothingHere() {
        let stranger = record(ranAt: lastRunAfter, status: "ok")
        let elsewhere = "some-other-task"

        var answered = tapped()
        answered.answered(stranger, lastRunBefore: lastRunBefore, jobID: elsewhere)
        var recovering = tapped()
        recovering.failed(timeout, jobNow: stranger, lastRunBefore: lastRunBefore, jobID: elsewhere)
        var claimed = tapped()
        claimed.answered(record(ranAt: lastRunBefore, claimed: true), lastRunBefore: lastRunBefore, jobID: elsewhere)

        #expect(answered.phase == .requested)
        #expect(recovering.phase == .failed(noAnswer))
        #expect(claimed.phase == .requested)
    }

    @Test func answersWithNoRunUnderWayChangeNothing() {
        var idle = CronRun()
        idle.answered(record(ranAt: lastRunAfter), lastRunBefore: lastRunBefore, jobID: jobID)
        idle.failed(HermesAPIError.http(status: 409, detail: ""))
        #expect(idle.phase == .idle)
    }

    // MARK: when it fails

    @Test func aGatewayAlreadyRunningItSaysSo() {
        var run = tapped()
        run.failed(HermesAPIError.http(status: 409, detail: "Job is running already, or another scheduler holds its claim"))
        guard case .failed(let words) = run.phase else {
            Issue.record("a 409 should leave the run failed, got \(run.phase)")
            return
        }
        #expect(words.contains("already running"))
        #expect(look(run) == "Run now | free | problem")
        // The message stays up until the next tap, which is allowed to start over.
        run.settle(attempt: run.attempt)
        #expect(look(run) == "Run now | free | problem")
        let retried = run.begin()
        #expect(retried)
    }

    @Test func errorsAreGivenInPlainWords() {
        #expect(CronRun.plainWords(HermesAPIError.http(status: 404, detail: "Job not found")).contains("refresh the list"))
        #expect(CronRun.plainWords(HermesAPIError.http(status: 400, detail: "The task has finished already")).contains("error 400"))
        #expect(CronRun.plainWords(HermesAPIError.http(status: 500, detail: "")).contains("error 500"))
        #expect(CronRun.plainWords(HermesAPIError.transport("The server could not be reached")) == noAnswer)
        #expect(CronRun.plainWords(HermesAPIError.sessionExpired).contains("sign in"))
    }

    @Test func silenceWhileTheGatewayStillWorksCountsAsStartedNotFailed() {
        let refusal = HermesAPIError.http(status: 409, detail: "")
        #expect([CronRun.mayStillBeRunning(after: timeout), CronRun.mayStillBeRunning(after: refusal)] == [true, false])

        /// The button after a timeout, given what the gateway's record says by then.
        func afterSilence(seeing record: JSONValue?) -> CronRun {
            var run = tapped()
            if let record { run.failed(timeout, jobNow: record, lastRunBefore: lastRunBefore, jobID: jobID) } else { run.failed(timeout) }
            return run
        }
        let claimed = afterSilence(seeing: record(ranAt: lastRunBefore, claimed: true))
        #expect(claimed.phase == .started)
        #expect(claimed.note?.text == "Your assistant is still checking. The last result updates when it finishes.")
        #expect(afterSilence(seeing: record(ranAt: lastRunBefore, execution: "running")).phase == .started)
        #expect(afterSilence(seeing: record(ranAt: "2026-10-08T06:33:00Z", status: "ok")).phase == .finished(result: "ok"))

        // Nothing is in progress and no new run began: it didn't happen, and the button explains.
        #expect(afterSilence(seeing: record(ranAt: lastRunBefore)).phase == .failed(noAnswer))
        #expect(afterSilence(seeing: nil).phase == .failed(noAnswer))
    }

    @Test func anUnreadableSuccessIsStartedAndACancelLeavesNothing() {
        var garbled = tapped()
        garbled.failed(HermesAPIError.decoding("not JSON"))
        var cancelled = tapped()
        cancelled.failed(CancellationError())
        #expect(garbled.phase == .requested)
        #expect(cancelled.phase == .idle && cancelled.note == nil)
    }

    // MARK: what the task list shows

    @Test func aScheduleGivenAsAnObjectKeepsItsRunDetailsAndDelivery() throws {
        let raw: JSONValue = ["id": "reminder", "schedule": ["kind": "once", "run_at": "2027-03-04T09:00:00Z"],
                              "last_run_at": "2026-10-16T09:00:00.456Z", "last_status": "delivery_failed", "deliver": "bot-chat"]
        let task = try #require(ScheduledWork.decode(raw))
        #expect(task.schedule == "2027-03-04T09:00:00Z")
        #expect(task.deliver == "bot-chat")
        #expect(ScheduledWork.date(task.lastRunAt) != nil)
        #expect(ScheduledWork.result(task) == "Delivery Failed")
        #expect(ScheduledWork.status(task, raw: raw) == "Check needed")
    }

    @Test func pausedAndFinishedTasksNeverPromiseAnOldNextCheck() {
        var task = CronJob(id: "reminder", enabled: false, state: "paused", nextRunAt: "2027-03-04T09:00:00Z")
        #expect(ScheduledWork.next(task) == "Paused")
        #expect(ScheduledWork.status(task, raw: [:]) == "Paused")
        task.state = "completed"
        #expect(ScheduledWork.next(task) == "No more checks")
        #expect(ScheduledWork.status(task, raw: [:]) == "Finished")
        #expect(ScheduledWork.status(task, raw: ["fire_claim": ["by": "sample"]]) == "Checking now")
    }

    @Test func pauseAndResumeNeedTheRightRecordInTheRightState() {
        func confirmed(_ answer: JSONValue, enabled: Bool) -> Bool { ScheduledWork.confirms(answer, jobID: "reminder", enabled: enabled) }
        #expect(!confirmed(["ok": true], enabled: false))
        #expect(!confirmed(["id": "elsewhere", "enabled": false], enabled: false))
        #expect(!confirmed(["id": "reminder", "enabled": true], enabled: false))
        #expect(confirmed(["id": "reminder", "enabled": false, "state": "paused"], enabled: false))
        #expect(!confirmed(["id": "reminder", "enabled": true, "state": "paused"], enabled: true))
        #expect(confirmed(["id": "reminder", "enabled": true, "state": "active"], enabled: true))
    }

    @MainActor @Test func aRunOutlastsThePageThatStartedIt() {
        let store = CronRuns()
        var accepted = false
        store.update("gw|task") { accepted = $0.begin() }
        #expect(accepted)
        // Reopening the page: the same key still shows Running… and tapping sends nothing.
        #expect(store.run("gw|task").title == "Running…")
        store.update("gw|task") { accepted = $0.begin() }
        #expect(!accepted)
        // The same task on a different gateway, or another task, runs independently.
        #expect(store.run("elsewhere|task").phase == .idle)
    }
}
