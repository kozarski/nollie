import SwiftUI
import NollieCore

enum SetupCheckState: Equatable {
    case notChecked, needed, working, ready, attention, unavailable, optional

    var title: String {
        switch self {
        case .notChecked: String(localized: "Not checked", comment: "A setup step's state")
        case .needed: String(localized: "Not yet", comment: "A setup step's state")
        case .working: String(localized: "In progress", comment: "A setup step's state")
        case .ready: String(localized: "Ready", comment: "A setup step's state")
        case .attention: String(localized: "Needs attention", comment: "A setup step's state")
        case .unavailable: String(localized: "Not in this version", comment: "A setup step's state")
        case .optional: String(localized: "Optional", comment: "A setup step's state")
        }
    }
    var symbol: String {
        switch self {
        case .ready: "checkmark.circle.fill"
        case .attention: "exclamationmark.circle"
        case .unavailable: "minus.circle"
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
struct NativeSetupChecklistView: View {
    @Bindable var setup: MacHermesSetup
    var preferences: OnboardingPreferences
    var connect: () -> Void
    var isConnecting = false
    var isLocked = false
    var containedInGlass = false
    var previewWorking = false
    var compact = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.scenePhase) private var scenePhase
    @State private var showDetails = false
    @State private var observedWork = false
    @State private var celebration = false
    @State private var celebrationCount = 0
    @State private var isStoppingService = false

    private var isWorkingPreview: Bool {
        #if DEBUG
        DemoMode.isOn && previewWorking
        #else
        false
        #endif
    }

    private var displayDependencies: [NativeDependencyStep] {
        guard isWorkingPreview else { return setup.dependencies }
        return NativeSetupPlan.steps.map { step in
            var preview = step
            switch step.id {
            case "uv", "python", "hermes": preview.state = .ready
            case "dependencies": preview.state = .installing
            default: preview.state = .notChecked
            }
            return preview
        }
    }

    /// The preparation steps show as one "Getting Nollie ready" row; their names stay in "What's installed".
    private static let preparationIDs = Set(NativeSetupPlan.preparationSteps)
    private var preparation: [NativeDependencyStep] { displayDependencies.filter { Self.preparationIDs.contains($0.id) } }
    private var preparedCount: Int { preparation.filter { $0.state == .ready }.count }
    private var trail: [NativeDependencyStep] {
        let states = preparation.map(\.state)
        let state: NativeDependencyStep.State =
            !states.isEmpty && states.allSatisfy({ $0 == .ready }) ? .ready
            : states.contains(.installing) ? .installing
            : states.contains(.failed) ? .failed
            : states.contains(.blocked) ? .blocked
            : states.contains(.notChecked) ? .notChecked : .needsInstall
        let summary = NativeDependencyStep(id: "prepare", title: String(localized: "Getting Nollie ready"), detail: "", state: state, optional: false)
        return [summary] + displayDependencies.filter { !Self.preparationIDs.contains($0.id) }
    }

    private var isWorking: Bool { isWorkingPreview || isConnecting || setup.isBusy || setup.managedRuntime.isBusy }
    private var isReady: Bool { !isWorkingPreview && !setup.managedRuntime.isBusy && setup.canConnect }
    private var runtimeProgressTitle: String? {
        guard !isWorkingPreview, setup.managedRuntime.isBusy else { return nil }
        if isStoppingService { return String(localized: "Stopping", comment: "The background service's state") }
        return setup.managedRuntime.state == .starting ? String(localized: "Starting", comment: "The background service's state")
            : String(localized: "Checking", comment: "The background service's state")
    }

    var body: some View {
        VStack(spacing: compact ? 9 : 14) {
            if isWorkingPreview {
                Label("Preview · no installation is running", systemImage: "eye")
                    .font(.caption.weight(.medium)).foregroundStyle(.secondary)
                    .accessibilityIdentifier("onboarding.install.preview")
            }
            CharacterView(look: .main, state: isWorking ? .working : .listening, size: compact ? 76 : 130)
                .scaleEffect(celebration && !reduceMotion ? 1.06 : 1)
                .accessibilityHidden(true)
            VStack(spacing: 7) {
                Text(isStoppingService ? "Turning it off." : isReady ? "Your assistant has a home." : isWorking ? "Making room for your assistant." : "Let's get everything ready.")
                    .font(.title2.bold()).multilineTextAlignment(.center)
                Text(isReady ? "The connection passed its check." : "A few small pieces work together behind the scenes.")
                    .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                if isReady {
                    Label(isConnecting ? "Connecting" : "Ready to connect", systemImage: "checkmark.circle.fill")
                        .font(.subheadline.weight(.semibold)).foregroundStyle(Color.readableGreen)
                        .symbolEffect(.bounce, value: celebrationCount)
                }
            }
            VStack(spacing: 0) {
                ForEach(Array(trail.enumerated()), id: \.element.id) { index, dependency in
                    dependencyRow(dependency, index: index)
                }
            }
            VStack(spacing: 12) {
            if setup.error != nil, !isWorkingPreview {
                Text(setup.error.map { String(localized: "\($0) Your progress is saved.", comment: "After an error message") } ?? "")
                    .font(.subheadline).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            #if NOLLIE_DIRECT
            if isReady {
                Button {
                    guard !isWorking, !isLocked else { return }
                    connect()
                } label: {
                    primaryLabel(isConnecting ? String(localized: "Connecting…") : String(localized: "Connect"))
                }
                    .buttonStyle(OnboardingPrimaryButtonStyle())
                    .disabled(isWorking || isLocked)
                    .accessibilityIdentifier("onboarding.install.connect")
            } else if !isWorking {
                if setup.runtimePrepared {
                    Text("Keeps working after you close Nollie, while this Mac is awake. Turn it off anytime.")
                        .font(.subheadline).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                    if setup.managedRuntime.state == .requiresApproval {
                        Button { setup.managedRuntime.openApprovalSettings() } label: {
                            primaryLabel(String(localized: "Open Login Items"))
                        }
                            .buttonStyle(OnboardingPrimaryButtonStyle())
                            .accessibilityIdentifier("onboarding.runtime.approve")
                    } else if setup.managedRuntime.state == .starting {
                        Label("Starting up…", systemImage: "hourglass")
                            .font(.subheadline.weight(.medium)).foregroundStyle(.secondary)
                    } else {
                        Button {
                            observedWork = true
                            Task { await setup.startBackgroundService() }
                        } label: {
                            primaryLabel(setup.backgroundActionTitle)
                        }
                        .buttonStyle(OnboardingPrimaryButtonStyle())
                        .disabled(!setup.managedRuntime.isAvailable || setup.managedRuntime.state == .unavailable)
                        .accessibilityIdentifier("onboarding.runtime.start")
                    }
                } else {
                    Button {
                        guard !isWorkingPreview else { return }
                        observedWork = true
                        Task { await setup.installDependencies(preferences: preferences) }
                    } label: {
                        primaryLabel(setup.error == nil ? (preparedCount == 0 ? String(localized: "Get Nollie ready") : String(localized: "Finish getting ready"))
                                     : String(localized: "Try again"))
                    }
                    .buttonStyle(OnboardingPrimaryButtonStyle())
                    .disabled(!setup.directInstallationAvailable)
                    .accessibilityIdentifier("onboarding.install.start")
                }
            }
            #else
            Text("Get Nollie from nollie.app to set up a new assistant. This version connects to one you already run.")
                .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
            #endif
            Button { showDetails = true } label: {
                Label("What's installed", systemImage: "info.circle")
            }
            .buttonStyle(.nollieGlass)
            .accessibilityLabel("Installation details")
            }
            .padding(.top, compact ? 12 : 20)
        }
        .padding(containedInGlass ? 0 : 24)
        .frame(maxWidth: .infinity)
        .modifier(SetupGlassCard(enabled: !containedInGlass, opaque: reduceTransparency || contrast == .increased))
        .sheet(isPresented: $showDetails) {
            NavigationStack {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        Text("Everything is installed in Nollie's own folder. Your existing setup stays untouched.")
                            .font(.subheadline).foregroundStyle(.secondary)
                        Text("About \(NativeSetupPlan.downloadMegabytes) MB to download and \(NativeSetupPlan.diskMegabytes) MB on this Mac. Every download is a fixed version Nollie was tested with, checked before it's used.")
                            .font(.subheadline).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        ForEach(displayDependencies) { dependency in
                            VStack(alignment: .leading, spacing: 5) {
                                Text(dependency.title).font(.headline)
                                Text(dependency.detail).font(.subheadline).foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                                Text(statusTitle(dependency)).font(.caption.weight(.medium))
                                #if NOLLIE_DIRECT
                                if (dependency.state == .needsInstall || dependency.state == .failed),
                                   !["service", "computer"].contains(dependency.id) {
                                    Button(dependency.state == .failed ? "Retry this step" : "Install this item") {
                                        observedWork = true
                                        Task { await setup.installDependency(dependency.id, preferences: preferences) }
                                    }
                                    .disabled(isWorking)
                                    .accessibilityIdentifier("onboarding.dependency.\(dependency.id).install")
                                }
                                #endif
                            }
                        }
                        if let error = setup.error, !isWorkingPreview {
                            Label(error, systemImage: "exclamationmark.circle")
                                .font(.subheadline).foregroundStyle(.secondary)
                        }
                        if !isWorkingPreview {
                            Button("Check again") { Task { await setup.inspectDependencies() } }
                                .disabled(isWorking)
                                .accessibilityIdentifier("onboarding.install.check")
                        }
                        if !isWorkingPreview, setup.managedRuntime.isRegistered {
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
            .withAppModel()
        }
        .task { if !isWorkingPreview { await setup.inspectDependencies() } }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active, !isWorkingPreview, !isWorking {
                Task { await setup.inspectDependencies() }
            }
        }
        .onChange(of: setup.isBusy) { _, busy in if busy { observedWork = true } }
        .onChange(of: setup.canConnect) { before, after in
            guard !isWorkingPreview, SetupTrailProgress.shouldCelebrate(wasReady: before, isReady: after, observedWork: observedWork) else { return }
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
        case "computer": String(localized: "Add a computer")
        default: String(localized: "Set up", comment: "A setup step's name")
        }
    }

    private func shortDetail(_ dependency: NativeDependencyStep) -> String {
        if dependency.id == "service", runtimeProgressTitle != nil {
            if isStoppingService { return String(localized: "Turning it off. Your setup files are kept.") }
            return setup.managedRuntime.state == .starting
                ? String(localized: "Starting and checking the connection.")
                : String(localized: "Checking the background service.")
        }
        if dependency.optional, dependency.state == .blocked {
            return String(localized: "Optional. Coming in a later version.")
        }
        if dependency.id == "service", !isWorkingPreview, setup.managedRuntime.state == .requiresApproval {
            return String(localized: "Allow Nollie Runtime in Login Items, then check again.")
        }
        if dependency.state == .blocked { return String(localized: "Not in this version yet.") }
        if dependency.state == .failed { return String(localized: "Didn't finish. Try again below.") }
        switch dependency.id {
        case "prepare":
            let total = preparation.count
            switch dependency.state {
            case .ready: return String(localized: "Everything your assistant needs is in place.")
            case .installing: return String(localized: "\(preparedCount) of \(total) parts ready. Keep Nollie open.")
            default:
                return preparedCount == 0
                    ? String(localized: "About \(NativeSetupPlan.downloadMegabytes) MB to download. Usually 2 to 5 minutes, longer on a slow connection.")
                    : String(localized: "\(preparedCount) of \(total) parts ready. The rest takes a few minutes.")
            }
        case "service": return String(localized: "Works while this Mac is awake.")
        case "computer": return String(localized: "Optional space to browse and work.")
        default: return dependency.detail
        }
    }

    private func checkState(_ dependency: NativeDependencyStep) -> SetupCheckState {
        if dependency.id == "service", runtimeProgressTitle != nil { return .working }
        if dependency.optional, dependency.state == .blocked { return .unavailable }
        return checkState(dependency.state)
    }

    private func statusTitle(_ dependency: NativeDependencyStep) -> String {
        if dependency.id == "service", let runtimeProgressTitle { return runtimeProgressTitle }
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
