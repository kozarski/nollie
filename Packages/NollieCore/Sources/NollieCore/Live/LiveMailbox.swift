import Synchronization

/// Hands pictures to an encoder one at a time, newest first. While one frame is in the encoder,
/// a single slot holds the next; a newer picture replaces an older waiting one (that one counts
/// as dropped), so a slow encoder or link never builds a queue. A keyframe request rides with
/// the next frame handed over, not with whatever the encoder happens to finish next.
public struct LiveMailbox<Frame> {
    public struct Handoff {
        public var frame: Frame
        public var keyframe: Bool
        public init(frame: Frame, keyframe: Bool) { self.frame = frame; self.keyframe = keyframe }
    }

    public enum Admission {
        /// The encoder was idle: encode this now.
        case encodeNow(Handoff)
        /// The encoder is busy; the frame waits, replacing an older waiting one if there was one.
        case waiting(replacedOlder: Bool)
        /// The mailbox is closed.
        case refused
    }

    public private(set) var inFlight = false
    public private(set) var dropped = 0
    public private(set) var closed = false
    public private(set) var keyframeRequested = false
    /// The newest frame admitted, kept so a still screen can be encoded again as a keyframe.
    public private(set) var latest: Frame?
    private var waiting: Frame?

    public init() {}

    public var hasWaiting: Bool { waiting != nil }

    public mutating func admit(_ frame: Frame) -> Admission {
        guard !closed else { return .refused }
        latest = frame
        if !inFlight {
            inFlight = true
            return .encodeNow(Handoff(frame: frame, keyframe: takeKeyframeRequest()))
        }
        let replaced = waiting != nil
        if replaced { dropped += 1 }
        waiting = frame
        return .waiting(replacedOlder: replaced)
    }

    /// The encoder finished a frame. Returns the next one to encode, if one waited.
    public mutating func encoderReturned() -> Handoff? {
        guard let next = waiting, !closed else {
            inFlight = false
            return nil
        }
        waiting = nil
        return Handoff(frame: next, keyframe: takeKeyframeRequest())
    }

    /// For a still screen: when a keyframe is wanted and nothing is in the encoder or waiting,
    /// hands the newest frame over again as that keyframe.
    public mutating func repeatLatest() -> Handoff? {
        guard keyframeRequested, !inFlight, waiting == nil, !closed, let latest else { return nil }
        inFlight = true
        keyframeRequested = false
        return Handoff(frame: latest, keyframe: true)
    }

    public mutating func requestKeyframe() {
        guard !closed else { return }
        keyframeRequested = true
    }

    public mutating func takeKeyframeRequest() -> Bool {
        defer { keyframeRequested = false }
        return keyframeRequested
    }

    /// Drops the waiting frame and refuses new ones. A frame already in the encoder finishes.
    public mutating func close() {
        closed = true
        waiting = nil
        latest = nil
        keyframeRequested = false
    }
}

extension LiveMailbox: Sendable where Frame: Sendable {}
extension LiveMailbox.Handoff: Sendable where Frame: Sendable {}
extension LiveMailbox.Handoff: Equatable where Frame: Equatable {}
extension LiveMailbox.Admission: Sendable where Frame: Sendable {}

/// A `LiveMailbox` shared between capture callbacks and an encoder's queue.
public final class LockedLiveMailbox<Frame: Sendable>: Sendable {
    private let state = Mutex(LiveMailbox<Frame>())

    public init() {}

    public func withLock<Result: Sendable>(_ body: (inout LiveMailbox<Frame>) -> Result) -> Result {
        state.withLock { body(&$0) }
    }

    public func admit(_ frame: Frame) -> LiveMailbox<Frame>.Admission { withLock { $0.admit(frame) } }
    public func encoderReturned() -> LiveMailbox<Frame>.Handoff? { withLock { $0.encoderReturned() } }
    public func repeatLatest() -> LiveMailbox<Frame>.Handoff? { withLock { $0.repeatLatest() } }
    public func requestKeyframe() { withLock { $0.requestKeyframe() } }
    public func close() { withLock { $0.close() } }
    public var dropped: Int { withLock { $0.dropped } }
    public var inFlight: Bool { withLock { $0.inFlight } }
    public var keyframeRequested: Bool { withLock { $0.keyframeRequested } }
}
