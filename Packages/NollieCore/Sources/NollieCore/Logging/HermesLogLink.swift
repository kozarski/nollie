import Darwin
import Foundation

/// Makes `<logs folder>/Hermes` a link to the managed Hermes's own `logs` folder, so Console shows
/// Hermes next to Nollie's own files. Only ever touches a link it made itself: a real folder or file
/// by that name is left alone.
public enum HermesLogLink {
    public static let linkName = "Hermes"

    public enum Result: Equatable, Sendable {
        case linked(String), unchanged(String), removed, nothingToLink, blocked
    }

    /// The `home/logs` folder of the most recently active prepared setup in `setups`, if there is one.
    public static func hermesLogs(in setups: URL, fileManager fm: FileManager = .default) -> URL? {
        var best: (URL, Date)?
        for name in (try? fm.contentsOfDirectory(atPath: setups.path)) ?? [] where UUID(uuidString: name) != nil {
            let logs = setups.appendingPathComponent(name).appendingPathComponent("home").appendingPathComponent("logs")
            var info = stat()
            guard lstat(logs.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR else { continue }
            let modified = Date(timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec))
            if best == nil || modified > best!.1 { best = (logs, modified) }
        }
        return best?.0
    }

    @discardableResult
    public static func refresh(setups: URL, in directory: URL, fileManager fm: FileManager = .default) -> Result {
        let link = directory.appendingPathComponent(linkName)
        var info = stat()
        let exists = lstat(link.path, &info) == 0
        let isLink = exists && (info.st_mode & S_IFMT) == S_IFLNK
        if exists, !isLink { return .blocked }
        guard let target = hermesLogs(in: setups, fileManager: fm) else {
            if isLink { unlink(link.path); return .removed }
            return .nothingToLink
        }
        if isLink, (try? fm.destinationOfSymbolicLink(atPath: link.path)) == target.path { return .unchanged(target.path) }
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        if isLink { unlink(link.path) }
        return symlink(target.path, link.path) == 0 ? .linked(target.path) : .blocked
    }
}
