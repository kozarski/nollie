import SwiftUI
import NollieCore

/// Updating the companion on the gateway to the version this build ships.
extension PushSetupModel {
    /// An approximate "time remaining" for the card, based on the current stage.
    var updateRemaining: String? {
        switch updateStage {
        case "Preparing Update…", "Installing…", "Restarting Gateway…": "About 1 minute remaining"
        case "Restart to finish": "Waiting for the restart"
        case "Verifying…": "Up to 2 minutes"
        case "Still verifying…": "Giving it another minute"
        default: nil
        }
    }

    // MARK: Helpers

    private static let clockStyle = Date.FormatStyle().hour().minute().second()

    private func say(_ line: String) {
        var entries = updateConsole
        entries.append(Date().formatted(Self.clockStyle) + "  " + line)
        updateConsole = Array(entries.suffix(40))
    }

    private func fail(_ text: String, logged: String? = nil) {
        if let logged { say("FAILED " + logged) }
        updateOutcome = (false, text)
    }

    private func moveBar(to fraction: Double) {
        withAnimation(.snappy) { updateProgress = fraction }
    }

    /// Fills the bar, announces success, and clears the card a few seconds later.
    private func conclude(_ version: String) async {
        moveBar(to: 1)
        updateStage = "Update Complete"
        say("companion v\(version) is up and connected")
        updateOutcome = (true, "Now on v\(version). The companion is up and connected.")
        try? await Task.sleep(nanoseconds: 4_000_000_000)
        withAnimation(.smooth(duration: 0.7)) {
            update.consoleOpen = false
            update.outcome = nil
            update.progress = 0
            update.stage = ""
        }
    }

    // MARK: Update in place

    /// Writes the plugin files, turns the plugin on and waits for a fresh heartbeat, describing each
    /// step beneath a progress bar. If the running companion cannot reload itself, it finishes with a
    /// restart countdown.
    func updateCompanion(runtime rt: GatewayRuntime) async {
        guard !updating else { return }
        (updating, updateProgress, updateConsole, updateOutcome, showUpdateConsole) = (true, 0, [], nil, true)
        defer { updating = false }
        guard await backUpCompanion(runtime: rt) else { return fail(error ?? "The companion backup failed.") }
        guard let home = rt.profileHome else { return fail("The gateway did not say where its home folder is.") }
        guard let files = CompanionBundle.pluginFiles else { return fail("This build is missing the plugin files.") }

        let target = Self.bundledPluginVersion
        let folder = "\(home)/plugins/\(Self.pluginID)"
        let steps = Double(files.count + 3) // the files, enabling, restarting, the first heartbeat
        updateStage = "Preparing Update…"
        say("Updating companion \(installedVersion.map { "v\($0)" } ?? "?") to v\(target)")

        for (index, file) in files.enumerated() {
            do {
                try await writeFile(rt, path: "\(folder)/\(file.name)", data: file.data, mime: file.mime)
            } catch {
                return fail("Could not write \(file.name): \(error.localizedDescription)", logged: "\(file.name): \(error.localizedDescription)")
            }
            say("wrote \(folder)/\(file.name) (\(file.data.count) bytes)")
            moveBar(to: Double(index + 1) / steps)
        }
        updateStage = "Installing…"
        if let refusal = await enable(rt) { return fail(refusal, logged: "enable: \(refusal)") }
        say("Nollie companion enabled")
        moveBar(to: Double(files.count + 1) / steps)

        // From 1.0.12 the companion swaps in new code on its own, so wait up to thirty seconds for that.
        updateStage = "Reloading…"
        say("files are in place; waiting for the companion to reload itself")
        let reloaded = await poll(times: 10) {
            await checkCompanion(runtime: rt)
            return heartbeat?.version == target && !runningOlderCode
        }
        if reloaded {
            say("companion v\(target) reloaded in place, no restart needed")
            moveBar(to: 5 / steps)
            updateStage = "Verifying…"
            if await poll(times: 10, until: { await checkCompanion(runtime: rt); return companionHealthy }) || companionHealthy {
                return await conclude(target)
            }
        }
        updateNeedsRestart = true
        updateStage = "Restart to finish"
        say("the running companion did not pick the files up; restarting the \(heartbeat?.profile ?? "default") gateway will")
        scheduleRestartCountdown(runtime: rt)
    }

    /// Enables the plugin; the reason it would not, or nil.
    private func enable(_ rt: GatewayRuntime) async -> String? {
        do {
            let reply = try await enableCompanion(runtime: rt)
            return reply["ok"]?.boolValue == false ? (reply["error"]?.stringValue ?? "Hermes would not enable the plugin.") : nil
        } catch {
            return error.localizedDescription
        }
    }

    // MARK: After a restart

    /// Second half of an update. Restarts the gateway, then watches for the new companion's first heartbeat.
    func finishUpdateAfterRestart(runtime rt: GatewayRuntime) async {
        let target = Self.bundledPluginVersion
        let steps = 6.0
        (updating, showUpdateConsole) = (true, true)
        defer { updating = false }
        updateStage = "Restarting Gateway…"
        let profile = heartbeat?.profile
        say("restarting the gateway (profile \(profile ?? "default"))")
        // Show the gateway's own restart output in the console as it arrives.
        let mirror = Task { [weak self] in
            var seen = 0
            repeat {
                try? await Task.sleep(nanoseconds: 500_000_000)
                let lines = rt.maintenance.actionLog
                for line in lines.dropFirst(seen) { self?.say("gateway: " + line) }
                seen = lines.count
            } while !Task.isCancelled
        }
        await rt.maintenance.restartGateway(runtime: rt, profile: profile == "default" ? nil : profile)
        mirror.cancel()
        if case .failed(let why) = rt.maintenance.phase { return fail("Restart failed: \(why)", logged: "restart: \(why)") }
        say("gateway restart finished")
        (restartPending, updateNeedsRestart) = (false, false)
        moveBar(to: 5 / steps)

        updateStage = "Verifying…"
        let began = Date()
        var lastLine = ""
        let verified = await poll(times: 40) {
            await checkCompanion(runtime: rt)
            if let beat = heartbeat {
                let line = "heartbeat v\(beat.version): " + (beat.connected == true ? "connected" : (beat.error ?? "not connected"))
                if line != lastLine { say(line); lastLine = line }
            }
            if companionHealthy && installedVersion == target { return true }
            let elapsed = -began.timeIntervalSinceNow
            moveBar(to: (5 + min(0.9, elapsed / 120)) / steps)
            if elapsed > 60 && updateStage == "Verifying…" {
                updateStage = "Still verifying…"
                say("no new heartbeat after a minute; waiting a little longer")
            }
            return elapsed >= 120
        }
        guard verified, companionHealthy, installedVersion == target else {
            updateStage = "Not verified"
            let last = heartbeat.map { "The last heartbeat is from v\($0.version), \($0.connected == true ? "connected" : "not connected")." } ?? "No heartbeat has been read."
            return fail("The files are on the gateway, but the new companion did not report in within two minutes. \(last) Restart the gateway once more (Settings, Gateway), then check again here. If it still does not report, open the Companion page and run the test.")
        }
        await conclude(target)
    }
}
