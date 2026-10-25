#if os(macOS)
import Darwin
import Foundation

@main struct NollieRuntimeHelperMain {
    static func main() {
        NollieLogFiles.start(.runtimeHelper)
        #if NOLLIE_DIRECT
        guard let entrypoint = Bundle.main.url(forResource: "runtime_entry", withExtension: "py") else { return }
        let paths = NolliePaths.current
        let serviceDirectory = paths.runtimeService
        let backend = NativeRuntimeBackend(installations: paths.setups, entrypoint: entrypoint)
        let service = RuntimeService(supervisor: NollieRuntimeSupervisor(backend: backend),
                                     credentials: RuntimeKeychainCredentials(),
                                     consent: RuntimeConsentFile(directory: serviceDirectory))
        // The exit relay: helpers' computers reach the internet through this Mac, so a Tailscale
        // exit node carries their traffic too. On by itself whenever a computer runs.
        let relay = RuntimeExitRelay(directory: serviceDirectory)
        // Nollie Link: the TLS door for linked phones. It listens only while a device is linked or
        // a pairing code is showing.
        let link = RuntimeLink.make(service: service, directory: serviceDirectory, relay: relay)
        // Cua for helpers' own computers: fetched, verified and installed here, never in the app.
        let cua = CuaInstaller(system: CuaMacSystem(), work: paths.cuaSetup)
        let delegate = RuntimeListenerDelegate(service: service, link: link, cua: cua, relay: relay)
        let listener = NSXPCListener(machServiceName: NollieRuntimeIPCConfiguration.machService)
        listener.delegate = delegate
        // Nollie.app dragged to the Trash or deleted: nobody is left to ask about data, so nothing
        // is deleted. Hermes and Cua's background part stop, this helper leaves launchd, and a
        // reinstalled Nollie offers to use the setup again or remove it.
        let presence = AppPresence.forThisHelper()
        let goneAtLaunch = presence?.check() == .gone
        if !goneAtLaunch {
            listener.resume()
            Task { await service.resumeEnabledInstallation() }
            Task { await link?.resume() }
            Task { await relay.run() }
            // Cua's background part only, headless, once a Nollie setup has finished. Never its app.
            Task { await cua.startDaemonIfSetUp() }
        }
        if let presence {
            Task {
                guard let verdict = goneAtLaunch ? .gone : await presence.watch() else { return }
                await service.halt()
                await link?.close()
                await relay.close()
                guard verdict == .gone else {
                    // A newer Nollie.app took this one's place: launchd starts its helper instead.
                    exit(75)
                }
                _ = await cua.stopDaemon()
                RuntimeAppGoneRecord.write(in: serviceDirectory, app: presence.installedPath)
                RuntimeAppGoneRecord.leaveLaunchd()
                exit(0)
            }
        }
        // The owner pipes close on process termination. Children then stop even
        // when launchd ends the helper without an opportunity for async cleanup.
        withExtendedLifetime((listener, delegate, service, link, cua, presence, relay)) { RunLoop.current.run() }
        #endif
    }
}

#if NOLLIE_DIRECT
enum RuntimeAppGoneRecord {
    /// A small private note for a reinstalled Nollie. Never a secret, never a path chosen by a caller.
    static func write(in directory: URL, app: String) {
        guard (try? OwnedSetupFiles.createPrivateDirectory(directory)) != nil,
              let data = try? JSONEncoder().encode(NollieRuntimeAppGone(at: Date(), app: app)),
              let fd = try? OwnedSetupFiles.directory(directory) else { return }
        defer { close(fd) }
        _ = unlinkat(fd, NollieRuntimeAppGone.fileName, 0)
        try? OwnedSetupFiles.writeNew(data, to: directory.appendingPathComponent(NollieRuntimeAppGone.fileName))
    }

    /// Takes this helper out of launchd for this login, so it isn't started again until Nollie is
    /// back. Booting out ends this process; exit afterwards covers a refusal.
    static func leaveLaunchd() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = ["bootout", "gui/\(getuid())/\(NollieRuntimeContract.serviceLabel)"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run(); process.waitUntilExit() } catch {}
    }
}
#endif
#endif
