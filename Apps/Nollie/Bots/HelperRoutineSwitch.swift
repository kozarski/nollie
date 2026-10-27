import Foundation
import Observation
import NollieCore

/// The switch for a helper's suggested schedule, on its page. Off until the person turns it on:
/// on makes an ordinary schedule for that helper (or resumes the one it made before), off pauses
/// it. It reads the gateway's own schedules every time, so Settings › Schedules and this switch
/// always agree. The calls are passed in, so the rules can be checked without a gateway.
@MainActor @Observable
final class HelperRoutineSwitch {
    enum Standing: Equatable { case checking, off, on, unavailable }

    struct Calls {
        /// The bot's schedules, as the gateway lists them.
        var jobs: (_ profile: String) async throws -> [JSONValue]
        var create: (_ profile: String, _ payload: JSONValue) async throws -> JSONValue
        /// Pauses (true) or resumes (false) one schedule.
        var pause: (_ profile: String, _ job: String, _ pause: Bool) async throws -> JSONValue
    }

    let helper: ReadyMadeHelper
    let routine: HelperRoutine
    private(set) var standing: Standing = .checking
    private(set) var busy = false
    private(set) var problem: String?
    /// The schedule this switch stands for, once there is one.
    private(set) var job: CronJob?

    init(helper: ReadyMadeHelper, routine: HelperRoutine) {
        self.helper = helper
        self.routine = routine
    }

    var isOn: Bool { standing == .on }

    /// What a new schedule is made of: the helper's own task, its time, and its chat for the results.
    var payload: JSONValue {
        .object([
            "name": .string(routine.jobName(for: helper)),
            "prompt": .string(routine.prompt),
            "schedule": .string(routine.cron),
            "deliver": .string("bot-chat"),
        ])
    }

    /// Looks for the schedule this switch made before. None means off.
    func load(profile: String, _ calls: Calls) async {
        do {
            let found = try await calls.jobs(profile).compactMap { raw -> CronJob? in
                guard let job = ScheduledWork.decode(raw), job.name == routine.jobName(for: helper) else { return nil }
                // A list from a gateway that ignores the bot filter: keep only this bot's.
                if let owner = ScheduledWork.owner(raw), owner != profile { return nil }
                return job
            }
            // An active one wins over a paused one, should both exist.
            job = found.first { !ScheduledWork.paused($0) && !ScheduledWork.completed($0) } ?? found.first
            standing = job.map { ScheduledWork.paused($0) || ScheduledWork.completed($0) ? .off : .on } ?? .off
        } catch {
            standing = .unavailable
        }
    }

    /// The person's tap. Never a second schedule: an earlier one is resumed, and an answer that
    /// was lost is read back from the gateway rather than tried again.
    func set(_ on: Bool, profile: String, _ calls: Calls, allowed: () -> Bool) async {
        guard !busy, standing == .on || standing == .off, on != isOn, allowed() else { return }
        busy = true
        problem = nil
        defer { busy = false }
        do {
            if let job, !ScheduledWork.completed(job) {
                _ = try await calls.pause(profile, job.identity, !on)
            } else if on {
                let reply = try await calls.create(profile, payload)
                let made = ScheduledWork.decode(reply)
                if made?.name != routine.jobName(for: helper) || ScheduledWork.owner(reply).map({ $0 != profile }) == true {
                    problem = String(localized: "That wasn't confirmed. Check Schedules.")
                }
            } else {
                return
            }
        } catch {
            problem = on ? String(localized: "It didn't turn on. Try again.") : String(localized: "It didn't turn off. Try again.")
        }
        // What the gateway says now is the answer, also when the reply was lost on the way.
        await load(profile: profile, calls)
        if standing == (on ? .on : .off) { problem = nil }
    }
}

extension HelperRoutineSwitch.Calls {
    /// The gateway's own schedule routes, for the helper's profile.
    @MainActor static func gateway(_ runtime: GatewayRuntime) -> Self {
        let api = runtime.api
        return Self(
            jobs: { profile in
                let reply: JSONValue = try await api.get("/api/cron/jobs", profile: profile)
                return reply["jobs"]?.arrayValue ?? reply["items"]?.arrayValue ?? reply.arrayValue ?? []
            },
            create: { profile, payload in try await api.send("POST", "/api/cron/jobs", profile: profile, json: payload) },
            pause: { profile, job, pause in
                try await api.send("POST", "/api/cron/jobs/\(job)/\(pause ? "pause" : "resume")", profile: profile,
                                   body: EmptyBody())
            })
    }
}
