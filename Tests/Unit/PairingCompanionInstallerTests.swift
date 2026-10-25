#if os(macOS)
import CryptoKit
import Foundation
import Testing
import NollieCore
@testable import Nollie

@MainActor
struct PairingCompanionInstallerTests {
    private let home = "/fixture/hermes"
    private func plan() -> PairingCompanionPackage.Plan {
        .init(files: PairingCompanionPackage.paths.map { path in
            let data = Data(("New " + path).utf8)
            return .init(relativePath: path, data: data,
                         sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined())
        })
    }
    // The backup deliberately rejects symlink ancestors, including macOS's /var temporary alias.
    private func folder() -> URL { URL.cachesDirectory.appendingPathComponent("NollieTests-Pairing-" + UUID().uuidString) }

    @MainActor private final class Fixture {
        var files: [String: Data] = [:]
        var writes: [String] = []
        var reads: [String] = []
        var events: [String] = []
        var checkCount = 0
        var enabled = false
        var allowed = true
        var reportedHome = "/fixture/hermes"
        var readFailure = false
        var corruptAfterUpload = false
        var changeBeforeWrite = false
        var cancelAfterWrite = false
        var busyAtEnable = false
        var unsafeAfterBackup = false
        var directoryChecks = 0
        var ready = true
        var rejection: String?
        var verifyBackup: (@MainActor () throws -> Void)?

        var operations: PairingCompanionInstaller.Operations {
            .init(check: {
                self.checkCount += 1
                if self.busyAtEnable && self.checkCount == 2 { throw PairingCompanionInstaller.Failure.busy }
                self.events.append("check")
                return self.reportedHome
            }, validateDirectories: { _ in
                self.directoryChecks += 1
                if self.unsafeAfterBackup && self.directoryChecks > 1 { throw PairingCompanionInstaller.Failure.wrongHome }
                self.events.append("directories")
            }, read: { path in
                self.reads.append(path)
                if self.readFailure { throw URLError(.cannotOpenFile) }
                if self.corruptAfterUpload && self.writes.contains(path) { return Data("incorrect".utf8) }
                if self.changeBeforeWrite && self.reads.filter({ $0 == path }).count == 2 { return Data("another writer".utf8) }
                return self.files[path]
            }, upload: { path, file in
                try self.verifyBackup?()
                self.writes.append(path)
                self.events.append("upload")
                self.files[path] = file.data
                if self.cancelAfterWrite { self.allowed = false }
            }, enable: { _ in
                if let rejection = self.rejection { throw NSError(domain: rejection, code: 1) }
                self.enabled = true; self.events.append("enable")
            }, capability: {
                self.events.append("capability")
                return .init(supported: self.ready, reason: self.ready ? nil : "companion_required")
            }, stillAllowed: { self.allowed })
        }
    }

    @Test func verifiedBackupPrecedesEveryWriteAndManifestPublishesLast() async throws {
        let parent = folder(); defer { try? FileManager.default.removeItem(at: parent) }
        let fixture = Fixture()
        let oldPath = home + "/plugins/nollie-pairing/provider.py"
        let original = Data("Prior companion bytes".utf8)
        fixture.files[oldPath] = original
        fixture.verifyBackup = {
            let folders = try FileManager.default.contentsOfDirectory(at: parent, includingPropertiesForKeys: nil)
            let backup = try #require(folders.first)
            let receipt = try JSONDecoder().decode(CompanionFileBackup.Receipt.self, from: Data(contentsOf: backup.appendingPathComponent("manifest.json")))
            let entry = try #require(receipt.entries.first { $0.path == oldPath })
            #expect(try Data(contentsOf: backup.appendingPathComponent(entry.copy)) == original)
            #expect(receipt.absent.count == 5)
        }
        let installer = PairingCompanionInstaller()
        await installer.install(plan: plan(), backupParent: parent, operations: fixture.operations)
        #expect(installer.phase == .ready)
        #expect(fixture.writes.count == 6)
        #expect(fixture.writes.last?.hasSuffix("/plugin.yaml") == true)
        #expect(fixture.events.suffix(3) == ["check", "enable", "capability"])
        #expect(!fixture.reads.contains { $0.hasSuffix("config.yaml") || $0.contains("private") })
    }

    @Test func backupReadFailureNeverCopiesOrEnables() async {
        let parent = folder(); defer { try? FileManager.default.removeItem(at: parent) }
        let fixture = Fixture(); fixture.readFailure = true
        let installer = PairingCompanionInstaller()
        await installer.install(plan: plan(), backupParent: parent, operations: fixture.operations)
        #expect(installer.phase == .failed)
        #expect(fixture.writes.isEmpty && !fixture.enabled)
        #expect(installer.backupDirectory == nil)
    }

    @Test func concurrentChangeStopsBeforeFirstOverwrite() async {
        let parent = folder(); defer { try? FileManager.default.removeItem(at: parent) }
        let fixture = Fixture(); fixture.changeBeforeWrite = true
        let installer = PairingCompanionInstaller()
        await installer.install(plan: plan(), backupParent: parent, operations: fixture.operations)
        #expect(installer.phase == .failed)
        #expect(fixture.writes.isEmpty && !fixture.enabled)
        #expect(installer.backupDirectory != nil)
    }

    @Test func uploadedBytesMustMatchBeforeActivation() async {
        let parent = folder(); defer { try? FileManager.default.removeItem(at: parent) }
        let fixture = Fixture(); fixture.corruptAfterUpload = true
        let installer = PairingCompanionInstaller()
        await installer.install(plan: plan(), backupParent: parent, operations: fixture.operations)
        #expect(installer.phase == .failed)
        #expect(fixture.writes.count == 1 && !fixture.enabled)
        #expect(installer.backupDirectory != nil)
    }

    @Test func lockOrConnectionChangeStopsRemainingMutations() async {
        let parent = folder(); defer { try? FileManager.default.removeItem(at: parent) }
        let fixture = Fixture(); fixture.cancelAfterWrite = true
        let installer = PairingCompanionInstaller()
        await installer.install(plan: plan(), backupParent: parent, operations: fixture.operations)
        #expect(installer.phase == .failed)
        #expect(fixture.writes.count == 1 && !fixture.enabled)
    }

    @Test func tasksStartingDuringCopyPreventActivation() async {
        let parent = folder(); defer { try? FileManager.default.removeItem(at: parent) }
        let fixture = Fixture(); fixture.busyAtEnable = true
        let installer = PairingCompanionInstaller()
        await installer.install(plan: plan(), backupParent: parent, operations: fixture.operations)
        #expect(installer.phase == .failed)
        #expect(fixture.writes.count == 6 && !fixture.enabled)
        #expect(installer.message == PairingCompanionInstaller.Failure.busy.localizedDescription)
    }

    @Test func enabledButUnavailableNeverReportsReadyOrRestarts() async {
        let parent = folder(); defer { try? FileManager.default.removeItem(at: parent) }
        let fixture = Fixture(); fixture.ready = false
        let installer = PairingCompanionInstaller()
        await installer.install(plan: plan(), backupParent: parent, operations: fixture.operations)
        #expect(fixture.enabled)
        #expect(installer.phase == .needsActivation)
        #expect(installer.message?.contains("dashboard restart may be needed") == true)
        #expect(fixture.events.last == "capability")
    }

    @Test func remoteErrorsNeverBecomeUserVisibleDetails() async {
        let parent = folder(); defer { try? FileManager.default.removeItem(at: parent) }
        let fixture = Fixture(); fixture.rejection = "untrusted server details"
        let installer = PairingCompanionInstaller()
        await installer.install(plan: plan(), backupParent: parent, operations: fixture.operations)
        #expect(installer.phase == .failed)
        #expect(installer.message == PairingCompanionInstaller.Failure.enable.localizedDescription)
        #expect(installer.message?.contains("untrusted") == false)
    }

    @Test func activityAndPathChecksFailClosed() throws {
        let wire = Data(#"{"gateway_busy":false,"active_agents":0,"active_sessions":7}"#.utf8)
        let status = try JSONCoding.decoder.decode(PairingCompanionInstaller.ActivityStatus.self, from: wire)
        #expect(status.gatewayBusy == false && status.activeAgents == 0)
        try PairingCompanionInstaller.requireIdle(status)
        try PairingCompanionInstaller.requireIdle(.init(gatewayBusy: false, activeAgents: 0))
        #expect(throws: PairingCompanionInstaller.Failure.self) { try PairingCompanionInstaller.requireIdle(.init(gatewayBusy: true, activeAgents: 0)) }
        #expect(throws: PairingCompanionInstaller.Failure.self) { try PairingCompanionInstaller.requireIdle(.init(gatewayBusy: false, activeAgents: 1)) }
        #expect(throws: PairingCompanionInstaller.Failure.self) { try PairingCompanionInstaller.requireIdle(.init(gatewayBusy: nil, activeAgents: 0)) }
        #expect(throws: PairingCompanionInstaller.Failure.self) { try PairingCompanionInstaller.requireIdle(.init(gatewayBusy: false, activeAgents: -1)) }
        for path in ["~/.hermes", "/", "/fixture/../hermes", "/fixture/profiles/private", "/fixture/hermes/"] {
            #expect(throws: PairingCompanionInstaller.Failure.self) { try PairingCompanionInstaller.validHome(path) }
        }
    }

    @Test func connectionChangeWhileEnableWaitsPreventsSecondMutation() async throws {
        var allowed = true
        var continuation: CheckedContinuation<Bool, Never>?
        var activations = 0
        let task = Task {
            try await PairingCompanionInstaller.enableThenActivate(validate: {
                guard allowed else { throw PairingCompanionInstaller.Failure.cancelled }
            }, enable: {
                await withCheckedContinuation { continuation = $0 }
            }, activate: { activations += 1 })
        }
        while continuation == nil { await Task.yield() }
        allowed = false
        #expect(!task.isCancelled)
        continuation?.resume(returning: true)
        await #expect(throws: PairingCompanionInstaller.Failure.self) { try await task.value }
        #expect(activations == 0)
    }

    @Test func aNewDirectoryLinkAfterBackupPreventsAllWrites() async {
        let parent = folder(); defer { try? FileManager.default.removeItem(at: parent) }
        let fixture = Fixture(); fixture.unsafeAfterBackup = true
        let installer = PairingCompanionInstaller()
        await installer.install(plan: plan(), backupParent: parent, operations: fixture.operations)
        #expect(installer.phase == .failed)
        #expect(installer.backupDirectory != nil)
        #expect(fixture.writes.isEmpty && !fixture.enabled)
    }

    @Test func danglingDirectoryLinksAreRejectedFromTheirParents() async throws {
        let components = ["plugins", "nollie-pairing", "dashboard"]
        for brokenIndex in components.indices {
            var requested: [String] = []
            await #expect(throws: PairingCompanionInstaller.Failure.self) {
                try await PairingCompanionInstaller.validateDirectoryTree(home: home) { parent in
                    requested.append(parent)
                    let index = requested.count - 1
                    let name = components[index]
                    let entry = PairingCompanionInstaller.DirectoryListing.Entry(name: name,
                        path: parent + "/" + name, isDirectory: index != brokenIndex, brokenLink: index == brokenIndex)
                    return .init(path: parent, entries: [entry])
                }
            }
            #expect(requested.count == brokenIndex + 1)
        }
        let wire = Data(#"{"path":"/fixture/hermes","entries":[{"name":"plugins","path":"/fixture/hermes/plugins","is_directory":false,"broken_link":true}]}"#.utf8)
        let listing = try JSONCoding.decoder.decode(PairingCompanionInstaller.DirectoryListing.self, from: wire)
        #expect(listing.entries.first?.brokenLink == true)
    }

    @Test func onlyVerifiedAbsentDirectoriesCanBeCreated() async throws {
        var reads = 0
        try await PairingCompanionInstaller.validateDirectoryTree(home: home) { path in
            reads += 1
            return .init(path: path, entries: [])
        }
        #expect(reads == 1)
        await #expect(throws: PairingCompanionInstaller.Failure.self) {
            try await PairingCompanionInstaller.validateDirectoryTree(home: home) { path in
                .init(path: path, entries: [.init(name: "plugins", path: "/elsewhere/plugins", isDirectory: true)])
            }
        }
        await #expect(throws: HermesAPIError.self) {
            try await PairingCompanionInstaller.validateDirectoryTree(home: home) { _ in
                throw HermesAPIError.http(status: 404, detail: "Fixture")
            }
        }
    }
}
#endif
