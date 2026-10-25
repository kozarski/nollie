import AppKit
import NollieCore
import SwiftUI

/// One appearance for the whole app, set on AppKit so native controls and SwiftUI agree.
enum MacAppearance {
    /// "light" and "dark" set an appearance; anything else (the default is "system") removes the
    /// override so the Mac's own light and dark changes come through.
    @MainActor static func apply(_ choice: String) {
        let wanted: NSAppearance? = switch choice {
        case "light": NSAppearance(named: .aqua)
        case "dark": NSAppearance(named: .darkAqua)
        default: nil
        }
        if NSApplication.shared.appearance?.name != wanted?.name {
            NSApplication.shared.appearance = wanted
        }
    }
}

/// Work done once, before any scene exists.
enum MacLaunch {
    @MainActor static func prepare() {
        NollieLogFiles.start(.app)
        #if DEBUG
        // The demo copy has its own bundle id and keeps credentials in memory only.
        DemoMode.prepare()
        #endif
        NolliePaths.moveInLegacyFolders()
        // The notification extension uses the same Keychain group, and old items get moved across once.
        Keychain.accessGroup = Keychain.sharedGroupFromBundle()
        Keychain.migrateToAccessGroupIfNeeded()
        NotificationPreviewPreferences.mirror()
        MacAppearance.apply(UserDefaults.standard.string(forKey: "colorSchemePreference") ?? "system")
    }
}

/// How the window follows the Mac: coming to the front and going behind, sleep and wake, unlocking.
struct MacLifecycle: ViewModifier {
    let model: AppModel
    let scheme: String

    private static let app = NotificationCenter.default
    private static let system = NSWorkspace.shared.notificationCenter

    func body(content: Content) -> some View {
        content
            .onChange(of: scheme, initial: true) { _, choice in MacAppearance.apply(choice) }
            .task { await startUp() }
            .onChange(of: model.lock.isLocked) { _, locked in
                guard !locked else { return }
                Task { await model.signInAgainIfExpired() }
            }
            .onReceive(Self.app.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in cameToFront() }
            .onReceive(Self.app.publisher(for: NSApplication.didResignActiveNotification)) { _ in
                LocalNotifier.isForeground = false
            }
            .onReceive(Self.system.publisher(for: NSWorkspace.willSleepNotification)) { _ in model.lock.didEnterBackground() }
            .onReceive(Self.system.publisher(for: NSWorkspace.didWakeNotification)) { _ in model.lock.willEnterForeground() }
            .onReceive(Self.system.publisher(for: NSWorkspace.screensDidSleepNotification)) { _ in
                model.lock.didEnterBackground()
                BotAmbient.shared.displayAsleep = true
            }
            .onReceive(Self.system.publisher(for: NSWorkspace.screensDidWakeNotification)) { _ in
                model.lock.willEnterForeground()
                BotAmbient.shared.displayAsleep = false
            }
    }

    private func startUp() async {
        await model.activateSavedConnection()
        await model.cloudAlerts.refresh()
        await model.refreshCompanionUpdateFlag()
        #if NOLLIE_DIRECT
        // A newer Nollie may carry newer add-ons for the managed setup. They go in without asking.
        Task.detached(priority: .utility) { await MacHermesSetup.updateAddOnsIfNeeded() }
        #endif
    }

    /// On a Mac "in the foreground" means the frontmost app, and local notifications only fire when it is not.
    private func cameToFront() {
        LocalNotifier.isForeground = true
        BotAmbient.shared.enabled = true
        Task { await model.push.refreshAuthorization() }
        Task { await model.cloudAlerts.refresh() }
        if let runtime = model.runtime, !model.isDemo {
            CloudAlertHelperController.shared.updateCanonicalSession(
                connectionID: runtime.connection.id,
                sessionID: BotsHome.shared.entry(runtime, "default").storedID)
        }
        // A locked Mac cannot read remembered sign-ins, and the app might have launched in that
        // state, so load them afresh. If a session lapsed while some other app was in front, it is
        // renewed from the remembered sign-in.
        model.store.remembered.reload()
        Task { await model.signInAgainIfExpired() }
    }
}

extension TurnBoard {
    /// The menu bar icon's badge: someone is needed, the Mac is in use, work is going on, or nothing.
    var menuBarBadge: MenuBarIcon.Badge {
        if attention > 0 { return .needsYou }
        if turns.contains(where: { !$0.attention && $0.detail.contains("computer_use") }) { return .usingMac }
        return running > 0 ? .working : .idle
    }
}
