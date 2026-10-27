import SwiftUI
import NollieCore

/// Settings › Software Update: the Nollie Companion, updated in place like an iPhone update. What
/// is true now at the top, the one thing to do next, and versions under Details.
struct SoftwareUpdateView: View {
    @State private var setup = PushSetupModel()
    @State private var details = false
    @Environment(AppModel.self) private var model

    private var hero: SoftwareUpdateHero.State {
        SoftwareUpdateHero.State(connected: model.runtime != nil, checked: setup.companionCheckedAt != nil,
                                 installed: setup.installedVersion != nil, checking: setup.checkingCompanion,
                                 updateAvailable: setup.updateAvailable, updating: setup.updating,
                                 showsConsole: setup.showUpdateConsole, needsRestart: setup.updateNeedsRestart,
                                 restarting: setup.restarting, outcome: setup.updateOutcome?.ok)
    }

    var body: some View {
        SettingsPage("softwareUpdate.page") {
            SoftwareUpdateHero(state: hero, stage: setup.updateStage)
            if let rt = model.runtime {
                if setup.updating || setup.showUpdateConsole || setup.updateOutcome != nil {
                    progress
                }
                next(rt)
                if setup.companionCheckedAt != nil, !setup.updating {
                    GlassButton("Check again", symbol: "arrow.triangle.2.circlepath",
                                value: setup.companionCheckedAt?.formatted(date: .omitted, time: .shortened),
                                id: "softwareUpdate.check") { Task { await setup.checkCompanion(runtime: rt) } }
                        .disabled(setup.checkingCompanion)
                        .opacity(setup.checkingCompanion ? 0.5 : 1)
                }
                detailsGroup
            }
        }
        .animation(.smooth, value: hero)
        .task { await setup.prepareIfConnected(model.runtime) }
        .reloadable { await setup.checkIfConnected(model.runtime) }
        .onChange(of: setup.companionCheckedAt) { shareResult() }
    }

    /// Tells the rest of the app what the check found.
    private func shareResult() {
        model.companionInstalledVersion = setup.installedVersion
        model.companionUpdateAvailable = setup.updateAvailable
    }

    /// The bar while it installs, with how long is left.
    private var progress: some View {
        VStack(spacing: 10) {
            ProgressView(value: setup.updateProgress)
                .progressViewStyle(.linear)
                .tint(setup.updateOutcome?.ok == false ? .red : setup.updateProgress >= 1 ? .green : .accentColor)
            if let remaining = setup.updateRemaining {
                Text(remaining).font(.body).foregroundStyle(Ink.text2)
                    .contentTransition(.opacity)
            }
        }
        .accessibilityElement(children: .combine)
        .testID("softwareUpdate.progress")
    }

    /// The one thing to do next, by state.
    @ViewBuilder private func next(_ rt: GatewayRuntime) -> some View {
        if setup.companionCheckedAt != nil, setup.installedVersion == nil {
            NavigationLink { SetupWizardHost() } label: { prominentLabel("Set up") }
                .buttonStyle(.nollieGlassProminent).buttonBorderShape(.capsule).controlSize(.large)
                .testID("softwareUpdate.setUp")
        } else if setup.updateNeedsRestart, !setup.updating {
            RestartSteps(setup: setup, runtime: rt)
        } else if setup.updateAvailable || setup.updateOutcome != nil, !setup.updating, setup.updateOutcome?.ok != true {
            FactStrip(facts: [Fact(symbol: "arrow.down.circle.fill", word: .verbatim(ByteCountFormatter.string(fromByteCount: Int64(PushSetupModel.bundledScriptSize), countStyle: .file))),
                              setup.runningCanSelfReload ? Fact(symbol: "bolt.fill", word: "No restart")
                                                         : Fact(symbol: "arrow.clockwise", word: "Needs a restart")],
                      id: "softwareUpdate.facts")
            Button { Task { await setup.updateCompanion(runtime: rt) } } label: {
                prominentLabel(setup.updateOutcome == nil ? "Install Now" : "Try Again")
            }
            .buttonStyle(.nollieGlassProminent).buttonBorderShape(.capsule).controlSize(.large)
            .testID("softwareUpdate.install")
        }
    }

    private func prominentLabel(_ title: LocalizedStringKey) -> some View {
        Text(title).fullWidthLabel()
    }

    /// Versions, size and what happened, for anyone who wants them.
    private var detailsGroup: some View {
        DisclosureGroup(isExpanded: $details) {
            VStack(alignment: .leading, spacing: 14) {
                DetailLine("Installed", setup.installedVersion ?? String(localized: "Not installed"))
                if let hb = setup.heartbeat { DetailLine("Running", hb.version) }
                DetailLine("In this app", PushSetupModel.bundledPluginVersion)
                DetailLine("Size", ByteCountFormatter.string(fromByteCount: Int64(PushSetupModel.bundledScriptSize), countStyle: .file))
                DetailLine("Brings", DeviceWords.CompanionBrings)
                if let outcome = setup.updateOutcome {
                    Text(outcome.text).font(.body).foregroundStyle(outcome.ok ? Ink.text : .red)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !setup.restartStage.isEmpty {
                    Text(setup.restartStage).font(.body).foregroundStyle(Ink.text2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let error = setup.restartError {
                    Text(error).font(.body).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !setup.updateConsole.isEmpty {
                    Text("What happened").font(.headline).foregroundStyle(Ink.text).padding(.top, 4)
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(setup.updateConsole.enumerated()), id: \.offset) { _, line in
                            Text(line).font(.callout.monospaced())
                                .foregroundStyle(line.contains("FAILED") ? Color.red : Ink.text2)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .textSelection(.enabled)
                }
            }
            .padding(.top, 14)
        } label: {
            Text("Details").font(.headline).foregroundStyle(Ink.text)
        }
        .testID("softwareUpdate.details")
    }
}

/// The top of Software Update: one large symbol and where the Companion stands.
struct SoftwareUpdateHero: View {
    enum State: Equatable {
        case offline, checking, notInstalled, updateReady, updating, restart, restarting, failed, updated, upToDate

        init(connected: Bool, checked: Bool, installed: Bool, checking: Bool, updateAvailable: Bool,
             updating: Bool, showsConsole: Bool, needsRestart: Bool, restarting: Bool = false, outcome: Bool?) {
            guard connected else { self = .offline; return }
            guard checked else { self = .checking; return }
            guard installed else { self = .notInstalled; return }
            if updateAvailable || updating || showsConsole || outcome != nil {
                if updating { self = .updating }
                else if needsRestart { self = restarting ? .restarting : .restart }
                else if outcome == false { self = .failed }
                else if outcome == true { self = .updated }
                else { self = .updateReady }
                return
            }
            self = checking ? .checking : .upToDate
        }

        var symbol: String {
            switch self {
            case .offline: "puzzlepiece.extension"
            case .checking: "arrow.triangle.2.circlepath"
            case .notInstalled: "puzzlepiece.extension"
            case .updateReady: "arrow.down.circle.fill"
            case .updating: "arrow.down.circle"
            case .restart: "arrow.clockwise.circle.fill"
            case .restarting: "arrow.clockwise.circle"
            case .failed: "xmark.octagon.fill"
            case .updated, .upToDate: "checkmark.circle.fill"
            }
        }
        var title: String {
            switch self {
            case .offline: String(localized: "Not connected")
            case .checking: String(localized: "Checking")
            case .notInstalled: String(localized: "Not installed")
            case .updateReady: String(localized: "Update ready")
            case .updating: String(localized: "Updating")
            case .restart: String(localized: "Restart to finish")
            case .restarting: String(localized: "Restarting")
            case .failed: String(localized: "Update failed")
            case .updated: String(localized: "Updated")
            case .upToDate: String(localized: "Up to date")
            }
        }
        var tint: Color {
            switch self {
            case .offline, .checking, .notInstalled: Ink.text2
            case .updateReady, .updating: .blue
            case .restart, .restarting: .orange
            case .failed: .red
            case .updated, .upToDate: .green
            }
        }
    }

    var state: State
    /// What the update is doing now, the line while it updates.
    var stage = ""

    private var line: String? {
        let version = PushSetupModel.bundledPluginVersion
        switch state {
        case .offline: return String(localized: "Connect Nollie first.")
        case .checking: return nil
        case .notInstalled: return String(localized: "Set it up to get \(DeviceWords.companionBrings).")
        case .updateReady: return String(localized: "Nollie Companion \(version).")
        // The stages name the server once ("Restarting Gateway…"); the hero says it plainly.
        case .updating:
            return stage.isEmpty ? nil : stage == CompanionUpdateStage.restartingGateway ? String(localized: "Restarting…") : stage
        case .restart: return String(localized: "Your bots pause for a few seconds.")
        case .restarting: return String(localized: "Your bots are back in a moment.")
        case .failed: return String(localized: "Try again, or open Details.")
        case .updated: return String(localized: "Nollie Companion \(version) is running.")
        case .upToDate: return String(localized: "Nollie Companion \(version).")
        }
    }

    var body: some View {
        PageHero(symbol: state.symbol, title: .verbatim(state.title), line: .verbatim(line), tint: state.tint, id: "softwareUpdate.hero")
    }
}

/// Finishing an update with a restart: a countdown with Restart now and Later, the wait while it
/// restarts, or, after Later, the reminder and a way to do it now.
private struct RestartSteps: View {
    @Bindable var setup: PushSetupModel
    var runtime: GatewayRuntime

    @ViewBuilder var body: some View {
        if setup.restarting {
            Waiting(setup: setup, runtime: runtime)
        } else if let end = setup.restartCountdownEnd {
            Countdown(setup: setup, runtime: runtime, end: end)
        } else if setup.restartPending {
            Pending(setup: setup, runtime: runtime)
        }
    }

    /// Checks the gateway, or restarts it, with the setup model.
    private static func run(_ job: @escaping @MainActor () async -> Void) -> () -> Void {
        { Task { await job() } }
    }

    /// The wait while the gateway restarts.
    private struct Waiting: View {
        let setup: PushSetupModel
        let runtime: GatewayRuntime

        var body: some View {
            VStack(spacing: 14) {
                heading
                if let began = setup.restartBegan {
                    TimelineView(.periodic(from: .now, by: 1)) { clock in
                        if clock.date.timeIntervalSince(began) >= 60 { tooSlow }
                    }
                }
            }
        }

        private var heading: some View {
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("Restarting").font(.headline).foregroundStyle(Ink.text)
                if let began = setup.restartBegan {
                    TimelineView(.periodic(from: .now, by: 1)) { clock in
                        let elapsed = max(0, Int(clock.date.timeIntervalSince(began)))
                        Text(Duration.seconds(elapsed).formatted(.time(pattern: .minuteSecond)))
                            .font(.headline.monospacedDigit())
                            .foregroundStyle(Ink.text2)
                    }
                }
            }
            .accessibilityElement(children: .combine)
        }

        private var tooSlow: some View {
            VStack(spacing: 12) {
                PageNote("Still waiting. It's usually back in under a minute, and Nollie gives it up to three. The update stays installed either way.")
                ButtonPair {
                    Button(action: RestartSteps.run { await setup.checkRestartNow(runtime: runtime) }) {
                        RestartSteps.wide("Check now")
                    }
                    Button { withAnimation(.snappy) { setup.stopWaitingForRestart() } } label: {
                        RestartSteps.wide("Finish later")
                    }
                }
                .buttonStyle(.nollieGlass)
                .buttonBorderShape(.capsule)
                .controlSize(.large)
            }
        }
    }

    /// The countdown to an automatic restart, with Restart now and Later.
    private struct Countdown: View {
        let setup: PushSetupModel
        let runtime: GatewayRuntime
        let end: Date

        var body: some View {
            VStack(spacing: 14) {
                HStack(spacing: 10) {
                    Text("Restarting in").font(.headline).foregroundStyle(Ink.text)
                    // Reaching zero is what triggers the restart. That last tick renders with `now` beyond `end`,
                    // hence the clamped range.
                    TimelineView(.periodic(from: .now, by: 1)) { clock in
                        Text(timerInterval: min(clock.date, end)...end, countsDown: true)
                            .font(.title2.monospacedDigit().weight(.semibold))
                            .foregroundStyle(.orange)
                            .onChange(of: clock.date >= end) { _, reached in
                                if reached { restart() }
                            }
                    }
                }
                .accessibilityElement(children: .combine)

                ProgressView(timerInterval: min(Date(), end)...end, countsDown: true) { EmptyView() } currentValueLabel: { EmptyView() }
                    .tint(.orange)

                ButtonPair {
                    Button(action: restart) { RestartSteps.wide("Restart now") }
                        .buttonStyle(.nollieGlassProminent)
                    Button { withAnimation(.snappy) { setup.restartLater() } } label: { RestartSteps.wide("Later") }
                        .buttonStyle(.nollieGlass)
                }
                .buttonBorderShape(.capsule)
                .controlSize(.large)
            }
            .transition(.opacity.combined(with: .move(edge: .top)))
        }

        private func restart() {
            Task { await setup.restartNow(runtime: runtime) }
        }
    }

    /// The reminder after Later, or after a restart that did not finish.
    private struct Pending: View {
        let setup: PushSetupModel
        let runtime: GatewayRuntime

        private var signInMayHelp: Bool {
            guard let failure = setup.restartError else { return false }
            return ["expired", "401"].contains { failure.localizedCaseInsensitiveContains($0) }
        }

        var body: some View {
            VStack(spacing: 14) {
                PageNote(
                    setup.restartError == nil
                        ? "The update is in. It starts working after a restart."
                        : "The restart didn't finish. Check now, or restart again.",
                    symbol: "exclamationmark.triangle.fill", tint: .orange)
                ButtonPair {
                    Button { Task { await setup.restartNow(runtime: runtime) } } label: { RestartSteps.wide("Restart now") }
                        .buttonStyle(.nollieGlassProminent)
                    Button(action: RestartSteps.run { await setup.checkRestartNow(runtime: runtime) }) {
                        RestartSteps.wide("Check now")
                    }
                    .buttonStyle(.nollieGlass)
                }
                .buttonBorderShape(.capsule)
                .controlSize(.large)
                if signInMayHelp {
                    GlassLink("Sign in again", symbol: "person.badge.key", id: "softwareUpdate.signIn") {
                        GatewayFormView(existing: runtime.connection)
                    }
                    PageNote("If it already came back, signing in again shows it running, and no restart is needed.")
                }
            }
        }
    }

    fileprivate static func wide(_ title: LocalizedStringKey) -> some View {
        Text(title).font(.headline).frame(maxWidth: .infinity).padding(.vertical, 4)
    }
}

/// Two buttons side by side, one above the other at the largest text sizes.
private struct ButtonPair<Content: View>: View {
    @ViewBuilder var content: Content
    @Environment(\.dynamicTypeSize) private var size

    var body: some View {
        let layout = size.isAccessibilitySize ? AnyLayout(VStackLayout(spacing: 12)) : AnyLayout(HStackLayout(spacing: 12))
        layout { content }
    }
}

/// One fact in Details: a name and its value, wrapping at large sizes.
private struct DetailLine: View {
    var name: LocalizedStringKey
    var value: String
    @Environment(\.dynamicTypeSize) private var size

    init(_ name: LocalizedStringKey, _ value: String) {
        self.name = name
        self.value = value
    }

    var body: some View {
        let layout = size.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 2))
                                              : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: 12))
        layout {
            Text(name).font(.body).foregroundStyle(Ink.text2)
            if !size.isAccessibilitySize { Spacer(minLength: 8) }
            Text(value).font(.body.weight(.medium)).foregroundStyle(Ink.text)
                .multilineTextAlignment(size.isAccessibilitySize ? .leading : .trailing)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }
}

/// Notification setup wizard, opened straight from Settings' first-run card.
struct SetupWizardHost: View {
    @State private var setup = PushSetupModel()
    @Environment(AppModel.self) private var model

    var body: some View {
        PushSetupView(setup: setup)
            .task { await setup.prepareIfConnected(model.runtime) }
    }
}

private extension PushSetupModel {
    /// Gets ready for the gateway in use, if there is one.
    func prepareIfConnected(_ runtime: GatewayRuntime?) async {
        guard let runtime else { return }
        await prepare(runtime: runtime)
    }

    /// Checks the Companion on the gateway in use, if there is one.
    func checkIfConnected(_ runtime: GatewayRuntime?) async {
        guard let runtime else { return }
        await checkCompanion(runtime: runtime)
    }
}
