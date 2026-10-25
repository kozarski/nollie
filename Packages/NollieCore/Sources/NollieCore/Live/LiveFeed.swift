import Foundation

/// One viewer's live picture of a helper's computer. It comes over the network from Nollie Link
/// or a gateway, or on the Mac straight from this Mac's own host; either way the viewer sees the
/// same events in the same order.
public protocol LiveFeed: AnyObject, Sendable {
    /// Everything the host sends, ending with exactly one `.closed`. Read it once.
    var events: AsyncStream<LiveFeedEvent> { get }
    /// A keyframe request or the once-a-second report. Ignored once the feed has closed.
    func send(_ message: LiveWire.ViewerMessage)
    /// Ends the feed from this side. `.closed(.cancelled)` follows unless it had already closed.
    func cancel()
}

public enum LiveFeedEvent: Sendable {
    /// Hello, a beat, the pointer, a new source size, or the end.
    case message(LiveWire.ServerMessage)
    /// One encoded frame, and when it arrived here.
    case video(LiveWire.Video, receivedAt: Date)
    /// The feed is over and nothing follows.
    case closed(LiveFeedClose)
}

public enum LiveFeedClose: Sendable, Equatable {
    /// It never started: there's no live picture here (an older gateway, the Mac app isn't
    /// running, a sign-in the stream can't use). Snapshots still work.
    case unavailable
    /// The host ended it and said why.
    case ended(LiveWire.EndReason)
    /// The connection was lost after it had started.
    case dropped
    /// This side cancelled it.
    case cancelled
}
