#if os(iOS)
import UIKit

/// Requests a bit more running time for async work started when the app is hidden (a
/// notification button, Siri). The time goes back when the work finishes or when the system
/// reclaims it, whichever happens first.
///
/// The expiry handler is essential: if a background task is still open when its allowance runs
/// out, the system ends the whole app. This work can sit waiting on the gateway for a long time,
/// and that did occur. Calling `end()` repeatedly does no harm.
@MainActor
final class BackgroundTime {
    private var task: UIBackgroundTaskIdentifier = .invalid

    init(_ name: String) {
        task = UIApplication.shared.beginBackgroundTask(withName: name) { [weak self] in
            MainActor.assumeIsolated { self?.end() }
        }
    }

    func end() {
        let current = task
        task = .invalid
        if current != .invalid { UIApplication.shared.endBackgroundTask(current) }
    }
}
#endif
