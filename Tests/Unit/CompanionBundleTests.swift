import Foundation
import Testing
@testable import Nollie
@testable import NollieCore

/// The push companion inside the app must be the one in the repository.
@Suite struct CompanionBundleTests {
    private struct Missing: Error { let path: String }

    private func repoData(_ relative: String) throws -> Data {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<3 { root.deleteLastPathComponent() }
        guard let data = try? Data(contentsOf: root.appendingPathComponent(relative)) else { throw Missing(path: relative) }
        return data
    }

    private func repoText(_ relative: String) throws -> String {
        guard let text = String(data: try repoData(relative), encoding: .utf8) else { throw Missing(path: relative) }
        return text
    }

    private func bundledCopy(of name: String, ext: String) -> URL? {
        let app = Bundle(for: AppModel.self)
        let inFolder = app.url(forResource: name, withExtension: ext, subdirectory: "hermes-push")
        return inFolder ?? app.url(forResource: name, withExtension: ext)
    }

    @Test(arguments: [("hermes_push", "py"), ("install", "sh")])
    func theBundledCopyMatchesTheSource(name: String, ext: String) throws {
        let inApp = try #require(bundledCopy(of: name, ext: ext))
        let inRepo = try repoData("Companions/hermes-push/\(name).\(ext)")
        #expect(try Data(contentsOf: inApp) == inRepo, "\(name).\(ext) is out of date; run Tools/sync-push-companion.sh")
    }

    /// The app shows the plugin and script versions side by side, so they have to agree.
    @MainActor @Test func pluginScriptAndAppReportOneVersion() throws {
        let pluginText = try repoText("Companions/hermes-push/plugin/nollie-push/plugin.yaml")
        let scriptText = try repoText("Companions/hermes-push/hermes_push.py")
        let pluginVersion = try #require(pluginText.firstMatch(of: /version: "([^"]+)"/)?.1)
        let scriptVersion = try #require(scriptText.firstMatch(of: /VERSION = "([^"]+)"/)?.1)
        #expect(pluginVersion == scriptVersion)
        #expect(String(pluginVersion) == PushSetupModel.bundledPluginVersion)
    }

    @Test func relayPayloadsOpenWithTheCompanionsOwnVector() throws {
        // AES-256-GCM with an all-zero key and nonce; the plaintext is {"title":"hi","body":"there"}.
        let key = Data(count: 32).base64EncodedString()
        let sealed = "AAAAAAAAAAAAAAAAtYU0VDkMDkw9bK26mN+/eh0EeugNhF4ctNCQrAgnBvQ6vurB94SMNXCYlKJV"
        let opened = try PushRelay.decrypt(sealed, keyBase64: key)
        #expect(opened["title"]?.stringValue == "hi")
        #expect(opened["body"]?.stringValue == "there")
    }
}
