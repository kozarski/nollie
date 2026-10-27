#if os(macOS)
import Darwin
import Foundation

/// Where Papertrail's door writes what it saw: one line per connection, in the bot's own Papertrail
/// (`<bot home>/nollie-workflow/papertrail/<day>.jsonl`), beside the lines the workflow add-on keeps.
/// Only when, which bot, what kind of program, and the host and port. Never a path, a query, a
/// header or a byte of what went. A bot on the Private list, or one whose list can't be read, gets
/// nothing written. Connections that stay on this Mac (loopback) are not lines at all.
final class PapertrailDoorBook: @unchecked Sendable {
    /// What a connection's label may say it came from. Anything else is a program.
    static let kinds: Set<String> = ["hermes", "terminal", "code", "mcp", "model", "reader", "program"]
    static let keepDays = 35
    /// Bots that were private before the list existed. They always count, as in the add-on.
    static let carriedOverPrivate: Set<String> = ["private", "moss"]
    static let privateListName = "nollie-private-bots.json"
    /// The label of a program no bot could be found for (`NollieRuntimeContract.Door.unplaced`).
    static let unplaced = "unplaced"

    struct Line: Codable, Equatable, Sendable {
        var v = 1
        var at: Double
        var route: String
        var source = "door"
        var kind: String
        var host: String
        var port: Int
    }

    private let home: URL
    private let clock: @Sendable () -> Date
    private let queue = DispatchQueue(label: "com.coreykozarski.nollie.papertrail-door.book")
    private var privateSeen: (signature: [Int64]?, names: Set<String>?)?
    private var prunedOn: [String: String] = [:]

    /// `home` is the managed setup's Hermes home: the main bot's, with the others under `profiles`.
    init(home: URL, clock: @escaping @Sendable () -> Date = { Date() }) {
        self.home = home
        self.clock = clock
    }

    /// Notes one connection, off the caller's thread. Never throws; a line that can't be written is dropped.
    func record(bot: String, kind: String, host: String, port: UInt16) {
        let at = clock()
        queue.async { [self] in _ = write(bot: bot, kind: kind, host: host, port: port, at: at) }
    }

    /// Waits for lines already handed over. Tests and shutdown.
    func flush() { queue.sync {} }

    // MARK: Rules

    /// `mac`, `network` or `online`, by the name or address alone, like the add-on's route rule.
    static func route(_ host: String) -> String {
        let name = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]."))
        if name.isEmpty { return "online" }
        if name == "localhost" || name.hasSuffix(".localhost") { return "mac" }
        if let v4 = ExitRelayTarget.dottedQuad(Substring(name)) {
            switch (v4[0], v4[1]) {
            case (127, _), (0, _): return "mac"
            case (10, _), (192, 168), (169, 254), (172, 16...31), (100, 64...127): return "network"
            default: return "online"
            }
        }
        if name.contains(":") {
            if name == "::1" || name == "::" { return "mac" }
            if name.hasPrefix("fc") || name.hasPrefix("fd") || ["fe8", "fe9", "fea", "feb"].contains(where: name.hasPrefix) {
                return "network"
            }
            return "online"
        }
        return name.hasSuffix(".local") || !name.contains(".") ? "network" : "online"
    }

    /// A profile name as Hermes allows it, lowercased; nil for anything else.
    static func botName(_ text: Substring) -> String? {
        let name = text.lowercased()
        guard (1...64).contains(name.utf8.count), let first = name.utf8.first,
              (48...57).contains(first) || (97...122).contains(first),
              name.utf8.allSatisfy({ (48...57).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95 }) else { return nil }
        return name
    }

    /// `bot.kind` from a proxy user name. A label that doesn't parse names no bot, and its connection
    /// is passed on without a line: Papertrail can't say whose it was.
    static func label(_ text: String) -> (bot: String, kind: String)? {
        let parts = text.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
        guard let bot = parts.first.flatMap(botName), bot != unplaced else { return nil }
        let kind = parts.count == 2 ? parts[1].lowercased() : "program"
        return (bot, kinds.contains(kind) ? kind : "program")
    }

    /// The add-on's rule: a value names a private bot when it, or any word in it, is on the list.
    static func isPrivate(_ bot: String, list: Set<String>) -> Bool {
        let names = list.union(carriedOverPrivate)
        let words = Set([bot]).union(bot.split(whereSeparator: { !($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") }).map(String.init))
            .union(bot.split(whereSeparator: { !($0.isLetter || $0.isNumber) }).map(String.init))
        return !words.isDisjoint(with: names)
    }

    /// The saved Private list, reread when the file changes. Nil when it can't be read: every bot
    /// then counts as private and nothing is written.
    private func privateNames() -> Set<String>? {
        let path = home.appendingPathComponent(Self.privateListName).path
        var info = stat()
        guard lstat(path, &info) == 0 else {
            return errno == ENOENT ? [] : nil
        }
        let signature = [Int64(info.st_mtimespec.tv_sec), Int64(info.st_mtimespec.tv_nsec), Int64(info.st_size), Int64(info.st_ino)]
        if let seen = privateSeen, seen.signature == signature { return seen.names }
        var names: Set<String>?
        if (info.st_mode & S_IFMT) == S_IFREG, info.st_size <= 16_384,
           let data = FileManager.default.contents(atPath: path),
           let document = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           document["version"] as? Int == 1, let list = document["profiles"] as? [Any], list.count <= 64 {
            let found = list.compactMap { ($0 as? String).flatMap { Self.botName(Substring($0)) == $0 ? $0 : nil } }
            names = found.count == list.count ? Set(found) : nil
        }
        privateSeen = (signature, names)
        return names
    }

    // MARK: Writing (on the book's queue)

    /// The line it wrote, or nil when there was nothing to write or it couldn't be.
    @discardableResult
    func write(bot: String, kind: String, host: String, port: UInt16, at: Date) -> Line? {
        let route = Self.route(host)
        guard route != "mac", let names = privateNames(), !Self.isPrivate(bot, list: names) else { return nil }
        let botHome = bot == "default" ? home : home.appendingPathComponent("profiles", isDirectory: true).appendingPathComponent(bot)
        let line = Line(at: (at.timeIntervalSince1970 * 1000).rounded() / 1000, route: route,
                        kind: Self.kinds.contains(kind) ? kind : "program", host: host, port: Int(port))
        guard let folder = folder(in: botHome), let data = try? JSONEncoder().encode(line) else { return nil }
        defer { close(folder) }
        let lock = openat(folder, "papertrail.lock", O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard lock >= 0 else { return nil }
        defer { close(lock) }
        guard regular(lock), take(lock) else { return nil }
        let day = Self.day(at)
        prune(folder, today: Self.day(clock()), bot: bot)
        let fd = openat(folder, day + ".jsonl", O_RDWR | O_APPEND | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        guard regular(fd) else { return nil }
        _ = fchmod(fd, 0o600)
        var bytes = [UInt8](data) + [10]
        var info = stat()
        if fstat(fd, &info) == 0, info.st_size > 0 {
            var last: UInt8 = 0
            if pread(fd, &last, 1, info.st_size - 1) == 1, last != 10 { bytes.insert(10, at: 0) }
        }
        var offset = 0
        while offset < bytes.count {
            let wrote = bytes[offset...].withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
            guard wrote > 0 else { return nil }
            offset += wrote
        }
        return line
    }

    /// The bot's Papertrail folder, made private when missing. Nil for a bot with no home, or any link
    /// on the way. The bot's home itself is never made here.
    private func folder(in botHome: URL) -> Int32? {
        let base = open(botHome.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard base >= 0 else { return nil }
        defer { close(base) }
        var info = stat()
        guard fstat(base, &info) == 0, info.st_uid == getuid() else { return nil }
        if mkdirat(base, "nollie-workflow", 0o700) != 0, errno != EEXIST { return nil }
        let workflow = openat(base, "nollie-workflow", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard workflow >= 0 else { return nil }
        defer { close(workflow) }
        guard fstat(workflow, &info) == 0, info.st_uid == getuid() else { return nil }
        if mkdirat(workflow, "papertrail", 0o700) != 0, errno != EEXIST { return nil }
        let trail = openat(workflow, "papertrail", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard trail >= 0 else { return nil }
        guard fstat(trail, &info) == 0, info.st_uid == getuid() else { close(trail); return nil }
        _ = fchmod(trail, 0o700)
        return trail
    }

    private func regular(_ fd: Int32) -> Bool {
        var info = stat()
        return fstat(fd, &info) == 0 && (info.st_mode & S_IFMT) == S_IFREG && info.st_uid == getuid()
    }

    /// The add-on's own lock, so a line from here never lands inside one of its.
    private func take(_ fd: Int32) -> Bool {
        let deadline = Date().addingTimeInterval(2)
        while flock(fd, LOCK_EX | LOCK_NB) != 0 {
            guard errno == EWOULDBLOCK, Date() < deadline else { return false }
            usleep(10_000)
        }
        return true
    }

    /// Day files more than 35 days old go, once a day per bot, as the add-on does.
    private func prune(_ folder: Int32, today: String, bot: String) {
        guard prunedOn[bot] != today, let oldest = Self.oldestKept(today: today) else { return }
        prunedOn[bot] = today
        let copy = dup(folder)
        guard copy >= 0, let directory = fdopendir(copy) else { return }
        defer { closedir(directory) }
        var stale: [String] = []
        while let entry = readdir(directory) {
            let name = withUnsafeBytes(of: entry.pointee.d_name) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
            guard name.hasSuffix(".jsonl"), name.count == 16, Self.parseDay(String(name.prefix(10))) != nil,
                  String(name.prefix(10)) < oldest else { continue }
            stale.append(name)
        }
        for name in stale { _ = unlinkat(folder, name, 0) }
    }

    static func day(_ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    static func parseDay(_ text: String) -> Date? {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: text)
    }

    static func oldestKept(today: String) -> String? {
        guard let date = parseDay(today),
              let oldest = Calendar(identifier: .gregorian).date(byAdding: .day, value: -keepDays, to: date) else { return nil }
        return day(oldest)
    }
}
#endif
