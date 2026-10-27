#if os(macOS)
import Darwin
import Foundation

/// What the Direct Mac edition carries for a managed setup, beside the pinned downloads:
/// Nollie's reviewed changes to the pinned Hermes source, and Nollie's own add-ons.
/// Both are copied into the app at build time (Tools/runtime-helper/embed-setup-kit.sh) and
/// checked here by SHA-256 before anything is written into an installation.
enum NativeSetupKit {
    static var root: URL? { Bundle.main.resourceURL?.appendingPathComponent("Setup Kit", isDirectory: true) }

    static func failure(_ message: String) -> ConfigurationBackup.Failure { .init(message) }
    static let missing = String(localized: "This copy of Nollie is missing some of its setup files. Reinstall Nollie, then try again.")

    /// A plain relative path: no root, no "." or "..", no empty parts, nothing unusual.
    static func isSafeRelativePath(_ path: String) -> Bool {
        guard !path.isEmpty, path.utf8.count < 512, !path.hasPrefix("/"), !path.contains("\\") else { return false }
        guard !path.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7f }) else { return false }
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        return !parts.contains { $0.isEmpty || $0 == "." || $0 == ".." }
    }

    // MARK: Hermes overlay

    struct Overlay: Sendable {
        struct Entry: Decodable, Sendable {
            let path: String
            let before: String?
            let after: String
            let bytes: Int
        }
        private struct Manifest: Decodable {
            let schema: Int
            let files: [Entry]
        }
        let files: URL
        let entries: [Entry]

        init(directory: URL, expectedDigest: String) throws {
            guard let manifest = try? OwnedSetupFiles.read(directory.appendingPathComponent("overlay.json"), maximum: 1_000_000),
                  OwnedSetupFiles.hash(manifest) == expectedDigest,
                  let decoded = try? JSONDecoder().decode(Manifest.self, from: manifest), decoded.schema == 1,
                  !decoded.files.isEmpty, decoded.files.count < 1_000,
                  decoded.files.allSatisfy({ NativeSetupKit.isSafeRelativePath($0.path) && $0.bytes > 0 && $0.bytes < 16_000_000 })
            else { throw NativeSetupKit.failure(NativeSetupKit.missing) }
            files = directory.appendingPathComponent("files", isDirectory: true)
            entries = decoded.files
        }

        /// Writes each reviewed file into a freshly unpacked, not yet published source tree.
        /// An original that differs from the reviewed one stops everything: the tree is then left
        /// unpublished, and no receipt is written.
        func apply(to staging: URL) throws {
            for entry in entries {
                let data = try OwnedSetupFiles.read(files.appendingPathComponent(entry.path), maximum: entry.bytes)
                guard data.count == entry.bytes, OwnedSetupFiles.hash(data) == entry.after else {
                    throw NativeSetupKit.failure(NativeSetupKit.missing)
                }
                let target = staging.appendingPathComponent(entry.path)
                let parent = try OwnedSetupFiles.directory(target.deletingLastPathComponent())
                defer { close(parent) }
                var info = stat()
                let exists = fstatat(parent, target.lastPathComponent, &info, AT_SYMLINK_NOFOLLOW) == 0
                if let before = entry.before {
                    guard exists, (info.st_mode & S_IFMT) == S_IFREG,
                          OwnedSetupFiles.hash(try OwnedSetupFiles.read(target, maximum: 16_000_000)) == before else {
                        throw NativeSetupKit.failure(String(localized: "This Hermes download doesn't match the version Nollie was tested with. Nothing was installed."))
                    }
                } else if exists {
                    throw NativeSetupKit.failure(String(localized: "This Hermes download doesn't match the version Nollie was tested with. Nothing was installed."))
                }
                let temporary = target.deletingLastPathComponent().appendingPathComponent(".nollie-" + UUID().uuidString)
                try OwnedSetupFiles.writeNew(data, to: temporary)
                guard renameat(parent, temporary.lastPathComponent, parent, target.lastPathComponent) == 0 else {
                    _ = unlinkat(parent, temporary.lastPathComponent, 0)
                    throw NativeSetupKit.failure(String(localized: "A reviewed Hermes change could not be written. Nothing was installed."))
                }
                guard OwnedSetupFiles.hash(try OwnedSetupFiles.read(target, maximum: entry.bytes)) == entry.after else {
                    throw NativeSetupKit.failure(String(localized: "A reviewed Hermes change did not verify. Nothing was installed."))
                }
            }
        }
    }

    static func hermesOverlay() throws -> Overlay {
        guard let root else { throw failure(missing) }
        return try Overlay(directory: root.appendingPathComponent("hermes-overlay", isDirectory: true),
                           expectedDigest: NativeSetupPlan.hermesOverlayDigest)
    }

    // MARK: Add-ons

    struct File: Decodable, Equatable, Sendable {
        let path: String
        let sha256: String
        let bytes: Int
    }

    struct AddOns: Sendable {
        let root: URL
        /// SHA-256 of the kit's own list: changes whenever any carried add-on file changes.
        let digest: String
        let installer: URL
        let names: [String]
        /// Every file the installer leaves in the Hermes home, relative to it.
        let installedFiles: [File]
    }

    private struct Kit: Decodable {
        struct Item: Decodable {
            let name: String
            let version: String
            let files: [File]
        }
        let schema: Int
        let installer: File
        let readerLock: File
        let items: [Item]
    }

    /// The reader's environment records which lockfile built it, so a new lock means a rebuild.
    static let readerMarker = "nollie-reader/venv/nollie-lock.sha256"

    static func addOns(at directory: URL? = root?.appendingPathComponent("add-ons", isDirectory: true)) throws -> AddOns {
        guard let directory,
              let data = try? OwnedSetupFiles.read(directory.appendingPathComponent("kit.json"), maximum: 4_000_000),
              let kit = try? JSONDecoder().decode(Kit.self, from: data), kit.schema == 1, !kit.items.isEmpty
        else { throw failure(missing) }
        let names = kit.items.map(\.name)
        guard Set(names).count == names.count,
              names.allSatisfy({ $0.range(of: "^nollie-[a-z]+$", options: .regularExpression) != nil }),
              kit.installer.path == "managed_addons.py",
              kit.readerLock.path == "nollie-reader/requirements.txt",
              kit.items.allSatisfy({ item in
                  !item.files.isEmpty && item.files.allSatisfy {
                      isSafeRelativePath($0.path) && $0.path.hasPrefix(item.name + "/") && $0.bytes >= 0 && $0.sha256.count == 64
                  }
              })
        else { throw failure(missing) }
        // The installer runs, so it is checked before every use, not only when listed.
        let installer = directory.appendingPathComponent(kit.installer.path)
        guard let script = try? OwnedSetupFiles.read(installer, maximum: max(kit.installer.bytes, 1)),
              OwnedSetupFiles.hash(script) == kit.installer.sha256 else { throw failure(missing) }
        var installed = kit.items.flatMap(\.files).map { File(path: "plugins/" + $0.path, sha256: $0.sha256, bytes: $0.bytes) }
        let marker = Data((kit.readerLock.sha256 + "\n").utf8)
        if names.contains("nollie-reader") {
            installed.append(File(path: readerMarker, sha256: OwnedSetupFiles.hash(marker), bytes: marker.count))
        }
        return AddOns(root: directory, digest: OwnedSetupFiles.hash(data), installer: installer, names: names,
                      installedFiles: installed)
    }
}
#endif
