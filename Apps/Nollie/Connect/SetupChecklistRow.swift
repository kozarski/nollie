import SwiftUI
import NollieCore

enum SetupCheckState: Equatable {
    case notChecked, needed, working, ready, attention, optional

    var title: String {
        switch self {
        case .notChecked: String(localized: "Not checked", comment: "A setup step's state")
        case .needed: String(localized: "Not yet", comment: "A setup step's state")
        case .working: String(localized: "In progress", comment: "A setup step's state")
        case .ready: String(localized: "Ready", comment: "A setup step's state")
        case .attention: String(localized: "Needs attention", comment: "A setup step's state")
        case .optional: String(localized: "Optional", comment: "A setup step's state")
        }
    }
    var symbol: String {
        switch self {
        case .ready: "checkmark.circle.fill"
        case .attention: "exclamationmark.circle"
        default: "circle"
        }
    }
}

/// The expanded details describe real requirements. Readiness is supplied by a fresh check.
struct SetupChecklistRow<Details: View>: View {
    var title: String
    var subtitle: String
    var symbol: String
    var state: SetupCheckState
    var expanded = false
    @ViewBuilder var details: () -> Details
    @State private var isExpanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 14, content: details)
                .font(.subheadline)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 14)
        } label: {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: symbol)
                    .font(.title3).foregroundStyle(.blue)
                    .frame(width: 30, height: 30)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.headline).foregroundStyle(.primary)
                    Text(subtitle).font(.subheadline).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 5) {
                        if state == .working { ProgressView().controlSize(.mini) }
                        else { Image(systemName: state.symbol) }
                        Text(state.title)
                    }
                    .font(.caption.weight(.medium))
                    .foregroundStyle(state == .ready ? Color.readableGreen : .secondary)
                    .padding(.top, 3)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .tint(.secondary)
        .padding(18)
        .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 22))
        .onAppear { isExpanded = expanded }
    }
}

enum SetupTrailProgress {
    static func completedPrefix(_ states: [SetupCheckState]) -> Int {
        states.prefix(while: { $0 == .ready }).count
    }
    static func shouldCelebrate(wasReady: Bool, isReady: Bool, observedWork: Bool) -> Bool {
        !wasReady && isReady && observedWork
    }
}

#if os(macOS)
/// What the Mac's setup screen lists, apart from the view. Only rows a person can act on, or watch
/// finish, are shown: a copy of Nollie that can't run the background service shows no row for it.
enum SetupTrail {
    /// Exactly where to allow the background service, in the words System Settings uses.
    static var approvalSteps: String {
        String(localized: "Open System Settings › General › Login Items & Extensions and turn on Nollie under Allow in the Background. Then come back here.")
    }

    /// The preparation steps as one state: ready when all are, else the most telling one.
    static func rollUp(_ states: [NativeDependencyStep.State]) -> NativeDependencyStep.State {
        !states.isEmpty && states.allSatisfy({ $0 == .ready }) ? .ready
            : states.contains(.installing) ? .installing
            : states.contains(.failed) ? .failed
            : states.contains(.blocked) ? .blocked
            : states.contains(.notChecked) ? .notChecked : .needsInstall
    }

    /// The background service's row, from what the service reports.
    static func serviceState(_ state: ManagedRuntimeClient.State) -> NativeDependencyStep.State {
        switch state {
        case .ready: .ready
        case .starting: .installing
        case .requiresApproval, .unavailable: .blocked
        case .failed: .failed
        case .off, .stopped, .needsVerification: .needsInstall
        }
    }

    /// Only the Direct download with its signed background service can keep an assistant running.
    /// The Mac App Store edition, the demo copy and an unsigned build can't, so they show no row for it.
    static func showsService(direct: Bool, runtimeAvailable: Bool, state: ManagedRuntimeClient.State) -> Bool {
        direct && runtimeAvailable && state != .unavailable
    }

    /// One "Getting Nollie ready" row for the downloads, then the background service where it can run.
    static func rows(_ dependencies: [NativeDependencyStep], showsService: Bool) -> [NativeDependencyStep] {
        let preparation = dependencies.filter { NativeSetupPlan.preparationSteps.contains($0.id) }
        let summary = NativeDependencyStep(id: "prepare", title: String(localized: "Getting Nollie ready"), detail: "",
                                           state: rollUp(preparation.map(\.state)), optional: false)
        return [summary] + dependencies.filter { $0.id == "service" && showsService }
    }

    /// What a preparation step is doing, named with its size, so a bar that waits says why.
    static func partWords(_ id: String) -> String? {
        switch id {
        case "uv": String(localized: "Getting the download tool, 14 MB")
        case "python": String(localized: "Getting Python, 27 MB")
        case "hermes": String(localized: "Downloading Hermes, 91 MB")
        case "dependencies": String(localized: "Adding Hermes's libraries, about 40 MB")
        case "addons": String(localized: "Adding Nollie's add-ons, about 20 MB")
        default: nil
        }
    }

    /// A step that stopped, in plain words: what happened, that nothing else changed, what to do.
    /// The exact reason stays under "What's installed".
    static func plainFailure(step: String, reason: String) -> String {
        if reason == NativeSetupPlan.lowDiskMessage { return reason }
        let part: String = switch step {
        case "uv": String(localized: "the download tool")
        case "python": String(localized: "Python")
        case "hermes": String(localized: "Hermes")
        case "dependencies": String(localized: "Hermes's libraries")
        case "addons": String(localized: "Nollie's add-ons")
        default: String(localized: "a part of Nollie")
        }
        return String(localized: "Couldn't finish getting \(part). Nothing else on your Mac changed. Check your internet connection, then try again.",
                      comment: "%@ is a part of the setup, such as Hermes")
    }

    /// After someone pressed Keep it running and macOS asked for approval in System Settings, coming
    /// back with it allowed carries on starting, without a second press.
    static func resumesStart(after previous: ManagedRuntimeClient.State, now current: ManagedRuntimeClient.State,
                             requested: Bool) -> Bool {
        requested && previous == .requiresApproval && [.off, .stopped, .needsVerification].contains(current)
    }
}

#if DEBUG
/// Demo pictures: `-nollie-demo-install-state <name>` draws the setup step as the Direct download shows
/// it, with nothing installed or started. `store` is the Mac App Store edition's look.
enum SetupTrailPreview: String {
    case fresh, preparing, prepareFailed, prepared, starting, approval, failed, ready, unavailable, store

    static var requested: Self? {
        guard DemoMode.isOn else { return nil }
        let args = ProcessInfo.processInfo.arguments
        if args.contains("-nollie-demo-install-working") { return .preparing }
        guard let at = args.firstIndex(of: "-nollie-demo-install-state"), args.indices.contains(at + 1) else { return nil }
        return Self(rawValue: args[at + 1])
    }

    var direct: Bool { self != .store }
    var runtimeAvailable: Bool { ![.unavailable, .store].contains(self) }
    var runtimeState: ManagedRuntimeClient.State {
        switch self {
        case .starting: .starting
        case .approval: .requiresApproval
        case .failed: .failed
        case .ready: .ready
        case .unavailable, .store: .unavailable
        case .fresh, .preparing, .prepareFailed, .prepared: .off
        }
    }
    var error: String? {
        switch self {
        case .failed: String(localized: "Your assistant didn't answer when Nollie checked. Try again.")
        case .prepareFailed: SetupTrail.plainFailure(step: "hermes", reason: "")
        default: nil
        }
    }
    var errorDetail: String? {
        self == .prepareFailed ? "The download stopped with network error -1009. You can retry this step." : nil
    }
    var dependencies: [NativeDependencyStep] {
        NativeSetupPlan.steps.map { step in
            var shown = step
            if step.id == "service" { shown.state = SetupTrail.serviceState(runtimeState) }
            else if self == .store { shown.state = .blocked }
            else if self == .fresh { shown.state = .needsInstall }
            else if self == .preparing {
                shown.state = ["uv", "python"].contains(step.id) ? .ready : step.id == "hermes" ? .installing : .needsInstall
            } else if self == .prepareFailed {
                shown.state = ["uv", "python"].contains(step.id) ? .ready : step.id == "hermes" ? .failed : .needsInstall
            } else { shown.state = .ready }
            return shown
        }
    }
}
#endif

struct NativeSetupChecklistView: View {
    @Bindable var setup: MacHermesSetup
    var preferences: OnboardingPreferences
    var connect: () -> Void
    var isConnecting = false
    var isLocked = false
    var containedInGlass = false
    var previewWorking = false
    var compact = false
    /// Where an edition that can't set up a new assistant sends the person instead.
    var connectExisting: (() -> Void)? = nil
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.scenePhase) private var scenePhase
    @State private var showDetails = false
    @State private var observedWork = false
    @State private var celebration = false
    @State private var celebrationCount = 0
    @State private var isStoppingService = false
    /// Keep it running was pressed; macOS may first ask for approval in System Settings.
    @State private var startRequested = false

    #if DEBUG
    private var preview: SetupTrailPreview? { previewWorking ? .preparing : SetupTrailPreview.requested }
    #endif

    /// A picture of the step, with nothing installed or started behind it.
    private var isPreview: Bool {
        #if DEBUG
        preview != nil
        #else
        false
        #endif
    }

    private var isWorkingPreview: Bool {
        #if DEBUG
        preview == .preparing
        #else
        false
        #endif
    }

    private var direct: Bool {
        #if DEBUG
        if let preview { return preview.direct }
        #endif
        return setup.directInstallationAvailable
    }

    private var runtimeState: ManagedRuntimeClient.State {
        #if DEBUG
        if let preview { return preview.runtimeState }
        #endif
        return setup.managedRuntime.state
    }

    private var runtimeAvailable: Bool {
        #if DEBUG
        if let preview { return preview.runtimeAvailable }
        #endif
        return setup.managedRuntime.isAvailable
    }

    /// Every preparation step verified, add-ons included. Until then the main button prepares (or tries
    /// again), and Keep it running isn't offered.
    private var preparationReady: Bool { SetupTrail.rollUp(preparation.map(\.state)) == .ready }

    private var shownError: String? {
        #if DEBUG
        if let preview { return preview.error }
        #endif
        return setup.error
    }

    private var shownErrorDetail: String? {
        #if DEBUG
        if let preview { return preview.errorDetail }
        #endif
        return setup.errorDetail
    }

    private var displayDependencies: [NativeDependencyStep] {
        #if DEBUG
        if let preview { return preview.dependencies }
        #endif
        return setup.dependencies
    }

    private var showsService: Bool { SetupTrail.showsService(direct: direct, runtimeAvailable: runtimeAvailable, state: runtimeState) }

    private static let preparationIDs = Set(NativeSetupPlan.preparationSteps)
    private var preparation: [NativeDependencyStep] { displayDependencies.filter { Self.preparationIDs.contains($0.id) } }
    private var preparedCount: Int { preparation.filter { $0.state == .ready }.count }
    /// The preparation steps show as one "Getting Nollie ready" row; their names stay in "What's installed".
    private var trail: [NativeDependencyStep] { SetupTrail.rows(displayDependencies, showsService: showsService) }

    private var isWorking: Bool { isWorkingPreview || isConnecting || setup.isBusy || setup.managedRuntime.isBusy || (isPreview && runtimeState == .starting) }
    private var isReady: Bool {
        if isPreview { return runtimeState == .ready }
        return !setup.managedRuntime.isBusy && setup.canConnect
    }
    private var runtimeProgressTitle: String? {
        guard !isPreview, setup.managedRuntime.isBusy else { return nil }
        if isStoppingService { return String(localized: "Stopping", comment: "The background service's state") }
        return setup.managedRuntime.state == .starting ? String(localized: "Starting", comment: "The background service's state")
            : String(localized: "Checking", comment: "The background service's state")
    }

    private var headline: LocalizedStringKey {
        if !direct { return "Get Nollie from nollie.app." }
        if isStoppingService { return "Turning it off." }
        if isReady { return "Your assistant has a home." }
        return isWorking ? "Making room for your assistant." : "Let's get everything ready."
    }

    private var line: LocalizedStringKey {
        if !direct { return "This version connects to an assistant you already run." }
        return isReady ? "The connection passed its check." : "A few small pieces work together behind the scenes."
    }

    var body: some View {
        VStack(spacing: compact ? 9 : 14) {
            if isPreview {
                Label("Preview · no installation is running", systemImage: "eye")
                    .font(.caption.weight(.medium)).foregroundStyle(.secondary)
                    .accessibilityIdentifier("onboarding.install.preview")
            }
            CharacterView(look: .main, state: isWorking ? .working : .listening, size: compact ? 76 : 130)
                .scaleEffect(celebration && !reduceMotion ? 1.06 : 1)
                .accessibilityHidden(true)
            VStack(spacing: 7) {
                Text(headline)
                    .font(.title2.bold()).multilineTextAlignment(.center)
                Text(line)
                    .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                if isReady {
                    Label(isConnecting ? "Connecting" : "Ready to connect", systemImage: "checkmark.circle.fill")
                        .font(.subheadline.weight(.semibold)).foregroundStyle(Color.readableGreen)
                        .symbolEffect(.bounce, value: celebrationCount)
                }
            }
            if direct {
                VStack(spacing: 0) {
                    ForEach(Array(trail.enumerated()), id: \.element.id) { index, dependency in
                        dependencyRow(dependency, index: index)
                    }
                }
            }
            VStack(spacing: 12) {
                if direct { directActions } else { otherEditionActions }
            }
            .padding(.top, compact ? 12 : 20)
        }
        .padding(containedInGlass ? 0 : 24)
        .frame(maxWidth: .infinity)
        .modifier(SetupGlassCard(enabled: !containedInGlass, opaque: reduceTransparency || contrast == .increased))
        .sheet(isPresented: $showDetails) { details.withAppModel() }
        .task { if !isPreview { await setup.inspectDependencies() } }
        // Nollie may be bringing the assistant back by itself in the background. While the service row
        // says it didn't start, or is starting, look again every few seconds so the row tells the truth.
        .task(id: setup.managedRuntime.state) {
            guard !isPreview, [.failed, .starting, .stopped].contains(setup.managedRuntime.state) else { return }
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled, !isWorking, !setup.managedRuntime.isBusy else { return }
            await setup.inspectDependencies()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active, !isPreview, !isWorking {
                Task { await setup.inspectDependencies() }
            }
        }
        .onChange(of: setup.managedRuntime.state) { before, after in
            guard !isPreview else { return }
            if SetupTrail.resumesStart(after: before, now: after, requested: startRequested) {
                startRequested = false
                Task { await setup.startBackgroundService() }
            } else if after == .ready || after == .failed {
                startRequested = false
            }
        }
        .onChange(of: setup.isBusy) { _, busy in if busy { observedWork = true } }
        .onChange(of: setup.canConnect) { before, after in
            guard !isPreview, SetupTrailProgress.shouldCelebrate(wasReady: before, isReady: after, observedWork: observedWork) else { return }
            if !reduceMotion { celebrationCount += 1 }
            withAnimation(reduceMotion ? nil : .spring(duration: 0.45, bounce: 0.2)) { celebration = true }
        }
        .task(id: celebration) {
            guard celebration, !reduceMotion else { return }
            try? await Task.sleep(for: .milliseconds(700))
            guard !Task.isCancelled else { return }
            withAnimation(.smooth(duration: 0.35)) { celebration = false }
        }
        .disabled(isLocked)
    }

    /// The Direct download: prepare, then keep it running, then connect. One main button at a time.
    @ViewBuilder private var directActions: some View {
        if let error = shownError, !isWorkingPreview {
            Text(String(localized: "\(error) Your progress is saved.", comment: "After an error message"))
                .font(.subheadline).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        if isReady {
            Button {
                guard !isWorking, !isLocked, !isPreview else { return }
                connect()
            } label: {
                primaryLabel(isConnecting ? String(localized: "Connecting…") : String(localized: "Connect"))
            }
                .buttonStyle(OnboardingPrimaryButtonStyle())
                .disabled(isWorking || isLocked)
                .accessibilityIdentifier("onboarding.install.connect")
        } else if !isWorking || (isPreview && runtimeState == .starting) {
            if preparationReady {
                if !showsService {
                    // A copy without the signed background service (an unsigned or damaged one) can't go on.
                    Text("This copy of Nollie can't keep your assistant running. Get Nollie again from nollie.app.")
                        .font(.subheadline).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                    Link(destination: URL(string: "https://nollie.app")!) { primaryLabel(String(localized: "Open nollie.app")) }
                        .buttonStyle(OnboardingPrimaryButtonStyle())
                        .accessibilityIdentifier("onboarding.runtime.getNollie")
                } else if runtimeState == .requiresApproval {
                    Button {
                        guard !isPreview else { return }
                        startRequested = true
                        setup.managedRuntime.openApprovalSettings()
                    } label: {
                        primaryLabel(String(localized: "Open Login Items"))
                    }
                        .buttonStyle(OnboardingPrimaryButtonStyle())
                        .accessibilityIdentifier("onboarding.runtime.approve")
                } else if runtimeState == .starting {
                    Label("Starting up…", systemImage: "hourglass")
                        .font(.subheadline.weight(.medium)).foregroundStyle(.secondary)
                } else {
                    if runtimeState != .failed {
                        Text("Keeps working after you close Nollie, while this Mac is awake. Turn it off anytime.")
                        .font(.subheadline).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                    Button {
                        guard !isPreview else { return }
                        observedWork = true
                        startRequested = true
                        Task { await setup.startBackgroundService() }
                    } label: {
                        primaryLabel(runtimeState == .failed ? String(localized: "Try again") : setup.backgroundActionTitle)
                    }
                    .buttonStyle(OnboardingPrimaryButtonStyle())
                    .accessibilityIdentifier("onboarding.runtime.start")
                }
            } else {
                Button {
                    guard !isPreview else { return }
                    observedWork = true
                    Task { await setup.installDependencies(preferences: preferences) }
                } label: {
                    primaryLabel(shownError == nil ? (preparedCount == 0 ? String(localized: "Get Nollie ready") : String(localized: "Finish getting ready"))
                                 : String(localized: "Try again"))
                }
                .buttonStyle(OnboardingPrimaryButtonStyle())
                .accessibilityIdentifier("onboarding.install.start")
            }
        }
        Button { showDetails = true } label: {
            Label("What's installed", systemImage: "info.circle")
        }
        .buttonStyle(.nollieGlass)
        .accessibilityLabel("Installation details")
    }

    /// The Mac App Store edition can't install an assistant; it connects to one the person runs.
    @ViewBuilder private var otherEditionActions: some View {
        if let connectExisting {
            Button { guard !isPreview else { return }; connectExisting() } label: {
                primaryLabel(String(localized: "Connect existing instead"))
            }
            .buttonStyle(OnboardingPrimaryButtonStyle())
            .accessibilityIdentifier("onboarding.install.connectExisting")
        }
        Link(destination: URL(string: "https://nollie.app")!) { Label("Open nollie.app", systemImage: "globe") }
            .buttonStyle(.nollieGlass)
            .accessibilityIdentifier("onboarding.install.getNollie")
    }

    private var details: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text("Everything is installed in Nollie's own folder. Your existing setup stays untouched.")
                        .font(.subheadline).foregroundStyle(.secondary)
                    Text("About \(NativeSetupPlan.downloadMegabytes) MB to download and \(NativeSetupPlan.diskMegabytes) MB on this Mac. Every download is a fixed version Nollie was tested with, checked before it's used.")
                        .font(.subheadline).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    ForEach(displayDependencies.filter { $0.id != "service" || showsService }) { dependency in
                        VStack(alignment: .leading, spacing: 5) {
                            Text(dependency.title).font(.headline)
                            Text(dependency.detail).font(.subheadline).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            Text(statusTitle(dependency)).font(.caption.weight(.medium))
                            #if NOLLIE_DIRECT
                            if (dependency.state == .needsInstall || dependency.state == .failed), dependency.id != "service" {
                                Button(dependency.state == .failed ? "Retry this step" : "Install this item") {
                                    guard !isPreview else { return }
                                    observedWork = true
                                    Task { await setup.installDependency(dependency.id, preferences: preferences) }
                                }
                                .disabled(isWorking)
                                .accessibilityIdentifier("onboarding.dependency.\(dependency.id).install")
                            }
                            #endif
                        }
                    }
                    if let error = shownError, !isWorkingPreview {
                        Label(error, systemImage: "exclamationmark.circle")
                            .font(.subheadline).foregroundStyle(.secondary)
                        if let detail = shownErrorDetail, detail != error {
                            Text("Exact reason: \(detail)", comment: "The technical reason a setup step stopped")
                                .font(.footnote).foregroundStyle(.secondary)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    if !isPreview {
                        Button("Check again") { Task { await setup.inspectDependencies() } }
                            .disabled(isWorking)
                            .accessibilityIdentifier("onboarding.install.check")
                    }
                    if !isPreview, setup.managedRuntime.isRegistered {
                        Button("Turn off background service", role: .destructive) {
                            Task {
                                isStoppingService = true
                                defer { isStoppingService = false }
                                await setup.stopBackgroundService()
                            }
                        }
                        .disabled(isWorking || isLocked)
                        .accessibilityIdentifier("onboarding.runtime.stop")
                        Text("Stops this Nollie setup and removes its background registration. Your files stay on this Mac.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
                .padding(24).frame(maxWidth: .infinity, alignment: .leading)
            }
            .navigationTitle("Installation details")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showDetails = false } } }
        }
        .frame(width: 560, height: 540)
    }

    private func primaryLabel(_ title: String) -> some View {
        Text(title).font(.title3.weight(.semibold))
            .frame(maxWidth: .infinity, minHeight: 52)
            .padding(.horizontal, 18)
    }

    private func dependencyRow(_ dependency: NativeDependencyStep, index: Int) -> some View {
        let state = checkState(dependency)
        let completed = SetupTrailProgress.completedPrefix(trail.map { checkState($0) })
        return HStack(alignment: .top, spacing: 14) {
            ZStack {
                if state == .working { ProgressView().controlSize(.small) }
                else {
                    Image(systemName: state.symbol).font(.title3)
                        .foregroundStyle(state == .ready ? Color.readableGreen : .secondary)
                }
            }
            .frame(width: 24, height: 24)
            VStack(alignment: .leading, spacing: 3) {
                Text(shortTitle(dependency.id)).font(.subheadline.weight(.semibold))
                Text(shortDetail(dependency)).font(.subheadline).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if dependency.id == "prepare", dependency.state == .installing {
                    ProgressView(value: Double(preparedCount), total: Double(max(preparation.count, 1)))
                        .progressViewStyle(.linear)
                        .padding(.top, 4)
                        .accessibilityLabel("Getting Nollie ready")
                        .accessibilityValue("\(preparedCount) of \(preparation.count) parts ready")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(statusTitle(dependency)).font(.subheadline.weight(.medium))
                .foregroundStyle(checkState(dependency) == .ready ? Color.readableGreen
                                 : checkState(dependency) == .attention ? Color.orange : .secondary)
        }
        .padding(.bottom, index == trail.count - 1 ? 0 : (compact ? 8 : 12))
        .overlay(alignment: .topLeading) {
            if index < trail.count - 1 {
                Rectangle().fill(index < completed ? Color.readableGreen : Color.secondary.opacity(0.22))
                    .frame(width: 2).padding(.top, 28).padding(.leading, 11)
                    .allowsHitTesting(false)
            }
        }
        .accessibilityElement(children: .contain)
    }

    private func shortTitle(_ id: String) -> String {
        switch id {
        case "prepare": String(localized: "Getting Nollie ready")
        case "service": String(localized: "Keep it running")
        default: String(localized: "Set up", comment: "A setup step's name")
        }
    }

    private func shortDetail(_ dependency: NativeDependencyStep) -> String {
        if dependency.id == "service" {
            if runtimeProgressTitle != nil {
                if isStoppingService { return String(localized: "Turning it off. Your setup files are kept.") }
                return setup.managedRuntime.state == .starting
                    ? String(localized: "Starting and checking the connection.")
                    : String(localized: "Checking the background service.")
            }
            switch runtimeState {
            case .requiresApproval: return SetupTrail.approvalSteps
            case .starting: return String(localized: "Starting and checking the connection.")
            case .failed: return String(localized: "Didn't start. Try again below.")
            default: return String(localized: "Works while this Mac is awake.")
            }
        }
        if dependency.state == .failed { return String(localized: "Didn't finish. Try again below.") }
        guard dependency.id == "prepare" else { return dependency.detail }
        let total = preparation.count
        switch dependency.state {
        case .ready: return String(localized: "Everything your assistant needs is in place.")
        case .installing:
            if let current = preparation.first(where: { $0.state == .installing }), setup.checkingStep == current.id, !isPreview {
                return String(localized: "Checking what's already here. \(preparedCount) of \(total) parts ready.")
            }
            if let current = preparation.first(where: { $0.state == .installing }), let words = SetupTrail.partWords(current.id) {
                return String(localized: "\(words). \(preparedCount) of \(total) parts ready.", comment: "First what is happening, such as Downloading Hermes, 91 MB")
            }
            return String(localized: "\(preparedCount) of \(total) parts ready. Keep Nollie open.")
        default:
            return preparedCount == 0
                ? String(localized: "About \(NativeSetupPlan.downloadMegabytes) MB to download. Usually 2 to 5 minutes, longer on a slow connection.")
                : String(localized: "\(preparedCount) of \(total) parts ready. The rest takes a few minutes.")
        }
    }

    private func checkState(_ dependency: NativeDependencyStep) -> SetupCheckState {
        if dependency.id == "service", runtimeProgressTitle != nil { return .working }
        return checkState(dependency.state)
    }

    private func statusTitle(_ dependency: NativeDependencyStep) -> String {
        if dependency.id == "service" {
            if let runtimeProgressTitle { return runtimeProgressTitle }
            // Something to do in System Settings, not a fault.
            if runtimeState == .requiresApproval { return String(localized: "Needs your OK", comment: "A setup step's state: waiting for approval in System Settings") }
            if checkState(dependency) == .needed { return String(localized: "Off", comment: "The background service's state") }
        }
        if checkState(dependency) == .needed { return String(localized: "Not started", comment: "A setup step's state") }
        return checkState(dependency).title
    }

    private func checkState(_ state: NativeDependencyStep.State) -> SetupCheckState {
        switch state {
        case .ready: .ready
        case .installing: .working
        case .notChecked: .notChecked
        case .needsInstall: .needed
        case .blocked, .failed: .attention
        }
    }
}

private struct SetupGlassCard: ViewModifier {
    var enabled = true
    var opaque: Bool
    func body(content: Content) -> some View {
        if !enabled {
            content
        } else if opaque {
            content.background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 28))
                .overlay { RoundedRectangle(cornerRadius: 28).strokeBorder(.primary.opacity(0.25), lineWidth: 1) }
        } else {
            content.nollieGlass(.regular, in: .rect(cornerRadius: 28))
        }
    }
}
#endif
