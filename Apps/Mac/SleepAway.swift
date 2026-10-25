import AppKit
import NollieCore

/// On a Mac, away means asleep.
///
/// The phone toggles the runtime's `isAway` with its scene phase, and returning is what fetches a
/// reply that came in meanwhile and checks the socket. A Mac has no scene phase, so this listens
/// for workspace sleep and wake instead. Windows that are covered, or an app in the background,
/// do not count as away.
@MainActor
final class MacSleepAway {
    typealias Report = @MainActor (Bool) -> Void

    static let shared = MacSleepAway { AppModel.shared.runtime?.isAway = $0 }

    /// Which workspace notification means which state.
    private static let transitions: KeyValuePairs<Notification.Name, Bool> = [
        NSWorkspace.willSleepNotification: true,
        NSWorkspace.didWakeNotification: false,
    ]

    private var heard: [NSObjectProtocol] = []
    private let report: Report

    var isObserving: Bool { heard.isEmpty == false }

    init(away: @escaping Report) {
        report = away
    }

    /// Listens on the workspace's own centre unless a test hands in another. A second start is ignored.
    func start(center: NotificationCenter = NSWorkspace.shared.notificationCenter) {
        guard !isObserving else { return }
        heard = Self.transitions.map { name, away in
            center.addObserver(forName: name, object: nil, queue: nil) { [weak self] _ in
                MainActor.assumeIsolated { self?.report(away) }
            }
        }
    }

    func stop(center: NotificationCenter = NSWorkspace.shared.notificationCenter) {
        for listener in heard { center.removeObserver(listener) }
        heard = []
    }
}
