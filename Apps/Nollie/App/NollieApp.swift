import SwiftUI
import NollieCore

@main
struct NollieApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("colorSchemePreference") private var schemeChoice = "system"
    @AppStorage(AppTheme.accentKey) private var accentID = "blue"
    @State private var model: AppModel

    init() {
        Self.prepareProcess()
        _model = State(initialValue: AppModel.shared)
    }

    /// Everything that has to happen once, before the first window.
    private static func prepareProcess() {
        #if DEBUG
        // The demo copy keeps credentials in memory, and long main-thread stalls go to the perf log.
        DemoMode.prepare()
        Perf.watchMainThread()
        #endif
        // Bot photos used to live outside Nollie's folder; move them in, once.
        NolliePaths.moveInLegacyFolders()
        // The notification extensions share the Keychain group, so move older items over, once.
        Keychain.accessGroup = Keychain.sharedGroupFromBundle()
        Keychain.migrateToAccessGroupIfNeeded()
        NotificationPreviewPreferences.mirror()
        ImageTranscode.install()
        TypingHaptics.shared.start()
        // Bots that still hold a look from the old drawn faces take their default character.
        BotAvatarStore.migrate()
    }

    private var preferredScheme: ColorScheme? {
        ["light": ColorScheme.light, "dark": .dark][schemeChoice]
    }

    var body: some Scene {
        WindowGroup {
            // Debug: `-nollie-demo-new-chat <rows>` shows the new conversation screen instead.
            ConversationDemoGate { RootView() }
                .environment(model)
                .notificationPreviewPolicy()
                .tint(AppTheme.accent(accentID).color)
                .preferredColorScheme(preferredScheme)
                .onOpenURL(perform: model.open)
                // A chat handed over from a Mac, iPhone or iPad opens here.
                .continuesHandoff(model)
                .task(launch)
                .onChange(of: model.lock.isLocked) { _, locked in
                    guard !locked else { return }
                    Task { await model.signInAgainIfExpired() }
                }
                .onChange(of: scenePhase) { _, phase in react(to: phase) }
        }
    }

    @Sendable private func launch() async {
        // A launch in the background on a locked phone cannot read the remembered sign-ins. The window
        // only opens after unlocking.
        model.store.remembered.reload()
        await HelperAtWorkActivities.shared.showPreview()
        await model.activateSavedConnection()
        await model.cloudAlerts.refresh()
        await model.refreshCompanionUpdateFlag()
    }

    private func react(to phase: ScenePhase) {
        switch phase {
        case .active: cameToFront()
        case .background: wentToBackground()
        case .inactive: LocalNotifier.isForeground = false
        @unknown default: break
        }
    }

    private func cameToFront() {
        LocalNotifier.isForeground = true
        // Replies that streamed while away are drawn now, once.
        model.runtime?.isAway = false
        model.lock.willEnterForeground()
        BotMotionSource.shared.apply(active: true)
        AwayWatch.shared.returned(runtime: model.runtime)
        // Read the remembered sign-ins once more. A launch while locked could not, and that same
        // process might still be alive.
        model.store.remembered.reload()
        HelperAtWorkActivities.shared.foreground()

        let follow: [() async -> Void] = [
            { await model.push.refreshAuthorization() },
            { await model.cloudAlerts.refresh() },
            { await model.refreshCompanionUpdateFlag() },
            { await model.push.refreshRelayIfStale() },
            // A session that ended while we were away can sign in again now, behind the app lock if it is showing.
            { await model.signInAgainIfExpired() },
        ]
        for step in follow {
            Task { await step() }
        }
    }

    private func wentToBackground() {
        // Hidden from view, so streamed replies skip redraws (see GatewayRuntime.isAway).
        model.runtime?.isAway = true
        AwayWatch.shared.left(runtime: model.runtime)
        LocalNotifier.isForeground = false
        BotMotionSource.shared.apply(active: false)
        model.lock.didEnterBackground()
        HelperAtWorkActivities.shared.background()
    }
}
