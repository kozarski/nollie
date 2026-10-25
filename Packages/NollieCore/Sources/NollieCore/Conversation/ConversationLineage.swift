import Foundation

/// The stored session ids one conversation has lived under, oldest first. Hermes compresses a long chat by carrying
/// it on under a new id; every id here is an alias for the same conversation, and the last one (the tip) is where
/// new messages go. Each segment is known to be the parent of the next. See `Docs/specs/conversation-engine.md`.
public struct ConversationLineage: Codable, Hashable, Sendable {
    /// Oldest first; never empty.
    public private(set) var segments: [String]
    /// True once the oldest segment is known to have no parent.
    public private(set) var rootKnown: Bool
    /// Ids known to belong to this conversation whose place is not known yet (the chat moved on several
    /// compressions while this device was away). They find their place again as parents are learned.
    public private(set) var aliases: [String] = []

    public init(tip: String) {
        segments = [tip]
        rootKnown = false
    }

    public init(segments: [String], rootKnown: Bool, aliases: [String] = []) {
        precondition(!segments.isEmpty, "a lineage has at least one segment")
        self.segments = segments
        self.rootKnown = rootKnown
        self.aliases = aliases.filter { !segments.contains($0) }
    }

    public var tip: String { segments[segments.count - 1] }
    public var oldest: String { segments[0] }

    public func contains(_ id: String) -> Bool { segments.contains(id) || aliases.contains(id) }

    /// Where a segment sits, oldest at 0.
    public func position(of id: String) -> Int? { segments.firstIndex(of: id) }

    /// Hermes named a stored id for this conversation. A new one becomes the tip; one already known (a repeat or a
    /// late announcement) changes nothing. Returns whether the tip moved.
    @discardableResult
    public mutating func advance(to id: String) -> Bool {
        guard !id.isEmpty, !segments.contains(id) else { return false }
        aliases.removeAll { $0 == id }
        segments.append(id)
        return true
    }

    /// Attaching found the chat under `id`, which may be several compressions past the tip: it becomes the tip of
    /// a new chain, and the ids known so far wait as aliases until their parents place them again. Returns whether
    /// the tip changed.
    @discardableResult
    public mutating func resolve(to id: String) -> Bool {
        guard !id.isEmpty, !segments.contains(id) else { return false }
        var waiting = aliases
        for segment in segments where !waiting.contains(segment) { waiting.append(segment) }
        aliases = waiting.filter { $0 != id }
        segments = [id]
        rootKnown = false
        return true
    }

    /// The segment before the oldest one is now known. Nil means the oldest one is the root.
    public mutating func learnParent(_ parent: String?) {
        guard !rootKnown else { return }
        if let parent, !parent.isEmpty, !segments.contains(parent) {
            segments.insert(parent, at: 0)
            aliases.removeAll { $0 == parent }
        } else {
            rootKnown = true
        }
    }

    /// This lineage with what `other` knows besides: segments older than this one's oldest and newer than its tip
    /// where the two chains meet, and the rest as aliases.
    public func merging(_ other: ConversationLineage) -> ConversationLineage {
        var result = self
        let meets = other.segments.contains { segments.contains($0) }
        if let start = other.position(of: oldest), start > 0 {
            result.segments = Array(other.segments[..<start]) + segments
            result.rootKnown = other.rootKnown
        } else if other.oldest == oldest, other.rootKnown {
            result.rootKnown = true
        }
        if let at = other.position(of: tip) {
            for segment in other.segments[(at + 1)...] { result.advance(to: segment) }
        }
        let unplaced = (meets ? [] : other.segments) + other.aliases
        for id in unplaced where !result.contains(id) { result.aliases.append(id) }
        result.aliases.removeAll { result.segments.contains($0) }
        return result
    }
}

/// Where a stored row lives: its segment and Hermes's row id. Ids increase within a segment.
public struct ConversationRowAddress: Codable, Hashable, Sendable, CustomStringConvertible {
    public var segment: String
    public var rowId: Int

    public init(segment: String, rowId: Int) {
        self.segment = segment
        self.rowId = rowId
    }

    public var description: String { "\(segment)#\(rowId)" }
}

extension ConversationLineage {
    /// Orders two addresses along the lineage: by segment, then by row id. Addresses outside it sort last.
    public func precedes(_ a: ConversationRowAddress, _ b: ConversationRowAddress) -> Bool {
        let left = position(of: a.segment) ?? Int.max
        let right = position(of: b.segment) ?? Int.max
        return left != right ? left < right : a.rowId < b.rowId
    }
}
