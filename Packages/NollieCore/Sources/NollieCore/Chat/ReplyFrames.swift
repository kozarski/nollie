import Foundation

/// Keeps a reply from painting twice when Hermes sends the same frames again.
///
/// Since Hermes 0.23 a turn's `message.start`, `message.delta` and `message.interim` carry the turn's `turn_id`,
/// and a delta its `segment` (how many interim seals came before it) and `offset` (UTF-16 units of that segment
/// already sent). The same frames can arrive twice: a replay after a reconnect, a retried attempt that streams
/// its segment again, a second socket. This remembers how much of each segment is on screen and lets through only
/// what is new. Frames without `turn_id` (Hermes 0.22) pass as before.
public struct ReplyFrameLedger: Hashable, Sendable {
    /// The turn streaming now.
    private var turnID: String?
    /// UTF-16 units shown per segment of that turn.
    private var shown: [Int: Int] = [:]
    /// Segments of that turn already sealed by an interim message.
    private var sealed: Set<Int> = []
    /// Turns that have finished, newest last, so a late copy of one of their frames is dropped.
    private var finished: [String] = []

    public init() {}

    /// What to do with a `message.start`: false when it is a copy of the turn already under way or finished.
    public mutating func start(turn id: String?) -> Bool {
        guard let id = Self.named(id) else { return true }
        if id == turnID || finished.contains(id) { return false }
        open(id)
        return true
    }

    /// The part of a delta's text not yet shown: all of it, the new tail of an overlapping copy, or nil for a copy.
    public mutating func delta(_ text: String, turn id: String?, segment: Int?, offset: Int?) -> String? {
        guard let id = Self.named(id) else { return text }
        if finished.contains(id) { return nil }
        if id != turnID { open(id) }
        guard let segment, let offset, offset >= 0 else { return text }
        if sealed.contains(segment) { return nil }
        let units = text.utf16.count
        let have = shown[segment] ?? 0
        guard offset + units > have else { return nil }
        shown[segment] = offset + units
        // A gap (frames missed) still shows what came; an overlap shows only the part past what is on screen.
        guard offset < have else { return text }
        return String(decoding: Array(text.utf16.dropFirst(have - offset)), as: UTF16.self)
    }

    /// Whether an interim message is new: false for a second copy of a segment's seal.
    public mutating func interim(turn id: String?, segment: Int?) -> Bool {
        guard let id = Self.named(id) else { return true }
        if finished.contains(id) { return false }
        if id != turnID { open(id) }
        guard let segment else { return true }
        return sealed.insert(segment).inserted
    }

    /// The turn ended (`message.complete` or an error): later copies of its frames are dropped.
    public mutating func finish() {
        guard let id = turnID else { return }
        finished.append(id)
        if finished.count > 8 { finished.removeFirst(finished.count - 8) }
        turnID = nil
        shown = [:]
        sealed = []
    }

    private mutating func open(_ id: String) {
        if let old = turnID, old != id { finish() }
        turnID = id
        shown = [:]
        sealed = []
    }

    private static func named(_ id: String?) -> String? {
        guard let id, !id.isEmpty else { return nil }
        return id
    }
}

extension ReplyFrameLedger {
    public mutating func start(_ payload: JSONValue?) -> Bool { start(turn: payload?["turn_id"]?.stringValue) }

    public mutating func delta(_ payload: JSONValue?) -> String? {
        delta(payload?["text"]?.stringValue ?? "", turn: payload?["turn_id"]?.stringValue,
              segment: payload?["segment"]?.intValue, offset: payload?["offset"]?.intValue)
    }

    public mutating func interim(_ payload: JSONValue?) -> Bool {
        interim(turn: payload?["turn_id"]?.stringValue, segment: payload?["segment"]?.intValue)
    }
}
