import CryptoKit
import Foundation

/// Where cached conversation pages are kept. Names are relative paths such as `folder/manifest.json`.
public protocol ConversationCacheStore: Sendable {
    func read(_ name: String) throws -> Data?
    func write(_ name: String, _ data: Data) throws
    func removeAll(under folder: String) throws
}

/// Files under a folder, by default `Application Support/Nollie/Conversations`.
public struct FileConversationCacheStore: ConversationCacheStore {
    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    /// The app's own folder for cached conversations.
    public static func applicationSupport() throws -> FileConversationCacheStore {
        FileConversationCacheStore(root: NolliePaths.current.conversations)
    }

    public func read(_ name: String) throws -> Data? {
        let url = root.appending(path: name)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try Data(contentsOf: url)
    }

    public func write(_ name: String, _ data: Data) throws {
        let url = root.appending(path: name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: [.atomic])
    }

    public func removeAll(under folder: String) throws {
        let url = root.appending(path: folder, directoryHint: .isDirectory)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }
}

/// Keeps everything in memory, for tests and previews. Counts reads so a test can tell the cache was used.
public final class MemoryConversationCacheStore: ConversationCacheStore, @unchecked Sendable {
    private let lock = NSLock()
    private var files: [String: Data] = [:]
    private var reads = 0

    public init() {}

    public var readCount: Int { lock.withLock { reads } }
    public var names: [String] { lock.withLock { files.keys.sorted() } }

    public func read(_ name: String) throws -> Data? {
        lock.withLock {
            reads += 1
            return files[name]
        }
    }

    public func write(_ name: String, _ data: Data) throws {
        lock.withLock { files[name] = data }
    }

    public func removeAll(under folder: String) throws {
        lock.withLock { files = files.filter { !$0.key.hasPrefix(folder + "/") } }
    }

    /// Replaces one file's bytes, so a test can plant an old or broken format.
    public func plant(_ name: String, _ data: Data) {
        lock.withLock { files[name] = data }
    }
}

/// The stored rows of one conversation as cached pages, plus its lineage and outbox, in versioned JSON. A page is
/// trusted for rows older than a position only when a run of pages covers that position: see "Cache format" in
/// `Docs/specs/conversation-engine.md`.
struct ConversationCache {
    static let formatVersion = 1

    struct Manifest: Codable, Hashable {
        var version = ConversationCache.formatVersion
        var lineage: ConversationLineage?
        var segments: [String: [Run]] = [:]
        var outbox: ConversationOutbox?
        var nextChunk = 1
    }

    /// Pages that together hold every stored row of a segment from `first` to `last`.
    struct Run: Codable, Hashable {
        var chunks: [Chunk]
        /// No rows of the segment are older than `first`.
        var reachesStart: Bool
        /// `last` was the segment's newest row when last fetched.
        var reachesNewest: Bool

        var first: Int { chunks.map(\.first).min() ?? 0 }
        var last: Int { chunks.map(\.last).max() ?? 0 }
        var count: Int { chunks.reduce(0) { $0 + $1.count } }

        func covers(_ rowId: Int) -> Bool { first <= rowId && rowId <= last }
    }

    struct Chunk: Codable, Hashable {
        var name: String
        var first: Int
        var last: Int
        var count: Int
    }

    struct ChunkFile: Codable {
        var version: Int
        var segment: String
        var rows: [ConversationHistoryRow]
    }

    let store: any ConversationCacheStore
    let folder: String
    private(set) var manifest: Manifest
    /// The few pages read last, so walking a page twice does not decode it twice.
    private var recent: [String: [ConversationHistoryRow]] = [:]
    private var recentOrder: [String] = []

    init(store: any ConversationCacheStore, key: String) {
        self.store = store
        folder = Self.folderName(for: key)
        let saved = (try? store.read("\(folder)/manifest.json")).flatMap { try? JSONDecoder().decode(Manifest.self, from: $0) }
        if let saved, saved.version == Self.formatVersion {
            manifest = saved
        } else {
            // Another format, or unreadable: it is only a copy, so start over.
            try? store.removeAll(under: folder)
            manifest = Manifest()
        }
    }

    /// A folder name a file system takes, readable and unique for the key.
    static func folderName(for key: String) -> String {
        let readable = String(key.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? Character($0) : "_" }.prefix(40))
        let digest = SHA256.hash(data: Data(key.utf8)).prefix(6).map { String(format: "%02x", $0) }.joined()
        return "\(readable)-\(digest)"
    }

    // MARK: Lineage and outbox

    mutating func save(lineage: ConversationLineage) {
        guard manifest.lineage != lineage else { return }
        manifest.lineage = lineage
        saveManifest()
    }

    mutating func save(outbox: ConversationOutbox) {
        guard manifest.outbox != outbox else { return }
        manifest.outbox = outbox
        saveManifest()
    }

    // MARK: Reading

    func run(of segment: String, covering rowId: Int) -> Run? {
        manifest.segments[segment]?.first { $0.covers(rowId) }
    }

    /// Up to `limit` cached rows of `segment` just older than `rowId`, oldest first, and whether they reach the
    /// segment's start. Nil when the cache does not cover that stretch.
    mutating func rows(of segment: String, olderThan rowId: Int, limit: Int) -> (rows: [ConversationHistoryRow], reachesStart: Bool)? {
        guard let run = run(of: segment, covering: rowId), let page = older(in: run, than: rowId, limit: limit) else { return nil }
        let reachesStart = run.reachesStart && (page.first?.address.rowId ?? rowId) == run.first
        if page.isEmpty && !reachesStart { return nil }
        return (page, reachesStart)
    }

    /// Up to `limit` cached rows of `segment` just newer than `rowId`, oldest first. Nil when not covered;
    /// empty when the cache holds nothing newer.
    mutating func rows(of segment: String, newerThan rowId: Int, limit: Int) -> [ConversationHistoryRow]? {
        guard let run = run(of: segment, covering: rowId) else { return nil }
        return newer(in: run, than: rowId, limit: limit)
    }

    /// The newest cached rows of a segment, oldest first.
    mutating func newestRows(of segment: String, limit: Int) -> [ConversationHistoryRow] {
        guard let run = manifest.segments[segment]?.max(by: { $0.last < $1.last }) else { return [] }
        return older(in: run, than: Int.max, limit: limit) ?? []
    }

    /// The oldest rows of a segment, when the cache has its start.
    mutating func oldestRows(of segment: String, limit: Int) -> [ConversationHistoryRow]? {
        guard let run = manifest.segments[segment]?.first(where: \.reachesStart) else { return nil }
        return newer(in: run, than: Int.min, limit: limit)
    }

    private mutating func older(in run: Run, than bound: Int, limit: Int) -> [ConversationHistoryRow]? {
        var found: [ConversationHistoryRow] = []
        for chunk in run.chunks.sorted(by: { $0.last > $1.last }) where chunk.first < bound {
            guard let rows = load(chunk) else { return nil }
            found.append(contentsOf: rows.filter { $0.address.rowId < bound })
            if found.count >= limit { break }
        }
        found.sort { $0.address.rowId < $1.address.rowId }
        return Array(found.suffix(limit))
    }

    private mutating func newer(in run: Run, than bound: Int, limit: Int) -> [ConversationHistoryRow]? {
        var found: [ConversationHistoryRow] = []
        for chunk in run.chunks.sorted(by: { $0.first < $1.first }) where chunk.last > bound {
            guard let rows = load(chunk) else { return nil }
            found.append(contentsOf: rows.filter { $0.address.rowId > bound })
            if found.count >= limit { break }
        }
        found.sort { $0.address.rowId < $1.address.rowId }
        return Array(found.prefix(limit))
    }

    /// Whether the cache knows the segment has no rows older than `rowId`.
    func reachesStart(of segment: String, at rowId: Int) -> Bool {
        guard let run = run(of: segment, covering: rowId) else { return false }
        return run.reachesStart && run.first == rowId
    }

    /// How many newest rows Hermes would skip to reach the rows just older than `rowId`: the cached rows from it to
    /// the segment's newest row, when the cache has that whole stretch.
    mutating func offset(of segment: String, below rowId: Int) -> Int? {
        guard let run = run(of: segment, covering: rowId), run.reachesNewest else { return nil }
        var count = 0
        for chunk in run.chunks {
            if chunk.first >= rowId {
                count += chunk.count
            } else if chunk.last >= rowId {
                guard let rows = load(chunk) else { return nil }
                count += rows.filter { $0.address.rowId >= rowId }.count
            }
        }
        return count
    }

    // MARK: Writing

    /// Keeps a page fetched from Hermes. `upTo`: the row it continues below (the page is contiguous with it), or nil
    /// for the newest page. A page that meets cached runs joins them into one.
    mutating func keep(_ page: [ConversationHistoryRow], of segment: String, upTo upper: Int?, reachesStart: Bool) {
        var runs = manifest.segments[segment] ?? []
        if page.isEmpty {
            // Nothing older than `upper`: its run reaches the start.
            if let upper, let index = runs.firstIndex(where: { $0.covers(upper) }), reachesStart {
                runs[index].reachesStart = true
                manifest.segments[segment] = runs
                saveManifest()
            }
            return
        }
        let low = page[0].address.rowId
        let high = max(upper ?? page[page.count - 1].address.rowId, page[page.count - 1].address.rowId)
        let fresh = page.filter { row in !runs.contains { $0.covers(row.address.rowId) } }
        var chunks: [Chunk] = []
        if !fresh.isEmpty {
            let name = "c-\(manifest.nextChunk)"
            manifest.nextChunk += 1
            let file = ChunkFile(version: Self.formatVersion, segment: segment, rows: fresh)
            guard let data = try? JSONEncoder().encode(file), (try? store.write("\(folder)/\(name).json", data)) != nil else { return }
            chunks.append(Chunk(name: name, first: fresh[0].address.rowId, last: fresh[fresh.count - 1].address.rowId, count: fresh.count))
            remember(name, fresh)
        }
        let meeting = runs.filter { $0.last >= low && $0.first <= high }
        runs.removeAll { $0.last >= low && $0.first <= high }
        let newest = upper == nil
        var joined = Run(chunks: chunks + meeting.flatMap(\.chunks), reachesStart: false, reachesNewest: newest)
        joined.chunks.sort { $0.first < $1.first }
        // The lowest piece decides whether the joined run reaches the start.
        let lowest = meeting.min { $0.first < $1.first }
        joined.reachesStart = (lowest.map { $0.first <= low && $0.reachesStart } ?? false) || (reachesStart && joined.first == low)
        joined.reachesNewest = newest || meeting.contains(where: \.reachesNewest)
        if newest { for index in runs.indices { runs[index].reachesNewest = false } }
        runs.append(joined)
        runs.sort { $0.first < $1.first }
        manifest.segments[segment] = runs
        saveManifest()
    }

    // MARK: Files

    private mutating func load(_ chunk: Chunk) -> [ConversationHistoryRow]? {
        if let rows = recent[chunk.name] { return rows }
        guard let data = try? store.read("\(folder)/\(chunk.name).json"),
              let file = try? JSONDecoder().decode(ChunkFile.self, from: data), file.version == Self.formatVersion else { return nil }
        remember(chunk.name, file.rows)
        return file.rows
    }

    private mutating func remember(_ name: String, _ rows: [ConversationHistoryRow]) {
        recent[name] = rows
        recentOrder.removeAll { $0 == name }
        recentOrder.append(name)
        while recentOrder.count > 4 { recent[recentOrder.removeFirst()] = nil }
    }

    private func saveManifest() {
        guard let data = try? JSONEncoder().encode(manifest) else { return }
        try? store.write("\(folder)/manifest.json", data)
    }
}
