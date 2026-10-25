import Foundation
import NollieCore

/// Where one removal looks: this device's real folders, or a temporary folder in tests.
struct RemovalPlaces: Equatable, Sendable {
    enum Edition: Equatable, Sendable {
        /// The Direct Mac edition: services, managed setups, Cua, a person's Hermes, the app itself.
        case macDirect
        /// The iPhone and the Mac App Store edition: only what is inside the app's own container.
        case contained
    }

    var edition: Edition
    /// The person's home folder (the app's container in the contained edition).
    var home: URL
    /// `home/Library`.
    var library: URL
    /// Nollie's one folder.
    var nollie: NolliePaths.Layout
    var bundleID: String
    /// This Nollie.app, moved to the Trash last. Nil when the app can't move itself.
    var app: URL?

    var hermes: URL { home.appendingPathComponent(".hermes", isDirectory: true) }
    var cuaHome: URL { home.appendingPathComponent(".cua", isDirectory: true) }
    var pushAgent: URL { library.appendingPathComponent("LaunchAgents/com.coreykozarski.nollie.push.plist") }

    /// Folders macOS makes for any app, named after its bundle ID: URL cache, cookies, web data and
    /// saved windows. They are Nollie's by name, as is its log folder (Hermes's logs are only linked
    /// there, so removing the folder leaves the setup's own files to the setup's removal).
    var systemFolders: [URL] {
        [library.appendingPathComponent("Logs", isDirectory: true).appendingPathComponent("Nollie", isDirectory: true),
         library.appendingPathComponent("Caches", isDirectory: true).appendingPathComponent(bundleID, isDirectory: true),
         library.appendingPathComponent("HTTPStorages", isDirectory: true).appendingPathComponent(bundleID, isDirectory: true),
         library.appendingPathComponent("WebKit", isDirectory: true).appendingPathComponent(bundleID, isDirectory: true),
         library.appendingPathComponent("Saved Application State", isDirectory: true).appendingPathComponent(bundleID + ".savedState", isDirectory: true)]
    }

    static func thisDevice() -> RemovalPlaces {
        let bundleID = Bundle.main.bundleIdentifier ?? AppIdentity.bundleID
        #if os(macOS)
        let home = FileManager.default.homeDirectoryForCurrentUser
        let direct = NativeSetupPlan.directAvailable && !NolliePaths.isSandboxed
        return RemovalPlaces(edition: direct ? .macDirect : .contained, home: home,
                             library: home.appendingPathComponent("Library", isDirectory: true),
                             nollie: NolliePaths.current, bundleID: bundleID,
                             app: direct ? Bundle.main.bundleURL : nil)
        #else
        let home = URL(fileURLWithPath: NSHomeDirectory())
        return RemovalPlaces(edition: .contained, home: home, library: home.appendingPathComponent("Library", isDirectory: true),
                             nollie: NolliePaths.current, bundleID: bundleID, app: nil)
        #endif
    }
}
