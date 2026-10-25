#if os(macOS)
import Foundation
import Testing

/// The Mac as the installer sees it, recorded step by step.
final class FakeCuaMac: CuaSetupSystem, @unchecked Sendable {
    private let lock = NSLock()
    var installedVersion: String?
    var downloaded: Data?
    var mountedVersion = CuaRelease.version
    var signed = true
    var running = false
    var socket = false
    var canRun = true
    var provisionWorks = false
    var cuaHome = false
    private(set) var steps: [String] = []
    /// Every program the installer asked to run, with its arguments.
    private(set) var launches: [(executable: String, arguments: [String])] = []
    /// Nollie's own copy, in its own folder; `personal` puts the person's copy in Applications instead.
    let folder = URL(fileURLWithPath: "/Users/me/Library/Application Support/Nollie/Cua/Cua Spaces.app")
    var personal = false
    let theirs = URL(fileURLWithPath: "/Applications/Cua Spaces.app")

    private func note(_ step: String) { lock.lock(); steps.append(step); lock.unlock() }
    private func record(_ executable: String, _ arguments: [String]) { lock.lock(); launches.append((executable, arguments)); lock.unlock() }

    func installedApp() -> (url: URL, version: String?)? { installedVersion.map { (personal ? theirs : folder, $0) } }
    func download(_ url: URL, to file: URL, maximum: Int, progress: @escaping @Sendable (Double) -> Void) async throws {
        note("download")
        #expect(url == CuaRelease.url)
        progress(1)
        try (downloaded ?? Data()).write(to: file)
    }
    func sha256(_ file: URL) throws -> String {
        let data = try Data(contentsOf: file)
        return data == Data("good".utf8) ? CuaRelease.sha256 : "different"
    }
    func size(_ file: URL) -> Int? { (try? Data(contentsOf: file)) == Data("good".utf8) ? CuaRelease.bytes : 1 }
    func attach(_ image: URL) async throws -> URL { note("attach"); return URL(fileURLWithPath: "/private/tmp/fake-mount") }
    func detach(_ mount: URL) async { note("detach") }
    func verify(_ app: URL) async throws { note("verify"); if !signed { throw CuaSetupFailure("unsigned") } }
    func version(_ app: URL) -> String? { mountedVersion }
    func isRunning() -> Bool { running }
    func install(_ app: URL, at destination: URL) async throws {
        note("install")
        #expect(destination == folder)
        installedVersion = mountedVersion; personal = false
    }
    func cuaHomeExists() -> Bool { cuaHome }
    func run(_ executable: URL, _ arguments: [String], timeout: TimeInterval) async throws -> (status: Int32, output: Data) {
        record(executable.path, arguments)
        note(arguments.joined(separator: " "))
        if arguments == ["daemon", "start"] { socket = true }
        if arguments == ["daemon", "stop"] { socket = false }
        if arguments.first == "runtime", provisionWorks { canRun = true }
        if arguments == ["--json", "runtime", "doctor"] {
            let doctor: [String: Any] = ["backends": [["backend": "managed", "ready": canRun],
                                                      ["backend": "lume", "ready": false, "provisionable": true, "provisioning": []],
                                                      ["backend": "qemu", "ready": false, "provisionable": true, "provisioning": ["brew install qemu"]]]]
            return (0, try JSONSerialization.data(withJSONObject: doctor))
        }
        return (0, Data())
    }
    func daemonSocketExists() -> Bool { socket }
    func installDestination() -> URL { folder }
}

@Suite struct CuaInstallerTests {
    private func installer(_ mac: FakeCuaMac) -> CuaInstaller {
        CuaInstaller(system: mac, work: FileManager.default.temporaryDirectory.appendingPathComponent("cua-setup-" + UUID().uuidString))
    }

    private func run(_ mac: FakeCuaMac) async -> NollieCuaSetupResponse {
        await run(mac, with: installer(mac))
    }

    private func run(_ mac: FakeCuaMac, with setup: CuaInstaller) async -> NollieCuaSetupResponse {
        _ = await setup.start()
        await setup.wait()
        return await setup.status()
    }

    /// Only Cua's command-line tool ever runs, and only to start, stop or ask its background part.
    /// Never `open`, never the app's own program (its window and menu bar item), never a login item.
    private func expectHeadless(_ mac: FakeCuaMac) {
        let allowed: [[String]] = [["daemon", "start"], ["daemon", "stop"], ["--json", "runtime", "doctor"]]
        for launch in mac.launches {
            #expect(launch.executable.hasSuffix("/" + CuaRelease.appName + "/Contents/MacOS/cua"), "\(launch.executable)")
            #expect(!launch.executable.hasSuffix("/open"))
            #expect(allowed.contains(launch.arguments) || launch.arguments.prefix(2) == ["runtime", "setup"], "\(launch.arguments)")
            for word in ["open", "login", "autostart", "install", "launch", "ui", "app"] {
                #expect(!launch.arguments.contains(word), "\(launch.arguments)")
            }
        }
    }

    @Test func freshInstallVerifiesBeforeCopyingThenStartsCua() async {
        let mac = FakeCuaMac()
        mac.downloaded = Data("good".utf8)
        let result = await run(mac)
        #expect(result.phase == .done)
        #expect(result.installedVersion == CuaRelease.version)
        #expect(mac.steps.prefix(4) == ["download", "attach", "verify", "install"])
        #expect(mac.steps.contains("daemon start"))
        #expect(!mac.steps.contains { $0.hasPrefix("runtime setup") })
    }

    @Test func aDownloadThatDoesNotMatchTheReleaseIsNeverOpened() async {
        let mac = FakeCuaMac()
        mac.downloaded = Data("tampered".utf8)
        let result = await run(mac)
        #expect(result.phase == .failed)
        #expect(result.failure == "The download didn't match Cua's published release, so it wasn't used.")
        #expect(!mac.steps.contains("attach"))
        #expect(mac.installedVersion == nil)
    }

    @Test func anUnsignedOrWrongVersionCopyIsNotInstalled() async {
        let unsigned = FakeCuaMac()
        unsigned.downloaded = Data("good".utf8)
        unsigned.signed = false
        #expect(await run(unsigned).phase == .failed)
        #expect(!unsigned.steps.contains("install"))
        #expect(unsigned.steps.last == "detach")

        let wrong = FakeCuaMac()
        wrong.downloaded = Data("good".utf8)
        wrong.mountedVersion = "0.10.9"
        #expect(await run(wrong).phase == .failed)
        #expect(!wrong.steps.contains("install"))
    }

    @Test func anOlderRunningCuaAsksToBeQuitFirst() async {
        let mac = FakeCuaMac()
        mac.installedVersion = "0.8.0"
        mac.running = true
        let result = await run(mac)
        #expect(result.phase == .needsQuit)
        #expect(mac.steps.isEmpty)
    }

    @Test func anOlderCuaIsUpdatedAfterItsDaemonStops() async {
        let mac = FakeCuaMac()
        mac.installedVersion = "0.8.0"
        mac.socket = true
        mac.downloaded = Data("good".utf8)
        let result = await run(mac)
        #expect(result.phase == .done)
        let stop = mac.steps.firstIndex(of: "daemon stop"), install = mac.steps.firstIndex(of: "install")
        #expect(stop != nil && install != nil && stop! < install!)
        #expect(mac.installedVersion == CuaRelease.version)
    }

    @Test func aCurrentCuaIsNotDownloadedAgain() async {
        let mac = FakeCuaMac()
        mac.installedVersion = CuaRelease.version
        mac.socket = true
        let result = await run(mac)
        #expect(result.phase == .done)
        #expect(!mac.steps.contains("download"))
        #expect(!mac.steps.contains("daemon start"))
    }

    @Test func missingComputerSupportIsAddedByCuaOrExplained() async {
        let mac = FakeCuaMac()
        mac.installedVersion = CuaRelease.version
        mac.socket = true
        mac.canRun = false
        mac.provisionWorks = true
        #expect(await run(mac).phase == .done)
        #expect(mac.steps.contains("runtime setup lume"))
        #expect(!mac.steps.contains("runtime setup qemu"))

        let stuck = FakeCuaMac()
        stuck.installedVersion = CuaRelease.version
        stuck.socket = true
        stuck.canRun = false
        let result = await run(stuck)
        #expect(result.phase == .failed)
        #expect(result.failure == "Cua can't run computers on this Mac yet. Its download page lists what it needs.")
    }

    @Test func aFreshInstallRecordsWhatNollieMadeForALaterRemoval() async throws {
        let mac = FakeCuaMac()
        mac.downloaded = Data("good".utf8)
        let setup = installer(mac)
        #expect(await run(mac, with: setup).phase == .done)
        let receipt = try JSONDecoder().decode(NollieCuaReceipt.self, from: Data(contentsOf: await setup.receiptURL))
        #expect(receipt == NollieCuaReceipt(app: mac.folder.path, madeCuaHome: true))
        #expect(FileManager.default.fileExists(atPath: await setup.readyURL.path))
        expectHeadless(mac)
    }

    @Test func updatingOrUsingSomeoneElsesCuaRecordsNoOwnership() async {
        let older = FakeCuaMac()
        older.installedVersion = "0.8.0"
        older.downloaded = Data("good".utf8)
        older.cuaHome = true
        let setup = installer(older)
        #expect(await run(older, with: setup).phase == .done)
        #expect(!FileManager.default.fileExists(atPath: await setup.receiptURL.path))

        let current = FakeCuaMac()
        current.installedVersion = CuaRelease.version
        let other = installer(current)
        #expect(await run(current, with: other).phase == .done)
        #expect(!FileManager.default.fileExists(atPath: await other.receiptURL.path))
        expectHeadless(older)
        expectHeadless(current)
    }

    @Test func nollieRuntimeStartsAndStopsOnlyCuasBackgroundPart() async {
        let mac = FakeCuaMac()
        mac.installedVersion = CuaRelease.version
        let setup = installer(mac)
        // Before any finished setup, launching Nollie Runtime starts nothing.
        await setup.startDaemonIfSetUp()
        #expect(mac.launches.isEmpty)
        #expect(await run(mac, with: setup).phase == .done)
        #expect(await setup.stopDaemon())
        #expect(!mac.socket)
        await setup.startDaemonIfSetUp()
        #expect(mac.socket)
        #expect(mac.steps.suffix(2) == ["daemon stop", "daemon start"])
        expectHeadless(mac)

        let none = FakeCuaMac()
        #expect(await installer(none).wake() == false)
        #expect(none.launches.isEmpty)
    }

    @Test func everySetupPathStaysHeadless() async {
        for prepare in [{ (m: FakeCuaMac) in m.downloaded = Data("good".utf8) },
                        { m in m.installedVersion = "0.8.0"; m.socket = true; m.downloaded = Data("good".utf8) },
                        { m in m.installedVersion = CuaRelease.version; m.canRun = false; m.provisionWorks = true },
                        { m in m.installedVersion = CuaRelease.version; m.canRun = false }] {
            let mac = FakeCuaMac()
            prepare(mac)
            _ = await run(mac)
            expectHeadless(mac)
        }
    }

    @Test func versionsCompareByNumber() {
        #expect(CuaRelease.isOlder("0.8.0"))
        #expect(CuaRelease.isOlder("0.9.12"))
        #expect(CuaRelease.isOlder("0.11.0"))
        #expect(!CuaRelease.isOlder("0.12.0"))
        #expect(!CuaRelease.isOlder("0.13.0"))
        #expect(CuaRelease.isOlder(nil))
        #expect(CuaRelease.isOlder("beta"))
    }

    @Test func thePersonsOwnCuaIsUsedButNeverReplaced() async {
        let current = FakeCuaMac()
        current.personal = true
        current.installedVersion = CuaRelease.version
        #expect(await run(current).phase == .done)
        #expect(!current.steps.contains("install"))
        #expect(current.launches.allSatisfy { $0.executable.hasPrefix(current.theirs.path + "/") })

        let older = FakeCuaMac()
        older.personal = true
        older.installedVersion = "0.8.0"
        older.downloaded = Data("good".utf8)
        let result = await run(older)
        #expect(result.phase == .failed)
        #expect(result.failure == "Your copy of Cua is older than Nollie needs. Update it from Cua's site, then try again.")
        #expect(older.steps.isEmpty)
    }

    @Test func cuaIsLookedForInApplicationsThenNolliesFolder() {
        let home = URL(fileURLWithPath: "/Users/me")
        let own = URL(fileURLWithPath: "/Users/me/Library/Application Support/Nollie/Cua")
        #expect(NollieCuaPlaces.folders(home: home, own: own).map(\.path) == ["/Applications", "/Users/me/Applications", own.path])
        #expect(CuaMacSystem(home: home, own: own).installDestination().path == own.path + "/Cua Spaces.app")
    }

    @Test func downloadsComeOnlyFromGitHubReleases() {
        #expect(CuaRelease.allowsDownload(from: CuaRelease.url))
        #expect(CuaRelease.allowsDownload(from: URL(string: "https://release-assets.githubusercontent.com/x")!))
        #expect(!CuaRelease.allowsDownload(from: URL(string: "http://github.com/x")!))
        #expect(!CuaRelease.allowsDownload(from: URL(string: "https://example.com/cua.dmg")!))
    }

    @Test func setupAnswersRoundTripThroughTheHelper() throws {
        let sent = NollieCuaSetupResponse(phase: .downloading, fraction: 0.5, installedVersion: "0.8.0", failure: nil)
        #expect(try NollieCuaSetupResponse.decode(sent.encoded()) == sent)
        #expect(throws: (any Error).self) { try NollieCuaSetupResponse.decode(Data(#"{"version":2,"phase":"done"}"#.utf8)) }
    }
}
#endif
