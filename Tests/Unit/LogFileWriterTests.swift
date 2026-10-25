import Darwin
import Foundation
import Testing
@testable import NollieCore

/// The Mac log files: size limit, how many are kept, who can read them.
@Suite struct LogFileWriterTests {
    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("logs-" + UUID().uuidString, isDirectory: true)
        return url.appendingPathComponent("Nollie", isDirectory: true)
    }

    private func mode(_ url: URL) -> Int {
        var info = stat()
        return stat(url.path, &info) == 0 ? Int(info.st_mode & 0o777) : -1
    }

    private func names(_ url: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []).sorted()
    }

    @Test func rotatesAtTheSizeLimitAndKeepsFiveFiles() throws {
        let directory = try folder()
        defer { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent()) }
        let writer = LogFileWriter(directory: directory, name: "Nollie", maxBytes: 1_000, keep: 5)
        for number in 0..<200 { writer.append(line: "line \(number) " + String(repeating: "x", count: 60)) }
        writer.flush()
        #expect(names(directory) == ["Nollie.1.log", "Nollie.2.log", "Nollie.3.log", "Nollie.4.log", "Nollie.log"])
        for name in names(directory) {
            let size = try #require(try FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent(name).path)[.size] as? Int)
            #expect(size <= 1_000, "\(name) is \(size) bytes")
        }
        // The newest lines are in the current file; the oldest are gone.
        let current = try String(contentsOf: writer.fileURL(), encoding: .utf8)
        #expect(current.contains("line 199 "))
        let everything = try names(directory).map { try String(contentsOf: directory.appendingPathComponent($0), encoding: .utf8) }.joined()
        #expect(!everything.contains("line 0 "))
    }

    @Test func folderIsPrivateAndFilesAreReadableOnlyByThePerson() throws {
        let directory = try folder()
        defer { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent()) }
        // A folder that already exists with looser permissions is tightened.
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
        let writer = LogFileWriter(directory: directory, name: "Nollie", maxBytes: 500, keep: 3)
        for number in 0..<40 { writer.append(line: "entry \(number) " + String(repeating: "y", count: 50)) }
        writer.flush()
        #expect(mode(directory) == 0o700)
        for name in names(directory) { #expect(mode(directory.appendingPathComponent(name)) == 0o600, "\(name)") }
        #expect(names(directory).count == 3)
    }

    @Test func oneEntryIsOneLineAndPrivateDetailFollowsTheSetting() throws {
        let directory = try folder()
        defer { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent()) }
        let writer = LogFileWriter(directory: directory, name: "Nollie")
        let entry = NollieLog.Entry(date: Date(), level: .error, category: .connection, message: "Sign-in refused\nsecond line",
                                    detail: "gateway.example.net answered 403")
        writer.append(entry, includeDetail: false)
        writer.append(entry, includeDetail: true)
        writer.flush()
        let lines = try String(contentsOf: writer.fileURL(), encoding: .utf8).split(separator: "\n").map(String.init)
        #expect(lines.count == 2)
        #expect(lines[0].contains(" error connection: Sign-in refused second line [<private>]"))
        #expect(!lines[0].contains("gateway.example.net"))
        #expect(lines[1].contains("[gateway.example.net answered 403]"))
    }

    @Test func keepsAddingToTheFileThatIsAlreadyThere() throws {
        let directory = try folder()
        defer { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent()) }
        let first = LogFileWriter(directory: directory, name: "Nollie")
        first.append(line: "one"); first.flush()
        let second = LogFileWriter(directory: directory, name: "Nollie")
        second.append(line: "two"); second.flush()
        let text = try String(contentsOf: first.fileURL(), encoding: .utf8)
        #expect(text.contains("one") && text.contains("two"))
    }

    @Test func hermesLinkPointsAtTheNewestSetupAndFollowsChanges() throws {
        let base = try folder().deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: base) }
        let fm = FileManager.default
        let setups = base.appendingPathComponent("Setups", isDirectory: true)
        let logs = base.appendingPathComponent("Logs", isDirectory: true)
        #expect(HermesLogLink.refresh(setups: setups, in: logs) == .nothingToLink)
        let one = setups.appendingPathComponent(UUID().uuidString).appendingPathComponent("home/logs")
        try fm.createDirectory(at: one, withIntermediateDirectories: true)
        #expect(HermesLogLink.refresh(setups: setups, in: logs) == .linked(one.path))
        #expect(HermesLogLink.refresh(setups: setups, in: logs) == .unchanged(one.path))
        #expect(try fm.destinationOfSymbolicLink(atPath: logs.appendingPathComponent("Hermes").path) == one.path)
        // The setup is replaced: the link follows.
        let two = setups.appendingPathComponent(UUID().uuidString).appendingPathComponent("home/logs")
        try fm.createDirectory(at: two, withIntermediateDirectories: true)
        try fm.setAttributes([.modificationDate: Date().addingTimeInterval(60)], ofItemAtPath: two.path)
        #expect(HermesLogLink.refresh(setups: setups, in: logs) == .linked(two.path))
        // Gone: the stale link goes too.
        try fm.removeItem(at: setups)
        #expect(HermesLogLink.refresh(setups: setups, in: logs) == .removed)
        // A real folder called Hermes is never touched.
        try fm.createDirectory(at: logs.appendingPathComponent("Hermes"), withIntermediateDirectories: true)
        #expect(HermesLogLink.refresh(setups: setups, in: logs) == .blocked)
    }
}
