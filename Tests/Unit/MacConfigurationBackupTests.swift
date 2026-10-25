#if os(macOS)
import CryptoKit
import Darwin
import Foundation
import Testing
@testable import Nollie

struct MacConfigurationBackupTests {
    private func fixture(_ action: (URL, URL, URL) throws -> Void) throws {
        guard let resolved = realpath(FileManager.default.temporaryDirectory.path, nil) else { throw ConfigurationBackup.Failure("Fixture directory unavailable.") }
        let temporary = String(cString: resolved)
        free(resolved)
        let root = URL(fileURLWithPath: temporary, isDirectory: true)
            .appendingPathComponent("nollie-backup-test-" + UUID().uuidString, isDirectory: true)
        let source = root.appendingPathComponent("hermes", isDirectory: true)
        let output = root.appendingPathComponent("backups", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try action(root, source, output)
    }

    @Test func copiesOnlyRootConfigurationAndVerifiesPrivateCopies() throws {
        try fixture { _, source, output in
            let config = Data("model: example\ninline_setting: fixture-sensitive-value\n".utf8)
            try config.write(to: source.appendingPathComponent("config.yaml"))
            try Data("A fixture assistant.".utf8).write(to: source.appendingPathComponent("SOUL.md"))
            try Data("Keep work scoped.".utf8).write(to: source.appendingPathComponent("AGENTS.md"))
            for excluded in [".env", "auth.json", "state.db", "kanban.db"] {
                try Data("excluded fixture".utf8).write(to: source.appendingPathComponent(excluded))
            }
            let privateProfile = source.appendingPathComponent("profiles/private", isDirectory: true)
            try FileManager.default.createDirectory(at: privateProfile, withIntermediateDirectories: true)
            try Data("excluded profile fixture".utf8).write(to: privateProfile.appendingPathComponent("SOUL.md"))
            let result = try ConfigurationBackup.create(from: source, in: output)
            #expect(Set(result.files) == Set(ConfigurationBackup.fileNames))
            #expect(try Data(contentsOf: result.directory.appendingPathComponent("config.yaml")) == config)
            #expect(try Data(contentsOf: source.appendingPathComponent("config.yaml")) == config)
            let copiedNames = try FileManager.default.contentsOfDirectory(atPath: result.directory.path)
            #expect(Set(copiedNames) == Set(ConfigurationBackup.fileNames + ["manifest.json"]))
            let manifest = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: result.directory.appendingPathComponent("manifest.json"))) as? [String: Any])
            #expect(manifest["scope"] as? String == "configuration-only")
            #expect(manifest["sensitiveSettingsMayBeIncluded"] as? Bool == true)
            let entries = try #require(manifest["files"] as? [[String: Any]])
            let entry = try #require(entries.first { $0["name"] as? String == "config.yaml" })
            #expect(entry["sha256"] as? String == SHA256.hash(data: config).map { String(format: "%02x", $0) }.joined())
            let directoryMode = try #require(FileManager.default.attributesOfItem(atPath: result.directory.path)[.posixPermissions] as? NSNumber)
            #expect(directoryMode.intValue == 0o700)
            for name in copiedNames {
                let mode = try #require(FileManager.default.attributesOfItem(atPath: result.directory.appendingPathComponent(name).path)[.posixPermissions] as? NSNumber)
                #expect(mode.intValue == 0o600)
            }
        }
    }

    @Test func refusesAnAllowlistedSymlinkBeforeCreatingOutput() throws {
        try fixture { root, source, output in
            let external = root.appendingPathComponent("outside.txt")
            try Data("untouched".utf8).write(to: external)
            try FileManager.default.createSymbolicLink(at: source.appendingPathComponent("config.yaml"), withDestinationURL: external)
            #expect(throws: ConfigurationBackup.Failure.self) { try ConfigurationBackup.create(from: source, in: output) }
            #expect(try FileManager.default.contentsOfDirectory(atPath: output.path).isEmpty)
            #expect(try String(contentsOf: external, encoding: .utf8) == "untouched")
        }
    }

    @Test func refusesSymlinkedSourceAncestryAndProfileRoots() throws {
        try fixture { root, source, output in
            try Data("safe".utf8).write(to: source.appendingPathComponent("config.yaml"))
            let alias = root.appendingPathComponent("linked-root")
            try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: source)
            #expect(throws: ConfigurationBackup.Failure.self) { try ConfigurationBackup.availableFiles(in: alias) }
            let profile = source.appendingPathComponent("profiles/research", isDirectory: true)
            try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
            #expect(throws: ConfigurationBackup.Failure.self) { try ConfigurationBackup.create(from: profile, in: output) }
        }
    }

    @Test func refusesAnOversizedFileAndDoesNotCreateBackup() throws {
        try fixture { _, source, output in
            try Data(repeating: 65, count: ConfigurationBackup.maximumSize + 1).write(to: source.appendingPathComponent("config.yaml"))
            #expect(throws: ConfigurationBackup.Failure.self) { try ConfigurationBackup.create(from: source, in: output) }
            #expect(try FileManager.default.contentsOfDirectory(atPath: output.path).isEmpty)
        }
    }

    @Test func missingFilesAreNotInventedAndEachBackupHasItsOwnFolder() throws {
        try fixture { _, source, output in
            #expect(try ConfigurationBackup.availableFiles(in: source).isEmpty)
            #expect(throws: ConfigurationBackup.Failure.self) { try ConfigurationBackup.create(from: source, in: output) }
            try Data("One file.".utf8).write(to: source.appendingPathComponent("SOUL.md"))
            let first = try ConfigurationBackup.create(from: source, in: output)
            let second = try ConfigurationBackup.create(from: source, in: output)
            #expect(first.files == ["SOUL.md"])
            #expect(first.directory != second.directory)
            #expect(FileManager.default.fileExists(atPath: first.directory.appendingPathComponent("manifest.json").path))
        }
    }

    @Test func refusesToWriteBackupInsideExistingSetup() throws {
        try fixture { _, source, _ in
            try Data("safe".utf8).write(to: source.appendingPathComponent("config.yaml"))
            #expect(throws: ConfigurationBackup.Failure.self) { try ConfigurationBackup.create(from: source, in: source) }
            #expect(try FileManager.default.contentsOfDirectory(atPath: source.path) == ["config.yaml"])
        }
    }
}
#endif
