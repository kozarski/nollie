#if os(macOS)
import Darwin
import Foundation
import Testing
@testable import Nollie

struct NativeSetupSafetyTests {
    private func fixture(_ action: (URL, URL, URL) throws -> Void) throws {
        guard let resolved = realpath(FileManager.default.temporaryDirectory.path, nil) else { throw NativeSetupPlan.failure("No fixture folder.") }
        let base = URL(fileURLWithPath: String(cString: resolved), isDirectory: true)
        free(resolved)
        let root = base.appendingPathComponent("nollie-setup-fixture-" + UUID().uuidString, isDirectory: true)
        let source = root.appendingPathComponent("existing", isDirectory: true)
        let output = root.appendingPathComponent("owned", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try action(root, source, output)
    }

    private func asyncFixture(_ action: (URL) async throws -> Void) async throws {
        guard let resolved = realpath(FileManager.default.temporaryDirectory.path, nil) else { throw NativeSetupPlan.failure("No fixture folder.") }
        let root = URL(fileURLWithPath: String(cString: resolved)).appendingPathComponent("nollie-receipt-fixture-" + UUID().uuidString)
        free(resolved)
        try OwnedSetupFiles.createPrivateDirectory(root)
        defer { try? FileManager.default.removeItem(at: root) }
        try await action(root)
    }

    @Test func importKeepsConfigurationInactiveAndNeverAdoptsAutomationOrProfiles() throws {
        try fixture { _, source, output in
            let config = Data("model: existing\ncommand_allowlist: ['all']\nstartup_hook: never-run\ninline_credential: fixture-only\n".utf8)
            try config.write(to: source.appendingPathComponent("config.yaml"))
            try Data("# Existing assistant\nKeep my tone.\n".utf8).write(to: source.appendingPathComponent("SOUL.md"))
            try Data("Follow my workflow.\n".utf8).write(to: source.appendingPathComponent("AGENTS.md"))
            for path in ["profiles/private", "cron", "bot-desktop", "board"] {
                let folder = source.appendingPathComponent(path)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try Data("excluded fixture".utf8).write(to: folder.appendingPathComponent("untouched"))
            }
            let preview = try ScopedHermesImport.preview(source: source)
            #expect(Set(preview.files.map(\.name)) == Set(ConfigurationBackup.fileNames))
            let result = try ScopedHermesImport.create(source: source, preview: preview, installations: output)
            #expect(try Data(contentsOf: source.appendingPathComponent("config.yaml")) == config)
            #expect(try Data(contentsOf: result.backup.appendingPathComponent("config.yaml")) == config)
            let activeConfig = try Data(contentsOf: result.home.appendingPathComponent("config.yaml"))
            let expectedConfig = try StarterAssistantDefaults.prepare(assistantName: "Nollie").configuration
            #expect(activeConfig == expectedConfig)
            let activeValues = try #require(JSONSerialization.jsonObject(with: activeConfig) as? [String: Any])
            #expect((activeValues["kanban"] as? [String: Any])?["auto_decompose"] as? Bool == false)
            #expect(activeValues["command_allowlist"] == nil)
            #expect(activeValues["startup_hook"] == nil)
            #expect(try String(contentsOf: result.home.appendingPathComponent("SOUL.md"), encoding: .utf8).contains("Existing assistant"))
            #expect(Set(try FileManager.default.contentsOfDirectory(atPath: result.home.path)) == Set(ConfigurationBackup.fileNames))
            let receipt = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: result.directory.appendingPathComponent("import-receipt.json"))) as? [String: Any])
            #expect(receipt["schedulesImported"] as? Bool == false)
            #expect(receipt["activeConfigurationImported"] as? Bool == false)
            #expect(receipt["computerPermissionsImported"] as? Bool == false)
            #expect((try FileManager.default.attributesOfItem(atPath: result.directory.path)[.posixPermissions] as? NSNumber)?.intValue == 0o700)
            #expect((try FileManager.default.attributesOfItem(atPath: result.home.appendingPathComponent("SOUL.md").path)[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        }
    }

    @Test func changedSourceRequiresAnotherPreviewBeforeAnyCopy() throws {
        try fixture { _, source, output in
            try Data("first".utf8).write(to: source.appendingPathComponent("SOUL.md"))
            let preview = try ScopedHermesImport.preview(source: source)
            try Data("second".utf8).write(to: source.appendingPathComponent("SOUL.md"))
            #expect(throws: ConfigurationBackup.Failure.self) {
                try ScopedHermesImport.create(source: source, preview: preview, installations: output)
            }
            #expect(!FileManager.default.fileExists(atPath: output.path))
        }
    }

    @Test func profileRootsAndSymlinkedDestinationsAreRejected() throws {
        try fixture { root, source, output in
            try Data("safe".utf8).write(to: source.appendingPathComponent("SOUL.md"))
            let preview = try ScopedHermesImport.preview(source: source)
            let destination = root.appendingPathComponent("outside", isDirectory: true)
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(at: output, withDestinationURL: destination)
            #expect(throws: ConfigurationBackup.Failure.self) {
                try ScopedHermesImport.create(source: source, preview: preview, installations: output)
            }
            #expect(try FileManager.default.contentsOfDirectory(atPath: destination.path).isEmpty)
            #expect(throws: ConfigurationBackup.Failure.self) {
                try ScopedHermesImport.preview(source: source.appendingPathComponent("profiles/private"))
            }
        }
    }

    @Test func nativeCommandsReceiveAnIsolatedEnvironment() {
        let root = URL(fileURLWithPath: "/fixture/Nollie setup with spaces")
        let values = NativeSetupPlan.environment(installation: root)
        #expect(values["HOME"] == root.appendingPathComponent("user").path)
        #expect(values["HERMES_HOME"] == root.appendingPathComponent("home").path)
        #expect(values["UV_PYTHON_BIN_DIR"] == root.appendingPathComponent("bin").path)
        #expect(values["UV_NO_CONFIG"] == "1")
        #expect(values["UV_NO_MODIFY_PATH"] == "1")
        #expect(values["PATH"] == "/usr/bin:/bin:/usr/sbin:/sbin")
        #expect(!values.keys.contains("SSH_AUTH_SOCK"))
        #expect(!values.keys.contains("OPENAI_API_KEY"))
    }

    @Test func archiveValidationRejectsTraversalLinksAndMultipleRoots() throws {
        try NativeSetupPlan.validateArchiveListing(names: "package/\npackage/bin\n", verbose: "drwx------ folder\n-rwx------ binary\n")
        for name in ["/absolute", "package/../escape", "package/file\nother/file", "package\\escape"] {
            #expect(throws: ConfigurationBackup.Failure.self) {
                try NativeSetupPlan.validateArchiveListing(names: name, verbose: "-rw------- file")
            }
        }
        for type in ["l", "h", "c", "b", "p"] {
            #expect(throws: ConfigurationBackup.Failure.self) {
                try NativeSetupPlan.validateArchiveListing(names: "package/link", verbose: type + "rwx------ linked")
            }
        }
    }

    @Test func preparationCannotMasqueradeAsGatewayOrComputerReadiness() async throws {
        let unused = URL(fileURLWithPath: "/unavailable/nollie-fixture-" + UUID().uuidString)
        let steps = await NativeDependencyInstaller(installation: unused).inspect()
        #expect(steps.first { $0.id == "service" }?.state == .notChecked)
        #expect(steps.first { $0.id == "computer" }?.state == .blocked)
        #expect(!steps.contains { $0.state == .ready })
        #expect(NativeSetupPlan.uv.sha256.count == 64)
        #expect(NativeSetupPlan.hermes.sha256.count == 64)
        #expect(!NativeSetupPlan.hermes.url.absoluteString.contains("latest"))
    }

    @Test func sourceInventoryReceiptLargerThanFourKilobytesIsReadable() async throws {
        try await asyncFixture { root in
            try OwnedSetupFiles.createPrivateDirectory(root.appendingPathComponent("receipts"))
            let files = (0..<500).map { NativeDependencyInstaller.FileRecord(path: "source/file-\($0).py", bytes: 40, sha256: String(repeating: "a", count: 64)) }
            let receipt = NativeDependencyInstaller.Receipt(schema: 1, owner: "com.coreykozarski.nollie", step: "hermes", version: NativeSetupPlan.hermesPreparedVersion, sha256: NativeSetupPlan.hermes.sha256, files: files)
            let bytes = try JSONEncoder().encode(receipt)
            #expect(bytes.count > 4096)
            try OwnedSetupFiles.writeNew(bytes, to: root.appendingPathComponent("receipts/hermes.json"))
            let reopened = try NativeDependencyInstaller.readReceipt(installation: root, id: "hermes")
            #expect(reopened.files.count == 500)
        }
    }

    @Test func missingPackageOrInterpreterInvalidatesPreparedLibraries() async throws {
        try await asyncFixture { root in
            let installer = NativeDependencyInstaller(installation: root)
            for directory in ["python", "environment/bin", "environment/lib/site-packages/openai", "receipts"] {
                try OwnedSetupFiles.createPrivateDirectory(root.appendingPathComponent(directory))
            }
            let python = root.appendingPathComponent("python/interpreter")
            try OwnedSetupFiles.writeNew(Data("fixture binary".utf8), to: python)
            let executable = root.appendingPathComponent("environment/bin/python")
            try FileManager.default.createSymbolicLink(at: executable, withDestinationURL: python)
            try OwnedSetupFiles.writeNew(Data("fixture venv".utf8), to: root.appendingPathComponent("environment/pyvenv.cfg"))
            let package = root.appendingPathComponent("environment/lib/site-packages/openai/__init__.py")
            try OwnedSetupFiles.writeNew(Data("fixture package".utf8), to: package)
            for (id, directory, version) in [("python", "python", NativeSetupPlan.pythonVersion), ("dependencies", "environment", NativeSetupPlan.hermesCommit)] {
                let files = try await installer.inventory(root.appendingPathComponent(directory), allowInternalLinks: true)
                let receipt = NativeDependencyInstaller.Receipt(schema: 1, owner: "com.coreykozarski.nollie", step: id, version: version, sha256: nil, files: files)
                try OwnedSetupFiles.writeNew(JSONEncoder().encode(receipt), to: root.appendingPathComponent("receipts/" + id + ".json"))
            }
            #expect(try await installer.verified("dependencies"))
            try FileManager.default.removeItem(at: package)
            #expect(try await !installer.verified("dependencies"))
            try OwnedSetupFiles.writeNew(Data("fixture package".utf8), to: package)
            #expect(try await installer.verified("dependencies"))
            try FileManager.default.removeItem(at: executable)
            #expect(try await !installer.verified("dependencies"))
        }
    }

    @Test func runtimeInventoryRefusesLinksOutsideOwnedSetup() async throws {
        try await asyncFixture { root in
            let runtime = root.appendingPathComponent("runtime")
            try OwnedSetupFiles.createPrivateDirectory(runtime)
            try FileManager.default.createSymbolicLink(atPath: runtime.appendingPathComponent("external").path, withDestinationPath: "/unrelated/private/file")
            let installer = NativeDependencyInstaller(installation: root)
            await #expect(throws: ConfigurationBackup.Failure.self) { try await installer.inventory(runtime, allowInternalLinks: true) }
        }
    }

    #if NOLLIE_DIRECT
    @Test func retryPreservesBrokenComponentsWithoutTouchingHomeOrImportBackup() async throws {
        try await asyncFixture { root in
            for directory in ["environment", "receipts", "home", "import-backup"] {
                try OwnedSetupFiles.createPrivateDirectory(root.appendingPathComponent(directory))
            }
            try OwnedSetupFiles.writeNew(Data("broken library".utf8), to: root.appendingPathComponent("environment/partial"))
            try OwnedSetupFiles.writeNew(Data("bad receipt".utf8), to: root.appendingPathComponent("receipts/dependencies.json"))
            try OwnedSetupFiles.writeNew(Data("original copied instructions".utf8), to: root.appendingPathComponent("home/SOUL.md"))
            try OwnedSetupFiles.writeNew(Data("inactive config".utf8), to: root.appendingPathComponent("import-backup/config.yaml"))
            let installer = NativeDependencyInstaller(installation: root)
            #expect(try await !installer.verified("dependencies"))
            try await installer.quarantineIncompleteStep("dependencies")
            #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("environment").path))
            #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("receipts/dependencies.json").path))
            #expect(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("quarantine").path).count == 2)
            #expect(try String(contentsOf: root.appendingPathComponent("home/SOUL.md"), encoding: .utf8) == "original copied instructions")
            #expect(try String(contentsOf: root.appendingPathComponent("import-backup/config.yaml"), encoding: .utf8) == "inactive config")
            try await installer.quarantineIncompleteStep("dependencies")
            #expect(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("quarantine").path).count == 2)
        }
    }

    @Test func nativeRunnerPassesLiteralArgumentsWithoutAShell() async throws {
        guard let resolved = realpath(FileManager.default.temporaryDirectory.path, nil) else { throw NativeSetupPlan.failure("No fixture folder.") }
        let root = URL(fileURLWithPath: String(cString: resolved)).appendingPathComponent("nollie-native-runner-" + UUID().uuidString)
        free(resolved)
        try OwnedSetupFiles.createPrivateDirectory(root)
        try OwnedSetupFiles.createPrivateDirectory(root.appendingPathComponent("temporary"))
        defer { try? FileManager.default.removeItem(at: root) }
        let literal = "$(touch never-created); `echo no` ' name with spaces"
        let output = try await NativeSetupProcess.run(executable: URL(fileURLWithPath: "/usr/bin/printf"), arguments: ["%s", literal],
            installation: root, environment: NativeSetupPlan.environment(installation: root), timeout: 5)
        #expect(output == literal)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("never-created").path))
    }

    @Test(.timeLimit(.minutes(1))) func nativeRunnerReportsNonzeroExitWithoutBlockingItsRunLoop() async throws {
        try await asyncFixture { root in
            try OwnedSetupFiles.createPrivateDirectory(root.appendingPathComponent("temporary"))
            for _ in 0..<3 {
                do {
                    _ = try await NativeSetupProcess.run(executable: URL(fileURLWithPath: "/usr/bin/false"), arguments: [],
                        installation: root, environment: NativeSetupPlan.environment(installation: root), timeout: 2)
                    Issue.record("A failed process must report its status.")
                } catch let error as NativeSetupProcess.Failure {
                    #expect(error.status == 1)
                }
            }
            #expect(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("temporary").path).isEmpty)
        }
    }

    @Test(.timeLimit(.minutes(1))) func nativeRunnerTimeoutStopsTheChildAndRemovesItsTemporaryLog() async throws {
        try await asyncFixture { root in
            try OwnedSetupFiles.createPrivateDirectory(root.appendingPathComponent("temporary"))
            await #expect(throws: ConfigurationBackup.Failure.self) {
                try await NativeSetupProcess.run(executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["30"],
                    installation: root, environment: NativeSetupPlan.environment(installation: root), timeout: 0.2)
            }
            #expect(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("temporary").path).isEmpty)
        }
    }
    #endif
}
#endif
