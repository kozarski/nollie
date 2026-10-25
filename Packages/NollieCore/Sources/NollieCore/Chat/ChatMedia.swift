import CryptoKit
import Foundation

// Pictures, videos and files in a chat.
//
// The gateway never sends these as bytes in a message. A person's attachment is stored as the
// words "[User attached image: <name>]" with the file in the profile's images folder. A bot's
// own files arrive as `MEDIA:/path` lines (how the gateway names a file in a reply), as a markdown
// link to a path, or as a path a tool printed. Here we spot those references and download the
// bytes through the gateway, while thumbnails come from what the gateway keeps on disk.

/// One file the chat refers to, found at one of a few possible places on the gateway.
public struct MediaRef: Identifiable, Sendable, Hashable {
    public var name: String
    /// Absolute paths to try, in order (several when the exact folder is a guess).
    public var candidates: [String]

    public init(path: String) { self.init(candidates: [path]) }

    public init(candidates: [String], name: String? = nil) {
        let firstName = candidates.first.map { URL(fileURLWithPath: $0, isDirectory: false).lastPathComponent }
        self.name = name ?? firstName ?? "image"
        self.candidates = candidates
    }

    public var id: String { candidates.first ?? name }

    public static let imageExtensions = Set("png jpg jpeg gif webp heic heif bmp".split(separator: " ").map(String.init))
    /// Videos the thread plays in place, such as a screen recording.
    public static let videoExtensions = Set("mp4 mov m4v".split(separator: " ").map(String.init))

    public static func isImage(_ path: String) -> Bool { imageExtensions.contains(extensionOf(path)) }
    public static func isVideo(_ path: String) -> Bool { videoExtensions.contains(extensionOf(path)) }

    fileprivate static func extensionOf(_ path: String) -> String {
        URL(fileURLWithPath: path, isDirectory: false).pathExtension.lowercased()
    }
}

public enum MediaScan {
    // MARK: Pictures

    /// Pictures a reply points at: `MEDIA:` tokens, markdown images with a gateway path, and
    /// lines that are nothing but a path to an image. Each picture once, in that order.
    public static func images(in text: String) -> [MediaRef] {
        var found = Finds { path in
            MediaRef.isImage(path) && (path.hasPrefix("/") || path.hasPrefix("~"))
        }
        let reply = normalisedLineEnds(text)
        mediaTokens(in: reply).forEach { found.take($0) }
        Shapes.markdownImage.hits(in: reply).forEach { found.take($0[2]) }
        pathOnlyLines(in: reply).forEach { found.take($0) }
        return found.refs
    }

    /// Image paths anywhere in a tool's output, such as what a screenshot tool reports.
    public static func imagePaths(inToolOutput text: String) -> [MediaRef] {
        var found = Finds { _ in true }
        Shapes.imageInOutput.hits(in: text).forEach { found.take($0[1]) }
        return found.refs
    }

    /// Video paths in a tool's output, wherever they sit: a recorder's `last_video_path`, a `MEDIA:`
    /// line or a path inside a sentence. A name that keeps going after the extension is not a match.
    public static func videoPaths(inToolOutput text: String) -> [MediaRef] {
        var found = Finds { _ in true }
        Shapes.videoInOutput.hits(in: text).forEach { found.take($0[1]) }
        return found.refs
    }

    // MARK: Files

    /// Files a reply mentions that are not pictures. Recognised forms: `MEDIA:` tokens, markdown links
    /// pointing at a gateway path, and lines made of a bare path. A candidate must end in a file name with
    /// an extension; if the same file turns up twice, only one card is made.
    public static func files(in text: String) -> [MediaRef] {
        var found = Finds { isFilePath($0) && !MediaRef.isImage($0) }
        let reply = normalisedLineEnds(text)
        mediaTokens(in: reply).forEach { found.take($0) }
        Shapes.angledLink.hits(in: reply).forEach { found.take($0[2]) }
        for hit in Shapes.plainLink.hits(in: reply) {
            found.take(hit[2].removingPercentEncoding ?? hit[2])
        }
        pathOnlyLines(in: reply).forEach { found.take($0) }
        return found.refs
    }

    /// An absolute gateway path to a named file: begins at the root or home, is not a web
    /// address, and ends in a name with a stem and a one to six character extension.
    public static func isFilePath(_ path: String) -> Bool {
        guard !path.contains("://") else { return false }
        return path.range(of: #"^(?:/|~/)(?:.*/)?[^/]+\.[\p{L}\p{N}]{1,6}$"#, options: .regularExpression) != nil
    }

    /// The icon family a file card uses.
    public enum FileKind: String, Sendable {
        case other, text, code, table, pdf, archive, audio, video

        public static func of(_ name: String) -> FileKind {
            kinds[MediaRef.extensionOf(name)] ?? .other
        }

        private static let kinds: [String: FileKind] = [
            "pdf": .pdf,
            "csv": .table, "tsv": .table, "xls": .table, "xlsx": .table, "numbers": .table,
            "zip": .archive, "gz": .archive, "tgz": .archive, "tar": .archive, "7z": .archive,
            "bz2": .archive, "xz": .archive, "dmg": .archive,
            "mp3": .audio, "m4a": .audio, "wav": .audio, "aac": .audio, "flac": .audio,
            "ogg": .audio, "opus": .audio, "aiff": .audio,
            "mp4": .video, "mov": .video, "m4v": .video, "webm": .video, "mkv": .video, "avi": .video,
            "txt": .text, "md": .text, "markdown": .text, "log": .text, "rtf": .text, "json": .text,
            "yaml": .text, "yml": .text, "toml": .text, "xml": .text, "html": .text, "htm": .text,
            "swift": .code, "py": .code, "js": .code, "ts": .code, "rb": .code, "go": .code, "rs": .code,
            "c": .code, "h": .code, "cpp": .code, "java": .code, "kt": .code, "sh": .code, "sql": .code,
            "css": .code,
        ]
    }

    // MARK: Reading a reply for display

    /// The reply minus its media references, for the bubble (pictures and cards sit under it).
    public static func textWithoutMedia(_ text: String) -> String {
        let kept = normalisedLineEnds(text)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .compactMap { original -> String? in
                let line = withoutMediaMarkup(String(original))
                let bare = line.trimmingCharacters(in: .whitespacesAndNewlines)
                if bare.hasPrefix("/") || bare.hasPrefix("~/"), !bare.contains(" "),
                   MediaRef.isImage(clean(bare)) || isFilePath(clean(bare)) {
                    return nil   // the line was only a path, maybe with a stray stop or bracket
                }
                if bare.isEmpty, !original.allSatisfy(\.isWhitespace) {
                    return nil   // the line held nothing but a reference that is now gone
                }
                return line
            }
        var result = kept.joined(separator: "\n")
        while result.contains("\n\n\n") { result = result.replacingOccurrences(of: "\n\n\n", with: "\n\n") }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// One line with its media tokens, gateway images and gateway file links reduced to words.
    private static func withoutMediaMarkup(_ line: String) -> String {
        var out = Shapes.mediaWithSpace.replacing(in: line) { _ in "" }
        // An image on the gateway leaves its alt text; one on the web stays for markdown to draw.
        out = Shapes.markdownImage.replacing(in: out) { g in
            g[2].hasPrefix("/") || g[2].hasPrefix("~") ? g[1] : g[0]
        }
        // A link to a gateway file leaves its words (the card sits under the bubble).
        for shape in [Shapes.angledLinkKeepingLead, Shapes.plainLinkKeepingLead] {
            out = shape.replacing(in: out) { g in isFilePath(clean(g[3])) ? g[1] + g[2] : g[0] }
        }
        return out
    }

    // MARK: A person's attachments

    /// Names in the "[User attached image: name]" marks a stored user message carries.
    public static func attachedImageNames(in userText: String) -> [String] {
        Shapes.attachmentMark.hits(in: userText).map { hit in hit[1].trimmingCharacters(in: .whitespaces) }
    }

    /// The person's own words with the attachment marks removed.
    public static func userTextWithoutAttachments(_ text: String) -> String {
        Shapes.attachmentMarkWithSpace.replacing(in: text) { _ in "" }
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Best guess at where an attached image lives remotely: inside the profile's images folder, below
    /// the Hermes home. That home is the gateway's own business, so every likely place is returned.
    public static func attachedImageRef(name: String, profile: String?) -> MediaRef {
        let homes = [profile.flatMap { $0.isEmpty || $0 == "default" ? nil : "profiles/\($0)" }, "", "profiles/default"]
        let spots = homes.compactMap { $0 }.map { home in
            "~/.hermes/" + (home.isEmpty ? "" : home + "/") + "images/" + name
        }
        return MediaRef(candidates: spots, name: name)
    }

    // MARK: Pieces shared by the scans

    /// Collects accepted paths in the order they turn up, each once.
    private struct Finds {
        private let isWanted: (String) -> Bool
        private var paths: [String] = []

        init(accepts: @escaping (String) -> Bool) { isWanted = accepts }

        var refs: [MediaRef] { paths.map { MediaRef(path: $0) } }

        mutating func take(_ raw: String) {
            let path = MediaScan.clean(raw)
            if !path.isEmpty, isWanted(path), !paths.contains(path) { paths.append(path) }
        }
    }

    private static func mediaTokens(in text: String) -> [String] {
        Shapes.mediaToken.hits(in: text).map { $0[1] }
    }

    /// Lines that are only an absolute (or home) path with no spaces.
    private static func pathOnlyLines(in text: String) -> [String] {
        text.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { ($0.hasPrefix("/") || $0.hasPrefix("~/")) && !$0.contains(" ") }
    }

    /// Swift reads "\r\n" as one character, so a reply with Windows line ends would look like a
    /// single line. A cheap look for a carriage return on the bytes comes first.
    static func normalisedLineEnds(_ text: String) -> String {
        text.utf8.contains(13) ? text.replacingOccurrences(of: "\r\n", with: "\n") : text
    }

    /// Trims spaces, then closing punctuation off the end and opening punctuation off the front.
    static func clean(_ raw: String) -> String {
        let closers = Set(".,;:)]}>\"'`"), openers = Set("\"'`<([")
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard let last = trimmed.lastIndex(where: { !closers.contains($0) }) else { return "" }
        let body = trimmed[...last]
        guard let first = body.firstIndex(where: { !openers.contains($0) }) else { return "" }
        return String(body[first...])
    }

    // MARK: Patterns

    /// A compiled pattern that hands back capture groups as plain strings (group 0 is the
    /// whole match, and a group that did not take part is empty).
    private struct Shape {
        private let expression: NSRegularExpression

        init(_ source: String, ignoringCase: Bool = false) {
            expression = try! NSRegularExpression(pattern: source, options: ignoringCase ? [.caseInsensitive] : [])
        }

        func hits(in text: String) -> [[String]] {
            let whole = NSRange(text.startIndex..., in: text)
            return expression.matches(in: text, range: whole).map { Self.groups(of: $0, in: text) }
        }

        func replacing(in text: String, _ make: ([String]) -> String) -> String {
            let whole = NSRange(text.startIndex..., in: text)
            var out = text
            for hit in expression.matches(in: text, range: whole).reversed() {
                guard let span = Range(hit.range, in: out) else { continue }
                out.replaceSubrange(span, with: make(Self.groups(of: hit, in: text)))
            }
            return out
        }

        private static func groups(of hit: NSTextCheckingResult, in text: String) -> [String] {
            (0..<hit.numberOfRanges).map { index in
                Range(hit.range(at: index), in: text).map { String(text[$0]) } ?? ""
            }
        }
    }

    /// The shapes the scans look for, written from named pieces.
    private enum Shapes {
        private static let imageNames = MediaRef.imageExtensions.sorted().joined(separator: "|")
        private static let videoNames = MediaRef.videoExtensions.sorted().joined(separator: "|")
        /// What may stand just before a path inside a sentence or a key=value.
        private static let beforePath = #"(?:^|[\s"'`(=:])"#
        private static let pathBody = #"(?:~|/)[^\s"'`)<>]+"#
        private static let altText = #"\[([^\]]*)\]"#

        static let mediaToken = Shape(#"MEDIA:(\S+)"#)
        static let mediaWithSpace = Shape(#"\s*MEDIA:\S+"#)
        static let markdownImage = Shape(#"!"# + altText + #"\(([^)\s]+)\)"#)

        static let angledLink = Shape(#"(?:^|[^!])"# + altText + #"\(<([^>]+)>\)"#)
        static let plainLink = Shape(#"(?:^|[^!])"# + altText + #"\(([^)\s<]+)\)"#)
        static let angledLinkKeepingLead = Shape(#"(^|[^!])"# + altText + #"\(<([^>]+)>\)"#)
        static let plainLinkKeepingLead = Shape(#"(^|[^!])"# + altText + #"\(([^)\s<]+)\)"#)

        static let imageInOutput = Shape("\(beforePath)(\(pathBody)\\.(?:\(imageNames)))", ignoringCase: true)
        static let videoInOutput = Shape("\(beforePath)(\(pathBody)\\.(?:\(videoNames)))(?![A-Za-z0-9_]|\\.[A-Za-z0-9])",
                                         ignoringCase: true)

        static let attachmentMark = Shape(#"\[User attached image: ([^\]]+)\]"#)
        static let attachmentMarkWithSpace = Shape(#"\s*\[User attached image: [^\]]+\]"#)
    }
}

// MARK: Fetching

/// Tries each path in turn and returns the first result that works; if none does, the last
/// failure is thrown.
private func firstSuccess<T>(of paths: [String], _ attempt: (String) async throws -> T) async throws -> T {
    var failure: Error = HermesAPIError.transport("No path to try.")
    for path in paths {
        do { return try await attempt(path) } catch { failure = error }
    }
    throw failure
}

/// Gateway routes for pictures. `GET /api/media?path=` serves an image from beneath the Hermes home
/// folder, encoded as a data URL. For anything else the gateway is willing to read there is
/// `/api/files/read`. Both are subject to a size limit.
public struct GatewayMediaAPI: Sendable {
    let api: HermesAPI
    public var profile: String?

    public init(api: HermesAPI, profile: String? = nil) {
        self.api = api
        self.profile = profile
    }

    /// What the picture routes answer: a data URL, spelled either way depending on the version.
    struct DataURLReply: Decodable {
        var data_url: String?
        var dataUrl: String?
        var size: Int?
        var mime_type: String?

        /// The bytes inside a `data:<type>;base64,<payload>` address.
        var bytes: Data? {
            guard let address = data_url ?? dataUrl, address.hasPrefix("data:"),
                  let comma = address.firstIndex(of: ",") else { return nil }
            guard address[..<comma].contains(";base64") else { return nil }
            return Data(base64Encoded: String(address[address.index(after: comma)...]))
        }
    }

    /// Tries each candidate path until the gateway serves one, returning the bytes and the path that worked.
    public func fetch(_ ref: MediaRef) async throws -> (Data, String) {
        try await firstSuccess(of: ref.candidates) { path in (try await fetch(path: path), path) }
    }

    public func fetch(path: String) async throws -> Data {
        let query = [URLQueryItem(name: "path", value: path)]
        // Start with the media route. Outside the media folders, the general files route may still succeed.
        for (attempt, route) in ["/api/media", "/api/files/read"].enumerated() {
            do {
                let reply: DataURLReply = try await api.get(route, query: query, profile: profile)
                if let bytes = reply.bytes { return bytes }
            } catch let failure as HermesAPIError where attempt == 0 {
                if case .http(let status, _) = failure, ![403, 404, 415].contains(status) { throw failure }
            }
        }
        throw HermesAPIError.transport("No picture data came back from the gateway.")
    }
}

/// Files fetched once and kept in the caches folder (the system may clear it), named by gateway
/// and path, so a picture shown in several rows is downloaded once.
public actor MediaStore {
    public static let shared = MediaStore()

    private let folder: URL
    /// Downloads under way, so two rows asking for the same file wait on one fetch.
    private var underway: [String: Task<URL, Error>] = [:]

    public init() {
        folder = NolliePaths.current.media
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    /// A stable 32 character name for one path on one gateway.
    public nonisolated static func key(gateway: String, path: String) -> String {
        SHA256.hash(data: Array("\(gateway)|\(path)".utf8)).prefix(16)
            .map { ($0 < 16 ? "0" : "") + String($0, radix: 16) }
            .joined()
    }

    /// The picture on disk, downloaded through `api` the first time it is asked for.
    public func localURL(for ref: MediaRef, gateway: String, api: GatewayMediaAPI) async throws -> URL {
        try await localFile(for: ref, gateway: gateway) { path in
            let scratch = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try await api.fetch(path: path).write(to: scratch, options: .atomic)
            return scratch
        }
    }

    /// Any file, such as a picture or a screen recording. `fetchFile` brings one candidate path
    /// to a temporary file, which is moved in with the others; the first path that works wins.
    public func localFile(for ref: MediaRef, gateway: String,
                          download fetchFile: @escaping @Sendable (String) async throws -> URL) async throws -> URL {
        if let kept = cached(ref, gateway: gateway) { return kept }
        return try await download(ref, gateway: gateway) { store in
            try await firstSuccess(of: ref.candidates) { path in
                let temporary = try await fetchFile(path)
                let target = store.location(gateway: gateway, path: path)
                try? FileManager.default.removeItem(at: target)
                try FileManager.default.moveItem(at: temporary, to: target)
                return target
            }
        }
    }

    /// The file if it was fetched before; no network.
    public func cached(_ ref: MediaRef, gateway: String) -> URL? {
        ref.candidates
            .map { location(gateway: gateway, path: $0) }
            .first { FileManager.default.fileExists(atPath: $0.path) }
    }

    private func download(_ ref: MediaRef, gateway: String,
                          _ work: @escaping @Sendable (MediaStore) async throws -> URL) async throws -> URL {
        let token = gateway + "|" + ref.id
        if let running = underway[token] { return try await running.value }
        let task = Task { try await work(self) }
        underway[token] = task
        defer { underway[token] = nil }
        return try await task.value
    }

    fileprivate nonisolated func location(gateway: String, path: String) -> URL {
        let suffix = MediaRef.extensionOf(path)
        let name = Self.key(gateway: gateway, path: path)
        return folder.appendingPathComponent(suffix.isEmpty ? name : name + "." + suffix)
    }
}
