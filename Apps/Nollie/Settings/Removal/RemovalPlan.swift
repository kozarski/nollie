import Foundation
import NollieCore

/// A Hermes whose helpers have computers Nollie made, and the Python that runs its add-on.
struct RemovalHermes: Hashable, Sendable {
    /// The HOME the computer add-on ran with: the person's home, or a managed setup's `user` folder.
    var home: URL
    var python: URL
    /// A managed setup, deleted right after: only its computers need to go, not its settings.
    var managed: Bool
}

/// One thing Remove does. Every step that touches a file names it, and `RemovalPlan.permits` decides
/// again, just before it runs, whether that file is Nollie's to touch.
enum RemovalStep: Hashable, Sendable {
    /// Nollie Runtime stops Hermes, Cua's background part and the Link door, and forgets its keys.
    case stopRuntime
    case unregisterRuntime
    case unregisterNotifications
    /// Puts each helper's settings back and deletes the computers Nollie made for them.
    case releaseComputers(RemovalHermes)
    /// The old notification relay's launchd job, then its plist.
    case stopPushService(URL)
    /// Nollie's own add-on or its folder in a person's Hermes: to the Trash, never deleted outright.
    case trash(URL)
    /// Takes Nollie's add-ons out of a Hermes config's plugin lists, after a dated copy.
    case tidyConfig(URL)
    /// A file or folder of Nollie's own, deleted.
    case delete(URL)
    case deleteIfEmpty(URL)
    case forgetKeychain(String)
    case clearSettings
    case deleteCloudData
    case trashApp(URL)

    /// The file a step touches, if any.
    var url: URL? {
        switch self {
        case .stopPushService(let u), .trash(let u), .tidyConfig(let u), .delete(let u), .deleteIfEmpty(let u), .trashApp(let u): u
        case .releaseComputers(let h): h.home
        default: nil
        }
    }
}

/// One line on the Remove sheet: a plain sentence and the steps behind it.
struct RemovalPart: Identifiable, Equatable, Sendable {
    enum Kind: String, Sendable { case computers, background, hermes, cua, setup, files, keychain, cloud, app }
    var kind: Kind
    var title: String
    var detail: String?
    var steps: [RemovalStep]
    var id: Kind { kind }

    var symbol: String {
        switch kind {
        case .computers: "desktopcomputer"
        case .background: "stop.circle"
        case .hermes: "puzzlepiece.extension"
        case .cua: "shippingbox"
        case .setup: "person.crop.circle"
        case .files: "folder"
        case .keychain: "key"
        case .cloud: "icloud"
        case .app: "trash"
        }
    }
}

/// What Remove will do on this device, built from what is on disk. Pure apart from reading: building
/// it changes nothing. Things deliberately left are listed in `kept`, in plain words.
struct RemovalPlan: Equatable, Sendable {
    var parts: [RemovalPart]
    var kept: [String]
    var steps: [RemovalStep] { parts.flatMap(\.steps) }

    struct Options: Equatable, Sendable {
        var includeCloud = false
        /// A reinstalled Nollie removing what an earlier copy left: the app stays and doesn't quit.
        var keepApp = false
    }

    /// Nollie's own add-ons, by the names they install under.
    static let addOnNames: Set<String> = ["nollie-computer", "nollie-crew", "nollie-mac", "nollie-pairing", "nollie-reader",
                                          "nollie-workflow", "nollie-push"]
    /// Folders Nollie's add-ons keep beside Hermes's own in a Hermes home.
    static let addOnFolders: Set<String> = ["nollie-computer", "nollie-crew", "nollie-pairing", "nollie-workflow"]
    static let keychainServices = [".gateways", ".remembered", ".signins"]
    static let cuaApp = "Cua Spaces.app"

    // MARK: Building

    static func build(_ places: RemovalPlaces, options: Options = .init(), defaults: UserDefaults = .standard) -> RemovalPlan {
        var parts: [RemovalPart] = []
        var kept: [String] = []
        let layout = places.nollie
        let direct = places.edition == .macDirect
        let rootUsable = Disk.isPlainFolder(layout.root) && Disk.unlinked(layout.root.deletingLastPathComponent(), below: places.home)
        if Disk.exists(layout.root), !rootUsable {
            kept.append(String(localized: "Nollie's folder is a link, so Nollie left it and what it points to alone.",
                               comment: "Safety: Remove Nollie, what stays; keep exact meaning"))
        }
        let setups = rootUsable ? ownedSetups(layout) : (owned: [], unknown: [])

        if direct {
            // Helpers' computers first, while Hermes, Cua and the add-on are all still here.
            var homes: [RemovalHermes] = []
            for setup in setups.owned {
                let user = setup.appendingPathComponent("user", isDirectory: true)
                let python = setup.appendingPathComponent("environment/bin/python")
                if hasComputerRecords(user), Disk.isExecutable(python) { homes.append(.init(home: user, python: python, managed: true)) }
            }
            if Disk.isPlainFolder(places.hermes), hasComputerRecords(places.home) {
                if let python = hermesPython(places) {
                    homes.append(.init(home: places.home, python: python, managed: false))
                } else {
                    kept.append(String(localized: "Nollie couldn't find your Hermes's Python, so your helpers' own computers stay on. Turn each one off in Bot settings, then remove Nollie.",
                                       comment: "Safety: Remove Nollie, what stays; keep exact meaning"))
                }
            }
            if !homes.isEmpty {
                parts.append(.init(kind: .computers,
                                   title: String(localized: "Turn off your helpers' own computers and delete them", comment: "Safety: Remove Nollie, what goes; keep exact meaning"),
                                   detail: nil, steps: homes.map { .releaseComputers($0) }))
            }
            parts.append(.init(kind: .background, title: String(localized: "Stop Nollie Runtime and Nollie Notifications", comment: "Safety: Remove Nollie, what goes; keep exact meaning"),
                               detail: String(localized: "Your assistant on this Mac stops first.", comment: "Safety: Remove Nollie, what goes; keep exact meaning"),
                               steps: [.stopRuntime, .unregisterRuntime, .unregisterNotifications]))
            let hermes = hermesItems(places, kept: &kept)
            if !hermes.isEmpty {
                parts.append(.init(kind: .hermes, title: String(localized: "Take Nollie's add-ons out of your Hermes", comment: "Safety: Remove Nollie, what goes; keep exact meaning"),
                                   detail: String(localized: "Your bots, chats and memory stay. The add-ons go to the Trash.", comment: "Safety: Remove Nollie, what goes; keep exact meaning"),
                                   steps: hermes))
            }
            #if os(macOS)
            parts += cuaPart(places, kept: &kept)
            #endif
        }

        if !setups.owned.isEmpty {
            parts.append(.init(kind: .setup, title: String(localized: "Delete the assistant Nollie set up on this Mac", comment: "Safety: Remove Nollie, what goes; keep exact meaning"),
                               detail: String(localized: "With its chats, memory and settings.", comment: "Safety: Remove Nollie, what goes; keep exact meaning"),
                               steps: setups.owned.map { .delete($0) }))
        }
        if !setups.unknown.isEmpty {
            kept.append(String(localized: "A folder in Nollie's setups that Nollie didn't make stays where it is.", comment: "Safety: Remove Nollie, what stays; keep exact meaning"))
        }

        var files: [RemovalStep] = []
        if rootUsable {
            let names = (try? FileManager.default.contentsOfDirectory(atPath: layout.root.path)) ?? []
            for name in names.sorted() where name != ".DS_Store" {
                let item = layout.root.appendingPathComponent(name)
                if name == "Setups" || (name == "Cua" && parts.contains { $0.kind == .cua }) { continue }
                if NolliePaths.Layout.knownChildren.contains(name) {
                    if Disk.isLink(item) { kept.append(String(localized: "\(name) in Nollie's folder is a link, so Nollie left it alone.", comment: "Safety: Remove Nollie, what stays; the placeholder is a file or folder name; keep exact meaning")) }
                    else { files.append(.delete(item)) }
                } else {
                    kept.append(String(localized: "\(name) in Nollie's folder isn't something Nollie made, so it stays.", comment: "Safety: Remove Nollie, what stays; the placeholder is a file or folder name; keep exact meaning"))
                }
            }
            files.append(.deleteIfEmpty(layout.setups))
            files.append(.deleteIfEmpty(layout.root))
        }
        if layout.caches != layout.root.appendingPathComponent("Caches", isDirectory: true) {
            // The contained edition keeps caches in its container's own caches folder.
            files += [layout.transcripts, layout.media, layout.webImages].filter { Disk.exists($0) && !Disk.isLink($0) }.map { .delete($0) }
        }
        if direct {
            files += places.systemFolders.filter { Disk.exists($0) && !Disk.isLink($0) }.map { .delete($0) }
        }
        files.append(.clearSettings)
        parts.append(.init(kind: .files,
                           title: direct ? String(localized: "Delete Nollie's folder and settings on this Mac", comment: "Safety: Remove Nollie, what goes; keep exact meaning")
                               : String(localized: "Delete Nollie's chats, pictures and settings here", comment: "Safety: Remove Nollie, what goes; keep exact meaning"),
                           detail: direct ? String(localized: "Its caches, logs and records, in ~/Library/Application Support/Nollie.", comment: "Safety: Remove Nollie, what goes; keep exact meaning") : nil,
                           steps: files))

        parts.append(.init(kind: .keychain, title: String(localized: "Delete Nollie's connections and saved sign-ins from the keychain", comment: "Safety: Remove Nollie, what goes; keep exact meaning"),
                           detail: nil,
                           steps: keychainServices.map { .forgetKeychain(Keychain.baseBundleID + $0) }))
        if options.includeCloud {
            parts.append(.init(kind: .cloud, title: String(localized: "Delete Nollie's alerts in iCloud", comment: "Safety: Remove Nollie, what goes; keep exact meaning"), detail: nil,
                               steps: [.deleteCloudData]))
        }
        if direct, !options.keepApp, let app = places.app {
            parts.append(.init(kind: .app, title: String(localized: "Move Nollie to the Trash and quit", comment: "Safety: Remove Nollie, what goes; keep exact meaning"), detail: nil,
                               steps: [.trashApp(app)]))
        }
        return RemovalPlan(parts: parts, kept: kept)
    }

    /// Managed setups that carry Nollie's ownership record, and anything else in the setups folder.
    static func ownedSetups(_ layout: NolliePaths.Layout) -> (owned: [URL], unknown: [URL]) {
        guard Disk.isPlainFolder(layout.setups) else { return ([], Disk.exists(layout.setups) ? [layout.setups] : []) }
        var owned: [URL] = [], unknown: [URL] = []
        for name in ((try? FileManager.default.contentsOfDirectory(atPath: layout.setups.path)) ?? []).sorted() where name != ".DS_Store" {
            let folder = layout.setups.appendingPathComponent(name, isDirectory: true)
            if isOwnedSetup(folder) { owned.append(folder) } else { unknown.append(folder) }
        }
        return (owned, unknown)
    }

    /// A real folder named by a UUID, holding a regular `ownership.json` that names Nollie and that UUID.
    static func isOwnedSetup(_ folder: URL) -> Bool {
        let name = folder.lastPathComponent
        guard UUID(uuidString: name) != nil, name.count == 36, Disk.isPlainFolder(folder),
              let data = Disk.readSmallFile(folder.appendingPathComponent("ownership.json"), maximum: 4096),
              let owner = try? JSONDecoder().decode([String: String].self, from: data) else { return false }
        return owner["owner"] == AppIdentity.bundleID && owner["installationID"]?.uppercased() == name.uppercased()
    }

    private static func hasComputerRecords(_ home: URL) -> Bool {
        let folder = home.appendingPathComponent(".hermes/nollie-computer", isDirectory: true)
        return ["own-computers.json", "owned-spaces.json"].contains { Disk.isRegularFile(folder.appendingPathComponent($0)) }
    }

    static func hermesPythonCandidates(_ places: RemovalPlaces) -> [URL] {
        ["hermes-agent/venv/bin/python", "hermes-agent/.venv/bin/python"].map { places.hermes.appendingPathComponent($0) }
    }

    private static func hermesPython(_ places: RemovalPlaces) -> URL? {
        hermesPythonCandidates(places).first { Disk.isExecutable($0) }
    }

    /// Nollie's items in a person's own Hermes (`~/.hermes`). Nothing else in it is ever listed.
    private static func hermesItems(_ places: RemovalPlaces, kept: inout [String]) -> [RemovalStep] {
        let hermes = places.hermes
        if Disk.isLink(hermes) {
            kept.append(String(localized: "Your Hermes folder is a link, so Nollie left its add-ons there. You can remove them in Hermes.",
                               comment: "Safety: Remove Nollie, what stays; keep exact meaning"))
            return []
        }
        guard Disk.isPlainFolder(hermes) else { return [] }
        var steps: [RemovalStep] = []
        var linked = false
        func consider(_ url: URL) {
            guard Disk.exists(url) else { return }
            if Disk.isLink(url) || !Disk.unlinked(url.deletingLastPathComponent(), below: places.home) { linked = true; return }
            steps.append(.trash(url))
        }
        for name in addOnNames.sorted() { consider(hermes.appendingPathComponent("plugins/\(name)", isDirectory: true)) }
        var configs = [hermes.appendingPathComponent("config.yaml")]
        let profiles = hermes.appendingPathComponent("profiles", isDirectory: true)
        if Disk.isPlainFolder(profiles) {
            for profile in ((try? FileManager.default.contentsOfDirectory(atPath: profiles.path)) ?? []).sorted() where isProfileName(profile) {
                let folder = profiles.appendingPathComponent(profile, isDirectory: true)
                guard Disk.isPlainFolder(folder) else { continue }
                for name in addOnNames.sorted() { consider(folder.appendingPathComponent("plugins/\(name)", isDirectory: true)) }
                configs.append(folder.appendingPathComponent("config.yaml"))
            }
        }
        for name in addOnFolders.sorted() { consider(hermes.appendingPathComponent(name, isDirectory: true)) }
        let push = hermes.appendingPathComponent("push", isDirectory: true)
        if Disk.isRegularFile(push.appendingPathComponent("hermes_push.py")) { consider(push) }
        let backups = hermes.appendingPathComponent("plugin-backups", isDirectory: true)
        if Disk.isPlainFolder(backups) {
            for name in ((try? FileManager.default.contentsOfDirectory(atPath: backups.path)) ?? []).sorted()
            where addOnNames.contains(where: { name.hasPrefix($0 + "-") }) {
                consider(backups.appendingPathComponent(name, isDirectory: true))
            }
        }
        for config in configs where Disk.isRegularFile(config) && Disk.unlinked(config.deletingLastPathComponent(), below: places.home) {
            if let data = Disk.readSmallFile(config, maximum: 1_000_000), let text = String(data: data, encoding: .utf8),
               HermesPluginList.removing(addOnNames, from: text) != nil {
                steps.append(.tidyConfig(config))
            }
        }
        if Disk.isRegularFile(places.pushAgent) { steps.insert(.stopPushService(places.pushAgent), at: 0) }
        if linked { kept.append(String(localized: "Some of Nollie's add-ons in your Hermes are links, so Nollie left them alone.", comment: "Safety: Remove Nollie, what stays; keep exact meaning")) }
        return steps
    }

    static func isProfileName(_ name: String) -> Bool {
        name.range(of: "^[a-z0-9][a-z0-9_-]{0,63}$", options: .regularExpression) != nil
    }

    #if os(macOS)
    /// Cua: Nollie's own copy goes with Nollie's folder, and `~/.cua` only when Nollie's install made it.
    /// A Cua the person installed in Applications is never touched.
    private static func cuaPart(_ places: RemovalPlaces, kept: inout [String]) -> [RemovalPart] {
        var parts: [RemovalPart] = []
        if let receipt = cuaReceipt(places) {
            var steps: [RemovalStep] = []
            if Disk.isPlainFolder(places.nollie.cua) { steps.append(.delete(places.nollie.cua)) }
            if receipt.madeCuaHome, Disk.isPlainFolder(places.cuaHome) { steps.append(.delete(places.cuaHome)) }
            if !steps.isEmpty {
                parts.append(.init(kind: .cua, title: String(localized: "Remove Cua, which Nollie set up", comment: "Safety: Remove Nollie, what goes; keep exact meaning"),
                                   detail: String(localized: "With your helpers' computers and Cua's settings.", comment: "Safety: Remove Nollie, what goes; keep exact meaning"), steps: steps))
            }
        }
        let theirs = NollieCuaPlaces.folders(home: places.home, own: places.nollie.cua).dropLast()
            .map { $0.appendingPathComponent(cuaApp) }.filter(Disk.exists)
        if !theirs.isEmpty {
            kept.append(String(localized: "Cua stays in Applications, because you installed it yourself.", comment: "Safety: Remove Nollie, what stays; keep exact meaning"))
        }
        return parts
    }

    /// The record Nollie Runtime writes only when it installed Cua itself, into Nollie's folder.
    static func cuaReceipt(_ places: RemovalPlaces) -> NollieCuaReceipt? {
        guard rootIsSafe(places), Disk.unlinked(places.nollie.cuaSetup, below: places.nollie.root),
              let data = Disk.readSmallFile(places.nollie.cuaSetup.appendingPathComponent(NollieCuaReceipt.fileName), maximum: 4096),
              let receipt = try? JSONDecoder().decode(NollieCuaReceipt.self, from: data), receipt.version == 1,
              URL(fileURLWithPath: receipt.app).standardizedFileURL == places.nollie.cua.appendingPathComponent(cuaApp).standardizedFileURL
        else { return nil }
        return receipt
    }
    #endif

    // MARK: Checking each step

    /// Whether a step may touch what it names. Checked when the plan is built and again right before
    /// each step runs: only Nollie's own folder, the folders macOS keeps under Nollie's bundle ID,
    /// Nollie's named items in a person's Hermes, `~/.cua` when Nollie's own install made it, and
    /// this app. Never a path through a link, never a person's own Hermes data.
    static func permits(_ step: RemovalStep, in places: RemovalPlaces) -> Bool {
        let layout = places.nollie
        switch step {
        case .stopRuntime, .unregisterRuntime, .unregisterNotifications, .clearSettings, .deleteCloudData:
            return true
        case .forgetKeychain(let service):
            return keychainServices.contains { service == Keychain.baseBundleID + $0 }
        case .delete(let url):
            guard plain(url), !Disk.isLink(url) else { return false }
            let parent = url.deletingLastPathComponent().standardizedFileURL
            if parent == layout.root.standardizedFileURL, rootIsSafe(places) {
                return NolliePaths.Layout.knownChildren.subtracting(["Setups"]).contains(url.lastPathComponent)
            }
            if parent == layout.setups.standardizedFileURL, rootIsSafe(places), Disk.isPlainFolder(layout.setups) {
                return isOwnedSetup(url)
            }
            if [layout.transcripts, layout.media, layout.webImages].map(\.standardizedFileURL).contains(url.standardizedFileURL),
               !layout.caches.path.hasPrefix(layout.root.path + "/") {
                return Disk.unlinked(url.deletingLastPathComponent(), below: places.library)
            }
            if places.edition == .macDirect, places.systemFolders.map(\.standardizedFileURL).contains(url.standardizedFileURL) {
                return Disk.unlinked(url.deletingLastPathComponent(), below: places.library)
            }
            #if os(macOS)
            if places.edition == .macDirect, url.standardizedFileURL == places.cuaHome.standardizedFileURL {
                return cuaReceipt(places)?.madeCuaHome == true
            }
            #endif
            return false
        case .deleteIfEmpty(let url):
            return plain(url) && rootIsSafe(places) && [layout.root, layout.setups].map(\.standardizedFileURL).contains(url.standardizedFileURL)
        case .trash(let url):
            return places.edition == .macDirect && plain(url) && !Disk.isLink(url) && isNollieItemInHermes(url, places)
        case .tidyConfig(let url):
            guard places.edition == .macDirect, plain(url), !Disk.isLink(url), url.lastPathComponent == "config.yaml" else { return false }
            let folder = url.deletingLastPathComponent().standardizedFileURL
            let hermes = places.hermes.standardizedFileURL
            let inProfile = folder.deletingLastPathComponent() == hermes.appendingPathComponent("profiles").standardizedFileURL
                && isProfileName(folder.lastPathComponent)
            return (folder == hermes || inProfile) && Disk.unlinked(folder, below: places.home)
        case .stopPushService(let url):
            return places.edition == .macDirect && plain(url) && !Disk.isLink(url)
                && url.standardizedFileURL == places.pushAgent.standardizedFileURL && Disk.unlinked(url.deletingLastPathComponent(), below: places.home)
        case .releaseComputers(let hermes):
            guard places.edition == .macDirect, plain(hermes.home), plain(hermes.python) else { return false }
            if hermes.managed {
                let setup = hermes.home.deletingLastPathComponent()
                return hermes.home.lastPathComponent == "user" && setup.deletingLastPathComponent().standardizedFileURL == layout.setups.standardizedFileURL
                    && rootIsSafe(places) && isOwnedSetup(setup)
                    && hermes.python.standardizedFileURL == setup.appendingPathComponent("environment/bin/python").standardizedFileURL
            }
            return hermes.home.standardizedFileURL == places.home.standardizedFileURL
                && hermesPythonCandidates(places).map(\.standardizedFileURL).contains(hermes.python.standardizedFileURL)
                && Disk.unlinked(places.hermes, below: places.home)
        case .trashApp(let url):
            guard places.edition == .macDirect, plain(url), url.pathExtension == "app",
                  url.standardizedFileURL == places.app?.standardizedFileURL else { return false }
            let plist = url.appendingPathComponent("Contents/Info.plist")
            guard let data = Disk.readSmallFile(plist, maximum: 1_000_000),
                  let values = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return false }
            return values["CFBundleIdentifier"] as? String == places.bundleID
        }
    }

    /// An absolute file path with no `.` or `..` parts.
    private static func plain(_ url: URL) -> Bool {
        url.isFileURL && url.path.hasPrefix("/") && !url.pathComponents.contains("..") && !url.pathComponents.contains(".")
    }

    private static func rootIsSafe(_ places: RemovalPlaces) -> Bool {
        Disk.isPlainFolder(places.nollie.root) && Disk.unlinked(places.nollie.root.deletingLastPathComponent(), below: places.home)
    }

    private static func isNollieItemInHermes(_ url: URL, _ places: RemovalPlaces) -> Bool {
        let hermes = places.hermes.standardizedFileURL
        let item = url.standardizedFileURL
        let name = item.lastPathComponent
        let parent = item.deletingLastPathComponent()
        guard Disk.unlinked(parent, below: places.home), Disk.isPlainFolder(places.hermes) else { return false }
        if parent == hermes { return addOnFolders.contains(name) || (name == "push" && Disk.isRegularFile(item.appendingPathComponent("hermes_push.py"))) }
        if parent == hermes.appendingPathComponent("plugins") { return addOnNames.contains(name) }
        if parent == hermes.appendingPathComponent("plugin-backups") { return addOnNames.contains { name.hasPrefix($0 + "-") } }
        let profile = parent.deletingLastPathComponent()
        return parent.lastPathComponent == "plugins" && profile.deletingLastPathComponent() == hermes.appendingPathComponent("profiles")
            && isProfileName(profile.lastPathComponent) && addOnNames.contains(name)
    }
}

/// Reads the disk without following links.
enum Disk {
    private static func info(_ url: URL) -> stat? {
        var value = stat()
        return lstat(url.path, &value) == 0 ? value : nil
    }
    static func exists(_ url: URL) -> Bool { info(url) != nil }
    static func isLink(_ url: URL) -> Bool { info(url).map { ($0.st_mode & S_IFMT) == S_IFLNK } ?? false }
    static func isPlainFolder(_ url: URL) -> Bool { info(url).map { ($0.st_mode & S_IFMT) == S_IFDIR } ?? false }
    static func isRegularFile(_ url: URL) -> Bool { info(url).map { ($0.st_mode & S_IFMT) == S_IFREG } ?? false }
    static func isExecutable(_ url: URL) -> Bool { FileManager.default.isExecutableFile(atPath: url.path) }

    /// No folder from just below `anchor` down to `url` is a link (the anchor itself is trusted).
    static func unlinked(_ url: URL, below anchor: URL) -> Bool {
        let parts = url.standardizedFileURL.pathComponents, base = anchor.standardizedFileURL.pathComponents
        guard parts.count >= base.count, Array(parts.prefix(base.count)) == base else { return false }
        var current = anchor.standardizedFileURL
        for part in parts.dropFirst(base.count) {
            current.appendPathComponent(part)
            if isLink(current) { return false }
        }
        return true
    }

    /// A small regular file, read without following a link.
    static func readSmallFile(_ url: URL, maximum: Int) -> Data? {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var value = stat()
        guard fstat(fd, &value) == 0, (value.st_mode & S_IFMT) == S_IFREG, value.st_size <= maximum else { return nil }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
        return try? handle.read(upToCount: maximum + 1)
    }
}

/// What an earlier Nollie left when it was dragged to the Trash: Nollie Runtime's note, or a managed
/// setup this copy doesn't know about. A reinstalled Nollie offers to use it again or remove it.
struct RemovalLeftovers: Identifiable, Equatable, Sendable {
    /// The setup to use again: the one Nollie Runtime last ran, else the first Nollie made.
    var installationID: UUID
    /// Nollie Runtime noticed the app was gone and left this note.
    var note: URL?
    var id: UUID { installationID }

    static let noteName = "app-gone.json"

    static func find(_ places: RemovalPlaces, selected: String?) -> RemovalLeftovers? {
        guard places.edition == .macDirect, Disk.isPlainFolder(places.nollie.root) else { return nil }
        let note = places.nollie.runtimeService.appendingPathComponent(noteName)
        let hasNote = Disk.isRegularFile(note)
        let owned = RemovalPlan.ownedSetups(places.nollie).owned.compactMap { UUID(uuidString: $0.lastPathComponent) }
        guard !owned.isEmpty else { return nil }
        let known = selected.flatMap(UUID.init(uuidString:)).map(owned.contains) ?? false
        guard hasNote || !known else { return nil }
        // The setup the person last had running, from Nollie Runtime's own record of their yes.
        struct Consent: Decodable { var installationID: UUID }
        let consent = Disk.readSmallFile(places.nollie.runtimeService.appendingPathComponent("enabled.json"), maximum: 4096)
            .flatMap { try? JSONDecoder().decode(Consent.self, from: $0) }?.installationID
        let chosen = consent.flatMap { owned.contains($0) ? $0 : nil } ?? owned[0]
        return RemovalLeftovers(installationID: chosen, note: hasNote ? note : nil)
    }
}
