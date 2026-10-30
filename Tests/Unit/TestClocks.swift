import Foundation

// Clocks for code that waits: tests hand one in where the code would sleep on real time, so how busy the computer
// is never decides whether a test passes.

/// A clock that moves only when a test moves it. Code under test that sleeps on it (the gateway
/// client's deadlines, heartbeat, silence and retries) wakes exactly when the test says, never because the computer
/// was too busy to keep up.
final class SteppedClock: Clock, @unchecked Sendable {
    struct Instant: InstantProtocol {
        var offset: Swift.Duration
        func advanced(by duration: Swift.Duration) -> Instant { Instant(offset: offset + duration) }
        func duration(to other: Instant) -> Swift.Duration { other.offset - offset }
        static func < (a: Instant, b: Instant) -> Bool { a.offset < b.offset }
    }

    private struct Sleeper {
        var id: Int
        var deadline: Instant
        var wake: CheckedContinuation<Void, any Error>
    }

    private let lock = NSLock()
    private var current = Instant(offset: .zero)
    private var sleepers: [Sleeper] = []
    private var nextID = 0

    var now: Instant { lock.withLock { current } }
    var minimumResolution: Swift.Duration { .zero }

    func sleep(until deadline: Instant, tolerance: Swift.Duration?) async throws {
        let id = lock.withLock { nextID += 1; return nextID }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (wake: CheckedContinuation<Void, any Error>) in
                enum Now { case wait, wake, cancel }
                let now: Now = lock.withLock {
                    if Task.isCancelled { return .cancel }
                    if deadline <= current { return .wake }
                    sleepers.append(Sleeper(id: id, deadline: deadline, wake: wake))
                    return .wait
                }
                switch now {
                case .wait: break
                case .wake: wake.resume()
                case .cancel: wake.resume(throwing: CancellationError())
                }
            }
        } onCancel: {
            let cancelled = lock.withLock { () -> Sleeper? in
                guard let index = sleepers.firstIndex(where: { $0.id == id }) else { return nil }
                return sleepers.remove(at: index)
            }
            cancelled?.wake.resume(throwing: CancellationError())
        }
    }

    /// The deadlines of the timers waiting now, soonest first.
    var waiting: [Swift.Duration] { lock.withLock { sleepers.map { current.duration(to: $0.deadline) }.sorted() } }

    /// Moves time on and wakes every timer that is due.
    func advance(by duration: Swift.Duration) {
        let due = lock.withLock { () -> [Sleeper] in
            current = current.advanced(by: duration)
            let due = sleepers.filter { $0.deadline <= current }.sorted { $0.deadline < $1.deadline }
            sleepers.removeAll { $0.deadline <= current }
            return due
        }
        for sleeper in due { sleeper.wake.resume() }
    }

    /// Waits until a timer is set to fire within `limit`, then moves time to it, so it fires. False when none was.
    @discardableResult
    func fireNext(within limit: Swift.Duration) async -> Bool {
        guard await testClockEventually({ self.waiting.first.map { $0 <= limit } ?? false }) else { return false }
        advance(by: max(.zero, waiting.first ?? .zero))
        return true
    }
}

/// A clock that never waits: every sleep ends at once (after letting other tasks run), so paced code such as the
/// demo gateway's typing and streaming runs straight through, in the same order, in no real time.
struct InstantClock: Clock {
    struct Instant: InstantProtocol {
        var offset: Swift.Duration
        func advanced(by duration: Swift.Duration) -> Instant { Instant(offset: offset + duration) }
        func duration(to other: Instant) -> Swift.Duration { other.offset - offset }
        static func < (a: Instant, b: Instant) -> Bool { a.offset < b.offset }
    }

    var now: Instant { Instant(offset: .zero) }
    var minimumResolution: Swift.Duration { .zero }

    func sleep(until deadline: Instant, tolerance: Swift.Duration?) async throws {
        try Task.checkCancellation()
        await Task.yield()
    }
}

/// Waits until `condition` holds, asking every few milliseconds. False only after a minute: with the code's own
/// waits on a test clock, that ends only a broken test.
func testClockEventually(_ condition: @Sendable () -> Bool) async -> Bool {
    let clock = ContinuousClock()
    let end = clock.now.advanced(by: .seconds(60))
    while clock.now < end {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return condition()
}
