import os
import SwiftUI
import NollieCore

/// The window's content: first-run setup or the main screen, with the lock over either, and the
/// sheets that can appear on top (sign-in, away card, companion prompt, installer, pairing).
struct RootView: View {
    /// DEBUG: pass `-nollie-show-tour` to see the first-run tour on an already configured app.
    static let forceTour = debugFlag("-nollie-show-tour")
    /// DEBUG: pass `-nollie-show-welcome` to see the opening Get Started screen on a configured app.
    static let forceWelcome = debugFlag("-nollie-show-welcome")

    private static func debugFlag(_ name: String) -> Bool {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains(name)
        #else
        false
        #endif
    }

    @Environment(AppModel.self) private var model
    @AppStorage("launchTab") private var launchTab = "chats"
    @AppStorage(TabLayout.storageKey) private var savedLayout = ""
    @AppStorage(OnboardingProgress.storageKey) private var onboardingSaved = ""

    @State private var companion = CompanionFlow()
    /// A saved Board launch waits a little for the gateway to say whether it has the plugin.
    @State private var tabWaitingForPlugin: AppModel.AppTab?

    private var isOnboarding: Bool {
        Self.forceTour || Self.forceWelcome
            || OnboardingProgress.shouldPresent(hasConnections: model.hasConnections, raw: onboardingSaved)
    }

    /// Whether something else is up, so the Companion prompt should wait.
    private var somethingIsInTheWay: Bool {
        isOnboarding || model.isDemo || model.lock.isLocked || !model.signInPrompt.isEmpty || model.needsSignIn != nil
            || model.pendingDevicePairing != nil || model.devicePairingFlowActive
    }

    var body: some View {
        screens
            .animation(.default, value: model.lock.isLocked)
            .onChange(of: model.hiddenTabs) { before, now in
                // A saved Board launch can finish once the plugin answers.
                guard let tab = tabWaitingForPlugin, before.contains(tab), !now.contains(tab) else { return }
                tabWaitingForPlugin = nil
                if model.selectedTab == .chats, !model.chatsPathOpen { model.selectedTab = tab }
            }
            .modifier(KeyboardWatcher())
            .onAppear(perform: start)
            .onChange(of: model.hasConnections) { had, has in
                guard !had, has, !isOnboarding, !model.isDemo else { return }
                companion.firstGatewaySaved()
                offerCompanion()
            }
            .modifier(CompanionTriggers(onChange: offerCompanion))
            .notificationNavigation(model)
            .sheet(isPresented: signInShowing) {
                GatewaySignInSheet(connections: model.signInPrompt).withAppModel()
            }
            .sheet(isPresented: Binding(get: { model.awayPrompt && !model.lock.isLocked }, set: { model.awayPrompt = $0 })) {
                AwayCardSheet().withAppModel()
            }
            .modifier(CompanionSheets(flow: companion))
            #if os(iOS)
            .modifier(PairingSheet(isOnboarding: isOnboarding, companionIsShowing: companion.isShowing, onEnd: offerCompanion))
            #endif
    }

    private var screens: some View {
        // In a demo the pill sits above the screen, not over it: a navigation bar ignores a safe
        // area inset and would draw through the pill.
        VStack(spacing: 0) {
            if model.isDemo { DemoPill() }
            Group {
                if isOnboarding {
                    OnboardingView(skipWelcome: Self.forceTour)
                } else {
                    MainTabView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .overlay {
            if model.lock.isLocked { LockScreenView().transition(.opacity) }
        }
    }

    private var signInShowing: Binding<Bool> {
        Binding(
            get: { !model.signInPrompt.isEmpty && !model.lock.isLocked && !companion.isShowing },
            set: { if !$0 { model.signInPrompt = [] } })
    }

    // MARK: Start-up

    private func start() {
        tidyLayout()
        openLaunchTab()
        #if DEBUG
        LaunchFlags.apply(model: model, companion: companion)
        #endif
    }

    /// Older Home and administration layouts are retired without touching conversations.
    private func tidyLayout() {
        let defaults = UserDefaults.standard
        if defaults.bool(forKey: TabLayout.chatFirstAppliedKey) == false {
            savedLayout = TabLayout.default.encoded
            defaults.set(true, forKey: TabLayout.chatFirstAppliedKey)
        }
        savedLayout = TabLayout.parse(savedLayout).encoded
    }

    /// Opens the saved launch tab. If it needs a plugin the gateway has not confirmed yet, wait
    /// up to eight seconds for it.
    private func openLaunchTab() {
        let tab = TabLayout.launchTab(launchTab)
        launchTab = tab.rawValue
        guard model.hiddenTabs.contains(tab) else {
            model.selectedTab = tab
            return
        }
        tabWaitingForPlugin = tab
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(8))
            tabWaitingForPlugin = nil
        }
    }

    private func offerCompanion() {
        companion.offerIfFree(model: model, busy: somethingIsInTheWay)
    }
}

/// Tells the model when the keyboard is up, so the tab bar does not float over it.
private struct KeyboardWatcher: ViewModifier {
    @Environment(AppModel.self) private var model

    func body(content: Content) -> some View {
        let center = NotificationCenter.default
        content
            .onReceive(center.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in model.keyboardUp = true }
            .onReceive(center.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in model.keyboardUp = false }
    }
}

/// Re-offers the Companion whenever something that was in its way clears.
private struct CompanionTriggers: ViewModifier {
    @Environment(AppModel.self) private var model
    let onChange: () -> Void

    func body(content: Content) -> some View {
        content
            .onChange(of: model.signInPrompt.isEmpty) { onChange() }
            .onChange(of: model.needsSignIn == nil) { onChange() }
            .onChange(of: model.lock.isLocked) { onChange() }
    }
}

/// The Companion prompt and the installer it can lead to.
private struct CompanionSheets: ViewModifier {
    @Environment(AppModel.self) private var model
    @Bindable var flow: CompanionFlow

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: $flow.showsPrompt) {
                CompanionPromptSheet(
                    found: flow.version,
                    authorization: model.push.authorization,
                    install: flow.chooseSetUp,
                    allow: { flow.chooseAllow(model: model) },
                    later: flow.chooseLater)
                .withAppModel()
            }
            .sheet(isPresented: $flow.showsInstaller) {
                NavigationStack {
                    SetupWizardHost()
                        .toolbar {
                            ToolbarItem(placement: .confirmationAction) {
                                Button("Done") { flow.showsInstaller = false }
                            }
                        }
                }
                .withAppModel()
            }
    }
}

#if os(iOS)
/// The sheet for a camera pairing link or a Nollie Link code, once nothing else is in the way.
private struct PairingSheet: ViewModifier {
    @Environment(AppModel.self) private var model
    @AppStorage(OnboardingProgress.storageKey) private var onboardingSaved = ""
    let isOnboarding: Bool
    let companionIsShowing: Bool
    let onEnd: () -> Void

    private var showing: Binding<Bool> {
        Binding(
            get: {
                let waiting = model.pendingDevicePairing != nil || model.pendingLinkOffer != nil
                let clear = !model.lock.isLocked && model.signInPrompt.isEmpty && model.needsSignIn == nil
                    && !companionIsShowing
                return waiting && clear && model.selectedTab == .chats
            },
            set: { shown in
                guard !shown else { return }
                model.pendingDevicePairing = nil
                model.pendingLinkOffer = nil
            })
    }

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: showing) {
                PhoneDevicePairingView(initialInvitation: model.pendingDevicePairing, initialLinkOffer: model.pendingLinkOffer) { connection in
                    guard isOnboarding else { return }
                    var progress = OnboardingProgress.parse(onboardingSaved)
                    progress.paired(connection.id)
                    onboardingSaved = progress.encoded
                }
                .sheetFrame()
                .withAppModel()
            }
            .onChange(of: model.pendingDevicePairing?.id) { _, id in
                if id != nil { model.selectedTab = .chats } else { onEnd() }
            }
            .onChange(of: model.pendingLinkOffer) { _, offer in
                if offer != nil { model.selectedTab = .chats } else { onEnd() }
            }
            .onChange(of: model.devicePairingFlowActive) { _, active in
                if !active { onEnd() }
            }
    }
}
#endif
