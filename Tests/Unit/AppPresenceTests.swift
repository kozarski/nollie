#if os(macOS)
import Foundation
import Testing
@testable import Nollie

/// Nollie Runtime and Nollie Notifications notice when Nollie.app is dragged to the Trash, deleted,
/// moved or replaced by a newer copy. A fake disk and a fake clock for the rules, then a real
/// folder on disk for the descriptor that follows the bundle around.
@Suite struct AppPresenceTests {
    final class FakeDisk: AppPresenceProbe, @unchecked Sendable {
        private let lock = NSLock()
        private var _now: String?
        private var _bundles: [String: String]
        init(now: String?, bundles: [String: String]) { _now = now; _bundles = bundles }
        func set(now: String?, bundles: [String: String]) { lock.lock(); _now = now; _bundles = bundles; lock.unlock() }
        func currentPath() -> String? { lock.lock(); defer { lock.unlock() }; return _now }
        func bundleIdentifier(at path: String) -> String? { lock.lock(); defer { lock.unlock() }; return _bundles[path] }
    }

    static let installed = "/Applications/Nollie.app/Contents/Helpers/Nollie Runtime.app"
    static let id = "com.coreykozarski.nollie.runtime"

    private func presence(now: String?, bundles: [String: String]) -> (AppPresence, FakeDisk) {
        let disk = FakeDisk(now: now, bundles: bundles)
        return (AppPresence(installedPath: Self.installed, bundleIdentifier: Self.id, probe: disk), disk)
    }

    @Test func eachWayNollieCanLeaveItsPlace() {
        let installed = Self.installed, id = Self.id
        let trashed = "/Users/me/.Trash/Nollie.app/Contents/Helpers/Nollie Runtime.app"
        let moved = "/Users/me/Desktop/Nollie.app/Contents/Helpers/Nollie Runtime.app"
        #expect(presence(now: installed, bundles: [installed: id]).0.check() == .present)
        #expect(presence(now: trashed, bundles: [trashed: id]).0.check() == .gone)
        #expect(presence(now: "/Volumes/Disk/.Trashes/501/Nollie.app/Contents/Helpers/Nollie Runtime.app", bundles: [:]).0.check() == .gone)
        #expect(presence(now: nil, bundles: [:]).0.check() == .gone)
        #expect(presence(now: moved, bundles: [moved: id]).0.check() == .moved(moved))
        // A newer copy in its place while this one went to the Trash: an update, not a removal.
        #expect(presence(now: trashed, bundles: [installed: id, trashed: id]).0.check() == .replaced)
        #expect(presence(now: nil, bundles: [installed: id]).0.check() == .replaced)
        // Something else in its place is not Nollie.
        #expect(presence(now: trashed, bundles: [installed: "com.example.other"]).0.check() == .gone)
        #expect(presence(now: moved, bundles: [moved: "com.example.other"]).0.check() == .gone)
    }

    @Test func aFolderNamedLikeATrashOnlyCountsAsAWholeName() {
        #expect(AppPresence.isInTrash("/Users/me/.Trash/Nollie.app"))
        #expect(AppPresence.isInTrash("/Volumes/X/.Trashes/501/Nollie.app"))
        #expect(!AppPresence.isInTrash("/Users/me/My.Trash.Things/Nollie.app"))
        #expect(!AppPresence.isInTrash("/Applications/Nollie.app"))
    }

    /// Records each wait instead of waiting, and changes the disk when told to.
    final class FakeClock: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var waits: [Duration] = []
        var onWait: (Int) -> Void = { _ in }
        func sleep(_ duration: Duration) throws {
            lock.lock(); waits.append(duration); let count = waits.count; lock.unlock()
            onWait(count)
            if count > 50 { throw CancellationError() }
        }
    }

    @Test func theWatcherActsOnlyOnceASecondLookAgrees() async {
        let (watched, disk) = presence(now: Self.installed, bundles: [Self.installed: Self.id])
        let clock = FakeClock()
        let trashed = "/Users/me/.Trash/Nollie.app/Contents/Helpers/Nollie Runtime.app"
        clock.onWait = { count in
            // Present for two rounds, then in the Trash.
            if count == 2 { disk.set(now: trashed, bundles: [trashed: Self.id]) }
        }
        let verdict = await watched.watch(every: .seconds(45), confirmAfter: .seconds(5)) { try clock.sleep($0) }
        #expect(verdict == .gone)
        #expect(clock.waits == [.seconds(45), .seconds(45), .seconds(5)])
    }

    @Test func aSwapInPlaceThatSettlesIsNotARemoval() async {
        let (watched, disk) = presence(now: nil, bundles: [:])
        let clock = FakeClock()
        clock.onWait = { count in
            // Gone for a moment while a copy is put back, then present until the watch is cancelled.
            if count == 1 { disk.set(now: Self.installed, bundles: [Self.installed: Self.id]) }
        }
        let verdict = await watched.watch(every: .seconds(45), confirmAfter: .seconds(5)) { try clock.sleep($0) }
        #expect(verdict == nil)
        #expect(clock.waits.first == .seconds(5))
        #expect(clock.waits.dropFirst().allSatisfy { $0 == .seconds(45) })
    }

    @Test func theRealDescriptorFollowsTheBundleIntoTheTrash() throws {
        let fm = FileManager.default
        let base = try #require(realpath(fm.temporaryDirectory.path, nil))
        let root = URL(fileURLWithPath: String(cString: base)).appendingPathComponent("presence-" + UUID().uuidString)
        free(base)
        defer { try? fm.removeItem(at: root) }
        let app = root.appendingPathComponent("Applications/Nollie.app")
        let helper = app.appendingPathComponent("Contents/Helpers/Nollie Runtime.app")
        func make(_ bundle: URL, id: String) throws {
            try fm.createDirectory(at: bundle.appendingPathComponent("Contents"), withIntermediateDirectories: true)
            let plist = try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": id], format: .xml, options: 0)
            try plist.write(to: bundle.appendingPathComponent("Contents/Info.plist"))
        }
        try make(app, id: "com.coreykozarski.nollie")
        try make(helper, id: Self.id)
        let probe = try #require(OpenBundleProbe(helper))
        let installed = try #require(probe.currentPath())
        let watched = AppPresence(installedPath: installed, bundleIdentifier: Self.id, probe: probe)
        #expect(watched.check() == .present)

        let desktop = root.appendingPathComponent("Desktop/Nollie.app")
        try fm.createDirectory(at: desktop.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.moveItem(at: app, to: desktop)
        #expect(watched.check() == .moved(desktop.appendingPathComponent("Contents/Helpers/Nollie Runtime.app").path))

        let trash = root.appendingPathComponent(".Trash/Nollie.app")
        try fm.createDirectory(at: trash.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.moveItem(at: desktop, to: trash)
        #expect(watched.check() == .gone)

        // A new copy installed where the old one was, while the old one sits in the Trash.
        try make(app, id: "com.coreykozarski.nollie")
        try make(helper, id: Self.id)
        #expect(watched.check() == .replaced)

        try fm.removeItem(at: app)
        try fm.removeItem(at: trash)
        #expect(probe.currentPath() == nil)
        #expect(watched.check() == .gone)
    }
}
#endif
