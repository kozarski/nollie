import Foundation
import os
import Testing
@testable import NollieCore

/// The shared diagnostics file: what it says about this install, and what it must never say.
@Suite struct DiagnosticsReportTests {
    private let facts = DiagnosticsReport.Facts(appName: "Nollie", version: "1.4.2", build: "57", system: "Version 27.2 (Build 27C1)",
                                                device: "iPhone18,1", gatewayConnected: true, generated: Date(timeIntervalSince1970: 1_790_000_000))

    @Test func holdsVersionsSystemDeviceAndConnection() {
        let text = DiagnosticsReport.render(facts, sections: [.init(title: "System log", lines: ["a line"])])
        #expect(text.contains("App: Nollie 1.4.2 (57)"))
        #expect(text.contains("System: Version 27.2 (Build 27C1)"))
        #expect(text.contains("Device: iPhone18,1"))
        #expect(text.contains("Gateway connected: yes"))
        #expect(text.contains("== System log =="))
        var off = facts
        off.gatewayConnected = false
        #expect(DiagnosticsReport.render(off, sections: []).contains("Gateway connected: no"))
    }

    @Test func secretsAndAddressesNeverReachTheFile() {
        let bearer = "abcDEF123456789xyzABC"
        let sections: [DiagnosticsReport.Section] = [
            .init(title: "System log", lines: ["connect Authorization: Bearer \(bearer)", "signed in as corey@example.com"]),
            .init(title: "File: Nollie.log", lines: ["password=hunter2hunter2", "key sk-1234567890abcdefghij"]),
        ]
        let text = DiagnosticsReport.render(facts, sections: sections)
        for secret in [bearer, "corey@example.com", "hunter2hunter2", "sk-1234567890abcdefghij"] {
            #expect(!text.contains(secret), "\(secret)")
        }
    }

    @Test func tailKeepsTheLastLinesOnly() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("tail-" + UUID().uuidString + ".log")
        defer { try? FileManager.default.removeItem(at: file) }
        try (0..<5000).map { "line \($0)" }.joined(separator: "\n").write(to: file, atomically: true, encoding: .utf8)
        let lines = DiagnosticsReport.tail(of: file)
        #expect(lines.count == 2000)
        #expect(lines.first == "line 3000" && lines.last == "line 4999")
        #expect(DiagnosticsReport.tail(of: file.appendingPathExtension("missing")).isEmpty)
    }

    @Test func hermesLinesKeepOnlyProblemsAndTheirTracebacks() {
        let lines = [
            "2026-10-22 10:00:00 INFO gateway: Forwarded update prompt to chat: private words",
            "2026-10-22 10:00:01 WARNING gateway.run: slow reply",
            "2026-10-22 10:00:02 ERROR agent: failed",
            "Traceback (most recent call last):",
            "ValueError: nope",
            "2026-10-22 10:00:03 INFO agent: more private words",
        ]
        #expect(DiagnosticsReport.problems(in: lines) == Array(lines[1...4]))
    }

    @Test func theFileIsWrittenWithTheFacts() async throws {
        let file = try await DiagnosticsReport.makeFile(gatewayConnected: false)
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let text = try String(contentsOf: file, encoding: .utf8)
        #expect(file.pathExtension == "txt")
        #expect(text.hasPrefix("Nollie diagnostics"))
        #expect(text.contains("Gateway connected: no"))
        #expect(text.contains("App: "))
    }

    @Test func aChannelEntryAtNoticeOrAboveReachesTheSink() {
        let seen = LockedBox<[NollieLog.Entry]>([])
        let previous = NollieLog.sink.withLock { $0 }
        NollieLog.setSink { entry in seen.update { $0.append(entry) } }
        defer { NollieLog.setSink(previous) }
        NollieLog.perf.debug("quiet-\(UUID().uuidString)")
        let marker = "marker-\(UUID().uuidString)"
        NollieLog.perf.error(marker, detail: "private words")
        let mine = seen.value.filter { $0.message == marker }
        #expect(mine.count == 1)
        #expect(mine.first?.level == .error && mine.first?.category == .perf)
        #expect(!seen.value.contains { $0.level < .notice })
    }
}

private final class LockedBox<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value
    init(_ value: Value) { stored = value }
    var value: Value { lock.lock(); defer { lock.unlock() }; return stored }
    func update(_ change: (inout Value) -> Void) { lock.lock(); change(&stored); lock.unlock() }
}
