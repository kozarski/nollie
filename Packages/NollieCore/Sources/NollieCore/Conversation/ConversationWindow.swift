import Foundation

/// A bounded slice of a conversation's stored history, stitched across its lineage. It pages older rows from the
/// cache first and from Hermes after, drops rows past its capacity at the far end, and loads them back when the
/// person scrolls that way. See "The endless main chat" in `Docs/specs/conversation-engine.md`.
public actor ConversationWindow {
    public struct Configuration: Sendable {
        public var pageSize = 100
        public var capacity = 300
        /// Rows from either end at which the next page is loaded ahead of the scroll.
        public var prefetchMargin = 40
        /// Pages to skip at most when new rows at the tip shift Hermes's offsets under a walk.
        public var maxOverlapPages = 8

        public init(pageSize: Int = 100, capacity: Int = 300, prefetchMargin: Int = 40) {
            self.pageSize = pageSize
            self.capacity = max(capacity, pageSize * 2)
            self.prefetchMargin = prefetchMargin
        }
    }

    public let configuration: Configuration
    private var cache: ConversationCache
    private let source: any ConversationHistorySource
    private let lineageSource: (any ConversationLineageSource)?

    public private(set) var lineage: ConversationLineage
    /// Oldest first, along the lineage.
    public private(set) var rows: [ConversationHistoryRow] = []
    /// The newest stored row is in the window, so the live tail follows it.
    public private(set) var atNewestEnd = true
    /// The root's first row is in the window.
    public private(set) var atOldestEnd = false
    /// Pages read from Hermes and from the cache, for tests and diagnostics.
    public private(set) var networkPages = 0
    public private(set) var cachePages = 0

    private var loading = false
    /// Bumped each time the window starts over from the newest end. A page asked for before that belongs to rows
    /// no longer shown, and is dropped when it lands rather than inserted above the newest rows.
    private var generation = 0

    public init(key: String, lineage: ConversationLineage, store: any ConversationCacheStore,
                source: any ConversationHistorySource, lineageSource: (any ConversationLineageSource)? = nil,
                configuration: Configuration = Configuration()) {
        self.configuration = configuration
        self.source = source
        self.lineageSource = lineageSource
        var cache = ConversationCache(store: store, key: key)
        let known = cache.manifest.lineage.map { $0.merging(lineage) } ?? lineage
        cache.save(lineage: known)
        self.cache = cache
        self.lineage = known
    }

    /// The outbox saved with the cache, as it should be read back after a launch.
    public var savedOutbox: ConversationOutbox? { cache.manifest.outbox.map(ConversationOutbox.restored) }

    public func save(outbox: ConversationOutbox) { cache.save(outbox: outbox) }

    /// Hermes moved the tip, or attaching found the chat further on: the newer lineage leads.
    public func update(lineage newer: ConversationLineage) {
        lineage = newer.merging(lineage)
        cache.save(lineage: lineage)
    }

    public var addresses: Set<ConversationRowAddress> { Set(rows.map(\.address)) }

    /// The rows, both ends and the lineage read in one go, so a reader never pairs the rows of one page with the ends
    /// of another that landed between two reads.
    public var snapshot: (rows: [ConversationHistoryRow], atNewestEnd: Bool, atOldestEnd: Bool, lineage: ConversationLineage) {
        (rows, atNewestEnd, atOldestEnd, lineage)
    }

    // MARK: Opening

    /// Shows the newest cached rows at once, before Hermes is asked. Returns whether any were cached.
    @discardableResult
    public func openFromCache() -> Bool {
        let cached = cache.newestRows(of: lineage.tip, limit: configuration.pageSize)
        guard !cached.isEmpty else { return false }
        rows = cached
        atNewestEnd = true
        atOldestEnd = lineage.rootKnown && lineage.position(of: lineage.tip) == 0 && cache.reachesStart(of: lineage.tip, at: cached[0].address.rowId)
        cachePages += 1
        return true
    }

    /// Fetches the tip's newest page from Hermes and keeps it. While the window is at the newest end, rows not in it
    /// yet are added. Returns the rows that are new to the window.
    @discardableResult
    public func refreshNewest() async throws -> [ConversationHistoryRow] {
        let tip = lineage.tip
        let page = try await source.page(segment: tip, offset: 0, limit: configuration.pageSize)
        networkPages += 1
        cache.keep(page.rows, of: tip, upTo: nil, reachesStart: page.reachedStart)
        guard atNewestEnd, !page.rows.isEmpty else { return [] }
        guard let newest = rows.last else {
            rows = page.rows
            atOldestEnd = page.reachedStart && lineage.rootKnown && lineage.position(of: tip) == 0
            return page.rows
        }
        let fresh = page.rows.filter { lineage.precedes(newest.address, $0.address) }
        guard !fresh.isEmpty else { return [] }
        if joins(newest.address, fresh[0].address, page: page) {
            rows.append(contentsOf: fresh)
            trimOldest()
        } else {
            // A gap between what is shown and the newest rows: start again from the newest end.
            generation += 1
            rows = page.rows
            atOldestEnd = false
        }
        return fresh
    }

    /// Whether rows `newer` can follow `older` with nothing missing between them.
    private func joins(_ older: ConversationRowAddress, _ newer: ConversationRowAddress, page: ConversationHistoryPage) -> Bool {
        if older.segment == newer.segment {
            return cache.run(of: older.segment, covering: older.rowId)?.covers(newer.rowId) ?? false
        }
        // Across a compression: the older segment's newest row and the tip's first row.
        let olderRun = cache.run(of: older.segment, covering: older.rowId)
        return olderRun?.reachesNewest == true && olderRun?.last == older.rowId && page.reachedStart
            && lineage.position(of: older.segment).map { $0 + 1 } == lineage.position(of: newer.segment)
    }

    /// Starts over at the newest end, as when the history may have changed under the window. The rows shown stay
    /// until the newest page is in, so a screen never sees the window empty.
    public func reloadNewest() async throws {
        generation += 1
        let tip = lineage.tip
        let page = try await source.page(segment: tip, offset: 0, limit: configuration.pageSize)
        networkPages += 1
        cache.keep(page.rows, of: tip, upTo: nil, reachesStart: page.reachedStart)
        // Pages asked for while this one was on its way belong to the rows it replaces.
        generation += 1
        rows = page.rows
        atNewestEnd = true
        atOldestEnd = page.reachedStart && lineage.rootKnown && lineage.position(of: tip) == 0
    }

    // MARK: Scrolling

    /// Loads the rows before the oldest one shown. Returns whether any were added.
    @discardableResult
    public func loadOlder() async throws -> Bool {
        guard !loading, !atOldestEnd else { return false }
        loading = true
        defer { loading = false }
        guard let top = rows.first else {
            try await refreshNewest()
            return !rows.isEmpty
        }
        let asked = generation
        let (page, reachedStart) = try await older(than: top.address)
        // The window started over while the page was on its way (the jump to the newest rows): it is not above
        // anything shown now.
        guard asked == generation, rows.first?.address == top.address else { return false }
        rows.insert(contentsOf: page, at: 0)
        if page.isEmpty && reachedStart {
            try await stepIntoEarlierSegment(before: top.address.segment, generation: asked)
        }
        trimNewest()
        return rows.first?.address != top.address
    }

    /// Loads the rows after the newest one shown, once older pages pushed them out. Returns whether any were added.
    @discardableResult
    public func loadNewer() async throws -> Bool {
        guard !loading, !atNewestEnd, let bottom = rows.last else { return false }
        loading = true
        defer { loading = false }
        let segment = bottom.address.segment
        guard let newer = cache.rows(of: segment, newerThan: bottom.address.rowId, limit: configuration.pageSize) else {
            // Not cached (the cache was cleared): start again from the newest end.
            try await reloadNewest()
            return true
        }
        cachePages += 1
        if !newer.isEmpty {
            rows.append(contentsOf: newer)
        } else if segment == lineage.tip {
            atNewestEnd = true
            return false
        } else if let position = lineage.position(of: segment), position + 1 < lineage.segments.count,
                  let first = cache.oldestRows(of: lineage.segments[position + 1], limit: configuration.pageSize), !first.isEmpty {
            rows.append(contentsOf: first)
        } else {
            try await reloadNewest()
            return true
        }
        if let last = rows.last, last.address.segment == lineage.tip,
           cache.run(of: last.address.segment, covering: last.address.rowId).map({ $0.reachesNewest && $0.last == last.address.rowId }) == true {
            atNewestEnd = true
        }
        trimOldest()
        return true
    }

    /// The person is looking at the row at `index` of `rows`: load ahead when it is near either end.
    public func prefetch(around index: Int) async {
        if index < configuration.prefetchMargin {
            _ = try? await loadOlder()
        } else if !atNewestEnd, index >= rows.count - configuration.prefetchMargin {
            _ = try? await loadNewer()
        }
    }

    // MARK: Pages

    /// Rows just older than `address` within its segment, from the cache or else from Hermes.
    private func older(than address: ConversationRowAddress) async throws -> ([ConversationHistoryRow], Bool) {
        let limit = configuration.pageSize
        if let cached = cache.rows(of: address.segment, olderThan: address.rowId, limit: limit) {
            cachePages += 1
            return cached
        }
        var offset = cache.offset(of: address.segment, below: address.rowId)
            ?? rows.filter { $0.address.segment == address.segment && $0.address.rowId >= address.rowId }.count
        for _ in 0..<configuration.maxOverlapPages {
            let page = try await source.page(segment: address.segment, offset: offset, limit: limit)
            networkPages += 1
            let older = page.rows.filter { $0.address.rowId < address.rowId }
            if !older.isEmpty || page.reachedStart {
                cache.keep(older, of: address.segment, upTo: address.rowId, reachesStart: page.reachedStart)
                // A short page holds the segment's oldest rows, whatever overlapped the position.
                return (older, page.reachedStart)
            }
            // Every row was at or above the position: new rows at the tip moved the offsets. Skip ahead.
            offset += page.rows.count
        }
        return ([], false)
    }

    /// The window reached the start of a segment: go on with the newest rows of the one before, learning it first
    /// if needed. At the root, the window has the whole history.
    private func stepIntoEarlierSegment(before segment: String, generation asked: Int) async throws {
        guard let position = lineage.position(of: segment) else { return }
        if position == 0 {
            guard !lineage.rootKnown else { atOldestEnd = true; return }
            let parent = try await lineageSource?.parent(of: segment)
            guard asked == generation else { return }
            lineage.learnParent(parent)
            cache.save(lineage: lineage)
            guard let index = lineage.position(of: segment), index > 0 else { atOldestEnd = true; return }
        }
        guard let index = lineage.position(of: segment), index > 0 else { return }
        let earlier = lineage.segments[index - 1]
        var page = cache.manifest.segments[earlier]?.contains(where: \.reachesNewest) == true
            ? cache.newestRows(of: earlier, limit: configuration.pageSize) : []
        if page.isEmpty {
            let fetched = try await source.page(segment: earlier, offset: 0, limit: configuration.pageSize)
            networkPages += 1
            cache.keep(fetched.rows, of: earlier, upTo: nil, reachesStart: fetched.reachedStart)
            guard asked == generation else { return }
            page = fetched.rows
        } else {
            cachePages += 1
        }
        rows.insert(contentsOf: page, at: 0)
    }

    private func trimNewest() {
        guard rows.count > configuration.capacity else { return }
        rows.removeLast(rows.count - configuration.capacity)
        atNewestEnd = false
    }

    private func trimOldest() {
        guard rows.count > configuration.capacity else { return }
        rows.removeFirst(rows.count - configuration.capacity)
        atOldestEnd = false
    }
}
