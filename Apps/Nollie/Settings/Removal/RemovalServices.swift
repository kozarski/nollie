import Foundation
import NollieCore
#if os(macOS)
import ServiceManagement
#endif

/// The real effects of Remove on this device. The demo copy never gets these: it pretends.
@MainActor
struct LiveRemovalServices: RemovalServices {
    var places: RemovalPlaces

    func stopRuntime() async -> String? {
        #if os(macOS) && NOLLIE_DIRECT
        guard ManagedRuntimeServiceControl.system.status() == .enabled else { return nil }
        guard let reply = try? await ManagedRuntimeRequest.send(.prepareRemoval),
              let response = try? NollieRuntimeRemovalResponse.decode(reply.data) else {
            return "Couldn't reach Nollie Runtime. It stops when it's taken out of Login Items."
        }
        if !response.hermesStopped { return "Nollie Runtime didn't confirm your assistant stopped. It stops with Nollie Runtime." }
        if !response.cuaStopped { return "Cua's background part didn't stop. It stops when you log out." }
        if !response.keychainCleared { return "Some of Nollie Runtime's keys stay in the keychain." }
        #endif
        return nil
    }

    func unregisterRuntime() async -> String? {
        #if os(macOS) && NOLLIE_DIRECT
        let control = ManagedRuntimeServiceControl.system
        guard [.enabled, .requiresApproval].contains(control.status()) else { return nil }
        let unregister = control.unregister
        let finished = (try? await ManagedRuntimeDeadline<Void>.run(after: .seconds(15)) { try await unregister() }) != nil
        if !finished || [.enabled, .requiresApproval].contains(control.status()) {
            return "macOS hasn't taken Nollie Runtime out of Login Items yet. You can turn it off in Login Items."
        }
        #endif
        return nil
    }

    func unregisterNotifications() async -> String? {
        #if os(macOS) && NOLLIE_DIRECT
        let item = CloudAlertLoginItemClient.system
        guard [.enabled, .requiresApproval].contains(item.status()) else { return nil }
        let unregister = item.unregister
        let finished = (try? await ManagedRuntimeDeadline<Void>.run(after: .seconds(15)) { try await unregister() }) != nil
        if !finished || [.enabled, .requiresApproval].contains(item.status()) {
            return "macOS hasn't taken Nollie Notifications out of Login Items yet. You can turn it off in Login Items."
        }
        #endif
        return nil
    }

    func releaseComputers(_ hermes: RemovalHermes) async -> String? {
        #if os(macOS) && NOLLIE_DIRECT
        if ManagedRuntimeServiceControl.system.status() == .enabled {
            // Cua answers only while its background part runs; Nollie Runtime wakes it, headless.
            _ = try? await ManagedRuntimeRequest.send(.cuaWake)
        }
        guard let script = Self.verifiedComputerScript() else {
            return "This copy of Nollie is missing a file it needs to turn off your helpers' computers. Turn each one off in Bot settings."
        }
        var arguments = ["-I", "-B", script.path, "release", "--home", hermes.home.path, "--cua-home", places.home.path]
        var environment: [String: String]
        if hermes.managed {
            arguments.append("--spaces-only")
            environment = NativeSetupPlan.environment(installation: hermes.home.deletingLastPathComponent())
        } else {
            environment = ["HOME": places.home.path, "LANG": "en_US.UTF-8", "NO_COLOR": "1",
                           "PATH": places.home.appendingPathComponent(".local/bin").path + ":/usr/bin:/bin:/usr/sbin:/sbin"]
        }
        environment["CUA_TELEMETRY"] = "0"
        if let cua = NollieCuaPlaces.cli(home: places.home, own: places.nollie.cua) { environment["NOLLIE_CUA_CLI"] = cua.path }
        guard let output = await Self.run(hermes.python, arguments, environment: environment, timeout: 900),
              let report = try? JSONDecoder().decode(ReleaseReport.self, from: output) else {
            return "Couldn't turn off your helpers' computers. Turn each one off in Bot settings."
        }
        if let message = report.message { return message }
        let kept = report.profiles.sorted { $0.key < $1.key }.filter { $0.value.computer == "kept" }
        if let first = kept.first {
            let name = first.key == "default" ? "Your main helper" : first.key.capitalized
            return "\(name)'s computer stays. \(first.value.message ?? "")".trimmingCharacters(in: .whitespaces)
        }
        if let first = report.profiles.sorted(by: { $0.key < $1.key }).first(where: { $0.value.message != nil }) {
            return first.value.message
        }
        #endif
        return nil
    }

    func stopPushService() async -> String? {
        #if os(macOS)
        let label = "gui/\(getuid())/com.coreykozarski.nollie.push"
        _ = await Self.run(URL(fileURLWithPath: "/bin/launchctl"), ["bootout", label], environment: [:], timeout: 30)
        #endif
        return nil
    }

    func trash(_ url: URL) -> String? {
        #if os(macOS)
        do { try FileManager.default.trashItem(at: url, resultingItemURL: nil); return nil } catch {
            return "Couldn't move \(url.lastPathComponent) to the Trash. You can drag it there in Finder."
        }
        #else
        return nil
        #endif
    }

    func forgetKeychain(_ service: String) -> String? {
        Keychain.deleteAll(service: service) ? nil : "Some of Nollie's keychain items stay. You can delete them in Keychain Access."
    }

    func clearSettings() {
        UserDefaults.standard.removePersistentDomain(forName: places.bundleID)
        UserDefaults.standard.synchronize()
    }

    func deleteCloudData() async -> String? {
        do { try await CloudKitAlertStore().deleteEverything(); return nil } catch {
            return "Couldn't reach iCloud, so Nollie's alerts there stay. They expire by themselves within a week."
        }
    }

    // MARK: Helpers

    private struct ReleaseReport: Decodable {
        struct Profile: Decodable { var computer: String; var message: String? }
        var profiles: [String: Profile]
        var message: String?
    }

    #if os(macOS) && NOLLIE_DIRECT
    /// The computer add-on's own code, from the Setup Kit this app carries, checked by its digest.
    static func verifiedComputerScript() -> URL? {
        let relative = "nollie-computer/dashboard/own_computer.py"
        guard let kit = try? NativeSetupKit.addOns(),
              let file = kit.installedFiles.first(where: { $0.path == "plugins/" + relative }) else { return nil }
        let script = kit.root.appendingPathComponent(relative)
        guard let data = try? OwnedSetupFiles.read(script, maximum: max(file.bytes, 1)),
              OwnedSetupFiles.hash(data) == file.sha256 else { return nil }
        return script
    }
    #endif

    #if os(macOS)
    /// Runs a program with only the given environment and returns what it printed, or nil.
    static func run(_ executable: URL, _ arguments: [String], environment: [String: String], timeout: TimeInterval) async -> Data? {
        await Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = executable
            process.arguments = arguments
            process.environment = environment
            let output = Pipe()
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            process.standardInput = FileHandle.nullDevice
            do { try process.run() } catch { return nil }
            let reader = Task.detached { output.fileHandleForReading.readDataToEndOfFile() }
            let deadline = Date().addingTimeInterval(timeout)
            while process.isRunning {
                if Date() > deadline { process.terminate(); break }
                try? await Task.sleep(for: .milliseconds(100))
            }
            let data = await reader.value
            return process.terminationStatus == 0 && data.count < 1_000_000 ? data : nil
        }.value
    }
    #endif
}
