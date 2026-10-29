#if os(macOS)
import Foundation
import Darwin

/// The part of the dotenv format Hermes writes and reads itself (`secret_scope.load_env_file`):
/// `KEY=value`, `export KEY=value`, comments, and bare, single- or double-quoted values with an
/// optional inline comment. Lines are kept byte for byte when a file is rewritten.
struct RuntimeEnvFile {
    struct Assignment: Equatable {
        let line: Int
        let name: String
        let value: String
        /// A double-quoted value with an escape other than `\"` or `\\`, which python-dotenv and
        /// Hermes's own reader decode differently.
        let ambiguous: Bool
    }

    let lines: [String]
    let assignments: [Assignment]
    /// A quoted value that runs past its line. python-dotenv reads on into later lines and Hermes
    /// doesn't, so a file like this is left exactly as it is.
    let hasOpenQuote: Bool

    /// Nil when the bytes are not UTF-8: rewriting would change what Hermes reads.
    init?(_ data: Data) {
        var bytes = data
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { bytes.removeFirst(3) }
        guard let text = String(data: bytes, encoding: .utf8) else { return nil }
        var lines: [String] = []
        var start = text.startIndex
        while start < text.endIndex {
            let end = text[start...].firstIndex(of: "\n").map { text.index(after: $0) } ?? text.endIndex
            lines.append(String(text[start..<end]))
            start = end
        }
        var assignments: [Assignment] = []
        var open = false
        for (index, raw) in lines.enumerated() {
            guard let parsed = Self.parse(raw) else { continue }
            if parsed.open { open = true; continue }
            assignments.append(.init(line: index, name: parsed.name, value: parsed.value, ambiguous: parsed.ambiguous))
        }
        self.lines = lines
        self.assignments = assignments
        hasOpenQuote = open
    }

    /// What Hermes ends up with: the last assignment of each name wins.
    var values: [String: Assignment] {
        assignments.reduce(into: [:]) { $0[$1.name] = $1 }
    }

    /// Every `${NAME}` a value refers to. python-dotenv fills these in from the same file.
    var references: Set<String> {
        var names = Set<String>()
        for line in lines {
            var rest = Substring(line)
            while let open = rest.range(of: "${") {
                rest = rest[open.upperBound...]
                guard let close = rest.firstIndex(of: "}") else { break }
                names.insert(String(rest[..<close]))
                rest = rest[rest.index(after: close)...]
            }
        }
        return names
    }

    /// The file without any line that assigns one of `names`, with `header` first when given and
    /// not there yet. Never empty: an empty `.env` stops counting as a bot's own (Hermes
    /// `named_profile_has_servable_identity`).
    func removing(_ names: Set<String>, header: String?) -> String {
        let dropped = Set(assignments.filter { names.contains($0.name) }.map(\.line))
        var kept = lines.enumerated().filter { !dropped.contains($0.offset) }.map(\.element)
        if let header, !kept.contains(where: { $0.trimmingCharacters(in: .whitespacesAndNewlines) == header }) {
            kept.insert(header + "\n", at: 0)
        }
        if let last = kept.indices.last, !kept[last].hasSuffix("\n") { kept[last] += "\n" }
        let text = kept.joined()
        return text.isEmpty ? "\n" : text
    }

    private static func parse(_ raw: String) -> (name: String, value: String, ambiguous: Bool, open: Bool)? {
        var line = Substring(raw.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !line.isEmpty, !line.hasPrefix("#") else { return nil }
        if line.hasPrefix("export ") { line = line.dropFirst(7).drop { $0.isWhitespace } }
        guard let equals = line.firstIndex(of: "=") else { return nil }
        let name = line[..<equals].trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return nil }
        let rest = line[line.index(after: equals)...].trimmingCharacters(in: .whitespacesAndNewlines)
        if let quote = rest.first, quote == "\"" || quote == "'" {
            guard let close = closingQuote(rest, quote: quote) else { return (name, "", false, true) }
            let inner = rest[rest.index(after: rest.startIndex)..<close]
            // Hermes keeps `"a" b` whole, quotes and all; only a comment may follow a quoted value.
            let after = rest[rest.index(after: close)...].trimmingCharacters(in: .whitespaces)
            guard after.isEmpty || after.hasPrefix("#") else { return (name, "", true, false) }
            if quote == "'" { return (name, String(inner), false, false) }
            return unescaped(inner).map { (name, $0, false, false) } ?? (name, "", true, false)
        }
        // Unquoted: a `#` after whitespace starts a comment.
        var value = Substring(rest)
        var previous: Character = "="
        for index in rest.indices {
            if rest[index] == "#", previous.isWhitespace { value = rest[..<index]; break }
            previous = rest[index]
        }
        return (name, value.trimmingCharacters(in: .whitespaces), false, false)
    }

    private static func closingQuote(_ text: String, quote: Character) -> String.Index? {
        var index = text.index(after: text.startIndex)
        while index < text.endIndex {
            if quote == "\"", text[index] == "\\" {
                index = text.index(after: index)
                if index < text.endIndex { index = text.index(after: index) }
                continue
            }
            if text[index] == quote { return index }
            index = text.index(after: index)
        }
        return nil
    }

    /// `\"` and `\\` only, as Hermes writes them; nil for anything else.
    private static func unescaped(_ inner: Substring) -> String? {
        var result = ""
        var iterator = inner.makeIterator()
        while let character = iterator.next() {
            guard character == "\\" else { result.append(character); continue }
            guard let next = iterator.next(), next == "\"" || next == "\\" else { return nil }
            result.append(next)
        }
        return result
    }
}

/// Moves keys out of a setup's `.env` files into the Keychain, each time the assistant starts.
/// Safe to stop at any point: a key is written to the Keychain and read back before its line
/// leaves the file, and a file is only ever replaced whole, with one rename.
struct RuntimeKeyMigration {
    struct Outcome: Equatable, Sendable {
        /// Keys taken out of a `.env` file (now only in the Keychain).
        var moved = 0
        /// Keys Hermes cleared with an empty value, also forgotten in the Keychain.
        var cleared = 0
        /// Keys copied for a bot made as a copy of another.
        var copied = 0
        /// Keys still in a file because moving them wasn't safe. Zero means none on disk.
        var left = 0
        /// Keys of bots that no longer exist, forgotten.
        var forgotten = 0
    }

    static let header = "# Nollie keeps this bot's API keys in your Mac's Keychain, not in this file."
    static let cloneNote = ".nollie-keys-from"
    private static let maximumFile = 1 << 20
    private static let maximumValue = 65_536

    let installationID: UUID
    let home: URL
    let store: any RuntimeKeyStoring
    var lockAttempts = 60

    /// Throws only when the Keychain can't be read; any one file that can't be changed safely
    /// stays as it is and counts in `left`.
    func run() throws -> Outcome {
        var outcome = Outcome()
        var kept = Dictionary(try store.keys(for: installationID).map { ("\($0.profile)/\($0.name)", $0.value) }, uniquingKeysWith: { $1 })
        let profiles = livingProfiles()
        for (profile, folder) in profiles.live {
            moveLiveFile(profile: profile, folder: folder, kept: &kept, outcome: &outcome)
            stripBackups(profile: profile, folder: folder, kept: kept, outcome: &outcome)
        }
        for (profile, folder) in profiles.live where profile != "default" {
            copyClonedKeys(profile: profile, folder: folder, kept: &kept, outcome: &outcome)
        }
        if let known = profiles.complete {
            for (account, _) in kept {
                let parts = account.split(separator: "/", maxSplits: 1).map(String.init)
                guard parts.count == 2, !known.contains(parts[0]) else { continue }
                if (try? store.delete(profile: parts[0], name: parts[1], for: installationID)) != nil {
                    kept.removeValue(forKey: account)
                    outcome.forgotten += 1
                }
            }
        }
        return outcome
    }

    // MARK: Profiles

    /// `default` is the home itself; every other bot is `profiles/<id>`. A bot Hermes marked
    /// deleted (`profiles/.deleted/<id>`) no longer counts. `complete` is nil when the profiles
    /// folder couldn't be read, so nothing is forgotten on a guess.
    private func livingProfiles() -> (live: [(String, URL)], complete: Set<String>?) {
        var live = [("default", home)]
        let folder = home.appendingPathComponent("profiles", isDirectory: true)
        guard let fd = try? OwnedSetupFiles.directory(folder) else {
            var info = stat()
            return (live, lstat(folder.path, &info) != 0 && errno == ENOENT ? ["default"] : nil)
        }
        defer { close(fd) }
        guard let names = Self.entries(fd) else { return (live, nil) }
        let deleted = folder.appendingPathComponent(".deleted", isDirectory: true)
        for name in names.sorted() where name != "default" && RuntimeKeyNames.isProfile(name) {
            var info = stat()
            guard fstatat(fd, name, &info, AT_SYMLINK_NOFOLLOW) == 0, (info.st_mode & S_IFMT) == S_IFDIR else { continue }
            var marker = stat()
            if lstat(deleted.appendingPathComponent(name).path, &marker) == 0 { continue }
            live.append((name, folder.appendingPathComponent(name, isDirectory: true)))
        }
        return (live, Set(live.map(\.0)))
    }

    private static func entries(_ directory: Int32) -> [String]? {
        let copy = dup(directory)
        guard copy >= 0, let handle = fdopendir(copy) else { if copy >= 0 { close(copy) }; return nil }
        defer { closedir(handle) }
        var names: [String] = []
        while let entry = readdir(handle) {
            let name = withUnsafeBytes(of: entry.pointee.d_name) { raw in
                String(decoding: raw.prefix(Int(entry.pointee.d_namlen)), as: UTF8.self)
            }
            if name != "." && name != ".." { names.append(name) }
        }
        return names
    }

    // MARK: The live file

    private func moveLiveFile(profile: String, folder: URL, kept: inout [String: String], outcome: inout Outcome) {
        guard let directory = try? OwnedSetupFiles.directory(folder) else { return }
        defer { close(directory) }
        Self.removeLeftoverCopies(directory)
        guard let lock = takeLock(directory) else {
            outcome.left += countKeys(directory, ".env")
            return
        }
        defer { flock(lock, LOCK_UN); close(lock) }
        let file: (data: Data, identity: FileIdentity)
        switch Self.readFile(directory, ".env") {
        case .missing: return
        case .unsafe: outcome.left += 1; return
        case .read(let data, let identity): file = (data, identity)
        }
        guard let env = RuntimeEnvFile(file.data), !env.hasOpenQuote else {
            outcome.left += max(1, RuntimeEnvFile(file.data)?.values.keys.filter(RuntimeKeyNames.isKey).count ?? 1)
            return
        }
        let referenced = env.references
        var moving = Set<String>()
        for (name, assignment) in env.values where RuntimeKeyNames.isKey(name) {
            let account = "\(profile)/\(name)"
            let value = assignment.value
            if value.isEmpty {
                // Hermes clears a key by writing it empty. Forget the kept one as well.
                if kept[account] != nil, (try? store.delete(profile: profile, name: name, for: installationID)) != nil {
                    kept.removeValue(forKey: account)
                    outcome.cleared += 1
                }
                continue
            }
            // A 1Password reference is resolved by Hermes's own secret source; it isn't a key.
            if value.hasPrefix("op://") { continue }
            guard !assignment.ambiguous, !referenced.contains(name), !value.contains("${"), !value.contains("\0"),
                  value.utf8.count <= Self.maximumValue else { outcome.left += 1; continue }
            do {
                try store.save(RuntimeKey(profile: profile, name: name, value: value), for: installationID)
                kept[account] = value
                moving.insert(name)
            } catch {
                outcome.left += 1
            }
        }
        guard !moving.isEmpty else { return }
        if Self.replace(directory, ".env", with: env.removing(moving, header: Self.header), identity: file.identity) {
            outcome.moved += moving.count
        } else {
            // Still in the file and in the Keychain. The next start tries again.
            outcome.left += moving.count
        }
    }

    /// Hermes's own lock for a whole `.env` read and write (`config._env_write_lock`).
    private func takeLock(_ directory: Int32) -> Int32? {
        let lock = openat(directory, ".env.lock", O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard lock >= 0 else { return nil }
        var info = stat()
        guard fstat(lock, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_uid == getuid() else { close(lock); return nil }
        for attempt in 0..<max(1, lockAttempts) {
            if flock(lock, LOCK_EX | LOCK_NB) == 0 { return lock }
            if attempt + 1 < lockAttempts { usleep(50_000) }
        }
        close(lock)
        return nil
    }

    private func countKeys(_ directory: Int32, _ name: String) -> Int {
        guard case .read(let data, _) = Self.readFile(directory, name), let env = RuntimeEnvFile(data) else { return 1 }
        return env.values.filter { RuntimeKeyNames.isKey($0.key) && !$0.value.value.isEmpty && !$0.value.value.hasPrefix("op://") }.count
    }

    // MARK: Backups

    /// Hermes copies `.env` to `.env.bak-<time>` before it migrates its settings. A copy keeps no
    /// key the Keychain holds; one it doesn't hold stays, so a key is never lost.
    private func stripBackups(profile: String, folder: URL, kept: [String: String], outcome: inout Outcome) {
        guard let directory = try? OwnedSetupFiles.directory(folder) else { return }
        defer { close(directory) }
        guard let names = Self.entries(directory) else { return }
        for name in names.sorted() where name.hasPrefix(".env.bak") && !name.contains(Self.copyMarker) {
            guard case .read(let data, let identity) = Self.readFile(directory, name) else { outcome.left += 1; continue }
            guard let env = RuntimeEnvFile(data), !env.hasOpenQuote else { outcome.left += 1; continue }
            var stripping = Set<String>()
            for (key, assignment) in env.values where RuntimeKeyNames.isKey(key) && !assignment.value.isEmpty && !assignment.value.hasPrefix("op://") {
                if kept["\(profile)/\(key)"] != nil { stripping.insert(key) } else { outcome.left += 1 }
            }
            if !stripping.isEmpty, !Self.replace(directory, name, with: env.removing(stripping, header: nil), identity: identity) {
                outcome.left += stripping.count
            }
        }
    }

    // MARK: Copies of a bot

    /// A bot made as a copy gets the keys the copy would have carried in its `.env`: Nollie's
    /// entry point writes their names (never values) to `.nollie-keys-from` as Hermes makes it.
    private func copyClonedKeys(profile: String, folder: URL, kept: inout [String: String], outcome: inout Outcome) {
        guard let directory = try? OwnedSetupFiles.directory(folder) else { return }
        defer { close(directory) }
        guard case .read(let data, _) = Self.readFile(directory, Self.cloneNote) else { return }
        struct Note: Decodable { let version: Int; let from: String; let names: [String] }
        var complete = true
        if let note = try? JSONDecoder().decode(Note.self, from: data), note.version == 1, RuntimeKeyNames.isProfile(note.from),
           note.from != profile, note.names.count <= 512 {
            for name in note.names where RuntimeKeyNames.isKey(name) && kept["\(profile)/\(name)"] == nil {
                guard let value = kept["\(note.from)/\(name)"] else { continue }
                do {
                    try store.save(RuntimeKey(profile: profile, name: name, value: value), for: installationID)
                    kept["\(profile)/\(name)"] = value
                    outcome.copied += 1
                } catch {
                    complete = false
                }
            }
        }
        if complete { unlinkat(directory, Self.cloneNote, 0) }
    }

    // MARK: Files

    struct FileIdentity: Equatable {
        let device: Int32
        let inode: UInt64
        let size: Int64
        let modified: timespec
        let changed: timespec
        let mode: mode_t

        init(_ info: stat) {
            device = info.st_dev; inode = info.st_ino; size = info.st_size
            modified = info.st_mtimespec; changed = info.st_ctimespec; mode = info.st_mode
        }
        static func == (a: Self, b: Self) -> Bool {
            a.device == b.device && a.inode == b.inode && a.size == b.size && a.mode == b.mode
                && a.modified.tv_sec == b.modified.tv_sec && a.modified.tv_nsec == b.modified.tv_nsec
                && a.changed.tv_sec == b.changed.tv_sec && a.changed.tv_nsec == b.changed.tv_nsec
        }
    }

    enum FileRead { case missing, unsafe, read(Data, FileIdentity) }

    /// Only a regular file of this account with one name: never through a symbolic link, and
    /// never a hard link that rewriting would split.
    static func readFile(_ directory: Int32, _ name: String) -> FileRead {
        let fd = openat(directory, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard fd >= 0 else { return errno == ENOENT ? .missing : .unsafe }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_uid == getuid(), info.st_nlink == 1,
              info.st_size >= 0, info.st_size <= maximumFile else { return .unsafe }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 16_384)
        while true {
            let count = read(fd, &buffer, buffer.count)
            if count < 0 { return .unsafe }
            if count == 0 { break }
            data.append(contentsOf: buffer.prefix(count))
            if data.count > maximumFile { return .unsafe }
        }
        var after = stat()
        guard fstat(fd, &after) == 0, FileIdentity(after) == FileIdentity(info), data.count == Int(info.st_size) else { return .unsafe }
        return .read(data, FileIdentity(info))
    }

    private static let copyMarker = ".nollie-"

    /// A copy an earlier start wrote but never renamed, if it stopped halfway.
    private static func removeLeftoverCopies(_ directory: Int32) {
        for name in entries(directory) ?? [] where name.hasPrefix(".env") {
            guard let marker = name.range(of: copyMarker, options: .backwards),
                  UUID(uuidString: String(name[marker.upperBound...])) != nil else { continue }
            var info = stat()
            if fstatat(directory, name, &info, AT_SYMLINK_NOFOLLOW) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_uid == getuid() {
                unlinkat(directory, name, 0)
            }
        }
    }

    /// Writes a new copy beside the file, then renames it over the file only if the file is still
    /// the one that was read. The copy is owner-only. False leaves the original untouched.
    static func replace(_ directory: Int32, _ name: String, with text: String, identity: FileIdentity) -> Bool {
        let temporary = name + copyMarker + UUID().uuidString
        let fd = openat(directory, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { return false }
        var renamed = false
        defer { if !renamed { unlinkat(directory, temporary, 0) } }
        let bytes = Array(text.utf8)
        var written = 0
        while written < bytes.count {
            let count = bytes[written...].withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
            if count <= 0 { close(fd); return false }
            written += count
        }
        guard fchmod(fd, 0o600) == 0, fsync(fd) == 0 else { close(fd); return false }
        close(fd)
        var now = stat()
        guard fstatat(directory, name, &now, AT_SYMLINK_NOFOLLOW) == 0, FileIdentity(now) == identity,
              renameat(directory, temporary, directory, name) == 0 else { return false }
        renamed = true
        fsync(directory)
        return true
    }
}

/// What each Hermes process reads from its key pipe: `{"version": 1, "profiles": {bot: {NAME: value}}}`.
enum RuntimeKeyHandoff {
    static func payload(_ keys: [RuntimeKey]) -> Data {
        struct Body: Encodable { let version = 1; let profiles: [String: [String: String]] }
        var profiles: [String: [String: String]] = [:]
        for key in keys where RuntimeKeyNames.isProfile(key.profile) && RuntimeKeyNames.isKey(key.name) {
            profiles[key.profile, default: [:]][key.name] = key.value
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(Body(profiles: profiles))) ?? Data(#"{"profiles":{},"version":1}"#.utf8)
    }
}
#endif
