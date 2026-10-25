import Foundation

/// A conversation's stored history kept in memory: rows per segment, served newest first by offset as Hermes's
/// `/messages` does, and each segment's parent. For previews, tests and the demo screen; `latency` holds every
/// answer that long, as a slow line would.
public actor MemoryConversationHistory: ConversationHistorySource, ConversationLineageSource {
    private var segments: [String: [ConversationHistoryRow]]
    private let parents: [String: String]
    public var latency: Duration
    /// Pages asked for and not answered yet.
    public private(set) var pending = 0
    public private(set) var pagesServed = 0

    /// - Parameters:
    ///   - segments: every segment's stored rows, in any order.
    ///   - parents: the segment each one was compressed from; a segment without one is the root.
    public init(segments: [String: [ConversationHistoryRow]], parents: [String: String] = [:], latency: Duration = .zero) {
        self.segments = segments.mapValues { $0.sorted { $0.address.rowId < $1.address.rowId } }
        self.parents = parents
        self.latency = latency
    }

    public func page(segment: String, offset: Int, limit: Int) async throws -> ConversationHistoryPage {
        pending += 1
        defer { pending -= 1 }
        if latency > .zero { try await Task.sleep(for: latency) }
        pagesServed += 1
        let rows = segments[segment] ?? []
        let end = max(rows.count - offset, 0)
        let start = max(end - limit, 0)
        let slice = Array(rows[start..<end])
        return ConversationHistoryPage(rows: slice, reachedStart: slice.count < limit)
    }

    public func parent(of segment: String) async throws -> String? {
        if latency > .zero { try await Task.sleep(for: latency) }
        return parents[segment]
    }

    /// Stores a row at the end of its segment, as Hermes does when a turn settles.
    public func append(_ row: ConversationHistoryRow) {
        segments[row.address.segment, default: []].append(row)
    }

    public func setLatency(_ latency: Duration) { self.latency = latency }

    /// The highest row id stored in any segment.
    public var newestRowId: Int { segments.values.compactMap { $0.last?.address.rowId }.max() ?? 0 }
}
