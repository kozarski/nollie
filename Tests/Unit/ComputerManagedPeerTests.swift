#if os(macOS)
import Foundation
import NollieCore
import Testing
@testable import Nollie

/// The nollie-mac add-on in Nollie's own setup: accepted only on the Python Nollie installed (its
/// exact file, by the hash the installer recorded), running the shipped server.py under the gateway
/// or dashboard that this Nollie's Runtime started. Everything else is refused.
@Suite struct ComputerManagedPeerTests {
    static let app = "/Applications/Nollie.app"
    static let root = "/Users/x/Library/Application Support/Nollie/Setups/6A1C0D2E-7B4F-4C1A-9E2D-3F5A6B7C8D9E"
    static let interpreter = root + "/python/" + NativeSetupPlan.pythonKey + "/bin/python3.14"
    static let recorded = String(repeating: "ab", count: 32)
    static let team = "5985LRZFZS"
    let setup = ComputerPeer.Managed(root: root, interpreter: interpreter, interpreterDigest: recorded, app: app, team: team)

    func process(_ pid: Int32, parent: Int32, _ path: String, _ arguments: [String]) -> ComputerProcess {
        ComputerProcess(pid: pid, parent: parent, started: 100, path: path, arguments: arguments)
    }

    var runtime: ComputerProcess {
        process(30, parent: 1, Self.app + "/Contents/Helpers/Nollie Runtime.app/Contents/MacOS/Nollie Runtime", ["Nollie Runtime"])
    }

    func hermes(_ role: String, entry: String = app + "/Contents/Helpers/Nollie Runtime.app/Contents/Resources/runtime_entry.py",
                path: String = interpreter, source: String = root + "/hermes") -> ComputerProcess {
        process(40, parent: 30, path, [Self.root + "/environment/bin/python", "-I", "-B", entry, "--source", source, "--role", role])
    }

    func addOn(_ script: String = root + "/home/profiles/career/plugins/nollie-mac/server.py", path: String = interpreter) -> ComputerProcess {
        process(50, parent: 40, path, [path, "-I", script])
    }

    func facts(_ me: ComputerProcess, parent: ComputerProcess, ancestors: [ComputerProcess]? = nil, program: String? = recorded,
               top: ComputerSignature? = ComputerSignature(identifier: "com.coreykozarski.nollie.runtime", team: team, valid: true),
               launchd: Bool = true, stdio: Bool = true, oneJob: Bool = true, listens: Bool = true,
               signature: ComputerSignature = ComputerSignature(identifier: "python3.14", team: nil, valid: true)) -> ComputerPeer.Facts {
        var facts = ComputerPeer.Facts(me: me, parent: parent, ancestors: ancestors ?? [runtime], reachedLaunchd: launchd, signature: signature,
                                       stdioFromParent: stdio, oneLaunchdJob: oneJob, parentListens: listens)
        facts.programDigest = program
        facts.topSignature = top
        return facts
    }

    func identify(_ facts: ComputerPeer.Facts, setup: ComputerPeer.Managed? = nil, digest: String = ComputerPeer.addOnDigest) -> ComputerPeer? {
        ComputerPeer.identify(facts, managed: setup ?? self.setup) { _ in digest }
    }

    @Test func nolliesOwnPythonUnderNollieRuntimeIsAccepted() {
        #expect(identify(facts(addOn(), parent: hermes("gateway"))) == ComputerPeer(pid: 50, started: 100, host: .gateway, profile: "career"))
        #expect(identify(facts(addOn(Self.root + "/home/plugins/nollie-mac/server.py"), parent: hermes("api")))
                == ComputerPeer(pid: 50, started: 100, host: .dashboard, profile: "default"))
    }

    @Test func anInterpreterThatIsntTheOneNollieInstalledIsRefused() {
        // Its file changed since the installer recorded it (the wrong hash).
        #expect(identify(facts(addOn(), parent: hermes("gateway"), program: String(repeating: "cd", count: 32))) == nil)
        #expect(identify(facts(addOn(), parent: hermes("gateway"), program: nil)) == nil)
        // A copy of it anywhere else: not the path Nollie installed.
        let copy = "/Users/x/Downloads/python3.14"
        #expect(identify(facts(addOn(path: copy), parent: hermes("gateway"))) == nil)
        // The signature the kernel holds doesn't hold.
        #expect(identify(facts(addOn(), parent: hermes("gateway"), signature: ComputerSignature(identifier: nil, team: nil, valid: false))) == nil)
        // An unsigned build of Nollie accepts no setup.
        var unsigned = setup
        unsigned.team = nil
        #expect(identify(facts(addOn(), parent: hermes("gateway")), setup: unsigned) == nil)
    }

    @Test func aTerminalRunCopyOrAnotherParentIsRefused() {
        let zsh = process(60, parent: 1, "/bin/zsh", ["-zsh"])
        let terminal = process(20, parent: 1, "/System/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal", ["Terminal"])
        // Run by hand from a terminal: the parent is a shell, not Hermes.
        #expect(identify(facts(addOn(), parent: zsh, ancestors: [terminal])) == nil)
        // Hermes started by hand under a shell, with this Nollie's own entry point.
        #expect(identify(facts(addOn(), parent: hermes("gateway"), ancestors: [zsh, terminal])) == nil)
        #expect(identify(facts(addOn(), parent: hermes("gateway"), ancestors: [terminal], top: nil)) == nil)
        // Something other than this Nollie's Runtime above it, or another team's.
        let other = process(30, parent: 1, "/Applications/Other.app/Contents/MacOS/Other", ["Other"])
        #expect(identify(facts(addOn(), parent: hermes("gateway"), ancestors: [other])) == nil)
        #expect(identify(facts(addOn(), parent: hermes("gateway"),
                               top: ComputerSignature(identifier: "x", team: "OTHERTEAM1", valid: true))) == nil)
        // Not one launchd job, not started by launchd, stdio not Hermes's pipes, or not listening.
        #expect(identify(facts(addOn(), parent: hermes("gateway"), launchd: false)) == nil)
        #expect(identify(facts(addOn(), parent: hermes("gateway"), oneJob: false)) == nil)
        #expect(identify(facts(addOn(), parent: hermes("gateway"), stdio: false)) == nil)
        #expect(identify(facts(addOn(), parent: hermes("gateway"), listens: false)) == nil)
        // Another role, another entry point, another source, or another Python as the parent.
        #expect(identify(facts(addOn(), parent: hermes("chat"))) == nil)
        #expect(identify(facts(addOn(), parent: hermes("gateway", entry: "/tmp/runtime_entry.py"))) == nil)
        #expect(identify(facts(addOn(), parent: hermes("gateway", entry: Self.app + "/Contents/../../tmp/runtime_entry.py"))) == nil)
        #expect(identify(facts(addOn(), parent: hermes("gateway", source: "/tmp/hermes"))) == nil)
        #expect(identify(facts(addOn(), parent: hermes("gateway", path: "/usr/bin/python3"))) == nil)
    }

    @Test func onlyTheShippedServerInABotsOwnFolderAndNeverAPrivateOne() {
        for script in [Self.root + "/home/profiles/career/plugins/nollie-mac/other.py", "/tmp/nollie-mac/server.py",
                       Self.root + "/home/profiles/career/plugins/../../../x/plugins/nollie-mac/server.py",
                       Self.root + "/home/profiles/.career.staging-1/plugins/nollie-mac/server.py"] {
            #expect(identify(facts(addOn(script), parent: hermes("gateway"))) == nil, "\(script)")
        }
        #expect(identify(facts(addOn(), parent: hermes("gateway")), digest: "0000") == nil)
        var read: [String] = []
        let moss = addOn(Self.root + "/home/profiles/private/plugins/nollie-mac/server.py")
        #expect(ComputerPeer.identify(facts(moss, parent: hermes("gateway")), managed: setup) { read.append($0); return ComputerPeer.addOnDigest } == nil)
        #expect(read.isEmpty)
        // Extra arguments, or code instead of the file.
        let extra = process(50, parent: 40, Self.interpreter, [Self.interpreter, "-I", "-c", "import socket"])
        #expect(identify(facts(extra, parent: hermes("gateway"))) == nil)
    }

    /// Nollie's setups as they are on disk: the interpreter's real file, with no link, and the hash its
    /// receipt recorded. A link anywhere refuses the setup, and the program's hash follows no link.
    @Test func setupsAreReadExactlyAsInstalled() throws {
        let temp = try #require(realpath(FileManager.default.temporaryDirectory.path, nil))
        defer { free(temp) }
        let setups = URL(fileURLWithPath: String(cString: temp) + "/setups-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: setups) }
        let fm = FileManager.default
        func make(_ id: UUID, link: Bool = false) throws -> String {
            let root = setups.appendingPathComponent(id.uuidString).path
            let bin = root + "/python/" + NativeSetupPlan.pythonKey + "/bin"
            try fm.createDirectory(atPath: bin, withIntermediateDirectories: true)
            try fm.createDirectory(atPath: root + "/receipts", withIntermediateDirectories: true)
            let program = Data("fixture interpreter".utf8)
            if link {
                try program.write(to: URL(fileURLWithPath: root + "/elsewhere"))
                try fm.createSymbolicLink(atPath: bin + "/python3.14", withDestinationPath: root + "/elsewhere")
            } else {
                try program.write(to: URL(fileURLWithPath: bin + "/python3.14"))
            }
            let sha = try #require(ComputerPeer.programDigest(link ? root + "/elsewhere" : bin + "/python3.14"))
            let receipt: [String: Any] = ["schema": 1, "owner": "com.coreykozarski.nollie", "step": "python",
                                          "version": NativeSetupPlan.pythonVersion,
                                          "files": [["path": NativeSetupPlan.pythonKey + "/bin/python3.14", "bytes": program.count, "sha256": sha]]]
            try JSONSerialization.data(withJSONObject: receipt).write(to: URL(fileURLWithPath: root + "/receipts/python.json"))
            return root
        }
        let good = UUID(), linked = UUID()
        let root = try make(good)
        _ = try make(linked, link: true)
        try fm.createDirectory(at: setups.appendingPathComponent("not-a-setup"), withIntermediateDirectories: true)
        let found = ComputerPeer.managedSetups(setups: setups, app: Self.app, team: Self.team)
        #expect(found.map(\.root) == [root])
        #expect(found.first?.interpreterDigest == ComputerPeer.programDigest(root + "/python/" + NativeSetupPlan.pythonKey + "/bin/python3.14"))
        #expect(ComputerPeer.programDigest(setups.appendingPathComponent(linked.uuidString).path + "/python/" + NativeSetupPlan.pythonKey + "/bin/python3.14") == nil)
        // A changed interpreter no longer matches what was recorded.
        try Data("changed".utf8).write(to: URL(fileURLWithPath: root + "/python/" + NativeSetupPlan.pythonKey + "/bin/python3.14"))
        #expect(ComputerPeer.programDigest(root + "/python/" + NativeSetupPlan.pythonKey + "/bin/python3.14") != found.first?.interpreterDigest)
        // This test's own process is no add-on, whatever setups there are.
        #expect(ComputerPeer.identify(pid: getpid(), hermesHome: "/Users/x/.hermes", managed: found) == nil)
    }

    @Test func theSwitchListsTheAddOnAndItsServerOnly() {
        #expect(ComputerManagedAddOn.enabled(["nollie-workflow", "web"], on: true) == ["nollie-workflow", "web", "nollie-mac"])
        #expect(ComputerManagedAddOn.enabled(["nollie-mac", "web", "x/nollie-mac"], on: false) == ["web"])
        #expect(ComputerManagedAddOn.enabled(["nollie-mac", "web"], on: true) == ["web", "nollie-mac"])
        let id = UUID()
        let python = ComputerManagedAddOn.python(installation: id, setups: URL(fileURLWithPath: "/S"))
        #expect(python == "/S/\(id.uuidString)/python/\(NativeSetupPlan.pythonKey)/bin/python3.14")
        let server = ComputerManagedAddOn.server(python: python, home: "/S/h/profiles/career")
        #expect(server["args"] == .array([.string("-I"), .string("/S/h/profiles/career/plugins/nollie-mac/server.py")]))
        #expect(server["command"] == .string(python))
    }
}
#endif
