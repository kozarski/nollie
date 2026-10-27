import NollieCore
import SwiftUI

extension View {
    /// A window header with no title and no bar behind it, for screens that draw their own top.
    fileprivate func bareWindowHeader() -> some View {
        toolbar(removing: .title)
            .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
    }
}

/// Top view in the Mac window. Until a gateway has been saved it shows the welcome tour, afterwards
/// the real app. Whenever the lock is enabled it sits above both.
struct MacRootView: View {
    @AppStorage(OnboardingProgress.storageKey) private var tourProgress = ""
    @AppStorage(GlassAppearance.enabledKey) private var glassOn = GlassAppearance.defaultEnabled
    @AppStorage(GlassAppearance.strengthKey) private var glassLevel = GlassAppearance.defaultStrength

    @State private var previewTourFinished = false

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.openWindow) private var openWindow
    @Environment(AppModel.self) private var model

    /// Debug only: `-nollie-show-welcome` puts the first screen over an app that is already set up.
    static let forceWelcome: Bool = {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains("-nollie-show-welcome")
        #else
        false
        #endif
    }()

    private var glass: GlassAppearance.Policy {
        GlassAppearance.resolve(enabled: glassOn, strength: glassLevel,
                                reduceTransparency: reduceTransparency, increaseContrast: contrast == .increased)
    }

    private var touring: Bool {
        if Self.forceWelcome { return !previewTourFinished }
        return OnboardingProgress.shouldPresent(hasConnections: model.hasConnections, raw: tourProgress)
    }

    var body: some View {
        layers
            .modifier(MacWindowChrome(touring: touring, glass: glass))
            // Kept for code that has no view to ask, like an App Intent run with the window closed.
            .task { MacWindow.openMain = { openWindow(id: MacWindow.main) } }
            .companionOffer(touring: touring)
            .notificationNavigation(model)
            .weeklyNoteHost()
            #if NOLLIE_DIRECT
            .modifier(LeftoverOffer())
            #endif
            #if DEBUG
            .modifier(MacDemoLaunch(touring: touring))
            #endif
    }

    private var layers: some View {
        ZStack {
            if touring {
                OnboardingView(onPreviewFinished: { previewTourFinished = true })
                    .frame(minWidth: 520, minHeight: 440)
                    .bareWindowHeader()
            } else {
                MainSplitView(glassPolicy: glass)
            }
            if model.lock.isLocked {
                MacLockCover().bareWindowHeader()
            }
        }
        // In the title bar's row, beside the chat's own header, so no content is pushed down.
        .overlay(alignment: .top) {
            if model.isDemo { DemoPill().padding(.top, 6).ignoresSafeArea(.container, edges: .top) }
        }
    }
}

/// Window sizing for the tour and the backdrop behind everything: clear during the tour, frosted
/// after it.
private struct MacWindowChrome: ViewModifier {
    let touring: Bool
    let glass: GlassAppearance.Policy
    @State private var tourHeight: CGFloat = 740

    func body(content: Content) -> some View {
        content
            .onPreferenceChange(OnboardingWindowHeightKey.self) { tourHeight = $0 }
            .background(OnboardingWindowSize(isPresented: touring, preferredHeight: tourHeight,
                                             mainWindowUsesGlass: glass.usesGlass))
            .containerBackground(for: .window) {
                if touring { Color.clear } else { MacFrostedBackdrop(policy: glass) }
            }
    }
}

#if NOLLIE_DIRECT
/// Looks once at launch for traces an earlier Nollie left behind when it was dragged to the Trash,
/// and offers to clear them up.
private struct LeftoverOffer: ViewModifier {
    @State private var found: RemovalLeftovers?

    func body(content: Content) -> some View {
        content
            .task { found = await look() }
            .sheet(item: $found) { LeftoverSetupSheet(leftover: $0).withAppModel() }
    }

    private func look() async -> RemovalLeftovers? {
        guard !DemoMode.isOn else { return demoLeftover }
        let selected = UserDefaults.standard.string(forKey: MacHermesSetup.selectedInstallationKey)
        return RemovalLeftovers.find(.thisDevice(), selected: selected)
    }

    /// The demo copy shows no real traces, only the one a launch flag asks for.
    private var demoLeftover: RemovalLeftovers? {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-nollie-demo-leftover") {
            return RemovalLeftovers(installationID: UUID(), note: nil)
        }
        #endif
        return nil
    }
}
#endif

/// Where the Go menu can take the person. Settings has its own command in the app menu.
enum MacPages {
    static let order: [AppModel.AppTab] = [.chats, .kanban, .cron]

    private static let names: [AppModel.AppTab: String] = [.bots: "All Bots", .cron: "Schedules"]

    static func title(_ tab: AppModel.AppTab) -> String { names[tab] ?? tab.title }
}

/// Hides the window until Touch ID or the account password succeeds.
private struct MacLockCover: View {
    var body: some View {
        VStack(spacing: 14) {
            padlock
            title
            if let text = model.lock.lastError { reason(text) }
            unlock
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Ink.canvas)
        .task { await model.lock.unlock() }
    }

    @Environment(AppModel.self) private var model

    private var padlock: some View {
        Image(systemName: "lock.fill")
            .foregroundStyle(.secondary)
            .font(.system(size: 34).weight(.medium))
    }

    private var title: some View {
        Text("Nollie is locked").font(.headline)
    }

    private func reason(_ text: String) -> some View {
        Text(text).foregroundStyle(.secondary).font(.footnote)
    }

    private var unlock: some View {
        Button("Unlock with \(model.lock.biometryName)") { Task { await model.lock.unlock() } }
            .keyboardShortcut(.defaultAction)
            .buttonStyle(.nollieGlassProminent)
    }
}
