#if os(iOS)
import Foundation
import NollieCore

/// Looks after running turns while the app is off screen, and explains afterwards if one was cut short.
///
/// `left` asks the system for extra background time while a turn is still running. `returned` waits
/// for the chats to reload and tags any that end in the gateway's interruption marker, so the person
/// hears that the app being away was the reason.
@MainActor
final class AwayWatch {
    /// Shorter absences cannot explain a gateway abandoning a chat.
    nonisolated static var shortestAway: TimeInterval { 10 }
    /// How long after returning the chats are inspected as they reload.
    nonisolated static var settleWindow: TimeInterval { 45 }

    static let shared: AwayWatch = .init()

    /// The turns that were running when the app went away.
    private struct Trip {
        var chats: Set<String>
        let start = Date()

        var wasLongEnough: Bool { Date().timeIntervalSince(start) >= AwayWatch.shortestAway }
    }

    private var trip: Trip?
    private let extraTime = ExtraTime()
    private var review: Task<Void, Never>?

    func left(runtime: GatewayRuntime?) {
        review?.cancel()
        let running = (runtime?.chats ?? []).filter { $0.isRunning && !$0.storedID.isEmpty }
        trip = Trip(chats: Set(running.map(\.storedID)))
        if running.isEmpty { return }
        let stillBusy: @MainActor () -> Bool = { [weak runtime] in
            runtime?.chats.contains(where: \.isRunning) ?? false
        }
        if extraTime.hold(while: stillBusy) {
            PushLog.note("went away with \(running.count) turn(s) still running: keeping the connection open")
        }
    }

    func returned(runtime: GatewayRuntime?) {
        extraTime.release()
        let finished = trip
        trip = nil
        guard let finished, !finished.chats.isEmpty, finished.wasLongEnough, let runtime else { return }
        review = Task { [weak runtime] in
            var waiting = finished.chats
            let cutoff = Date().addingTimeInterval(Self.settleWindow)
            while !waiting.isEmpty, Date() < cutoff, !Task.isCancelled {
                guard let runtime else { return }
                for id in waiting {
                    guard let chat = runtime.chatForStored(id) else { waiting.remove(id); continue }
                    if chat.isRunning || chat.isResuming { continue }
                    waiting.remove(id)
                    Self.tagIfInterrupted(chat)
                }
                if waiting.isEmpty { break }
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
    }

    private static func tagIfInterrupted(_ chat: ChatSession) {
        guard chat.interruptCause == nil, endsInterrupted(chat.items) else { return }
        PushLog.note("“\(chat.title.prefix(24))” was interrupted while the app was away")
        chat.interruptCause = .appWasAway
    }

    /// Whether the newest reply in the thread is the gateway's interruption marker.
    nonisolated static func endsInterrupted(_ items: [TranscriptItem]) -> Bool {
        let newest = items.reversed().lazy.compactMap { item -> (fromBot: Bool, text: String)? in
            switch item.kind {
            case .assistant(let text, _, _): (true, text)
            case .user: (false, "")
            default: nil
            }
        }.first
        guard let newest, newest.fromBot else { return false }
        return InterruptedTurn.parse(newest.text) != nil
    }
}

/// Extra background time. The wait sits on a global queue so the system can be answered even when a
/// long turn keeps the main thread busy; waiting on the main thread got the app ended.
@MainActor
private final class ExtraTime {
    private static let ceiling: TimeInterval = 600

    private var parked: DispatchSemaphore?
    private var poll: Task<Void, Never>?

    /// Starts holding time until `busy` turns false. Returns false when time is already held.
    func hold(while busy: @escaping @MainActor () -> Bool) -> Bool {
        if parked != nil { return false }
        let wake = DispatchSemaphore(value: 0)
        parked = wake
        let limit = DispatchTime.now() + Self.ceiling
        ProcessInfo.processInfo.performExpiringActivity(withReason: "nollie.turn.finishing") { runningOut in
            if runningOut {
                wake.signal()
            } else {
                _ = wake.wait(timeout: limit)
            }
        }
        poll = Task { [weak self] in
            var working = true
            while working && !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                working = busy()
            }
            self?.release()
        }
        return true
    }

    func release() {
        poll?.cancel()
        poll = nil
        parked?.signal()
        parked = nil
    }
}
#endif
