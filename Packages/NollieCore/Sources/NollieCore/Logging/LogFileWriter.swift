import Darwin
import Foundation

/// Appends lines to one log file and rotates it: when the file would pass `maxBytes` it becomes
/// `<name>.1.log`, the older ones move up, and only `keep` files exist in all (the current one
/// included). The folder is 0700 and every file 0600. All work happens on one background queue,
/// so a caller only pays for handing over a small value.
public final class LogFileWriter: @unchecked Sendable {
    public static let defaultMaxBytes = 10 * 1024 * 1024
    public static let defaultKeep = 5

    public let directory: URL
    public let name: String
    private let maxBytes: Int
    private let keep: Int
    private let queue = DispatchQueue(label: "com.coreykozarski.nollie.logfile", qos: .utility)
    // Everything below is touched only on `queue`.
    private var descriptor: Int32 = -1
    private var size = 0
    private let stamp: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = .current
        return formatter
    }()

    public init(directory: URL, name: String, maxBytes: Int = defaultMaxBytes, keep: Int = defaultKeep) {
        self.directory = directory
        self.name = name
        self.maxBytes = max(1, maxBytes)
        self.keep = max(1, keep)
    }

    deinit { if descriptor >= 0 { close(descriptor) } }

    public func fileURL(_ index: Int = 0) -> URL {
        directory.appendingPathComponent(index == 0 ? "\(name).log" : "\(name).\(index).log")
    }

    /// One log line for an entry. Newlines inside a message become spaces so one entry is one line.
    public static func line(_ entry: NollieLog.Entry, stamp: String, includeDetail: Bool) -> String {
        var line = "\(stamp) \(entry.level.word) \(entry.category.rawValue): \(oneLine(entry.message))"
        if let detail = entry.detail, !detail.isEmpty {
            line += " [\(includeDetail ? oneLine(detail) : "<private>")]"
        }
        return line
    }

    static func oneLine(_ text: String) -> String {
        guard text.contains(where: \.isNewline) else { return text }
        return text.split(whereSeparator: \.isNewline).joined(separator: " ")
    }

    public func append(_ entry: NollieLog.Entry, includeDetail: Bool) {
        queue.async { [self] in
            write(Self.line(entry, stamp: stamp.string(from: entry.date), includeDetail: includeDetail))
        }
    }

    public func append(line: String, date: Date = Date()) {
        queue.async { [self] in
            write("\(stamp.string(from: date)) \(Self.oneLine(line))")
        }
    }

    /// Waits until everything handed over so far is on disk. For tests and for quitting.
    public func flush() { queue.sync {} }

    // MARK: On the queue

    private func write(_ text: String) {
        let bytes = Array((text + "\n").utf8)
        if descriptor < 0, !open() { return }
        if size > 0, size + bytes.count > maxBytes {
            rotate()
            if descriptor < 0, !open() { return }
        }
        var offset = 0
        while offset < bytes.count {
            let written = bytes[offset...].withUnsafeBytes { Darwin.write(descriptor, $0.baseAddress, $0.count) }
            if written < 0 {
                if errno == EINTR { continue }
                close(descriptor); descriptor = -1
                return
            }
            offset += written
        }
        size += bytes.count
    }

    private func open() -> Bool {
        let fm = FileManager.default
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        chmod(directory.path, 0o700)
        let fd = Darwin.open(fileURL().path, O_WRONLY | O_APPEND | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { return false }
        fchmod(fd, 0o600)
        var info = stat()
        size = fstat(fd, &info) == 0 ? Int(info.st_size) : 0
        descriptor = fd
        return true
    }

    private func rotate() {
        if descriptor >= 0 { close(descriptor); descriptor = -1 }
        let fm = FileManager.default
        // Keep `keep` files in all: the current one and `keep - 1` older ones.
        try? fm.removeItem(at: fileURL(keep - 1))
        if keep > 1 {
            for index in stride(from: keep - 2, through: 1, by: -1) {
                try? fm.moveItem(at: fileURL(index), to: fileURL(index + 1))
            }
            try? fm.moveItem(at: fileURL(), to: fileURL(1))
        } else {
            try? fm.removeItem(at: fileURL())
        }
        size = 0
    }
}
