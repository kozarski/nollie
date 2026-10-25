import CryptoKit
import Foundation

/// The companion files this build ships (Apps/Nollie/Resources/hermes-push), and the little
/// bits of arithmetic done on them.
enum CompanionBundle {
    struct File {
        var name: String
        var data: Data
        var mime: String
    }

    private static func find(_ name: String, _ ext: String, in folder: String) -> URL? {
        Bundle.main.url(forResource: name, withExtension: ext, subdirectory: folder) ?? Bundle.main.url(forResource: name, withExtension: ext)
    }

    private static func read(_ name: String, _ ext: String, in folder: String, mime: String) -> File? {
        guard let url = find(name, ext, in: folder), let data = try? Data(contentsOf: url) else { return nil }
        return File(name: "\(name).\(ext)", data: data, mime: mime)
    }

    static var script: File? { read("hermes_push", "py", in: "hermes-push", mime: "text/x-python") }
    static var installer: File? { read("install", "sh", in: "hermes-push", mime: "text/x-shellscript") }

    /// The three files of the Hermes plugin, or nil if any is missing from the build.
    static var pluginFiles: [File]? {
        guard let script,
              let manifest = read("plugin", "yaml", in: "hermes-push/plugin", mime: "text/yaml"),
              let entry = read("__init__", "py", in: "hermes-push/plugin", mime: "text/x-python") else { return nil }
        return [script, manifest, entry]
    }

    static let scriptSize: Int = script?.data.count ?? 0

    static let scriptSHA256: String = script.map { sha256($0.data) } ?? ""

    /// The version named in plugin.yaml.
    static let pluginVersion: String = {
        guard let text = read("plugin", "yaml", in: "hermes-push/plugin", mime: "")
            .flatMap({ String(data: $0.data, encoding: .utf8) }),
              let found = text.firstMatch(of: /version: "([^"]+)"/) else { return "?" }
        return String(found.1)
    }()

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Whether a plugin's version is at least `minimum` (dotted numbers).
    static func version(_ text: String, atLeast minimum: [Int]) -> Bool {
        let parts = text.split(separator: ".").compactMap { Int($0) }
        for i in 0..<max(parts.count, minimum.count) {
            let a = i < parts.count ? parts[i] : 0, b = i < minimum.count ? minimum[i] : 0
            if a != b { return a > b }
        }
        return true
    }
}
