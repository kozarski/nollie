import Foundation
import NollieCore

/// Restarting the gateway after an install, with a countdown, and waiting for the companion to come back.
extension PushSetupModel {
    /// Runs `probe` up to `times` times with `gap` before each, stopping at the first true.
    /// A cancelled task stops early and counts as not found.
    func poll(times: Int, every gap: Duration = .seconds(3), until probe: () async -> Bool) async -> Bool {
        for _ in 0..<times {
            try? await Task.sleep(for: gap)
            if Task.isCancelled { return false }
            if await probe() { return true }
        }
        return false
    }

    // MARK: Countdown

    func scheduleRestartCountdown(runtime rt: GatewayRuntime, seconds: TimeInterval = 90) {
        restartPending = true
        restartCountdownEnd = Date(timeIntervalSinceNow: seconds)
        restartTimer?.cancel()
        restartTimer = Task { [weak self] in
            await self?.restartWhenDue(after: seconds, runtime: rt)
        }
    }

    /// The countdown's end: restart, unless "Later" or a restart in the meantime cancelled it.
    private func restartWhenDue(after seconds: TimeInterval, runtime rt: GatewayRuntime) async {
        do { try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) } catch { return }
        if restartCountdownEnd != nil { await restartNow(runtime: rt) }
    }

    /// Stops the countdown. `restartPending` stays set so the cards keep saying a restart is due.
    func restartLater() {
        restartCountdownEnd = nil
        restartTimer?.cancel()
        restartTimer = nil
    }

    func restartNow(runtime rt: GatewayRuntime) async {
        restartLater()
        if restarting { return }
        // The wait is a task of its own so "Finish later" can walk away from it without tearing
        // down the button's task.
        restartWait = Task { await self.waitForRestart(runtime: rt) }
        await restartWait?.value
    }

    func stopWaitingForRestart() {
        restartWait?.cancel()
        restartWait = nil
    }

    /// A single check of the companion. Once it has reported since the restart started, the wait ends.
    func checkRestartNow(runtime rt: GatewayRuntime) async {
        await checkCompanion(runtime: rt)
        guard let since = restartBegan ?? restartAskedAt, reportedSince(since) else {
            restartError = String(localized: "Not back yet. The companion has not checked in since the restart started.")
            return
        }
        stopWaitingForRestart()
        await markBackUp(rt)
        (restartError, restartPending) = (nil, false)
    }

    /// Closes the maintenance line as finished and reconnects this app to the gateway.
    private func markBackUp(_ rt: GatewayRuntime) async {
        rt.maintenance.finishEarly(String(localized: "Restarting gateway: back up"))
        await rt.reconnectNow()
    }

    /// Healthy, and its latest heartbeat was written after `moment`.
    private func reportedSince(_ moment: Date) -> Bool {
        companionHealthy && (heartbeat?.updatedAt ?? 0) > moment.timeIntervalSince1970 + 2
    }

    // MARK: The wait

    private func waitForRestart(runtime rt: GatewayRuntime) async {
        restarting = true
        restartBegan = Date()
        restartStage = String(localized: "Asking the gateway to restart")
        restartError = nil
        defer { (restarting, restartBegan, restartStage) = (false, nil, "") }
        if updateNeedsRestart { return await finishUpdateAfterRestart(runtime: rt) }

        // Another maintenance action that is still following its log would turn this restart into a quiet no-op.
        _ = await poll(times: 20, every: .seconds(1)) { !rt.maintenance.isBusy }

        // The restart request rarely answers, because the dashboard that would reply is the thing
        // restarting. It goes off in the background. The wait ends on the companion's first heartbeat
        // after the restart began, or on the request's own short timeout.
        let began = Date()
        restartAskedAt = began
        let profile = heartbeat?.profile.flatMap { $0 == "default" ? nil : $0 }
        var call = Task { await rt.maintenance.restartGateway(runtime: rt, profile: profile) }
        var renewed = false

        restartStage = String(localized: "Waiting for the companion to report back")
        var callFailed = false
        let found = await poll(times: 40) {
            if case .failed(let why) = rt.maintenance.phase {
                // An expired session is renewed once before the person is asked to sign in.
                let expired = ["expired", "401"].contains(where: why.localizedCaseInsensitiveContains)
                if expired && !renewed, (try? await rt.refreshSession()) != nil {
                    renewed = true
                    call = Task { await rt.maintenance.restartGateway(runtime: rt, profile: profile) }
                    return false
                }
                callFailed = true
                return true      // stop waiting: the call failed
            }
            await checkCompanion(runtime: rt)
            return reportedSince(began)
        }
        var back = found && !callFailed
        if Task.isCancelled { return restartStage = "" }
        if !back, case .failed = rt.maintenance.phase {
            // Even if the request errored, the restart may have gone through: the session ends with the old process.
            restartStage = String(localized: "The restart call failed. Checking whether the gateway came back anyway")
            back = await poll(times: 20) {
                await checkCompanion(runtime: rt)
                return reportedSince(began)
            }
            if Task.isCancelled { return restartStage = "" }
        }
        if !back {
            // A dashboard that never replies must not keep the page spinning forever.
            restartStage = String(localized: "Giving the gateway one more half minute")
            _ = await poll(times: 30, every: .seconds(1)) { !rt.maintenance.isBusy }
            if Task.isCancelled { return restartStage = "" }
            if rt.maintenance.isBusy {
                call.cancel()
                rt.maintenance.finishEarly(String(localized: "Gateway restart: still waiting for an answer"))
                restartError = String(localized: "The gateway has not reported back yet. It may still be restarting. Check now looks again, or finish later and come back.")
                return
            }
        } else {
            await markBackUp(rt)
        }
        // The companion decides. If it checks in now, the restart took place, regardless of what the request said.
        await checkCompanion(runtime: rt)
        if companionHealthy, let beat = heartbeat, -Date(timeIntervalSince1970: beat.updatedAt).timeIntervalSinceNow < 90 {
            if case .failed = rt.maintenance.phase { rt.maintenance.finishEarly(String(localized: "Restarting gateway: back up")) }
            (restartError, restartPending) = (nil, false)
        } else if case .failed(let why) = rt.maintenance.phase {
            restartError = why
        } else {
            restartPending = false
        }
    }
}
