import SwiftUI
import UniformTypeIdentifiers
import UserNotifications
import NollieCore

/// A guided flow for the push companion with a card for each step. A card opens only when every
/// earlier one is done, and the last step sends a real test notification.
struct PushSetupView: View {
    @Environment(AppModel.self) var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Bindable var setup: PushSetupModel

    @State private var step = SetupStep.apple
    @State private var movingForward = true
    @State var showKeyPicker = false
    @State var showCompanionSignIn = false
    @State var confirmStartOver = false
    @State private var confirmCancel = false
    /// Taken from the page on screen so the following page starts from a measured height, not a guess.
    @State private var headerHeight: CGFloat = 270
    /// Becomes true a little after the final step finishes, once the bot's hop has ended.
    @State private var finishSettled = false

    var rt: GatewayRuntime? { model.runtime }

    // MARK: Where things stand

    /// While files go up or the gateway restarts, the cards stay put.
    var locked: Bool {
        setup.installing || setup.updating || setup.restarting || rt?.maintenance.isBusy == true
    }

    /// The start step, after a gateway restart, while the companion has yet to report in.
    private var awaitingCompanion: Bool {
        guard step == .start, !isDone(.start), setup.installedOnGateway, !setup.restartPending else { return false }
        if setup.companionSignInRejected || setup.hasConnectionFailure { return false }
        return setup.restarting || setup.heartbeat != nil
    }

    func isDone(_ target: SetupStep) -> Bool {
        guard let rt else { return false }
        return target.isComplete(setup: setup, push: model.push, runtime: rt)
    }

    private func go(to target: SetupStep) {
        guard !locked, target != step else { return }
        guard SetupStep.allCases.prefix(target.rawValue).allSatisfy(isDone) else { return }
        movingForward = target.rawValue > step.rawValue
        withAnimation(.smooth(duration: 0.4)) { step = target }
    }

    private var guideKey: String { "\(step.rawValue)-\(isDone(step))" }

    // MARK: Body

    var body: some View {
        page
            .overlay(alignment: .bottom) { footer }
            .overlay(alignment: .topLeading) { backButton }
            .background(Color(.systemGroupedBackground))
            .modifier(WizardChrome())
            .modifier(KeyImporter(isPresented: $showKeyPicker, pick: setup.importKey))
            .sheet(isPresented: $showCompanionSignIn) { signInSheet.withAppModel() }
            .modifier(SetupAlerts(confirmCancel: $confirmCancel, confirmStartOver: $confirmStartOver,
                                  cancelSetup: cancelSetup, startOver: startOver))
            .task { await loadInitialState() }
            .task(id: step.rawValue, keepFresh)
            .onChange(of: isDone(.overview), settleFinish)
    }

    private var page: some View {
        StepPage(step: step, done: isDone(step), headerHeight: $headerHeight) {
            if let rt {
                stepContent(step, runtime: rt)
            } else {
                Text("Connect a gateway first.").foregroundStyle(.secondary)
            }
        } header: {
            let thinking = locked || awaitingCompanion
            let line = step.guideLine(setup: setup, done: isDone(step), locked: locked)
            NollieGuide(says: line, key: guideKey, turnKey: guideKey, thinking: thinking,
                        done: isDone(step), reduceMotion: reduceMotion, size: 88)
        }
        .transition(stepTransition)
        .id(step.rawValue)
    }

    private var stepTransition: AnyTransition {
        let entering: Edge = movingForward ? .trailing : .leading
        let leaving: Edge = movingForward ? .leading : .trailing
        return .asymmetric(insertion: .move(edge: entering).combined(with: .opacity),
                           removal: .move(edge: leaving).combined(with: .opacity))
    }

    private var footer: some View {
        SetupFooter(step: step, busy: locked || awaitingCompanion, locked: locked,
                    stepDone: isDone(step), allDone: isDone(.overview) && finishSettled,
                    advance: { if let next = step.next { go(to: next) } },
                    finish: finishSetup, exit: { dismiss() }, cancel: { confirmCancel = true })
    }

    @ViewBuilder private var backButton: some View {
        if let previous = step.previous {
            WizardBackButton { go(to: previous) }
                .transition(.opacity)
                .disabled(locked)
        }
    }

    @ViewBuilder private var signInSheet: some View {
        if let rt {
            CompanionSignInSheet(runtime: rt) { secrets in
                setup.acceptCompanionSignIn(secrets)
                setup.rememberCompanionSecrets(for: rt)
                // Recovery keeps the Apple key and earlier steps. The new sign-in still needs an install.
                movingForward = step.rawValue < SetupStep.install.rawValue
                step = .install
            }
            .sheetFrame()
        }
    }

    // MARK: Actions

    private func finishSetup() {
        if let rt { setup.markCompleted(for: rt) }
        dismiss()
    }

    private func cancelSetup() {
        if let rt { setup.startOver(runtime: rt) }
        dismiss()
    }

    private func startOver() {
        guard let rt else { return }
        setup.startOver(runtime: rt)
        withAnimation(.snappy) { step = .apple }
    }

    /// Holds the Done button back for a beat after the last card completes.
    private func settleFinish(_ was: Bool, _ finished: Bool) {
        finishSettled = false
        guard finished else { return }
        Task {
            try? await Task.sleep(nanoseconds: 900_000_000)
            finishSettled = true
        }
    }

    private func loadInitialState() async {
        fillTeamID()
        guard let rt else { return }
        await setup.prepare(runtime: rt)
        // Setup needs the profile folder, which only exists after the socket connects. A second device
        // opening setup straight away would otherwise find nothing installed.
        guard rt.profileHome == nil else { return }
        let ready = await setup.poll(times: 6, every: .seconds(1)) { rt.profileHome != nil }
        if ready { await setup.checkCompanion(runtime: rt) }
    }

    /// A build from a store carries its Team ID; the key card starts from it.
    private func fillTeamID() {
        guard setup.teamID.isEmpty else { return }
        setup.teamID = ProvisioningProfile.teamID ?? ""
    }

    /// The heartbeat is the proof for the last two steps, so keep it fresh while they show.
    @Sendable private func keepFresh() async {
        guard let rt, step == .start || step == .overview else { return }
        while true {
            do { try await Task.sleep(for: .seconds(5)) } catch { return }
            await setup.checkCompanion(runtime: rt)
        }
    }

    static func statusText(_ status: UNAuthorizationStatus) -> String {
        switch status {
        case .authorized: String(localized: "Allowed", comment: "Notification permission")
        case .denied: String(localized: "Denied", comment: "Notification permission")
        case .provisional: String(localized: "Provisional", comment: "Notification permission")
        case .ephemeral: String(localized: "Ephemeral", comment: "Notification permission")
        default: String(localized: "Not asked", comment: "Notification permission")
        }
    }
}

// MARK: - Presentation

/// The wizard owns the whole screen: no navigation bar, no back button, no tab bar.
private struct WizardChrome: ViewModifier {
    func body(content: Content) -> some View {
        content
            .toolbar(.hidden, for: .navigationBar)
            .hidesTabBar()
            .navigationBarBackButtonHidden(true)
    }
}

/// Asks for the .p8 key file.
private struct KeyImporter: ViewModifier {
    @Binding var isPresented: Bool
    let pick: (URL) -> Void

    private static let types: [UTType] = [UTType(filenameExtension: "p8") ?? .data, .data]

    func body(content: Content) -> some View {
        content.fileImporter(isPresented: $isPresented, allowedContentTypes: Self.types) { outcome in
            if case .success(let url) = outcome { pick(url) }
        }
    }
}

/// The two "are you sure" questions of the setup, asked the same way.
private struct SetupAlerts: ViewModifier {
    @Binding var confirmCancel: Bool
    @Binding var confirmStartOver: Bool
    let cancelSetup: () -> Void
    let startOver: () -> Void

    func body(content: Content) -> some View {
        content
            .modifier(Ask(isPresented: $confirmCancel, title: String(localized: "Cancel setup?"), yes: String(localized: "Cancel setup"),
                          no: String(localized: "Keep going"),
                          words: String(localized: "This clears the address, the companion sign-in and your progress on \(DeviceWords.this). Nothing on the gateway changes. Next time you start from the first step.",
                                        comment: "%@ is this iPhone, this iPad or this Mac"),
                          go: cancelSetup))
            .modifier(Ask(isPresented: $confirmStartOver, title: String(localized: "Start over?"), yes: String(localized: "Start over"),
                          no: String(localized: "Cancel"),
                          words: String(localized: "This clears the address, the companion sign-in and the progress on \(DeviceWords.this). The gateway stays as it is until you install again.",
                                        comment: "%@ is this iPhone, this iPad or this Mac"),
                          go: startOver))
    }

    /// One destructive question with a way out.
    private struct Ask: ViewModifier {
        @Binding var isPresented: Bool
        let title: String
        let yes: String
        let no: String
        let words: String
        let go: () -> Void

        func body(content: Content) -> some View {
            content.alert(title, isPresented: $isPresented) {
                Button(yes, role: .destructive, action: go)
                Button(no, role: .cancel) {}
            } message: {
                Text(words)
            }
        }
    }
}
