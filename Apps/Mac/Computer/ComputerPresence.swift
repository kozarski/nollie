#if os(macOS)
import AppKit
import CoreGraphics

/// Whether a person is at this Mac, so a bot never uses it unattended: not locked, not asleep,
/// and touched in the last few minutes. A running task ends the moment the Mac locks, the
/// screen sleeps or the Mac goes to sleep.
@MainActor
final class ComputerPresence {
    /// How long the keyboard and mouse may sit still before nobody counts as being there.
    nonisolated static let awayAfter: TimeInterval = 5 * 60

    private let gone: @MainActor () -> Void
    private var observers: [(NotificationCenter, any NSObjectProtocol)] = []

    init(gone: @escaping @MainActor () -> Void) { self.gone = gone }

    func start(workspace: NotificationCenter = NSWorkspace.shared.notificationCenter,
               distributed: NotificationCenter = DistributedNotificationCenter.default()) {
        guard observers.isEmpty else { return }
        let names: [(NotificationCenter, Notification.Name)] = [
            (workspace, NSWorkspace.willSleepNotification),
            (workspace, NSWorkspace.screensDidSleepNotification),
            (workspace, NSWorkspace.sessionDidResignActiveNotification),
            (distributed, Notification.Name("com.apple.screenIsLocked")),
        ]
        observers = names.map { center, name in
            (center, center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.gone() }
            })
        }
    }

    func stop() {
        for (center, observer) in observers { center.removeObserver(observer) }
        observers = []
    }

    /// Seconds since the person last pressed a key, moved the mouse or touched the trackpad.
    nonisolated static func secondsSinceInput() -> TimeInterval {
        guard let any = CGEventType(rawValue: UInt32.max) else { return .infinity }
        return CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: any)
    }

    nonisolated static func isLocked() -> Bool {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { return true }
        return session["CGSSessionScreenIsLocked"] as? Bool == true || session["kCGSSessionOnConsoleKey"] as? Bool == false
    }

    nonisolated static func personIsAtTheMac() -> Bool {
        !isLocked() && secondsSinceInput() < awayAfter
    }
}

/// Finding the app a bot names: running apps first, then installed ones.
enum ComputerApps {
    static func find(_ name: String) -> ComputerAppInfo? {
        let wanted = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !wanted.isEmpty, wanted.count < 100 else { return nil }
        let running = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }
        if let app = running.first(where: { $0.bundleIdentifier?.caseInsensitiveCompare(wanted) == .orderedSame })
            ?? running.first(where: { $0.localizedName?.caseInsensitiveCompare(wanted) == .orderedSame }),
           let url = app.bundleURL {
            return ComputerAppInfo(bundleURL: url)
        }
        if wanted.contains("."), let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: wanted) {
            return ComputerAppInfo(bundleURL: url)
        }
        let fileName = wanted.hasSuffix(".app") ? wanted : wanted + ".app"
        guard !fileName.contains("/") else { return nil }
        let folders = ["/Applications", "/System/Applications", "/System/Applications/Utilities",
                       "/Applications/Utilities", NSHomeDirectory() + "/Applications"]
        for folder in folders {
            let url = URL(fileURLWithPath: folder).appendingPathComponent(fileName)
            if FileManager.default.fileExists(atPath: url.path) { return ComputerAppInfo(bundleURL: url) }
        }
        return nil
    }
}
#endif
