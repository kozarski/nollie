import Foundation
import NollieCore

/// "Try a demo": the whole app on made-up bots and chats, with no Mac, no Hermes and no account.
///
/// The demo runs on `DemoGateway`, a gateway inside the app, so every screen uses its normal code.
/// While it lasts the Keychain is in memory and the saved gateways are set aside, nothing is
/// registered for notifications, and the settings are put back on the way out. A demo is never
/// kept: quitting the app ends it, and the next launch starts from the normal state.
extension AppModel {
    var isDemo: Bool { demo != nil }

    /// Starts the demo from the first screen or from anywhere else.
    func startDemo() async {
        guard demo == nil else { return }
        let gateway = DemoGateway()
        await deactivate()
        DemoSession.setSettingsAside()
        var connection = GatewayConnection(name: "Demo", gateway: gateway.address, authMode: .sessionToken)
        connection.connectionKind = "local"
        // Set before the runtime exists, so nothing it starts is wired like a real gateway.
        demo = gateway
        store.beginDemo(connection)
        resetNavigation()
        await activate(connection, backend: gateway.backend)
    }

    /// Ends the demo and brings back what was there: the saved gateways, the settings, the first screen.
    func leaveDemo() async {
        guard let gateway = demo else { return }
        let demoConnection = store.active?.id
        await deactivate()
        await gateway.shutdown()
        if let demoConnection { TranscriptCache.clear(connection: demoConnection) }
        store.endDemo()
        demo = nil
        DemoSession.putSettingsBack()
        resetNavigation()
        await activateSavedConnection()
    }

    #if DEBUG
    /// `-nollie-demo-start` taps Try a demo at launch, for pictures of the demo on the Mac, and
    /// `-nollie-demo-start-chat <bot>` then opens that bot's chat.
    func startDemoIfAsked() {
        let words = ProcessInfo.processInfo.arguments
        guard words.contains("-nollie-demo-start") else { return }
        let bot = words.firstIndex(of: "-nollie-demo-start-chat").flatMap { words.indices.contains($0 + 1) ? words[$0 + 1] : nil }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            await startDemo()
            guard let bot else { return }
            try? await Task.sleep(for: .seconds(3))
            await openMainChat(bot)
        }
    }
    #endif

    private func resetNavigation() {
        selectedTab = .chats
        pendingRoute = nil
        botSheet = nil
        visibleChat = nil
        visibleChatID = nil
        visibleChatRequestedID = nil
        boardChatContext = nil
        boardTaskToReveal = nil
        composeProfile = nil
        composeReturnTab = nil
    }
}

/// The app's settings, set aside while a demo runs so what the demo changes (a bot's look, the
/// last tab) is gone when it ends. They are kept on disk as well, so a demo that was cut short
/// by the app quitting is undone at the next launch.
enum DemoSession {
    private static var file: URL {
        NolliePaths.current.root.appending(component: "DemoSettingsAside.plist", directoryHint: .notDirectory)
    }

    private static var domain: String? { Bundle.main.bundleIdentifier }

    static func setSettingsAside() {
        guard let domain else { return }
        let defaults = UserDefaults.standard
        let kept = defaults.persistentDomain(forName: domain) ?? [:]
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let bytes = try? PropertyListSerialization.data(fromPropertyList: kept, format: .binary, options: 0) {
            try? bytes.write(to: file, options: .atomic)
        }
        // The first screen must not wait on a half-finished setup.
        defaults.removeObject(forKey: OnboardingProgress.storageKey)
    }

    static func putSettingsBack() {
        guard let domain, let bytes = try? Data(contentsOf: file),
              let kept = try? PropertyListSerialization.propertyList(from: bytes, options: [], format: nil) as? [String: Any] else { return }
        UserDefaults.standard.setPersistentDomain(kept, forName: domain)
        try? FileManager.default.removeItem(at: file)
    }

    /// At launch: a demo that never got to end leaves its settings file behind. Put them back.
    static func recoverIfInterrupted() {
        guard FileManager.default.fileExists(atPath: file.path) else { return }
        putSettingsBack()
    }
}
