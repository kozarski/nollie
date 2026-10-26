import Foundation
import Observation
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif
import UserNotifications
import NollieCore

/// The app's single shared model: saved gateways, the running one, which tab is showing, and the
/// requests other parts of the app make of the screen (open this chat, focus that box).
///
/// The behaviour is split by topic across files: gateway sign-in and activation here, links and
/// chat opening in `AppModel+Links`, and notification routing in `AppModel+Notifications`.
/// Stored properties must live in this declaration, so some are internal where an extension in
/// another file touches them.
@MainActor
@Observable
final class AppModel {
    /// The scene does not own this. A notification action can launch the app with no window at all,
    /// and the request still needs a place to land.
    static let shared = AppModel()

    // MARK: Gateways

    let lock: AppLock = AppLock()
    let push: PushRegistrar = PushRegistrar()
    /// What the system lets Nollie do. Reading it is silent; only a button asks.
    let permissions: PermissionCenter
    let cloudAlerts: CloudAlertTransport = .shared
    let store: ConnectionStore
    /// Quietly signs a gateway back in (after Face ID) using a sign-in the person chose to keep,
    /// once its session has ended for good.
    let rememberedSignIn: RememberedSignInCoordinator

    private(set) var runtime: GatewayRuntime?
    /// The in-app gateway while "Try a demo" is on (see `AppModel+Demo`). Nil in normal use.
    var demo: DemoGateway?
    var activationError: String?
    @ObservationIgnored var activationGeneration = UUID()
    @ObservationIgnored var activationRecovery: Task<Void, Never>?

    /// Gateways that need signing in again on this device. The banner adds to the list; the sheet at
    /// the root takes them one after another.
    var signInPrompt: [GatewayConnection] = []

    // MARK: Navigation state

    var selectedTab: AppTab = .chats
    var pendingRoute: PendingRoute?

    /// A bot page asked for from one of its menus (history, what it knows, settings), shown over
    /// the window by `BotSheetHost`.
    var botSheet: BotSheet?

    /// Id of the open chat as saved, so opening it again never stacks a duplicate.
    var visibleChatID: String?
    /// The open chat as an object. Before its first message it has no saved id, and the Mac's Chat
    /// menu still has to reach it for Stop, Approve and Deny.
    var visibleChat: ChatSession?
    var visibleChatRequestedID: String?
    /// A conversation sheet can cover the transcript without removing it.
    var visibleChatIsObscured = false

    /// Command-F on the Mac: moves focus into the search box above the chat list.
    var focusSearchRequest: UUID?

    // MARK: Compose and tab bar state

    /// Raised by the compose circle. Whichever screen is frontmost chooses the bot for the new chat.
    var newChatRequest: UUID?
    /// Set just before a `newChatRequest` that wants a chat of its own (`/new`, the New Chat
    /// intent) rather than the bot's main chat. It holds for a few seconds only, so a request
    /// nobody answered cannot turn a later tap into a new chat.
    var sideChatRequestedAt: Date?
    var sideChatWanted: Bool { Date().timeIntervalSince(sideChatRequestedAt ?? .distantPast) < 5 }

    /// Set on a long press of the compose circle, to open the full New Message sheet and skip the quick chat.
    var newChatSheetRequest: UUID?
    /// Chat menu, New Bot (command-N): the chat list opens its new-bot sheet.
    var newBotRequest: UUID?
    /// Where compose was tapped, when that tab was not Chats. The chat itself opens on Chats; once it
    /// or the sheet closes, we go back here. Opening a chat any other way, or tapping the bar, forgets it.
    var composeReturnTab: AppTab?
    /// The bot page showing now, so compose from there begins a chat with that bot.
    var composeProfile: String?
    #if DEBUG
    /// Opening line for the next new chat, supplied by the `-nollie-demo-say` launch flag.
    var demoFirstMessage: String?
    #endif

    /// One step through the chat list, forward (+1) or back (-1), asked for by the Mac's Chat menu.
    struct ChatStepRequest {
        let direction: Int
        let id = UUID()
    }
    var chatStepRequest: ChatStepRequest?

    /// True while a chat is pushed on the Chats tab. This follows the navigation path directly, so the bar hides at once.
    var chatsPathOpen = false
    /// The bar also hides for any view that calls `hidesTabBar()`. The count is kept per tab because
    /// a tap on the bar while it slides away can switch tabs: the new tab needs the bar back, while
    /// the old one keeps hiding it for its open chat.
    var tabBarHiders: [AppTab: Int] = [:]
    /// Root views say here if their tab sits on its first page. Pressing the active tab again from
    /// deeper down bumps `popToRoot`.
    var tabAtRoot: [AppTab: Bool] = [:]
    var popToRoot: [AppTab: Int] = [:]
    /// Goes up each time the current tab is tapped again, wherever it is, so lists can jump to the top.
    var tabReselected: [AppTab: Int] = [:]
    /// When a keyboard is showing the bar steps aside rather than sit on top of it.
    var keyboardUp = false

    var tabBarHidden: Bool {
        #if os(iOS)
        true
        #else
        (selectedTab == .chats && chatsPathOpen) || (tabBarHiders[selectedTab] ?? 0) > 0 || keyboardUp
        #endif
    }

    // MARK: Pairing, board and other requests

    /// A camera link held in memory until the person confirms the Mac on screen.
    var pendingDevicePairing: DevicePairingInvitation?
    /// A Nollie Link code opened as a link (https://nollie.app/pair#...) waiting to be confirmed.
    var pendingLinkOffer: NollieLinkOffer?
    var devicePairingFlowActive = false

    var boardChatContext: BoardChatContext?
    var boardTaskToReveal: BoardChatContext?

    /// What left the Mac today and what the crew did overnight. Settings' top tiles and the Mac
    /// sidebar's Papertrail button both read it, so they always agree.
    let crewSummary = CrewSummaryModel()
    /// Set to open Settings, What left your Mac (the Mac sidebar's Papertrail button).
    var papertrailRequest: UUID?

    /// Set when something that needs the Mac live was tapped while the phone cannot reach it.
    var awayPrompt = false

    /// Approve or Deny arrived from a notification and the "Confirm approvals" setting is on, so the
    /// chat asks before acting.
    var approvalConfirm: ApprovalConfirm?

    /// True when the plugin installed beside the gateway is older than the copy shipped inside this
    /// build. Notification settings show a badge until it is refreshed.
    var companionUpdateAvailable = false
    /// The companion version the last check found on the gateway (About shows it).
    var companionInstalledVersion: String?

    // MARK: Ask Nollie

    /// Raised by Ask Nollie once Nollie is unlocked. The main chat's composer takes the keyboard
    /// while it stands.
    var composerFocusRequestedAt: Date?
    /// The main chat that Ask Nollie opened, so only its box takes the keyboard.
    var composerFocusSession: String?
    var composerFocusWanted: Bool {
        !lock.isLocked && Date().timeIntervalSince(composerFocusRequestedAt ?? .distantPast) < 10
    }
    /// Why Ask Nollie could not open the main chat.
    var askNollieError: String?
    /// Ask Nollie is still to run: it came in behind the lock, or the lock came up before it
    /// finished. It runs again after the unlock.
    @ObservationIgnored var askNollieWaiting = false
    @ObservationIgnored var askNollieTask: Task<Void, Never>?

    // MARK: Notification routing state

    var notificationRouteError: String?
    @ObservationIgnored var notificationTask: Task<Void, Never>?
    @ObservationIgnored var notificationRequest: NotificationRequest?
    @ObservationIgnored var notificationGeneration = UUID()

    enum NotificationRequest {
        case route(PendingRoute)
        case cloud(String)
    }

    /// Pages that cannot appear at the moment, such as the Board when its plugin (or the whole
    /// gateway) is missing. Their place in the saved layout is kept for when the plugin is back.
    var hiddenTabs: Set<AppTab> {
        let boardReady = runtime?.kanban.isPresent ?? false
        return boardReady ? [] : [.kanban]
    }

    // MARK: Setup

    init() {
        permissions = PermissionCenter.make(push: push)
        let saved = ConnectionStore()
        store = saved
        rememberedSignIn = RememberedSignInCoordinator(vault: saved.remembered)
        rememberedSignIn.canPromptNow = { [weak self] in self?.canAskForSignInNow == true }
        #if DEBUG
        DemoMode.addGateway(to: saved)
        #endif
        DemoSession.recoverIfInterrupted()
        #if DEBUG
        startDemoIfAsked()
        #endif
        cloudAlerts.startObservingAccountChanges()
        listenForSystemEvents()
    }

    /// Things the app reacts to wherever it is: a push registration that needs syncing, and the
    /// phone becoming readable after being locked.
    private func listenForSystemEvents() {
        func onMain(_ name: Notification.Name, _ react: @escaping @MainActor (AppModel) async -> Void) {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    if let self { await react(self) }
                }
            }
        }
        onMain(.hermesPushRegistrationNeedsSync) { app in
            guard app.demo == nil, let current = app.runtime else { return }
            await app.push.syncRegistration(runtime: current)
        }
        #if os(iOS)
        // If the phone was locked at launch (say a notification started us), saved sign-ins could not be
        // read. This fires after unlocking; returning to the foreground also re-reads them
        // (see NollieApp).
        onMain(UIApplication.protectedDataDidBecomeAvailableNotification) { app in
            app.store.remembered.reload()
        }
        #endif
    }

    var hasConnections: Bool { store.connections.isEmpty == false }

    // MARK: Away from home

    /// How this phone reaches its linked Mac right now; nil when it is not linked to one.
    var linkReach: NollieLinkReach? { DemoMode.reach ?? runtime?.linkReach }

    /// True when the Mac cannot be reached. It also raises the away card in place of the action.
    func awayBlocks() -> Bool {
        guard linkReach == .away else { return false }
        awayPrompt = true
        return true
    }

    // MARK: Companion

    /// Pulls the companion manifest from the gateway (two quick file reads) to refresh
    /// `companionUpdateAvailable`; the app does this every time it is foregrounded.
    func refreshCompanionUpdateFlag() async {
        guard let runtime, push.registeredAt != nil else {
            companionUpdateAvailable = false
            return
        }
        let probe = PushSetupModel()
        await probe.checkCompanion(runtime: runtime)
        companionUpdateAvailable = probe.updateAvailable
        companionInstalledVersion = probe.installedVersion
    }

    // MARK: Signing in

    #if DEBUG
    /// Launch flag `-nollie-show-signin`: acts as though the current gateway wants a sign-in, handy
    /// for looking over the banner and sheet without logging anyone out.
    static let forceSignIn = ProcessInfo.processInfo.arguments.contains("-nollie-show-signin")
    #endif

    /// The current gateway when it has turned the session down and this device must sign in
    /// before it can use it again.
    var needsSignIn: GatewayConnection? {
        #if DEBUG
        if Self.forceSignIn, let forced = runtime?.connection ?? store.active { return forced }
        #endif
        if let runtime {
            if runtime.connection.lacksCredentials(runtime.secrets) { return runtime.connection }
            if case .authRejected = runtime.socketState { return runtime.connection }
            return nil
        }
        guard let saved = store.active, saved.lacksCredentials(store.secrets(for: saved.id)) else { return nil }
        return saved
    }

    /// Face ID may only be requested while we are frontmost and the app's lock screen is down. That
    /// lock raises Face ID on its own, and stacking a second prompt would collide.
    var canAskForSignInNow: Bool {
        #if os(iOS)
        let inFront = UIApplication.shared.applicationState == .active
        #else
        let inFront = NSApplication.shared.isActive
        #endif
        return inFront && !lock.isLocked
    }

    /// Runs on return to the foreground or unlock when the current gateway refuses the session because
    /// its refresh token was rejected. This gives the remembered sign-in the attempt it missed while
    /// we were away. A socket failing for any other reason is the person's to sort out (see
    /// `RememberedSignInCoordinator.signInAgainOnReturn`).
    func signInAgainIfExpired() async {
        guard let current = runtime,
              let renewed = await rememberedSignIn.signInAgainOnReturn(current),
              runtime === current
        else { return }
        await current.replaceSecrets(renewed)
    }

    /// Tells the Sign In sheet whether it can show a Face ID option for this gateway.
    func canSignInWithRemembered(_ connection: GatewayConnection) -> Bool {
        rememberedSignIn.decision(for: connection, asked: true) == .useRemembered
    }

    /// Behind the sheet's Face ID button: signs in with the kept sign-in because the person asked.
    func signInWithRemembered(_ connection: GatewayConnection) async throws {
        let access = store.secrets(for: connection.id).access
        let renewed = try await rememberedSignIn.signInWithRemembered(connection, access: access)
        if let current = runtime, current.connection.id == connection.id {
            await current.replaceSecrets(renewed)
        } else {
            store.saveSecrets(renewed, for: connection.id)
            if store.activeConnectionID == connection.id { await activate(connection) }
        }
        NotificationCenter.default.post(name: .hermesSessionsChanged, object: nil)
    }

    // MARK: Activating a gateway

    func activateSavedConnection() async {
        if let saved = store.active { await activate(saved) }
    }

    /// Makes `connection` the running gateway: stops the old runtime, builds and wires the new
    /// one, and starts it. `ifCurrent` lets a caller (such as a notification) abandon the switch
    /// if it has become stale part way through.
    func activate(_ connection: GatewayConnection, backend: GatewayBackend = .network, ifCurrent: () -> Bool = { true }) async {
        guard ifCurrent(), !Task.isCancelled else { return }
        if runtime?.connection.id == connection.id { return }

        let generation = UUID()
        activationGeneration = generation
        activationRecovery?.cancel()
        activationRecovery = nil

        if let old = runtime {
            await old.stop()
            guard activationGeneration == generation else { return }
            guard ifCurrent(), !Task.isCancelled else {
                // Abandoned after the old runtime was already stopped: bring it back up.
                activationRecovery = InterruptedRuntimeRecovery.schedule(
                    old, connectionID: old.connection.id,
                    currentRuntime: { [weak self] in self?.runtime },
                    activeConnectionID: { [weak self] in self?.store.activeConnectionID },
                    isCurrent: { [weak self] in self?.activationGeneration == generation },
                    start: { await $0.start() })
                return
            }
        }
        guard activationGeneration == generation, ifCurrent(), !Task.isCancelled else { return }

        let old = runtime
        store.activeConnectionID = connection.id
        let fresh = GatewayRuntime(connection: connection, store: store, backend: backend)
        wire(fresh, for: connection)
        activationError = nil
        runtime = fresh
        ChatGoals.shared.attach(fresh)
        // The old gateway is gone for good now, so let go of its chats and anything they were waiting on.
        // That happens only once the new one is in place, so nothing is left holding a runtime that is done.
        await old?.dispose()
        // A newer switch may have taken over while the old one was let go.
        guard runtime === fresh else { return }
        await fresh.start()
        if demo == nil { await push.registerForRemoteNotificationsIfAuthorized() }
    }

    /// Connects a new runtime to the pieces of the app it reports to.
    private func wire(_ runtime: GatewayRuntime, for connection: GatewayConnection) {
        #if os(macOS) && NOLLIE_DIRECT
        if connection.managedInstallationID != nil, !DemoMode.isOn {
            runtime.managedEndpointResolver = managedEndpointResolver(for: runtime)
        }
        #endif
        // A yes to buying, sending or posting checks it's you first, wherever it is given.
        runtime.approvalOwnerCheck = ApprovalOwnerCheck.hook(for: runtime)
        // A demo has no push, no notifications, no screen control and no remembered sign-in.
        guard demo == nil else { return }
        runtime.linkDemo = DemoMode.reach != nil
        runtime.pushRegistrar = push
        runtime.cardNotifier = LocalCardNotifier()
        // A screen action by a bot whose System control is on is answered here, with no card.
        // The answer needs a switch read from this runtime's own gateway, not another one's.
        runtime.approvalAutoAnswer = { [weak runtime] approval, profile in
            guard let runtime else { return nil }
            return SystemControl.shared.autoAnswer(approval, profile: profile, connection: runtime.connection.id,
                                                   gateway: runtime.connection.gateway)
        }
        #if os(iOS)
        runtime.activityReporterFactory = { BotTurnReporter() }
        #else
        runtime.activityReporterFactory = { MenuBarTurnReporter() }
        #endif
        // When a session ends for good and this device kept the sign-in, sign back in without a
        // prompt (after Face ID). With none kept, the person gets asked.
        runtime.signInAgain = { [weak self] connection, secrets in
            await self?.rememberedSignIn.signInAgain(connection, access: secrets.access)
        }
    }

    #if os(macOS) && NOLLIE_DIRECT
    /// For a gateway run by Nollie's own background service: ask the service where it is now.
    private func managedEndpointResolver(for runtime: GatewayRuntime) -> @MainActor @Sendable () async throws -> GatewayURL {
        { [weak self, weak runtime] in
            guard let self, let runtime, self.runtime === runtime,
                  self.store.activeConnectionID == runtime.connection.id
            else { throw SocketError.cancelled }
            do {
                let reply = try await ManagedRuntimeClient.readStatus()
                try Task.checkCancellation()
                guard self.runtime === runtime, reply.error == nil, reply.snapshot.phase == .ready,
                      let endpoint = reply.snapshot.endpoint,
                      let updated = runtime.connection.updatingManagedEndpoint(
                        endpoint,
                        activeConnectionID: self.store.activeConnectionID,
                        installationID: reply.snapshot.installationID,
                        enabledInstallationID: reply.snapshot.enabledInstallationID)
                else {
                    throw HermesAPIError.transport("Nollie's background service is not ready. The connection will retry.")
                }
                runtime.lastError = nil
                return updated.gateway
            } catch {
                guard self.runtime === runtime, !Task.isCancelled else { throw SocketError.cancelled }
                let waiting = "Waiting for Nollie's background service. The connection will retry."
                runtime.lastError = waiting
                throw HermesAPIError.transport(waiting)
            }
        }
    }
    #endif

    func deactivate() async {
        let generation = UUID()
        activationGeneration = generation
        activationRecovery?.cancel()
        activationRecovery = nil
        await runtime?.stop()
        guard activationGeneration == generation else { return }
        let old = runtime
        runtime = nil
        ChatGoals.shared.attach(nil)
        await old?.dispose()
    }

    /// Before removing Nollie's data: tell the gateway to stop sending here, then close the connection.
    func prepareForRemoval() async {
        if let runtime { await push.removeRegistration(runtime: runtime) }
        await deactivate()
    }

    /// Puts this device back at the first-run screen: all saved gateways, sign-ins, settings and bot
    /// looks are wiped, after telling the gateway to stop sending here. Chats and bots belong to the
    /// gateway and stay as they are.
    func resetApp() async {
        if let runtime { await push.removeRegistration(runtime: runtime) }
        await deactivate()
        for saved in store.connections { store.delete(id: saved.id) }

        // The shared copies the extensions read, the widget snapshot, and the last notification's trail.
        Keychain.delete(account: BotLooks.account)
        Keychain.delete(account: "widget.snapshot")
        Keychain.delete(account: "push.nse.last")
        BotAvatarStore.removeAllPhotos()
        wipeDefaults()

        lock.isEnabled = false
        selectedTab = .chats
        pendingRoute = nil
        visibleChat = nil
        visibleChatID = nil
        companionUpdateAvailable = false
        companionInstalledVersion = nil
        UNUserNotificationCenter.current().removeAllDeliveredNotifications()

        // Views being torn down still write a little as they leave (a last-visit time). Clear again
        // after they are gone so the fresh start really is empty.
        try? await Task.sleep(for: .milliseconds(500))
        wipeDefaults()
    }

    private func wipeDefaults() {
        guard let domain = Bundle.main.bundleIdentifier else { return }
        UserDefaults.standard.removePersistentDomain(forName: domain)
    }

    func deleteConnection(_ id: UUID) async {
        if let runtime, runtime.connection.id == id {
            await push.removeRegistration(runtime: runtime)
            await deactivate()
        }
        store.delete(id: id)
        guard let next = store.active else { return }
        await activate(next)
    }
}
