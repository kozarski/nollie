import CryptoKit
import Foundation

/// The signed app contains the complete companion. Loading a plan never installs it.
enum PairingCompanionPackage {
    static let pluginID = "nollie-pairing"
    static let version = "0.1.0"
    static let paths = ["__init__.py", "provider.py", "plugin.yaml", "dashboard/manifest.json", "dashboard/plugin_api.py", "dashboard/index.js"]

    struct File: Sendable {
        let relativePath: String
        let data: Data
        let sha256: String
        var mimeType: String {
            if relativePath.hasSuffix(".py") { return "text/x-python" }
            if relativePath.hasSuffix(".json") { return "application/json" }
            if relativePath.hasSuffix(".js") { return "text/javascript" }
            return "text/yaml"
        }
    }

    struct Plan: Sendable {
        let files: [File]
        var totalBytes: Int { files.reduce(0) { $0 + $1.data.count } }
        var pluginRelativeDirectory: String { "plugins/" + pluginID }
        var enableAPIPath: String { "/api/dashboard/agent-plugins/" + pluginID + "/enable" }
    }

    enum Failure: LocalizedError {
        case unavailable
        var errorDescription: String? { String(localized: "The pairing companion is missing or incomplete in this build.") }
    }

    static func load(bundle: Bundle = .main) throws -> Plan {
        guard let root = bundle.url(forResource: pluginID, withExtension: "bundle") else { throw Failure.unavailable }
        return try load(directory: root)
    }

    static func load(directory: URL) throws -> Plan {
        struct Manifest: Decodable {
            struct Entry: Decodable { let path: String; let bytes: Int; let sha256: String }
            let schema: Int
            let plugin: String
            let version: String
            let files: [Entry]
        }
        do {
            let root = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard root.isDirectory == true, root.isSymbolicLink != true else { throw Failure.unavailable }
            let manifestData = try read(directory.appendingPathComponent("package.json"), maximum: 16_384)
            let manifest = try JSONDecoder().decode(Manifest.self, from: manifestData)
            guard manifest.schema == 1, manifest.plugin == pluginID, manifest.version == version,
                  manifest.files.count == paths.count, Set(manifest.files.map(\.path)) == Set(paths) else { throw Failure.unavailable }
            let dashboard = try directory.appendingPathComponent("dashboard").resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard dashboard.isDirectory == true, dashboard.isSymbolicLink != true else { throw Failure.unavailable }
            let files = try paths.map { path -> File in
                guard let entry = manifest.files.first(where: { $0.path == path }), (1...524_288).contains(entry.bytes) else { throw Failure.unavailable }
                let data = try read(directory.appendingPathComponent(path), maximum: 524_288)
                let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
                guard data.count == entry.bytes, digest == entry.sha256 else { throw Failure.unavailable }
                return File(relativePath: path, data: data, sha256: digest)
            }
            return Plan(files: files)
        } catch { throw Failure.unavailable }
    }

    private static func read(_ url: URL, maximum: Int) throws -> Data {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              let size = values.fileSize, size > 0, size <= maximum else { throw Failure.unavailable }
        let data = try Data(contentsOf: url)
        guard data.count <= maximum else { throw Failure.unavailable }
        return data
    }
}
