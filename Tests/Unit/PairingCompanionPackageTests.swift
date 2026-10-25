import CryptoKit
import Foundation
import Testing
@testable import Nollie

struct PairingCompanionPackageTests {
    private func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("nollie-pairing-package-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("dashboard"), withIntermediateDirectories: true)
        var entries: [[String: Any]] = []
        for path in PairingCompanionPackage.paths {
            let data = Data(("Fixture " + path).utf8)
            try data.write(to: root.appendingPathComponent(path))
            entries.append(["path": path, "bytes": data.count, "sha256": SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()])
        }
        let manifest: [String: Any] = ["schema": 1, "plugin": "nollie-pairing", "version": "0.1.0", "files": entries]
        try JSONSerialization.data(withJSONObject: manifest).write(to: root.appendingPathComponent("package.json"))
        return root
    }

    @Test func planContainsOnlyReviewedPluginFilesAndDoesNotInstall() throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let plan = try PairingCompanionPackage.load(directory: root)
        #expect(plan.files.map(\.relativePath) == PairingCompanionPackage.paths)
        #expect(plan.totalBytes > 0)
        #expect(plan.pluginRelativeDirectory == "plugins/nollie-pairing")
        #expect(plan.enableAPIPath == "/api/dashboard/agent-plugins/nollie-pairing/enable")
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("plugins").path))
    }

    @Test func missingOrModifiedSourceFailsClosed() throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        try Data("modified".utf8).write(to: root.appendingPathComponent("provider.py"))
        #expect(throws: PairingCompanionPackage.Failure.self) { try PairingCompanionPackage.load(directory: root) }
        try FileManager.default.removeItem(at: root.appendingPathComponent("provider.py"))
        #expect(throws: PairingCompanionPackage.Failure.self) { try PairingCompanionPackage.load(directory: root) }
    }

    @Test func linkedSourcesCannotEscapeThePackagedFiles() throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.removeItem(at: root.appendingPathComponent("provider.py"))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("provider.py"), withDestinationURL: root.appendingPathComponent("__init__.py"))
        #expect(throws: PairingCompanionPackage.Failure.self) { try PairingCompanionPackage.load(directory: root) }
    }
}
