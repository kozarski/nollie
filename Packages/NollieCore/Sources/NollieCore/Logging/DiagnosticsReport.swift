import Foundation
import OSLog

/// "Copy diagnostics": one text file with what Nollie did in the last day, to share when something
/// went wrong. It holds the versions, whether a gateway is connected (never which), Nollie's own
/// system log entries, and on the Mac the tail of its log files. Everything passes through
/// `LogRedactor`, and the system keeps private details out of the entries on its own.
public enum DiagnosticsReport {
    public struct Facts: Sendable, Equatable {
        public var appName: String
        public var version: String
        public var build: String
        public var system: String
        public var device: String
        public var gatewayConnected: Bool
        public var generated: Date

        public init(appName: String, version: String, build: String, system: String, device: String,
                    gatewayConnected: Bool, generated: Date) {
            self.appName = appName; self.version = version; self.build = build; self.system = system
            self.device = device; self.gatewayConnected = gatewayConnected; self.generated = generated
        }

        public static func current(gatewayConnected: Bool, now: Date = Date()) -> Facts {
            let info = Bundle.main.infoDictionary
            return Facts(appName: info?["CFBundleName"] as? String ?? "Nollie",
                         version: info?["CFBundleShortVersionString"] as? String ?? "unknown",
                         build: info?["CFBundleVersion"] as? String ?? "unknown",
                         system: ProcessInfo.processInfo.operatingSystemVersionString,
                         device: deviceModel(), gatewayConnected: gatewayConnected, generated: now)
        }
    }

    /// A named block of lines, such as one log file.
    public struct Section: Sendable, Equatable {
        public var title: String
        public var lines: [String]
        public init(title: String, lines: [String]) { self.title = title; self.lines = lines }
    }

    public static let window: TimeInterval = 24 * 3600
    public static let linesPerFile = 2000

    /// The finished, redacted text.
    public static func render(_ facts: Facts, sections: [Section]) -> String {
        let stamp = ISO8601DateFormatter()
        stamp.timeZone = .current
        var text = """
        Nollie diagnostics
        Made: \(stamp.string(from: facts.generated))
        App: \(facts.appName) \(facts.version) (\(facts.build))
        System: \(facts.system)
        Device: \(facts.device)
        Gateway connected: \(facts.gatewayConnected ? "yes" : "no")
        Covers: the last 24 hours. Private details and secrets are left out.
        """
        for section in sections {
            text += "\n\n== \(section.title) ==\n"
            text += section.lines.isEmpty ? "(nothing)" : section.lines.joined(separator: "\n")
        }
        return LogRedactor.redact(text) + "\n"
    }

    /// Builds the report and writes it to a new file in a temporary folder.
    public static func makeFile(gatewayConnected: Bool, now: Date = Date()) async throws -> URL {
        let facts = Facts.current(gatewayConnected: gatewayConnected, now: now)
        var sections = [Section(title: "System log, since this launch", lines: await systemEntries(since: now.addingTimeInterval(-window)))]
        #if os(macOS)
        sections += macFileSections(now: now)
        #endif
        let text = render(facts, sections: sections)
        let day = ISO8601DateFormatter()
        day.formatOptions = [.withFullDate]
        day.timeZone = .current
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("NollieDiagnostics-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let file = folder.appendingPathComponent("Nollie Diagnostics \(day.string(from: now)).txt")
        try Data(text.utf8).write(to: file, options: [.atomic])
        return file
    }

    // MARK: Pieces

    /// Entries for Nollie's subsystem from this process. (The system only lets an app read its own.)
    public static func systemEntries(since: Date, limit: Int = 5000) async -> [String] {
        await Task.detached(priority: .utility) { () -> [String] in
            guard let store = try? OSLogStore(scope: .currentProcessIdentifier) else { return ["The system log could not be read."] }
            let predicate = NSPredicate(format: "subsystem == %@", NollieLog.subsystem)
            guard let entries = try? store.getEntries(at: store.position(date: since), matching: predicate) else {
                return ["The system log could not be read."]
            }
            let stamp = ISO8601DateFormatter()
            stamp.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            stamp.timeZone = .current
            var lines: [String] = []
            for case let entry as OSLogEntryLog in entries {
                lines.append("\(stamp.string(from: entry.date)) \(levelWord(entry.level)) \(entry.category): \(entry.composedMessage)")
            }
            return Array(lines.suffix(limit))
        }.value
    }

    static func levelWord(_ level: OSLogEntryLog.Level) -> String {
        switch level {
        case .debug: "debug"
        case .info: "info"
        case .notice: "notice"
        case .error: "error"
        case .fault: "fault"
        default: "log"
        }
    }

    /// The last `count` lines of a text, reading at most the last megabyte of a file.
    public static func tail(of file: URL, lines count: Int = linesPerFile, maximumBytes: Int = 1_048_576) -> [String] {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return [] }
        defer { try? handle.close() }
        guard let end = try? handle.seekToEnd() else { return [] }
        let start = end > UInt64(maximumBytes) ? end - UInt64(maximumBytes) : 0
        try? handle.seek(toOffset: start)
        guard let data = try? handle.readToEnd() else { return [] }
        var lines = String(decoding: data, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        if start > 0, !lines.isEmpty { lines.removeFirst() }  // a cut-off first line
        return Array(lines.suffix(count))
    }

    /// Hermes writes chat previews at its ordinary level, so only its warnings and errors (and the
    /// lines that continue them, such as a traceback) are shared.
    public static func problems(in lines: [String]) -> [String] {
        let levels = [" WARNING ", " ERROR ", " CRITICAL ", " WARNING[", " ERROR[", " CRITICAL["]
        var keeping = false
        var result: [String] = []
        for line in lines {
            let startsNew = line.first?.isNumber == true
            if startsNew { keeping = levels.contains { line.contains($0) } }
            if keeping { result.append(line) }
        }
        return result
    }

    #if os(macOS)
    static func macFileSections(now: Date, directory: URL = NollieLogFiles.directory, fileManager fm: FileManager = .default) -> [Section] {
        let cutoff = now.addingTimeInterval(-window)
        func recent(_ url: URL) -> Bool {
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            return modified.map { $0 >= cutoff } ?? true
        }
        var sections: [Section] = []
        let own = ((try? fm.contentsOfDirectory(atPath: directory.path)) ?? []).filter { $0.hasSuffix(".log") }.sorted()
        for name in own {
            let url = directory.appendingPathComponent(name)
            guard isRegularFile(url), recent(url) else { continue }
            sections.append(Section(title: "File: \(name)", lines: tail(of: url)))
        }
        let hermes = directory.appendingPathComponent(HermesLogLink.linkName)
        let theirs = ((try? fm.contentsOfDirectory(atPath: hermes.path)) ?? []).filter { $0.contains(".log") }.sorted()
        for name in theirs {
            let url = hermes.appendingPathComponent(name)
            guard isRegularFile(url), recent(url) else { continue }
            sections.append(Section(title: "Hermes file: \(name) (warnings and errors only)", lines: problems(in: tail(of: url))))
        }
        return sections
    }

    private static func isRegularFile(_ url: URL) -> Bool {
        var info = stat()
        return stat(url.path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFREG
    }
    #endif

    static func deviceModel() -> String {
        #if os(macOS)
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        if size > 0 {
            var buffer = [CChar](repeating: 0, count: size)
            if sysctlbyname("hw.model", &buffer, &size, nil, 0) == 0 { return String(cString: buffer) }
        }
        return "Mac"
        #else
        var info = utsname()
        uname(&info)
        return withUnsafeBytes(of: &info.machine) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
        #endif
    }
}
