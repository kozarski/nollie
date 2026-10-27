#if os(macOS)
import Darwin
import Foundation
import Testing
@testable import Nollie

struct NativeSetupKitTests {
    private func folder(_ action: (URL) throws -> Void) throws {
        guard let resolved = realpath(FileManager.default.temporaryDirectory.path, nil) else { throw NativeSetupPlan.failure("No fixture folder.") }
        let root = URL(fileURLWithPath: String(cString: resolved)).appendingPathComponent("nollie-kit-fixture-" + UUID().uuidString)
        free(resolved)
        try OwnedSetupFiles.createPrivateDirectory(root)
        defer { try? FileManager.default.removeItem(at: root) }
        try action(root)
    }

    private func write(_ text: String, _ url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    private func overlayFixture(_ root: URL, before: String?) throws -> (URL, String) {
        let overlay = root.appendingPathComponent("overlay")
        try write("reviewed = True\n", overlay.appendingPathComponent("files/pkg/module.py"))
        let after = OwnedSetupFiles.hash(Data("reviewed = True\n".utf8))
        let entry: [String: Any] = ["path": "pkg/module.py", "before": before.map { $0 as Any } ?? NSNull(), "after": after, "bytes": 16]
        let data = try JSONSerialization.data(withJSONObject: ["schema": 1, "files": [entry]])
        try data.write(to: overlay.appendingPathComponent("overlay.json"))
        return (overlay, OwnedSetupFiles.hash(data))
    }

    @Test func relativePathsStayInsideTheirFolder() {
        for good in ["plugins/nollie-crew/crew.py", "a", "dashboard/index.js"] { #expect(NativeSetupKit.isSafeRelativePath(good)) }
        for bad in ["", "/etc/passwd", "../escape", "a/../b", "a//b", "a/./b", "a\\b", "a/", "line\nbreak"] {
            #expect(!NativeSetupKit.isSafeRelativePath(bad))
        }
    }

    @Test func overlayReplacesOnlyTheReviewedOriginal() throws {
        try folder { root in
            let original = "original = True\n"
            let (overlay, digest) = try overlayFixture(root, before: OwnedSetupFiles.hash(Data(original.utf8)))
            let staging = root.appendingPathComponent("staging")
            try OwnedSetupFiles.createPrivateDirectory(staging)
            try write(original, staging.appendingPathComponent("pkg/module.py"))
            try NativeSetupKit.Overlay(directory: overlay, expectedDigest: digest).apply(to: staging)
            #expect(try String(contentsOf: staging.appendingPathComponent("pkg/module.py"), encoding: .utf8) == "reviewed = True\n")
            #expect(try FileManager.default.contentsOfDirectory(atPath: staging.appendingPathComponent("pkg").path) == ["module.py"])
        }
    }

    @Test func overlayRefusesAnotherOriginalAndLeavesItAlone() throws {
        try folder { root in
            let (overlay, digest) = try overlayFixture(root, before: OwnedSetupFiles.hash(Data("original = True\n".utf8)))
            let staging = root.appendingPathComponent("staging")
            try OwnedSetupFiles.createPrivateDirectory(staging)
            try write("someone else's change\n", staging.appendingPathComponent("pkg/module.py"))
            #expect(throws: ConfigurationBackup.Failure.self) {
                try NativeSetupKit.Overlay(directory: overlay, expectedDigest: digest).apply(to: staging)
            }
            #expect(try String(contentsOf: staging.appendingPathComponent("pkg/module.py"), encoding: .utf8) == "someone else's change\n")
        }
    }

    @Test func overlayRefusesAFileHermesAlreadyHasAndAChangedList() throws {
        try folder { root in
            let (overlay, digest) = try overlayFixture(root, before: nil)
            let staging = root.appendingPathComponent("staging")
            try OwnedSetupFiles.createPrivateDirectory(staging)
            try write("upstream now ships this\n", staging.appendingPathComponent("pkg/module.py"))
            #expect(throws: ConfigurationBackup.Failure.self) {
                try NativeSetupKit.Overlay(directory: overlay, expectedDigest: digest).apply(to: staging)
            }
            #expect(throws: ConfigurationBackup.Failure.self) {
                try NativeSetupKit.Overlay(directory: overlay, expectedDigest: String(repeating: "0", count: 64))
            }
        }
    }

    private func kitFixture(_ root: URL, prefix: String = "nollie-crew/") throws -> URL {
        let kit = root.appendingPathComponent("add-ons")
        try write("print('installer')\n", kit.appendingPathComponent("managed_addons.py"))
        try write("name: nollie-crew\n", kit.appendingPathComponent("nollie-crew/plugin.yaml"))
        try write("trafilatura==2.3.1\n", kit.appendingPathComponent("nollie-reader/requirements.txt"))
        func file(_ path: String, _ text: String) -> [String: Any] {
            ["path": path, "sha256": OwnedSetupFiles.hash(Data(text.utf8)), "bytes": text.utf8.count]
        }
        let kitList: [String: Any] = [
            "schema": 1,
            "installer": file("managed_addons.py", "print('installer')\n"),
            "readerLock": file("nollie-reader/requirements.txt", "trafilatura==2.3.1\n"),
            "items": [["name": "nollie-crew", "version": "0.1.0", "files": [file(prefix + "plugin.yaml", "name: nollie-crew\n")]],
                      ["name": "nollie-reader", "version": "0.1.0", "files": [file("nollie-reader/requirements.txt", "trafilatura==2.3.1\n")]]]]
        try JSONSerialization.data(withJSONObject: kitList).write(to: kit.appendingPathComponent("kit.json"))
        return kit
    }

    @Test func addOnsListEveryFileTheyLeaveInTheHermesHome() throws {
        try folder { root in
            let kit = try NativeSetupKit.addOns(at: try kitFixture(root))
            #expect(kit.names == ["nollie-crew", "nollie-reader"])
            #expect(kit.installedFiles.map(\.path) == ["plugins/nollie-crew/plugin.yaml", "plugins/nollie-reader/requirements.txt",
                                                       NativeSetupKit.readerMarker])
            #expect(kit.digest.count == 64)
        }
    }

    @Test func addOnsRefuseATamperedInstallerOrAStrayPath() throws {
        try folder { root in
            let kit = try kitFixture(root)
            try write("print('changed')\n", kit.appendingPathComponent("managed_addons.py"))
            #expect(throws: ConfigurationBackup.Failure.self) { try NativeSetupKit.addOns(at: kit) }
        }
        try folder { root in
            let kit = try kitFixture(root, prefix: "nollie-reader/../nollie-crew/")
            #expect(throws: ConfigurationBackup.Failure.self) { try NativeSetupKit.addOns(at: kit) }
        }
    }

    @Test func preparationIncludesAddOnsButTheServiceNeedsOnlyTheRuntime() {
        #expect(NativeSetupPlan.preparationSteps == ["uv", "python", "hermes", "dependencies", "addons"])
        #expect(NativeSetupPlan.runtimeSteps == ["uv", "python", "hermes", "dependencies"])
        #expect(NativeSetupPlan.hermesPreparedVersion.hasPrefix(NativeSetupPlan.hermes.version + "+nollie."))
        #expect(NativeSetupPlan.steps.map(\.id).prefix(5) == ["uv", "python", "hermes", "dependencies", "addons"])
    }

    /// Opt-in, with real pinned downloads already on disk: TEST_RUNNER_NOLLIE_SETUP_SEED names a folder
    /// holding uv.tar.gz and hermes.tar.gz (each is still checked against its pin). Runs the app's own
    /// installer for those two steps in a throwaway setup, overlay included, then checks the receipts.
    @Test func pinnedDownloadsInstallAndVerifyWithTheOverlay() async throws {
        #if NOLLIE_DIRECT
        guard let seed = ProcessInfo.processInfo.environment["NOLLIE_SETUP_SEED"], NativeSetupKit.root != nil else { return }
        guard let resolved = realpath(FileManager.default.temporaryDirectory.path, nil) else { return }
        let base = URL(fileURLWithPath: String(cString: resolved)).appendingPathComponent("nollie-setup-e2e-" + UUID().uuidString)
        free(resolved)
        try OwnedSetupFiles.createPrivateDirectory(base)
        defer { try? FileManager.default.removeItem(at: base) }
        let id = UUID()
        let installation = base.appendingPathComponent(id.uuidString)
        try OwnedSetupFiles.createPrivateDirectory(installation, exclusive: true)
        try OwnedSetupFiles.writeNew(JSONEncoder().encode(["owner": "com.coreykozarski.nollie", "installationID": id.uuidString]),
                                     to: installation.appendingPathComponent("ownership.json"))
        try OwnedSetupFiles.createPrivateDirectory(installation.appendingPathComponent("downloads"))
        for name in ["uv.tar.gz", "hermes.tar.gz"] {
            try FileManager.default.copyItem(at: URL(fileURLWithPath: seed).appendingPathComponent(name),
                                             to: installation.appendingPathComponent("downloads/" + name))
        }
        let installer = NativeDependencyInstaller(installation: installation)
        try await installer.install("uv")
        try await installer.install("hermes")
        #expect(try await installer.verified("uv"))
        #expect(try await installer.verified("hermes"))
        let receipt = try NativeDependencyInstaller.readReceipt(installation: installation, id: "hermes")
        #expect(receipt.version == NativeSetupPlan.hermesPreparedVersion)
        for entry in try NativeSetupKit.hermesOverlay().entries {
            let data = try Data(contentsOf: installation.appendingPathComponent("hermes/" + entry.path))
            #expect(OwnedSetupFiles.hash(data) == entry.after)
        }
        // Any change to a prepared file is caught, so the service would refuse to start.
        let scheduler = installation.appendingPathComponent("hermes/cron/scheduler.py")
        try Data("# changed\n".utf8).write(to: scheduler)
        #expect(try await !installer.verified("hermes"))
        #endif
    }

    /// In the Direct edition the app carries the kit; it must be the one this code expects.
    @Test func carriedKitMatchesThisBuild() throws {
        guard NativeSetupPlan.directAvailable, let root = NativeSetupKit.root,
              FileManager.default.fileExists(atPath: root.path) else { return }
        #expect(try !NativeSetupKit.hermesOverlay().entries.isEmpty)
        let kit = try NativeSetupKit.addOns()
        #expect(Set(kit.names) == ["nollie-workflow", "nollie-crew", "nollie-reader", "nollie-computer", "nollie-mac"])
    }
}
#endif
