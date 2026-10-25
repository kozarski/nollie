import Foundation
import Network

/// Tells the socket whether the device currently has a route out, and when that changes.
///
/// Connecting across a private network (a tailnet) often loses a race with the route coming up:
/// the first attempt fails and the retry delay kept growing even though the route appeared. With
/// no path, the connect loop now waits here for the next change and retries the instant a path
/// shows up (#305).
public final class NetworkWatch: @unchecked Sendable {
    public static let shared = NetworkWatch()

    private struct Reading { var satisfied = true; var changes = 0 }

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "dev.nollie.network-watch")
    private let reading = Guarded<Reading>(Reading())
    private let startOnce = Guarded<Bool>(false)

    public init() {}

    /// True while a path is up, and also before the monitor has said anything.
    public var isUsable: Bool {
        begin()
        return reading.withLock { $0.satisfied }
    }

    /// Goes up by one with every path change; compare two readings to see if one happened.
    public var mark: Int {
        begin()
        return reading.withLock { $0.changes }
    }

    /// Returns once the path differs from `mark`, after `seconds`, or when cancelled.
    public func waitForChange(since mark: Int, upTo seconds: Double) async {
        let giveUp = ContinuousClock.now + .seconds(seconds)
        while ContinuousClock.now < giveUp, !Task.isCancelled, self.mark == mark {
            try? await Task.sleep(for: .milliseconds(250))
        }
    }

    private func begin() {
        let first = startOnce.withLock { started -> Bool in
            defer { started = true }
            return !started
        }
        guard first else { return }
        monitor.pathUpdateHandler = { [reading] path in
            reading.withLock {
                $0.satisfied = path.status == .satisfied
                $0.changes += 1
            }
        }
        monitor.start(queue: queue)
    }
}

/// A value behind a lock.
final class Guarded<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) { self.value = value }

    func withLock<R>(_ body: (inout Value) -> R) -> R {
        lock.lock()
        defer { lock.unlock() }
        return body(&value)
    }
}
