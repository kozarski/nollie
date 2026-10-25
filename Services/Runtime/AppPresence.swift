#if os(macOS)
import Darwin
import Foundation

/// Whether the Nollie.app a helper lives in is still installed. Nollie Runtime and Nollie
/// Notifications live inside Nollie.app, so each watches its own bundle: when the person drags
/// Nollie to the Trash, the helper's bundle moves with it.
enum AppPresenceVerdict: Equatable, Sendable {
    /// Still where it was installed.
    case present
    /// Moved somewhere else that isn't a Trash (the helper keeps running from there).
    case moved(String)
    /// A new copy now sits where this one was, and this one has moved away (an update).
    case replaced
    /// In a Trash, or deleted.
    case gone
}

/// What a check reads from disk, so tests can stand in for it.
protocol AppPresenceProbe: Sendable {
    /// Where the bundle opened at launch is now. It follows a move, and is nil once deleted.
    func currentPath() -> String?
    /// The identifier in the Info.plist of the bundle at this path, or nil when there is none.
    func bundleIdentifier(at path: String) -> String?
}

struct AppPresence: Sendable {
    let installedPath: String
    let bundleIdentifier: String
    let probe: any AppPresenceProbe

    init(installedPath: String, bundleIdentifier: String, probe: any AppPresenceProbe) {
        self.installedPath = installedPath
        self.bundleIdentifier = bundleIdentifier
        self.probe = probe
    }

    /// This process's own bundle, when it lives inside another app (Nollie.app/Contents/...).
    static func forThisHelper(_ bundle: Bundle = .main) -> AppPresence? {
        guard let id = bundle.bundleIdentifier, bundle.bundleURL.pathExtension == "app",
              bundle.bundleURL.deletingLastPathComponent().pathComponents.contains(where: { $0.hasSuffix(".app") }),
              let probe = OpenBundleProbe(bundle.bundleURL), let path = probe.currentPath() else { return nil }
        return AppPresence(installedPath: path, bundleIdentifier: id, probe: probe)
    }

    /// The person's Trash, or a Trash on another volume.
    static func isInTrash(_ path: String) -> Bool {
        let parts = path.split(separator: "/")
        return parts.contains(".Trash") || parts.contains(".Trashes")
    }

    func check() -> AppPresenceVerdict {
        let now = probe.currentPath()
        if probe.bundleIdentifier(at: installedPath) == bundleIdentifier {
            // Something Nollie is where this one was installed: this one, or a newer copy in its place.
            return now == installedPath ? .present : .replaced
        }
        guard let now, !Self.isInTrash(now) else { return .gone }
        return probe.bundleIdentifier(at: now) == bundleIdentifier ? .moved(now) : .gone
    }

    /// Checks every `interval` and returns once the app is gone or replaced, confirmed by a second
    /// check a little later (so a copy being swapped in place is never mistaken for a removal).
    /// Returns nil when cancelled.
    func watch(every interval: Duration = .seconds(45), confirmAfter: Duration = .seconds(5),
               sleep: @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) async -> AppPresenceVerdict? {
        while !Task.isCancelled {
            let first = check()
            if first == .gone || first == .replaced {
                do { try await sleep(confirmAfter) } catch { return nil }
                if check() == first { return first }
            }
            do { try await sleep(interval) } catch { return nil }
        }
        return nil
    }
}

/// The real disk: the bundle is held open by descriptor (for events only, so it never keeps a
/// volume busy), which follows it through a move and reports where it is now.
final class OpenBundleProbe: AppPresenceProbe, @unchecked Sendable {
    private let descriptor: Int32

    init?(_ bundle: URL) {
        let fd = open(bundle.path, O_EVTONLY | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        descriptor = fd
    }

    deinit { close(descriptor) }

    func currentPath() -> String? {
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_nlink > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard fcntl(descriptor, F_GETPATH, &buffer) == 0 else { return nil }
        let path = String(cString: buffer)
        // A deleted bundle can keep reporting its last path: it must still be there.
        var there = stat()
        guard lstat(path, &there) == 0, there.st_ino == info.st_ino, there.st_dev == info.st_dev else { return nil }
        return path
    }

    func bundleIdentifier(at path: String) -> String? {
        let plist = URL(fileURLWithPath: path).appendingPathComponent("Contents/Info.plist")
        guard let size = (try? FileManager.default.attributesOfItem(atPath: plist.path)[.size] as? NSNumber)?.intValue,
              size <= 1_000_000, let data = try? Data(contentsOf: plist),
              let values = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return nil }
        return values["CFBundleIdentifier"] as? String
    }
}
#endif
