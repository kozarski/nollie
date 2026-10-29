import SwiftUI
import UserNotifications
import NollieCore

/// One real setup step at a time. The saved progress contains choices, never credentials
/// or a cached claim that a service or system permission is ready.
struct OnboardingView: View {
    var skipWelcome = false
    var onPreviewFinished: (() -> Void)? = nil
    #if DEBUG
    var fixtureProgress: OnboardingProgress? = nil
    #endif
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.scenePhase) private var scenePhase
    @ScaledMetric(relativeTo: .largeTitle) private var desktopTitleSize: CGFloat = 38
    @ScaledMetric(relativeTo: .body) private var desktopBodySize: CGFloat = 17
    @AppStorage(OnboardingProgress.storageKey) private var savedProgress = ""
    @AppStorage(WelcomeIntroTimeline.seenKey) private var welcomeIntroSeen = false
    @AppStorage(ModelPreferenceStore.key) private var savedModelMode = ModelSetupMode.local.rawValue
    @State private var previewProgress = OnboardingProgress()
    @State private var destination: Destination?
    @State private var modelStatus: OnboardingModelStatus?
    @State private var computerConfigured: Bool?
    /// The computer step's toggle: on means setup is under way or done.
    @State private var computerSwitchOn = false
    @State private var checkError: String?
    @State private var checking = false
    @State private var currentCheck: UUID?
    @State private var lastCheckIdentity: String?
    @State private var introDecisionMade = false
    @State private var introActive = false
    @State private var introPoseHeld = false
    @State private var introStartedAt = Date()
    #if os(macOS)
    @State private var localSetup = MacHermesSetup()
    @State private var managedConnectionTask: Task<Void, Never>?
    @State private var managedConnectionRequest: UUID?
    @State private var compactDesktop = true
    @Environment(\.dismissWindow) private var dismissWindow
    #endif

    private enum Destination: String, Identifiable {
        case gateway, pairing, models, backup, setupOverview, importReview, stepDetails, optionalCloud, link
        var id: String { rawValue }
    }

    private var isPreview: Bool {
        #if DEBUG
        let args = ProcessInfo.processInfo.arguments
        return fixtureProgress != nil || workingPreview || installStepPreview || demoIntroRequested || args.contains("-nollie-show-welcome") || args.contains("-nollie-show-tour")
        #else
        return false
        #endif
    }

    private var workingPreview: Bool {
        #if DEBUG && os(macOS)
        DemoMode.isOn && ProcessInfo.processInfo.arguments.contains("-nollie-demo-install-working")
        #else
        false
        #endif
    }

    /// The demo copy opens on the setup step as it really is on this Mac (nothing installed for the demo).
    private var installStepPreview: Bool {
        #if DEBUG && os(macOS)
        DemoMode.isOn && ProcessInfo.processInfo.arguments.contains("-nollie-demo-install-step")
        #else
        false
        #endif
    }

    private var isFixture: Bool {
        #if DEBUG
        fixtureProgress != nil
        #else
        false
        #endif
    }

    private var demoIntroTime: Double? {
        #if DEBUG
        let args = ProcessInfo.processInfo.arguments
        guard DemoMode.isOn, let i = args.firstIndex(of: "-nollie-demo-welcome-intro-time"),
              args.indices.contains(i + 1), let time = Double(args[i + 1]), time.isFinite else { return nil }
        return min(WelcomeIntroTimeline.duration, max(0, time))
        #else
        return nil
        #endif
    }

    #if DEBUG
    private static var demoStepName: String? {
        let args = ProcessInfo.processInfo.arguments
        guard let at = args.firstIndex(of: "-nollie-demo-onboarding-step"), args.indices.contains(at + 1) else { return nil }
        return args[at + 1]
    }
    #endif

    private var demoIntroRequested: Bool {
        #if DEBUG
        return DemoMode.isOn && (ProcessInfo.processInfo.arguments.contains("-nollie-demo-welcome-intro") || demoIntroTime != nil)
        #else
        return false
        #endif
    }

    private var introEligible: Bool {
        !skipWelcome && (!isPreview || demoIntroRequested) && progress.step == .welcome &&
            WelcomeIntroTimeline.shouldPlay(hasConnections: model.hasConnections, hasSavedProgress: !savedProgress.isEmpty,
                                            hasSeenIntro: welcomeIntroSeen, reduceMotion: reduceMotion,
                                            isFixture: isFixture, demoRequested: demoIntroRequested)
    }

    private var introVisible: Bool {
        progress.step == .welcome && (introActive || (!introDecisionMade && introEligible))
    }

    private var progress: OnboardingProgress {
        get {
            #if DEBUG
            if let fixtureProgress { return fixtureProgress }
            #endif
            return isPreview ? previewProgress : .parse(savedProgress)
        }
        nonmutating set {
            if isPreview { previewProgress = newValue }
            else { savedProgress = newValue.encoded }
        }
    }

    private var runtime: GatewayRuntime? {
        guard let rt = model.runtime else { return nil }
        return progress.connectionID == nil || progress.connectionID == rt.connection.id ? rt : nil
    }
    private var connected: Bool { runtime?.socketState.isOpen == true }
    private var assistantName: String { progress.preferences.resolvedAssistantName }
    private var focusProfile: String? { runtime?.selectedProfile }
    private var checkIdentity: String {
        "\(runtime?.connection.id.uuidString ?? "")/\(focusProfile ?? "default")/\(connected)"
    }

    private var contentWidth: CGFloat {
        #if os(macOS)
        640
        #else
        440
        #endif
    }

    private var heroSize: CGFloat {
        #if os(macOS)
        progress.step == .welcome ? (compactDesktop ? 176 : 208)
            : (compactDesktop ? (progress.step == .home ? 44 : 56) : 88)
        #else
        progress.step == .welcome ? 164 : progress.step == .howItWorks ? 56 : 92
        #endif
    }

    private var headlineFont: Font {
        #if os(macOS)
        .system(size: desktopTitleSize * (progress.step == .welcome ? 1.12 : compactDesktop ? 0.76 : 0.9), weight: .bold, design: .rounded)
        #else
        .system(.largeTitle, design: .rounded, weight: .bold)
        #endif
    }

    private var introductionFont: Font {
        #if os(macOS)
        .system(size: desktopBodySize * (compactDesktop ? 0.88 : 1))
        #else
        .body
        #endif
    }

    private var showsInstallerCharacter: Bool {
        #if os(macOS)
        progress.step == .connection && progress.route == .new
        #else
        false
        #endif
    }

    var body: some View {
        Group {
            #if DEBUG
            if isFixture { snapshotContents }
            else { presentation }
            #else
            presentation
            #endif
        }
        .overlayPreferenceValue(WelcomeHeroAnchorKey.self) { anchor in
            if introVisible {
                GeometryReader { geometry in
                    let target = anchor.map { geometry[$0] } ?? CGRect(x: (geometry.size.width - heroSize) / 2,
                                                                       y: geometry.size.height * 0.26,
                                                                       width: heroSize, height: heroSize)
                    WelcomeIntroView(startedAt: introStartedAt, heroFrame: target, size: geometry.size,
                                     fixedTime: demoIntroTime, skip: { finishIntro() })
                }
                .clipShape(.rect(cornerRadius: 32))
                .transition(.opacity)
            }
        }
        .tint(.blue)
        .task {
            guard !isFixture else { return }
            prepareIntro()
            #if DEBUG && os(iOS)
            if DemoMode.isOn && ProcessInfo.processInfo.arguments.contains("-nollie-demo-pairing") {
                destination = .pairing
            }
            #endif
            #if DEBUG
            // For pictures: `-nollie-demo-onboarding-step permissions|ready` opens that step.
            if DemoMode.isOn, let name = Self.demoStepName, let step = OnboardingProgress.Step(rawValue: name) {
                previewProgress.route = .new
                previewProgress.step = step
            }
            #endif
            if workingPreview || installStepPreview {
                previewProgress.route = .new
                previewProgress.step = .connection
                if workingPreview { return }
            }
            syncModelPreference()
            if skipWelcome, progress.step == .welcome { update { $0.step = .home } }
            if !isPreview {
                let matchingConnection = progress.connectionID.map { id in model.store.connections.contains { $0.id == id } } ?? model.hasConnections
                update {
                    #if os(iOS)
                    $0.resumeOnPhone(hasConnection: matchingConnection)
                    #else
                    $0.resume(hasConnection: matchingConnection)
                    #endif
                }
            }
            await model.push.refreshAuthorization()
            #if os(macOS)
            await localSetup.inspect()
            #endif
        }
        .task(id: "\(checkIdentity)/\(progress.step.rawValue)") {
            await refreshChecks()
        }
        .task(id: introActive) {
            guard introActive, demoIntroTime == nil else { return }
            do { try await Task.sleep(for: .seconds(WelcomeIntroTimeline.duration)) }
            catch { return }
            finishIntro()
        }
        .task(id: introVisible) {
            guard !introVisible, introPoseHeld else { return }
            do { try await Task.sleep(for: .seconds(0.25)) }
            catch { return }
            introPoseHeld = false
        }
        .onChange(of: reduceMotion) { _, reduced in
            if reduced { finishIntro(animated: false) }
        }
        #if os(macOS)
        .onChange(of: model.lock.isLocked) { _, locked in
            if locked { cancelManagedConnection() }
        }
        .onDisappear { cancelManagedConnection() }
        #endif
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { finishIntro(animated: false) }
            #if os(macOS)
            if phase == .background { cancelManagedConnection() }
            #endif
            if phase == .active && !workingPreview && !isFixture {
                Task {
                    await model.push.refreshAuthorization()
                    await refreshChecks()
                    #if os(macOS)
                    await localSetup.inspect()
                    #endif
                }
            }
        }
    }

    @ViewBuilder private var presentation: some View {
        #if os(macOS)
        navigationContent
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .modifier(OnboardingDesktopGlass(opaque: reduceTransparency || contrast == .increased))
            .clipShape(.rect(cornerRadius: 32))
            .background(Color.clear)
            .onGeometryChange(for: Bool.self) { $0.size.height < 820 } action: { compactDesktop = $0 }
            .preference(key: OnboardingWindowHeightKey.self,
                        value: [.welcome, .home].contains(progress.step) ? 740 : 900)
            .onExitCommand { dismissWindow(id: MacWindow.main) }
        #else
        navigationContent
        #endif
    }

    @ViewBuilder private var navigationContent: some View {
        #if os(macOS)
        flowContent
        #else
        if isFixture { flowContent }
        else { NavigationStack { flowContent } }
        #endif
    }

    private var flowContent: some View {
        Group {
            #if os(macOS)
            VStack(spacing: 0) {
            desktopHeader
                .fixedSize(horizontal: false, vertical: true)
            ViewThatFits(in: .vertical) {
                stepContents.fixedSize(horizontal: false, vertical: true)
                VStack(spacing: 18) {
                    Text(title).font(.title2.bold()).multilineTextAlignment(.center)
                    Text("This window is a little small for this step.")
                        .foregroundStyle(.secondary).multilineTextAlignment(.center)
                    Button("Show this step") { destination = .stepDetails }
                        .buttonStyle(.nollieGlassProminent).controlSize(.large)
                }
                .padding(24)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            controls.fixedSize(horizontal: false, vertical: true)
            }
            #else
            ScrollView { stepContents }
            .scrollBounceBehavior(.basedOnSize)
            .scrollIndicators(.hidden)
            .id(progress.step)
            .background { background }
            .safeAreaInset(edge: .bottom, spacing: 0) { controls }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    if let previous = previousStep {
                        Button {
                            update { $0.step = previous }
                        } label: { Label("Back", systemImage: "chevron.left") }
                        .accessibilityIdentifier("onboarding.back")
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    if progress.step != .welcome {
                        Text(stepLabel).font(.caption).foregroundStyle(.secondary)
                            .accessibilityLabel(stepLabel)
                    }
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            #endif
        }
        .opacity(introVisible ? 0 : 1)
        .allowsHitTesting(!introVisible)
        .accessibilityHidden(introVisible)
        .sheet(item: $destination, onDismiss: { syncModelPreference(); Task { await refreshChecks() } }) { target in
            sheet(target).withAppModel()
        }
    }

    private var stepContents: some View {
        VStack(spacing: pageSpacing) {
            if !showsInstallerCharacter { hero }
            content.frame(maxWidth: contentWidth)
            if let checkError, progress.step != .model {
                Label(checkError, systemImage: "exclamationmark.circle")
                    .font(.footnote).foregroundStyle(.secondary)
                    .frame(maxWidth: contentWidth, alignment: .leading)
            }
        }
        .frame(maxWidth: DeviceWords.isMac ? 700 : 620)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 24)
        .padding(.vertical, pageSpacing)
    }

    private var pageSpacing: CGFloat {
        #if os(macOS)
        compactDesktop ? (progress.step == .home ? 10 : 12) : 20
        #else
        progress.step == .howItWorks ? 16 : 24
        #endif
    }

    #if DEBUG
    /// Offscreen pictures use the same content without a native scroll container.
    private var snapshotContents: some View {
        VStack(spacing: 0) {
            Text("Layout preview").font(.caption).foregroundStyle(.secondary).padding(.top, 16)
            stepContents
            controls
        }
        .background(background)
        .tint(.blue)
    }
    #endif

    #if os(macOS)
    private var desktopHeader: some View {
        HStack(spacing: 16) {
            if let previous = previousStep {
                Button { update { $0.step = previous } } label: {
                    Label("Back", systemImage: "chevron.left")
                }
                    .buttonStyle(OutlinePillStyle())
                    .accessibilityIdentifier("onboarding.back")
            }
            // Something to ask while Hermes installs or the model downloads.
            if [.connection, .model, .computer, .permissions].contains(progress.step), !connected || modelStatus?.isReady != true {
                QuickAnswerButton(place: .macSetup)
            }
            Spacer()
            if progress.step != .welcome {
                VStack(alignment: .trailing, spacing: 7) {
                    Text(stepLabel).font(.caption.weight(.medium)).foregroundStyle(.secondary)
                    HStack(spacing: 4) {
                        ForEach(progress.steps.filter { $0 != .welcome && $0 != .ready }, id: \.self) { step in
                            Capsule().fill(step == progress.step ? Color.blue : Color.primary.opacity(0.12))
                                .frame(width: step == progress.step ? 22 : 6, height: 6)
                        }
                    }
                    .accessibilityHidden(true)
                }
            }
            Button { dismissWindow(id: MacWindow.main) } label: {
                Image(systemName: "xmark")
                    .font(.body.weight(.semibold))
                    .frame(width: 36, height: 36)
                    .contentShape(.rect)
            }
            .buttonStyle(OnboardingNeutralButtonStyle())
            .keyboardShortcut("w", modifiers: .command)
            .help("Close setup. You can continue later.")
            .accessibilityLabel("Close setup")
            .accessibilityIdentifier("onboarding.close")
        }
        .frame(minHeight: 32)
        .padding(.horizontal, 24).padding(.top, 16).padding(.bottom, 4)
        .contentShape(.rect)
        .gesture(WindowDragGesture())
        .allowsWindowActivationEvents()
    }
    #endif

    private var background: some View {
        ZStack {
            Color(.systemGroupedBackground)
            LinearGradient(colors: [Color.blue.opacity(0.08), .clear],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
        }
        .ignoresSafeArea()
    }

    private var hero: some View {
        VStack(spacing: pageSpacing) {
            ZStack {
                if progress.step == .welcome && !reduceTransparency && contrast != .increased {
                    Circle()
                        .fill(RadialGradient(colors: [.blue.opacity(0.20), .blue.opacity(0.07), .clear],
                                             center: .center, startRadius: 8, endRadius: heroSize * 0.70))
                        .frame(width: heroSize * 1.5, height: heroSize * 1.5)
                        .allowsHitTesting(false)
                }
                CharacterView(look: .main, state: progress.step == .welcome ? .idle : .listening, size: heroSize,
                              animated: !isFixture && !introPoseHeld)
                    .anchorPreference(key: WelcomeHeroAnchorKey.self, value: .bounds) { $0 }
            }
            .frame(height: heroSize * (progress.step == .welcome ? 1.16 : 1))
            .accessibilityHidden(true)
            VStack(spacing: 10) {
                Text(title)
                    .font(headlineFont)
                    .foregroundStyle(Color.primary)
                    .multilineTextAlignment(.center)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier("onboarding.title")
                Text(subtitle)
                    .font(introductionFont).foregroundStyle(Color.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: 490)
        }
    }

    private var title: String {
        #if os(iOS)
        if progress.step != .welcome && progress.step != .ready { return String(localized: "Set up Nollie on your Mac.") }
        #endif
        switch progress.step {
        case .welcome: return String(localized: "Meet Nollie.")
        case .home: return String(localized: "Let's get you started.")
        case .howItWorks: return String(localized: "How Nollie works")
        case .team: return String(localized: "Make it yours.")
        case .connection:
            if progress.route == .importCopy { return String(localized: "A copy, all your own.") }
            return progress.route == .new ? String(localized: "A home for \(assistantName).") : String(localized: "Bring your assistant along.")
        case .model: return String(localized: "Choose how Nollie thinks.")
        case .computer: return String(localized: "Their own computers.")
        case .permissions: return String(localized: "Allow a few things.")
        case .ready: return connected ? String(localized: "Ready when you are.") : String(localized: "One last connection check.")
        }
    }

    private var subtitle: String {
        #if os(iOS)
        if progress.step != .welcome && progress.step != .ready {
            return String(localized: "Your Mac does the work. Your iPhone keeps you connected.")
        }
        #endif
        switch progress.step {
        case .welcome: return String(localized: "A friendly assistant for everyday life.")
        case .home: return String(localized: "Start fresh, or use a setup you already have.")
        case .howItWorks: return String(localized: "A few things to know before setup.")
        case .team: return String(localized: "One assistant for everyday help.")
        case .connection:
            if progress.route == .importCopy { return String(localized: "Review a copy first. Your original stays as it is.") }
            if progress.route == .existing { return String(localized: "Your bots, chats, models, schedules and Board stay where they are.") }
            #if os(macOS)
            return String(localized: "A separate setup on this Mac for \(assistantName).")
            #else
            return String(localized: "Hermes runs on a Mac or server. This device connects to it when it's ready.")
            #endif
        case .model: return String(localized: "Where should your assistant think?")
        case .computer: return String(localized: "Room to work, away from your files.")
        case .permissions: return String(localized: "Nollie asks here, so nothing pops up later.")
        case .ready: return connected ? String(localized: "Start with a question or a task.") : String(localized: "Nollie can't reach your assistant yet.")
        }
    }

    private var stepLabel: String {
        #if os(iOS)
        return progress.step == .ready ? String(localized: "Ready when you are") : String(localized: "Connect to your Mac")
        #else
        let steps = progress.steps.filter { $0 != .welcome && $0 != .ready }
        guard let index = steps.firstIndex(of: progress.step) else { return String(localized: "Ready when you are") }
        return String(localized: "Step \(index + 1) of \(steps.count)")
        #endif
    }

    private var previousStep: OnboardingProgress.Step? {
        #if os(iOS)
        switch progress.step {
        case .welcome: nil
        case .home: .welcome
        default: .home
        }
        #else
        progress.previous
        #endif
    }

    @ViewBuilder private var content: some View {
        switch progress.step {
        case .welcome:
            WelcomeIdeasView(isActive: !introVisible, cyclesAutomatically: !isFixture)
        case .home:
            #if os(iOS)
            phonePairingStep
            #else
            VStack(spacing: 8) {
                choice("Start new", detail: "I'll help you set everything up.", symbol: "sparkles", id: "new", primary: true) {
                    update { $0.choose(.new) }
                }
                HStack(spacing: 12) {
                    Rectangle().fill(Color.primary.opacity(0.12)).frame(height: 1)
                    Text("Already use Hermes?")
                        .font(.subheadline.weight(.medium)).foregroundStyle(Color.secondary)
                        .fixedSize(horizontal: true, vertical: false)
                    Rectangle().fill(Color.primary.opacity(0.12)).frame(height: 1)
                }
                .padding(.vertical, 5)
                choice("Import Hermes", detail: "Bring a copy into Nollie.", symbol: "square.and.arrow.down", id: "importCopy") {
                    update { $0.choose(.importCopy) }
                }
                #if os(macOS)
                let found = localSetup.existingInstallationDetected == true
                #else
                let found = false
                #endif
                choice("Connect existing", detail: found ? "Existing setup found." : "Use your setup where it is.",
                       symbol: found ? "checkmark.circle.fill" : "link", id: "existing", found: found) {
                    update { $0.choose(.existing) }
                }
                #if os(macOS)
                if !found && model.hasConnections {
                    Label("A connection is already saved.", systemImage: "link")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                #endif
                HStack(spacing: 12) {
                    Button { destination = .setupOverview } label: {
                        Label("What is this?", systemImage: "questionmark.circle")
                    }
                    .buttonStyle(.nollieGlass)
                    .accessibilityIdentifier("onboarding.whatIsThis")
                    #if os(macOS)
                    if localSetup.existingInstallationDetected == nil {
                        Button { Task { await localSetup.checkThisMac() } } label: {
                            Label("Find my setup", systemImage: "magnifyingglass")
                        }
                        .buttonStyle(.nollieGlass)
                        .accessibilityIdentifier("onboarding.findExisting")
                    }
                    #endif
                }
                .padding(.top, 4)
            }
            .buttonStyle(.plain)
            #endif
        #if os(iOS)
        case .howItWorks, .team, .connection, .model, .computer, .permissions: phonePairingStep
        #else
        case .howItWorks: howItWorks
        case .team: team
        case .connection: connection
        case .model: modelStep
        case .computer: computerStep
        case .permissions: permissions
        #endif
        case .ready:
            VStack(spacing: 18) {
                #if os(iOS)
                statusRow("Your assistant", detail: connected ? String(localized: "Connected") : String(localized: "Reconnecting to your Mac"), ready: connected)
                // Asked here, with its reason, and only once the phone is connected.
                PermissionRows(center: model.permissions, kinds: [.notifications])
                Text("Keep your Mac awake and online. Other options are in Settings.")
                    .font(.callout).foregroundStyle(.secondary)
                #else
                statusRow("Your assistant", detail: connected ? String(localized: "Connected") : String(localized: "Not connected"), ready: connected)
                statusRow("Model", detail: readyDetail(.model, modelDetail), ready: modelStatus?.isReady == true)
                statusRow("Computer", detail: readyDetail(.computer, computerDetail), ready: computerConfigured == true ? true : nil)
                statusRow("Notifications", detail: readyDetail(.permissions, notificationDetail), ready: notificationsAllowed)
                if connected, NollieLinkMacClient.isAvailable(for: runtime?.connection) {
                    Button { destination = .link } label: { Label("Use Nollie on your iPhone", systemImage: "iphone") }
                        .buttonStyle(.nollieGlass).controlSize(.large)
                        .accessibilityIdentifier("onboarding.linkPhone")
                }
                #endif
            }
        }
    }

    #if os(iOS)
    private var phonePairingStep: some View {
        VStack(alignment: .leading, spacing: 18) {
            feature("Start on your Mac", "Install Nollie and set up your assistant.", symbol: "desktopcomputer")
            feature("Pair your iPhone", "On your Mac, open Settings and show the code.", symbol: "qrcode.viewfinder")
            Button("Connect manually") { destination = .gateway }
                .buttonStyle(.nollieGlass).accessibilityIdentifier("onboarding.connectManually")
            QuickAnswerButton(place: .phoneSetup)
        }
    }
    #endif

    private var howItWorks: some View {
        VStack(spacing: 0) {
            explanation("Everything in one place", "Chats, tasks and tools for your assistant, together.", symbol: "square.stack.3d.up")
            Divider().padding(.leading, 58)
            explanation("Keeps working", "Your crew keeps going with Nollie closed, while your Mac is awake.", symbol: "desktopcomputer")
            Divider().padding(.leading, 58)
            explanation("Where it thinks", "Local models stay on your Mac. Online models send your chats to that provider.", symbol: "cpu")
            Divider().padding(.leading, 58)
            explanation("You're in charge", "Using your Mac and iCloud are off until you say so.", symbol: "hand.raised")
        }
        .accessibilityIdentifier("onboarding.howItWorks")
    }

    private func explanation(_ title: LocalizedStringKey, _ detail: LocalizedStringKey, symbol: String) -> some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: symbol)
                .font(.title2.weight(.medium)).foregroundStyle(.blue)
                .frame(width: 42, height: 32)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    #if os(macOS)
                    .font(.system(size: desktopBodySize, weight: .semibold))
                    #else
                    .font(.headline)
                    #endif
                Text(detail).font(introductionFont).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, minHeight: compactLayout ? 68 : 80, alignment: .leading)
        .padding(.vertical, compactLayout ? 9 : 12)
        .accessibilityElement(children: .combine)
    }

    private var team: some View {
        OnboardingTeamStep(
            assistantName: Binding(get: { progress.preferences.assistantName }, set: { name in
                update(animated: false) { $0.preferences.assistantName = String(name.prefix(32)) }
            }),
            compact: compactLayout
        )
    }

    private var compactLayout: Bool {
        #if os(macOS)
        compactDesktop
        #else
        true
        #endif
    }

    @ViewBuilder private var connection: some View {
        if progress.route == .importCopy {
            #if os(macOS) && NOLLIE_DIRECT
            VStack(alignment: .leading, spacing: 18) {
                feature("Preview before copying", "Choose the original folder, review the files, then decide.", symbol: "doc.text.magnifyingglass")
                feature("Your original stays put", "Copies its instructions and settings. Chats, bots and schedules stay where they are.", symbol: "checkmark.shield")
                Button("Review the import") { destination = .importReview }
                    .buttonStyle(.nollieGlassProminent).controlSize(.large)
                    .accessibilityIdentifier("onboarding.import.review")
            }
            #else
            VStack(alignment: .leading, spacing: 18) {
                feature("Import needs the download version", "Get Nollie from nollie.app to import. You can connect to your setup instead.", symbol: "desktopcomputer")
                Button("Connect existing instead") { update { $0.choose(.existing) } }
                    .buttonStyle(.nollieGlassProminent)
                    .accessibilityIdentifier("onboarding.import.connectExisting")
            }
            #endif
        } else if progress.route == .existing {
            VStack(alignment: .leading, spacing: 18) {
                #if os(iOS)
                feature("Connect with a code", "On your Mac, open Settings and show the code.", symbol: "qrcode.viewfinder")
                Button("Connect manually") { destination = .gateway }
                    .buttonStyle(.nollieGlass).accessibilityIdentifier("onboarding.connectManually")
                #else
                feature("Your setup stays yours", "Nollie only saves how to reach it. Your files stay as they are.", symbol: "checkmark.shield")
                Button { destination = .backup } label: { Label("Back up first", systemImage: "externaldrive.badge.timemachine") }
                    .buttonStyle(.nollieGlass)
                    .accessibilityIdentifier("onboarding.backup")
                #endif
            }
        } else {
            #if os(macOS)
            NativeSetupChecklistView(setup: localSetup, preferences: progress.preferences,
                                     connect: connectManagedAssistant,
                                     isConnecting: managedConnectionRequest != nil, isLocked: model.lock.isLocked,
                                     containedInGlass: true,
                                     previewWorking: workingPreview, compact: compactDesktop)
            #else
            VStack(alignment: .leading, spacing: 20) {
                feature("Start on a Mac", "Open Nollie on your Mac and choose Start new.", symbol: "desktopcomputer")
                feature("Then scan its code", "On your Mac, open Settings and show the code.", symbol: "qrcode.viewfinder")
                Button("Connect manually") { destination = .gateway }
                    .buttonStyle(.nollieGlass).accessibilityIdentifier("onboarding.haveGateway")
            }
            #endif
        }
    }

    private var modelPreference: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 12) {
                ForEach(ModelSetupMode.allCases) { preference in
                    modelPreferenceCard(preference, stacked: false)
                        .frame(minWidth: 174, maxWidth: .infinity)
                }
            }
            VStack(spacing: 10) {
                ForEach(ModelSetupMode.allCases) { preference in
                    modelPreferenceCard(preference, stacked: true)
                }
            }
        }
        .accessibilityIdentifier("onboarding.modelPreference")
    }

    private var modelStep: some View {
        VStack(spacing: 18) {
            modelPreference
            HStack(spacing: 14) {
                if checking && modelStatus == nil {
                    ProgressView().controlSize(.small).frame(width: 24)
                } else {
                    Image(systemName: modelStatus?.isReady == true ? "checkmark.circle.fill" : "circle.dotted")
                        .font(.title3).foregroundStyle(modelStatus?.isReady == true ? Color.readableGreen : Color.secondary)
                        .frame(width: 24).accessibilityHidden(true)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Your model").font(.subheadline.weight(.semibold))
                    Text(onboardingModelDetail).font(.subheadline).foregroundStyle(.secondary)
                        .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, minHeight: 54, alignment: .leading)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("onboarding.modelStatus")
            Button { destination = .models } label: {
                Text(LocalModelQuickstartSection.scope(for: runtime) != nil && progress.preferences.modelMode != .cloud
                     ? "Set up your local model" : "Choose a model").font(.body.weight(.semibold))
                    .padding(.horizontal, 8)
            }
            .buttonStyle(.nollieGlass).controlSize(.large)
            .disabled(runtime == nil)
            .accessibilityIdentifier("onboarding.models")
        }
    }

    private var onboardingModelDetail: String {
        if checking && modelStatus == nil { return String(localized: "Checking your model…") }
        if checkError != nil && modelStatus == nil { return String(localized: "Couldn't check your model yet.") }
        if !connected { return String(localized: "Reconnect to check.") }
        return modelDetail
    }

    private func modelPreferenceCard(_ preference: ModelSetupMode, stacked: Bool) -> some View {
        let selected = progress.preferences.modelMode == preference
        let symbol: String = switch preference {
        case .local: "desktopcomputer"
        case .cloud: "cloud"
        case .both: "square.stack.3d.up"
        }
        let detail: String = switch preference {
        case .local: String(localized: "Private and free. Runs on this Mac.")
        case .cloud: String(localized: "Uses your ChatGPT or Claude plan.")
        case .both: String(localized: "This Mac first, online when it helps.")
        }
        return Button {
            savedModelMode = preference.rawValue
            update(animated: false) { $0.preferences.modelMode = preference }
        } label: {
            let layout = stacked ? AnyLayout(HStackLayout(spacing: 14)) : AnyLayout(VStackLayout(alignment: .leading, spacing: 12))
            layout {
                Image(systemName: symbol).font(.system(size: 25, weight: .medium))
                    .foregroundStyle(selected ? Color.blue : Color.secondary)
                    .frame(width: 32, height: 30).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 5) {
                    Text(preference.title).font(.title3.weight(.semibold)).foregroundStyle(.primary)
                    Text(detail).font(.subheadline).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(18)
            .frame(maxWidth: .infinity, minHeight: stacked ? 76 : 142, alignment: .leading)
            .overlay(alignment: .topTrailing) {
                if selected {
                    Image(systemName: "checkmark.circle.fill").font(.body.weight(.semibold)).foregroundStyle(.blue)
                        .padding(12).accessibilityHidden(true)
                }
            }
        }
        .buttonStyle(OnboardingNeutralButtonStyle())
        .overlay {
            RoundedRectangle(cornerRadius: Ink.cardRadius, style: .continuous).strokeBorder(selected ? Color.blue : .clear, lineWidth: 2)
                .allowsHitTesting(false)
        }
        .accessibilityLabel(String(localized: "\(preference.title). \(detail)", comment: "A choice's name, then its line"))
        .accessibilityValue(selected ? "Selected" : "Not selected")
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("onboarding.modelPreference.\(preference.rawValue)")
    }

    @ViewBuilder private var computerStep: some View {
        #if os(macOS)
        if connected, let rt = runtime {
            OnboardingComputerStep(runtime: rt, profile: focusProfile ?? "default", name: assistantName) { on in
                computerSwitchOn = on
            }
        } else {
            VStack(alignment: .leading, spacing: 18) {
                statusRow("Computers", detail: computerDetail, ready: nil)
                reconnectButton
            }
        }
        #else
        EmptyView()
        #endif
    }

    private var permissions: some View {
        VStack(alignment: .leading, spacing: 14) {
            PermissionRows(center: model.permissions, kinds: PermissionKind.inSetup)
                .accessibilityIdentifier("onboarding.permissions")
            Text("Using your Mac comes later, and only if you turn it on. Change any of these in \(DeviceWords.settings).")
                .font(.subheadline).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Divider()
            feature("Alerts on your iPhone", "Send alerts through your iCloud to Nollie on your other devices. Optional.", symbol: "icloud")
            Button("iCloud alerts…") { destination = .optionalCloud }
                .buttonStyle(.nollieGlass)
                .accessibilityIdentifier("onboarding.reviewCloud")
        }
    }

    private var controls: some View {
        Group {
            VStack(spacing: 8) {
                if showsPrimaryControl {
                    Button(action: primaryAction) {
                        Text(primaryTitle).font(.title3.weight(.semibold))
                            .frame(maxWidth: .infinity).padding(.vertical, 16)
                    }
                    .buttonStyle(OnboardingPrimaryButtonStyle())
                    .disabled(primaryDisabled)
                    .accessibilityIdentifier("onboarding.continue")
                }
                if [.welcome, .home].contains(progress.step), !isFixture {
                    // After the main path, never instead of it.
                    Button { Task { await model.startDemo() } } label: {
                        Text("Try a demo")
                            .font(.subheadline.weight(.medium)).foregroundStyle(.primary).padding(.horizontal, 6)
                    }
                    .buttonStyle(.nollieGlass).controlSize(.large).tint(.primary)
                    .accessibilityIdentifier("onboarding.tryDemo")
                }
                #if os(iOS)
                Button { update { $0.skip() } } label: {
                    Text(progress.step == .welcome ? "Skip setup" : "Finish setup later")
                        .font(.subheadline.weight(.medium)).foregroundStyle(.primary).padding(.horizontal, 6)
                }
                .buttonStyle(.nollieGlass).controlSize(.large).tint(.primary)
                .accessibilityIdentifier("onboarding.skip")
                #else
                if [.model, .computer, .permissions].contains(progress.step) {
                    Button(progress.step == .permissions ? "Not now" : "Set up later") { update { $0.advance(deferStep: true) } }
                        .buttonStyle(OutlinePillStyle())
                        .accessibilityIdentifier("onboarding.later")
                } else if [.welcome, .home, .howItWorks].contains(progress.step) || showsInstallerCharacter {
                    Button { update { $0.skip() } } label: {
                        Text(progress.step == .welcome ? "Skip setup" : "Finish setup later")
                            .font(.subheadline.weight(.medium)).foregroundStyle(.primary).padding(.horizontal, 6)
                    }
                        .buttonStyle(.nollieGlass).controlSize(.large).tint(.primary)
                        .accessibilityIdentifier("onboarding.skip")
                } else {
                    Button(progress.step == .welcome ? "Skip setup" : "Finish setup later") { update { $0.skip() } }
                        .buttonStyle(OutlinePillStyle())
                        .accessibilityIdentifier("onboarding.skip")
                }
                #endif
            }
            .frame(maxWidth: progress.step == .welcome ? 360 : contentWidth)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 24).padding(.top, 8).padding(.bottom, 16)
        .background {
            #if os(macOS)
            Color.clear
            #else
            // Fades in from above, so there is no hard edge over the page.
            Rectangle().fill(.regularMaterial)
                .mask(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.45)],
                                     startPoint: .top, endPoint: .bottom))
                .ignoresSafeArea(edges: .bottom)
            #endif
        }
    }

    private var showsPrimaryControl: Bool {
        #if os(iOS)
        return true
        #else
        if progress.step == .home { return false }
        if progress.step == .connection {
            if progress.route == .importCopy { return false }
            #if os(macOS)
            if progress.route == .new { return false }
            #endif
        }
        return true
        #endif
    }

    private var primaryTitle: String {
        #if os(iOS)
        if progress.step != .welcome && progress.step != .ready { return String(localized: "Scan QR code") }
        #endif
        switch progress.step {
        case .welcome: return String(localized: "Get started")
        case .home, .howItWorks, .team: return String(localized: "Continue")
        case .connection:
            if progress.route == .importCopy { return String(localized: "Import is not available yet") }
            #if os(iOS)
            return String(localized: "Scan QR code")
            #else
            if progress.route == .existing { return String(localized: "Connect") }
            if managedConnectionRequest != nil { return String(localized: "Connecting…") }
            return localSetup.canConnect ? String(localized: "Connect") : String(localized: "Finish setup to connect")
            #endif
        case .model, .computer, .permissions: return String(localized: "Continue")
        case .ready: return connected ? String(localized: "Start chatting") : String(localized: "Check connection")
        }
    }

    private var primaryDisabled: Bool {
        #if os(iOS)
        return model.lock.isLocked || checking
        #else
        switch progress.step {
        case .connection:
            if progress.route == .importCopy { return true }
            #if os(macOS)
            return model.lock.isLocked || (progress.route == .new &&
                (!localSetup.canConnect || localSetup.isBusy || managedConnectionRequest != nil))
            #else
            return false
            #endif
        case .model: return !connected || modelStatus?.isReady != true
        case .computer: return !connected || !(computerSwitchOn || computerConfigured == true)
        case .ready: return checking
        default: return false
        }
        #endif
    }

    private func primaryAction() {
        #if os(iOS)
        if progress.step != .welcome && progress.step != .ready { destination = .pairing; return }
        #endif
        switch progress.step {
        case .welcome: update { $0.step = .home }
        case .home: break
        case .howItWorks, .team: update { $0.advance() }
        case .connection:
            guard progress.route != .importCopy else { return }
            #if os(macOS)
            if progress.route == .existing { destination = .gateway }
            else if progress.route == .new { connectManagedAssistant() }
            #else
            destination = .pairing
            #endif
        case .model, .computer, .permissions: update { $0.advance() }
        case .ready:
            if connected {
                update { $0.finish(connected: true) }
                if !isPreview {
                    let profile = focusProfile ?? "default"
                    Task { await model.openMainChat(profile) }
                }
            }
            else { Task { await model.activateSavedConnection(); await refreshChecks() } }
        }
    }

    #if os(macOS)
    private func connectManagedAssistant() {
        guard !isPreview, !DemoMode.isOn, !model.lock.isLocked, progress.route == .new,
              progress.step == .connection, localSetup.canConnect, !localSetup.isBusy,
              !localSetup.managedRuntime.isBusy,
              managedConnectionRequest == nil, let installationID = localSetup.installationID else { return }
        let request = UUID()
        managedConnectionRequest = request
        checkError = nil
        managedConnectionTask = Task { @MainActor in
            let originalActiveID = model.store.activeConnectionID
            var savedConnectionID: UUID?
            let isCurrent = {
                !Task.isCancelled && self.managedConnectionRequest == request && !self.model.lock.isLocked
                    && self.progress.route == .new && self.progress.step == .connection
                    && self.localSetup.installationID == installationID
                    && (self.model.store.activeConnectionID == originalActiveID
                        || (savedConnectionID != nil && self.model.store.activeConnectionID == savedConnectionID))
            }
            defer {
                if managedConnectionRequest == request {
                    managedConnectionRequest = nil
                    managedConnectionTask = nil
                }
            }
            do {
                let prepared = try await localSetup.prepareConnection(name: assistantName,
                    connections: { model.store.connections }, isCurrent: isCurrent)
                guard isCurrent() else { return }
                savedConnectionID = prepared.connection.id
                try model.store.upsert(prepared.connection, secrets: prepared.secrets)
                if let runtime = model.runtime, runtime.connection.id == prepared.connection.id {
                    guard isCurrent() else { return }
                    await runtime.replaceSecrets(prepared.secrets)
                } else {
                    await model.activate(prepared.connection, ifCurrent: isCurrent)
                }
                guard isCurrent(), model.runtime?.connection.id == prepared.connection.id else { return }
                update { $0.connected(prepared.connection.id) }
            } catch is CancellationError {
                return
            } catch {
                guard isCurrent() else { return }
                checkError = String(localized: "Couldn't finish connecting. Check the service, then try again.")
            }
        }
    }

    private func cancelManagedConnection() {
        managedConnectionRequest = nil
        managedConnectionTask?.cancel()
        managedConnectionTask = nil
    }
    #endif

    @ViewBuilder private func sheet(_ target: Destination) -> some View {
        switch target {
        case .setupOverview:
            detailSheet("Your setup") {
                feature("Start new", "A fresh home for your assistant on this Mac. You pick its name and model.", symbol: "sparkles")
                feature("Import Hermes", "Hermes is the engine behind your assistant. Import copies its instructions and settings into Nollie. Your original stays as it is.", symbol: "doc.on.doc")
                feature("Connect existing", "Use the Hermes you already run, where it is. Nothing in it changes.", symbol: "link")
            }
        case .stepDetails:
            detailSheet("Setup details") { stepContents }
        case .importReview:
            #if os(macOS) && NOLLIE_DIRECT
            detailSheet("Import Hermes") {
                ConfigurationImportView(setup: localSetup, preferences: progress.preferences,
                                        connectExisting: { destination = nil; update { $0.choose(.existing) } },
                                        backup: { destination = .backup },
                                        continueSetup: { destination = nil; update { $0.route = .new; $0.step = .connection } })
            }
            #else
            detailSheet("Import Hermes") { Text("Import needs the download version of Nollie from nollie.app.") }
            #endif
        case .optionalCloud:
            detailSheet("iCloud alerts") {
                CloudAlertsControls()
                Text("Your Mac needs to stay awake and online.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        case .link:
            #if os(macOS)
            NollieLinkSheet().withAppModel()
            #else
            EmptyView()
            #endif
        case .pairing:
            #if os(iOS)
            PhoneDevicePairingView { connection in
                update { $0.paired(connection.id) }
            }
            .sheetFrame().withAppModel()
            #else
            EmptyView()
            #endif
        case .gateway:
            NavigationStack {
                GatewayFormView(existing: progress.step == .connection ? nil : runtime?.connection,
                                initialURL: newGatewayURL, initialName: progress.route == .new ? assistantName : nil,
                                initialSessionToken: newGatewayToken,
                                initialManagedInstallationID: newManagedInstallationID) { connection in
                    update {
                        #if os(iOS)
                        $0.paired(connection.id)
                        #else
                        $0.connected(connection.id)
                        #endif
                    }
                }
            }
            .sheetFrame().withAppModel()
        case .models:
            NavigationStack {
                ModelPreferencesView(showsPreference: false)
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { destination = nil } } }
            }
            .sheetFrame().withAppModel()
        case .backup:
            NavigationStack {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        Text("Back up your settings").font(.title2.bold())
                        Text("Saves a copy of your settings and instructions. Chats, bots and schedules aren't included. Keep it somewhere private.")
                            .foregroundStyle(.secondary)
                        #if os(macOS)
                        Text("Pick your Hermes folder, then where to save the copy.")
                            .foregroundStyle(.secondary)
                        Button(localSetup.backupCompleted ? "Back up again" : "Back up") {
                            Task { await localSetup.backupExisting() }
                        }
                        .buttonStyle(.nollieGlassProminent)
                        .disabled(localSetup.isBusy || !localSetup.nativeBackupAvailable)
                        .accessibilityIdentifier("onboarding.backup.run")
                        if localSetup.backupCompleted {
                            Label("Backed up and checked", systemImage: "checkmark.circle.fill")
                                .foregroundStyle(Color.readableGreen)
                                .accessibilityIdentifier("onboarding.backup.verified")
                        }
                        if localSetup.backupCompleted {
                            Text(localSetup.backupDetail).font(.footnote).foregroundStyle(.secondary)
                        }
                        if let error = localSetup.error { Text(error).font(.footnote).foregroundStyle(.red) }
                        #else
                        Text("Back up from Nollie on the Mac that runs Hermes.")
                            .font(.footnote).foregroundStyle(.secondary)
                        #endif
                    }
                    .padding(24)
                }
                .navigationTitle("Backup")
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { destination = nil } } }
            }
            .sheetFrame().withAppModel()
        }
    }

    private func detailSheet<Content: View>(_ title: LocalizedStringKey, @ViewBuilder content: () -> Content) -> some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20, content: content)
                    .frame(maxWidth: 560, alignment: .leading)
                    .frame(maxWidth: .infinity).padding(24)
            }
            .navigationTitle(title)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { destination = nil } } }
        }
        .sheetFrame().withAppModel()
    }

    private var newGatewayURL: String? {
        #if os(macOS)
        progress.route == .new ? localSetup.gatewayURL : nil
        #else
        nil
        #endif
    }

    private var newGatewayToken: String? {
        #if os(macOS)
        guard progress.route == .new, localSetup.canConnect, localSetup.gatewayURL != nil else { return nil }
        return localSetup.connectionToken
        #else
        nil
        #endif
    }

    private var newManagedInstallationID: UUID? {
        #if os(macOS) && NOLLIE_DIRECT
        guard progress.route == .new, localSetup.canConnect else { return nil }
        return localSetup.installationID
        #else
        return nil
        #endif
    }

    private var reconnectButton: some View {
        Button("Reconnect") { destination = .gateway }
            .buttonStyle(.nollieGlass)
            .accessibilityIdentifier("onboarding.reconnect")
    }

    private var notificationsAllowed: Bool {
        model.push.authorization == .authorized || model.push.authorization == .provisional
    }
    private var notificationDetail: String {
        switch model.push.authorization {
        case .authorized: return String(localized: "Allowed on this device")
        case .provisional: return String(localized: "Quiet notifications allowed")
        case .denied: return String(localized: "Off in System Settings")
        default: return String(localized: "Not on yet")
        }
    }
    /// A step put off during setup says so on the Ready step, right where you look for it.
    private func readyDetail(_ step: OnboardingProgress.Step, _ detail: String) -> String {
        progress.deferred.contains(step) ? String(localized: "Set up later in Settings") : detail
    }
    private var modelDetail: String {
        switch modelStatus {
        case .ready(let model): return model
        case .needsSignIn: return String(localized: "Needs sign-in")
        case .unverified(let model): return String(localized: "\(model), not signed in yet")
        case .notConfigured: return String(localized: "No model selected yet")
        case nil: return connected ? String(localized: "Not checked yet") : String(localized: "Reconnect to check")
        }
    }
    private var computerDetail: String {
        switch computerConfigured {
        case true: return String(localized: "Ready")
        case false: return computerSwitchOn ? String(localized: "Getting ready") : String(localized: "Not set up yet. You can turn it on in Bot settings.")
        case nil: return String(localized: "Not checked yet")
        }
    }

    private func refreshChecks() async {
        #if os(iOS)
        return
        #else
        guard !workingPreview && !isFixture else { return }
        if lastCheckIdentity != checkIdentity {
            lastCheckIdentity = checkIdentity
            currentCheck = nil
            checking = false
            modelStatus = nil
            computerConfigured = nil
            checkError = nil
        }
        guard [.model, .computer, .ready].contains(progress.step),
              let rt = runtime, connected else { return }
        let check = UUID()
        let identity = checkIdentity
        let profile = focusProfile
        currentCheck = check
        checking = true
        modelStatus = nil
        computerConfigured = nil
        checkError = nil
        defer { if currentCheck == check { checking = false } }
        do {
            let options: ModelOptionsResult = try await rt.api.get("/api/model/options", profile: profile)
            guard checkIdentity == identity, currentCheck == check, !Task.isCancelled else { return }
            modelStatus = .read(options)
            // The main helper's own computer, from the computer add-on. Without the add-on: not yet.
            let own: HelperComputerStatus? = try? await rt.api.get(HelperComputerStatus.path,
                                                                    query: [URLQueryItem(name: "profile", value: profile ?? "default")])
            guard checkIdentity == identity, currentCheck == check, !Task.isCancelled else { return }
            computerConfigured = own.map { $0.on && $0.state != .needsYou } ?? false
        } catch {
            guard checkIdentity == identity, currentCheck == check, !Task.isCancelled else { return }
            checkError = String(localized: "Couldn't check this setup. Your existing settings are unchanged.")
        }
        #endif
    }

    private func syncModelPreference() {
        guard !isPreview else { return }
        if UserDefaults.standard.object(forKey: ModelPreferenceStore.key) == nil {
            savedModelMode = progress.preferences.modelMode.rawValue
        } else if let mode = ModelSetupMode(rawValue: savedModelMode), mode != progress.preferences.modelMode {
            update(animated: false) { $0.preferences.modelMode = mode }
        }
    }

    private func update(animated: Bool = true, _ change: (inout OnboardingProgress) -> Void) {
        var next = progress
        change(&next)
        #if os(macOS)
        if next.step != progress.step || next.route != progress.route || next.completion != progress.completion {
            cancelManagedConnection()
        }
        #endif
        withAnimation(animated && !reduceMotion ? .smooth(duration: 0.25) : nil) { progress = next }
        if isPreview && next.completion != .inProgress { onPreviewFinished?() }
    }

    private func prepareIntro() {
        guard !introDecisionMade else { return }
        let play = introEligible
        introDecisionMade = true
        guard play else { return }
        introStartedAt = Date()
        introPoseHeld = true
        introActive = true
        if !demoIntroRequested { welcomeIntroSeen = true }
    }

    private func finishIntro(animated: Bool = true) {
        guard introVisible else { return }
        withAnimation(animated && !reduceMotion ? .easeOut(duration: 0.22) : nil) {
            introDecisionMade = true
            introActive = false
        }
    }

    private func feature(_ title: LocalizedStringKey, _ detail: LocalizedStringKey, symbol: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol).font(.title3).foregroundStyle(.blue)
                .frame(width: 28).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text(detail).font(.subheadline).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func choice(_ title: LocalizedStringKey, detail: LocalizedStringKey, symbol: String, id: String, primary: Bool = false, found: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 16) {
                Image(systemName: symbol).font(.title2).foregroundStyle(primary ? Color.white : found ? Color.readableGreen : Color.blue)
                    .frame(width: 38, height: 38).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 6) {
                    Text(title).font(primary ? .title2.bold() : .title3.weight(.semibold))
                        .foregroundStyle(primary ? Color.white : Color.primary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(detail).font(found ? .subheadline.weight(.medium) : .subheadline)
                        .foregroundStyle(primary ? Color.white.opacity(0.92) : found ? Color.primary : Color.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.footnote.weight(.semibold))
                    .foregroundStyle(primary ? Color.white.opacity(0.85) : Color.secondary)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 16).padding(.vertical, primary ? 16 : 12)
            .frame(maxWidth: .infinity, minHeight: primary ? 88 : 64, alignment: .leading)
        }
        .buttonStyle(OnboardingNeutralButtonStyle(emphasized: primary, found: found))
        .accessibilityIdentifier("onboarding.route.\(id)")
    }

    private func teamMember(_ name: String, role: String, detail: String, symbol: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol).font(.title3).foregroundStyle(.blue)
                .frame(width: 38, height: 38)
                .background(Color.blue.opacity(0.07), in: .circle)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(name).font(.headline)
                Text(role).font(.caption.weight(.medium)).foregroundStyle(.secondary)
                Text(detail).font(.subheadline).foregroundStyle(.secondary)
            }
        }
    }

    private func statusRow(_ title: LocalizedStringKey, detail: String, ready: Bool?) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: ready == true ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(ready == true ? Color.readableGreen : Color.secondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text(detail).font(.subheadline).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

#if os(macOS)
private struct OnboardingDesktopGlass: ViewModifier {
    var opaque: Bool
    func body(content: Content) -> some View {
        if opaque {
            content.background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 32))
                .overlay { RoundedRectangle(cornerRadius: 32).strokeBorder(.primary.opacity(0.25), lineWidth: 1) }
        } else {
            content.nollieGlass(.regular, in: .rect(cornerRadius: 32), solid: Color(nsColor: .windowBackgroundColor))
        }
    }
}
#endif

private struct OnboardingNeutralButtonStyle: ButtonStyle {
    var emphasized = false
    /// A soft green card for a setup Nollie already found on this Mac.
    var found = false
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    func makeBody(configuration: Configuration) -> some View {
        Group {
            if emphasized {
                configuration.label
                    .nollieGlass(.regular.tint(.blue).interactive(), in: .rect(cornerRadius: Ink.cardRadius, style: .continuous), solid: .blue)
            } else if found {
                configuration.label
                    .nollieGlass(.regular.tint(.green.opacity(0.28)).interactive(), in: .rect(cornerRadius: Ink.cardRadius, style: .continuous),
                                 solid: Color.green.opacity(0.16))
                    .overlay { RoundedRectangle(cornerRadius: Ink.cardRadius, style: .continuous).strokeBorder(Color.readableGreen.opacity(0.35), lineWidth: 1) }
            } else if reduceTransparency || contrast == .increased {
                configuration.label
                    .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: Ink.cardRadius, style: .continuous))
                    .overlay { RoundedRectangle(cornerRadius: Ink.cardRadius, style: .continuous).strokeBorder(.primary.opacity(0.3), lineWidth: 1) }
            } else {
                configuration.label.nollieGlass(.regular.interactive(), in: .rect(cornerRadius: Ink.cardRadius, style: .continuous))
            }
        }
        .foregroundStyle(Color.primary)
        .opacity(configuration.isPressed ? 0.8 : 1)
        .contentShape(.rect(cornerRadius: Ink.cardRadius, style: .continuous))
    }
}

struct OnboardingPrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(Ink.onInk)
            .nollieGlass(.regular.tint(Ink.ink), in: Capsule(), solid: Ink.ink)
            .opacity(isEnabled ? (configuration.isPressed ? 0.82 : 1) : 0.35)
            .contentShape(.capsule)
    }
}
