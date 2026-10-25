import Foundation
import os

/// Nollie's logging. One subsystem for everything (the app, the demo copy, every extension and the
/// Mac helper), and one category per part, so Console can show all of Nollie with one filter.
///
///     NollieLog.chat.info("Reply arrived")
///     NollieLog.connection.error("Sign-in refused", detail: "\(host) answered \(status)")
///
/// Rules, because a log is something a person may be asked to share:
/// - Never a token, key, password, cookie or sign-in code. Not in the message, not in the detail.
/// - The message is public and fixed: what happened, in a few plain words, with numbers and
///   states at most. It never holds chat text, names, file paths, hosts or addresses.
/// - Anything that helps find the cause but is personal (a host, a path, a bot's name, a piece of
///   chat) goes in `detail`. The system keeps `detail` private, and the Mac log files show it only
///   in a Debug build.
/// - `debug` is for noisy steps, `info` for ordinary steps, `notice` for what is worth keeping when
///   something later goes wrong, `error` for a failure Nollie recovers from or shows, `fault` for
///   something that should never happen. Notice and above are also written to the Mac log files.
public enum NollieLog {
    /// Fixed, not the bundle id, so the demo copy and the extensions log under the same name.
    public static let subsystem = "com.coreykozarski.nollie"

    public enum Category: String, CaseIterable, Sendable {
        case app, connection, chat, runtime, helpers, computer, alerts, pairing, link, board, intents, updates, perf
    }

    public enum Level: Int, Comparable, CaseIterable, Sendable {
        case debug, info, notice, error, fault

        public static func < (a: Level, b: Level) -> Bool { a.rawValue < b.rawValue }

        public var word: String {
            switch self { case .debug: "debug"; case .info: "info"; case .notice: "notice"; case .error: "error"; case .fault: "fault" }
        }

        var osType: OSLogType {
            switch self { case .debug: .debug; case .info: .info; case .notice: .default; case .error: .error; case .fault: .fault }
        }
    }

    /// One line on its way to a log file.
    public struct Entry: Sendable, Equatable {
        public var date: Date
        public var level: Level
        public var category: Category
        public var message: String
        public var detail: String?
    }

    /// A small wrapper over `os.Logger` for one category.
    public struct Channel: Sendable {
        public let category: Category
        private let logger: Logger

        public init(_ category: Category) {
            self.category = category
            logger = Logger(subsystem: NollieLog.subsystem, category: category.rawValue)
        }

        public func debug(_ message: String, detail: String? = nil) { emit(.debug, message, detail) }
        public func info(_ message: String, detail: String? = nil) { emit(.info, message, detail) }
        public func notice(_ message: String, detail: String? = nil) { emit(.notice, message, detail) }
        public func error(_ message: String, detail: String? = nil) { emit(.error, message, detail) }
        public func fault(_ message: String, detail: String? = nil) { emit(.fault, message, detail) }

        public func log(_ level: Level, _ message: String, detail: String? = nil) { emit(level, message, detail) }

        private func emit(_ level: Level, _ message: String, _ detail: String?) {
            if let detail {
                logger.log(level: level.osType, "\(message, privacy: .public) \(detail, privacy: .private)")
            } else {
                logger.log(level: level.osType, "\(message, privacy: .public)")
            }
            if level >= .notice, let sink = NollieLog.sink.withLock({ $0 }) {
                sink(Entry(date: Date(), level: level, category: category, message: message, detail: detail))
            }
        }
    }

    public static let app = Channel(.app)
    public static let connection = Channel(.connection)
    public static let chat = Channel(.chat)
    public static let runtime = Channel(.runtime)
    public static let helpers = Channel(.helpers)
    /// Using the Mac: Nollie Computer and the bot's desktop.
    public static let computer = Channel(.computer)
    public static let alerts = Channel(.alerts)
    public static let pairing = Channel(.pairing)
    public static let link = Channel(.link)
    public static let board = Channel(.board)
    public static let intents = Channel(.intents)
    public static let updates = Channel(.updates)
    public static let perf = Channel(.perf)

    public static func channel(_ category: Category) -> Channel { Channel(category) }

    /// Where notice-and-above entries also go (the Mac log files). Set once at startup.
    public typealias Sink = @Sendable (Entry) -> Void
    static let sink = OSAllocatedUnfairLock<Sink?>(initialState: nil)

    public static func setSink(_ newSink: Sink?) { sink.withLock { $0 = newSink } }
}
