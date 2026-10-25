#if os(macOS)
import AppKit
import Foundation
import Testing
@testable import Nollie

/// The broker's door, and the real Nollie Computer helper when this build carries it. Every call
/// to the helper here is read-only or harmless if it were ever let through (a lone Shift press);
/// nothing clicks, types or asks macOS for a permission.
@Suite(.serialized) struct ComputerHelperTests {
    @Test func brokerRequestsAreBoundedAndTyped() {
        let start = ComputerBroker.parse(["op": "start", "session_id": "s", "profile": "career",
                                          "apps": Array(repeating: "Notes", count: 20) + [1, 2], "purpose": String(repeating: "x", count: 900)])
        guard case let .start(request) = start else { Issue.record("not a start"); return }
        #expect(request.apps.count == 8)
        #expect(request.purpose.count == 300)
        let act = ComputerBroker.parse(["op": "act", "task": "t", "action": "key", "app": "Notes",
                                        "keys": ["cmd", "shift", "option", "ctrl", "fn", "x", "y"], "x": 3, "scope": "desktop"])
        #expect(act == .act(task: "t", ComputerActRequest(kind: .key, app: "Notes", x: 3, keys: ["cmd", "shift", "option", "ctrl", "fn"])))
        #expect(ComputerBroker.parse(["op": "act", "task": "t", "action": "launch_app"]) == .invalid("Unknown action."))
        #expect(ComputerBroker.parse(["op": "shutdown"]) == .invalid("Unknown request."))
        #expect(ComputerBroker.parse([:]) == .invalid("Unknown request."))
    }

    @MainActor @Test func brokerAnswersOnlyThisUserAndRefusesWhenNobodyIsThere() async throws {
        let folder = URL(fileURLWithPath: "/tmp").appendingPathComponent("nc-" + UUID().uuidString.prefix(6))
        let path = folder.appendingPathComponent("c.sock").path
        let center = ComputerCenter()
        center.helperAvailable = { true }
        center.personPresent = { false }
        let broker = ComputerBroker()
        broker.start(path: path, center: center)
        defer { broker.stop(path: path); try? FileManager.default.removeItem(at: folder) }
        let folderMode = try FileManager.default.attributesOfItem(atPath: folder.path)[.posixPermissions] as? Int
        let socketMode = try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? Int
        #expect(folderMode == 0o700)
        #expect(socketMode == 0o600)
        let reply = try await Task.detached { () throws -> [String?] in
            let reply = try DriverLine(path: path, timeout: 5).send(["op": "start", "session_id": "s", "profile": "career", "apps": ["Finder"], "purpose": "x"])
            return [(reply["ok"] as? Bool).map { "\($0)" }, reply["error"] as? String]
        }.value
        #expect(reply == ["false", ComputerCenter.unattended])
        let unknown = try await Task.detached { () throws -> Bool? in
            try DriverLine(path: path, timeout: 5).send(["op": "act", "task": "nope", "action": "look", "app": "Finder"])["ok"] as? Bool
        }.value
        #expect(unknown == false)
        #expect(center.task == nil)
    }

    private static var finderPID: Int? {
        NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first.map { Int($0.processIdentifier) }
    }

    @Test(.enabled(if: ComputerHelper.isBundled && finderPID != nil))
    func theHelperTakesActionsOnlyFromNollieAndOnlyForApprovedApps() throws {
        let finderPID = try #require(Self.finderPID)
        let ownPID = Int(ProcessInfo.processInfo.processIdentifier)
        let sharedPidFile = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches/cua-driver/cua-driver.pid")
        let sharedBefore = try? Data(contentsOf: sharedPidFile)
        let support = FileManager.default.temporaryDirectory.appendingPathComponent("nollie-computer-test-" + UUID().uuidString.prefix(6))
        defer { try? FileManager.default.removeItem(at: support) }

        let helper = try ComputerHelper(support: support)
        defer { helper.stop() }
        let metadata = try helper.metadata()
        #expect(metadata["driver_version"] as? String == "0.36.0")
        #expect(metadata["embedded"] as? Bool == true)

        // Any other process running as this user reaches only the permission check.
        let outside = try helper.callOutsideSession("list_windows", ["pid": finderPID])
        #expect(Self.refused(outside))
        #expect(ComputerHelper.errorText(outside).contains("outside the capability manifest"), "\(ComputerHelper.errorText(outside))")
        let permissions = try helper.callOutsideSession("check_permissions", ["prompt": false])
        #expect(permissions["ok"] as? Bool == true)
        let source = ((permissions["result"] as? [String: Any])?["structuredContent"] as? [String: Any])?["source"] as? [String: Any]
        #expect(source?["attribution"] as? String == "host")

        // Nollie's own session: Finder only, the approved tools only.
        let finder = ComputerTask.App(info: ComputerAppInfo(bundleID: "com.apple.finder", name: "Finder"), viewOnly: false)
        try helper.openSession("use", manifest: try #require(ComputerManifest.use([finder])))
        _ = try helper.call("use", "list_windows", ["pid": finderPID])
        Self.expectRefusal("outside the capability manifest") { try helper.call("use", "list_windows", ["pid": ownPID]) }
        Self.expectRefusal("outside the capability manifest") { try helper.call("use", "list_apps", [:]) }
        Self.expectRefusal("outside the capability manifest") { try helper.call("use", "get_screen_size", [:]) }

        // A view-only session refuses input outright.
        var viewOnly = finder
        viewOnly.viewOnly = true
        try helper.openSession("view", manifest: try #require(ComputerManifest.view([viewOnly])))
        _ = try helper.call("view", "list_windows", ["pid": finderPID])
        Self.expectRefusal("outside the capability manifest") { try helper.call("view", "press_key", ["pid": finderPID, "key": "shift"]) }

        // Stop: gone within a second, its private folder with it.
        let elapsed = helper.stop()
        #expect(elapsed < 1)
        #expect(!helper.isRunning)
        #expect(!FileManager.default.fileExists(atPath: helper.runDirectory.path))
        // A standalone Cua Driver's pid file on this Mac is never touched.
        #expect((try? Data(contentsOf: sharedPidFile)) == sharedBefore)
    }

    /// The call fails with the driver's own manifest refusal, not some other error.
    private static func expectRefusal(_ words: String, sourceLocation: SourceLocation = #_sourceLocation, _ call: () throws -> Any) {
        do {
            _ = try call()
            Issue.record("Not refused", sourceLocation: sourceLocation)
        } catch let ComputerHelper.Failure.refused(message) {
            #expect(message.contains(words), "\(message)", sourceLocation: sourceLocation)
        } catch {
            Issue.record("Unexpected \(error)", sourceLocation: sourceLocation)
        }
    }

    private static func refused(_ reply: [String: Any]) -> Bool {
        if reply["ok"] as? Bool != true { return true }
        return (reply["result"] as? [String: Any])?["isError"] as? Bool == true
    }
}
#endif
