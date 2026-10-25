import Foundation
import os
import NollieCore

/// Timing helpers for debug builds only; in release every call compiles to nothing.
///
/// - `tick(_:)` counts how often a heavy view re-evaluates and logs the totals every second.
/// - `watchMainThread()` logs whenever the main thread is blocked for 250 ms or longer.
/// - `note(_:)` adds a single line to that same log.
///
/// To follow along in a terminal: `log stream --predicate 'category == "perf" AND subsystem == "Nollie"'`
enum Perf {
    #if DEBUG
    private static let log = Logger(subsystem: NollieLog.subsystem, category: "perf")
    private static let tally = Tally()
    private static let watch = MainThreadWatch()

    /// Counts per name, written out once a second while anything was counted.
    private final class Tally: @unchecked Sendable {
        private let state = OSAllocatedUnfairLock(initialState: (counts: [String: Int](), running: false))

        func count(_ name: String) {
            let shouldStart = state.withLock { s in
                s.counts[name, default: 0] += 1
                defer { s.running = true }
                return !s.running
            }
            guard shouldStart else { return }
            Task { @MainActor in
                while true {
                    try? await Task.sleep(for: .seconds(1))
                    flush()
                }
            }
        }

        private func flush() {
            let taken = state.withLock { s in
                let current = s.counts
                s.counts.removeAll()
                return current
            }
            guard !taken.isEmpty else { return }
            let parts = taken.keys.sorted().map { "\($0)=\(taken[$0] ?? 0)" }
            Perf.log.notice("\(parts.joined(separator: " "), privacy: .public)")
        }
    }

    /// One timer thread does both jobs. Every 20 ms it checks the clock; a long gap means the whole
    /// app was suspended. It also keeps one question in flight to the main thread, and when the
    /// answer finally arrives, the wait (less any suspension) is how long the main thread was busy.
    private final class MainThreadWatch: @unchecked Sendable {
        private struct Question {
            let askedAt: UInt64
            let suspendedThen: UInt64
            var answeredAt: UInt64?
        }

        private struct State {
            var started = false
            var lastBeat: UInt64 = 0
            var suspended: UInt64 = 0
            var question: Question?
        }

        private let state = OSAllocatedUnfairLock(initialState: State())
        private let queue = DispatchQueue(label: "dev.nollie.main-thread-watch", qos: .utility)
        private var timer: DispatchSourceTimer?

        private static func now() -> UInt64 { DispatchTime.now().uptimeNanoseconds }

        func startOnce() {
            let first = state.withLock { s -> Bool in
                if s.started { return false }
                (s.started, s.lastBeat) = (true, Self.now())
                return true
            }
            guard first else { return }
            let source = DispatchSource.makeTimerSource(queue: queue)
            source.schedule(deadline: .now(), repeating: .milliseconds(20))
            source.setEventHandler { [weak self] in self?.beat() }
            source.resume()
            timer = source
        }

        private func beat() {
            let nowTime = Self.now()
            let (busy, asked) = state.withLock { s -> (UInt64?, Bool) in
                let gap = nowTime - s.lastBeat
                s.lastBeat = nowTime
                if gap > 200_000_000 { s.suspended += gap }
                guard let q = s.question else {
                    s.question = Question(askedAt: nowTime, suspendedThen: s.suspended)
                    return (nil, true)
                }
                guard let answered = q.answeredAt else { return (nil, false) }
                s.question = nil
                let waited = answered - q.askedAt
                let asleep = s.suspended - q.suspendedThen
                return (waited > asleep ? waited - asleep : 0, false)
            }
            if let busy, busy >= 250_000_000 {
                Perf.log.notice("main thread busy \(busy / 1_000_000) ms")
            }
            if asked {
                DispatchQueue.main.async { [weak self] in
                    self?.state.withLock { $0.question?.answeredAt = Self.now() }
                }
            }
        }
    }
    #endif

    static func tick(_ name: String) {
        #if DEBUG
        tally.count(name)
        #endif
    }

    static func watchMainThread() {
        #if DEBUG
        watch.startOnce()
        #endif
    }

    static func note(_ line: String) {
        #if DEBUG
        log.notice("\(line, privacy: .public)")
        #endif
    }
}
