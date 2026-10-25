import Foundation
import NollieCore
import Synchronization

/// The Mac's own Watch screen, watching this Mac's host in-process: the same events a phone gets
/// over the network, with no network in between. Like the door, video never piles up: only so
/// many frames wait for the screen, and once one is dropped the rest wait for a keyframe.
final class LiveLocalFeed: LiveFeed, LiveHostViewer {
    /// Video frames that may wait for the screen to take them.
    static let videoWaiting = 2

    let events: AsyncStream<LiveFeedEvent>
    private let line: Line

    init() {
        let line = Line()
        self.line = line
        // The screen pulls each event, so the feed knows what it hasn't taken yet.
        events = AsyncStream(unfolding: { await line.next() }, onCancel: { line.cancel() })
    }

    /// Ties the feed to the host it was attached to. A feed cancelled meanwhile leaves at once.
    func connect(_ host: LiveHost, id: LiveHost.ViewerID) { line.connect(host, id: id) }

    /// Frames dropped because the screen fell behind.
    var dropped: Int { line.dropped }

    /// Cancelled or ended: nothing more reaches the screen.
    var isClosed: Bool { line.isClosed }

    // MARK: LiveFeed

    func send(_ message: LiveWire.ViewerMessage) { line.send(message) }

    func cancel() { line.cancel() }

    // MARK: LiveHostViewer

    func send(_ message: LiveWire.ServerMessage) { line.add(.message(message)) }

    func send(_ video: LiveWire.Video, encoded: Data) { line.add(video) }

    func end(_ reason: LiveWire.EndReason) { line.close(.ended(reason), saying: .message(.end(reason))) }

    /// For a feed that never started: there's no live picture here.
    func unavailable() { line.close(.unavailable) }

    /// Events in order, waiting for the screen. Text and the end always wait; video is dropped
    /// rather than queued.
    private final class Line: Sendable {
        private let state = Mutex(State())

        private struct State {
            var host: LiveHost?
            var id: LiveHost.ViewerID?
            var closed = false
            var waiting: [LiveFeedEvent] = []
            var videoWaiting = 0
            /// A frame was dropped: the rest can't be shown until a keyframe.
            var skipping = false
            var dropped = 0
            var reader: CheckedContinuation<LiveFeedEvent?, Never>?

            /// Hands the oldest event to a reader that is waiting for one.
            mutating func deliver() {
                guard let reader, let event = take() else { return }
                self.reader = nil
                reader.resume(returning: event)
            }

            mutating func take() -> LiveFeedEvent? {
                guard !waiting.isEmpty else { return nil }
                let event = waiting.removeFirst()
                if case .video = event { videoWaiting -= 1 }
                return event
            }
        }

        var dropped: Int { state.withLock { $0.dropped } }
        var isClosed: Bool { state.withLock { $0.closed } }

        func connect(_ host: LiveHost, id: LiveHost.ViewerID) {
            let leave = state.withLock { state -> Bool in
                guard !state.closed else { return true }
                state.host = host
                state.id = id
                return false
            }
            if leave { host.detach(id) }
        }

        func send(_ message: LiveWire.ViewerMessage) {
            let (host, id) = state.withLock { $0.closed ? (nil, nil) : ($0.host, $0.id) }
            guard let host, let id else { return }
            host.receive(.viewer(message), from: id)
        }

        /// The screen's next event; nil once `.closed` has been taken.
        func next() async -> LiveFeedEvent? {
            await withCheckedContinuation { reader in
                state.withLock { state in
                    if let event = state.take() { return reader.resume(returning: event) }
                    if state.closed { return reader.resume(returning: nil) }
                    state.reader = reader
                }
            }
        }

        func add(_ event: LiveFeedEvent) {
            state.withLock { state in
                guard !state.closed else { return }
                state.waiting.append(event)
                state.deliver()
            }
        }

        /// The newest keyframe replaces every frame still waiting; a frame with no room is dropped,
        /// and the host is asked for a keyframe once.
        func add(_ video: LiveWire.Video) {
            let ask = state.withLock { state -> (LiveHost, LiveHost.ViewerID)? in
                guard !state.closed else { return nil }
                if state.videoWaiting >= LiveLocalFeed.videoWaiting {
                    if video.keyframe {
                        let before = state.waiting.count
                        state.waiting.removeAll { if case .video = $0 { true } else { false } }
                        state.dropped += before - state.waiting.count
                        state.videoWaiting = 0
                    } else {
                        state.dropped += 1
                        defer { state.skipping = true }
                        guard !state.skipping, let host = state.host, let id = state.id else { return nil }
                        return (host, id)
                    }
                } else if state.skipping, !video.keyframe {
                    state.dropped += 1
                    return nil
                }
                state.skipping = false
                state.waiting.append(.video(video, receivedAt: Date()))
                state.videoWaiting += 1
                state.deliver()
                return nil
            }
            if let (host, id) = ask { host.receive(.viewer(.keyframe), from: id) }
        }

        func cancel() {
            guard let (host, id) = close(.cancelled) else { return }
            if let host, let id { host.detach(id) }
        }

        /// Closes once, with exactly one `.closed` after everything still waiting. Returns the host
        /// it was on, or nil if it had closed.
        @discardableResult
        func close(_ how: LiveFeedClose, saying last: LiveFeedEvent? = nil) -> (LiveHost?, LiveHost.ViewerID?)? {
            state.withLock { state -> (LiveHost?, LiveHost.ViewerID?)? in
                guard !state.closed else { return nil }
                state.closed = true
                if let last { state.waiting.append(last) }
                state.waiting.append(.closed(how))
                state.deliver()
                defer { state.host = nil; state.id = nil }
                return (state.host, state.id)
            }
        }
    }
}
