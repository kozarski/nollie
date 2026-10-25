import Foundation
import os
import NollieCore

/// Brief record of what push registration and time away just did, shown on the diagnostics page.
/// Notes come from the main thread and background tasks, so the list is guarded by a lock.
enum PushLog {
    private static let capacity = 12
    private static let recent = OSAllocatedUnfairLock(initialState: [String]())
    private static let stream = Logger(subsystem: NollieLog.subsystem, category: "alerts")

    /// Oldest first.
    static var lines: [String] { recent.withLock { $0 } }

    static func note(_ message: String) {
        // Notes can mention chats, so release builds keep them private in the system log.
        #if DEBUG
        stream.notice("\(message, privacy: .public)")
        #else
        stream.notice("\(message, privacy: .private)")
        #endif
        let entry = Date().formatted(.dateTime.hour().minute().second()) + " " + message
        recent.withLock { list in
            list.append(entry)
            if list.count > capacity { list.removeFirst(list.count - capacity) }
        }
    }
}
