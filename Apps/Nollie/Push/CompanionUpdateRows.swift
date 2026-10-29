import SwiftUI
import NollieCore

/// Companion update screens modelled on Software Update: release notes, one Install Now button, a
/// bar showing the stage and estimated time, and finally "Update Complete". A small console tails the
/// gateway's progress and disappears a few seconds after it succeeds.
struct CompanionUpdateRows: View {
    @Bindable var setup: PushSetupModel
    let runtime: GatewayRuntime

    private var progressVisible: Bool { setup.updating || setup.showUpdateConsole || setup.updateOutcome != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            UpdateSummary(setup: setup)
            if progressVisible { UpdateProgress(setup: setup) }
            if setup.showUpdateConsole { UpdateConsole(lines: setup.updateConsole) }
            UpdateAction(setup: setup, runtime: runtime)
        }
        .inset(v: 6)
        .modifier(UpdateMotion(lineCount: setup.updateConsole.count, consoleOpen: setup.showUpdateConsole,
                               updating: setup.updating))
    }
}

/// Lets the console and the bar ease in and out as the run moves along.
private struct UpdateMotion: ViewModifier {
    let lineCount: Int
    let consoleOpen: Bool
    let updating: Bool

    func body(content: Content) -> some View {
        content
            .animation(.smooth, value: updating)
            .animation(.smooth, value: consoleOpen)
            .animation(.snappy, value: lineCount)
    }
}

// MARK: - Summary

/// The puzzle-piece badge, the version and size, and (before anything starts) a line on what it does.
private struct UpdateSummary: View {
    let setup: PushSetupModel

    private var untouched: Bool { !setup.updating && setup.updateOutcome == nil && !setup.updateNeedsRestart }
    private var succeeded: Bool { setup.updateOutcome?.ok == true }

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            badge
            VStack(alignment: .leading, spacing: 3) {
                Text("Nollie Companion \(PushSetupModel.bundledPluginVersion)").font(.headline)
                Text(ByteCountFormatter.string(fromByteCount: Int64(PushSetupModel.bundledScriptSize), countStyle: .file))
                    .small(.subheadline)
                if untouched { pitch.padding(.top, 2) }
            }
            Spacer(minLength: 0)
        }
    }

    private var pitch: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Sends replies as notifications and brings approval cards to \(DeviceWords.your) as soon as a bot needs a yes.")
                .note()
            if setup.runningCanSelfReload {
                StatusNote(String(localized: "Updates without restarting the gateway."), symbol: "checkmark.circle")
            } else {
                StatusNote(String(localized: "Needs a gateway restart to finish. Running turns pause for a few seconds."),
                           symbol: "arrow.clockwise", tone: .warning)
            }
        }
    }

    private var badge: some View {
        let (top, bottom) = (Color(red: 0.24, green: 0.77, blue: 0.93), Color(red: 0.04, green: 0.16, blue: 0.41))
        let sky = LinearGradient(colors: [top, bottom], startPoint: .topLeading, endPoint: .bottomTrailing)
        return Image(systemName: succeeded ? "checkmark" : "puzzlepiece.extension.fill")
            .contentTransition(.symbolEffect(.replace.downUp))
            .font(.title2.weight(.semibold))
            .foregroundStyle(.white)
            .frame(square: 60)
            .background(sky, in: .rect(cornerRadius: 14))
            .symbolEffect(.bounce, value: succeeded)
    }
}

// MARK: - Progress

/// The bar, the stage and time left, and how the run ended.
private struct UpdateProgress: View {
    let setup: PushSetupModel

    private var tint: Color {
        if setup.updateOutcome?.ok == false { return .red }
        return setup.updateProgress >= 1 ? .green : .accentColor
    }

    private var rightHandText: String {
        setup.updateRemaining ?? (setup.updateProgress >= 1 ? 1.0.formatted(.percent) : "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ProgressView(value: setup.updateProgress)
                .tint(tint)
                .scaleEffect(y: 1.6)
                .inset(v: 4)
            HStack {
                Text(setup.updateStage).contentTransition(.opacity).font(.footnote.weight(.medium))
                Spacer()
                Text(rightHandText).small(.footnote.monospacedDigit())
            }
            ending
        }
        .transition(.opacity.combined(with: .move(edge: .top)))
    }

    @ViewBuilder private var ending: some View {
        if let result = setup.updateOutcome {
            if result.ok {
                Text("Nollie Companion \(PushSetupModel.bundledPluginVersion) is in place and working.").note()
            } else {
                StatusNote(result.text, symbol: "xmark.octagon", tone: .problem)
            }
        }
    }
}

// MARK: - Console

/// What the gateway is doing, a line at a time, following the newest.
private struct UpdateConsole: View {
    let lines: [String]

    var body: some View {
        ScrollViewReader { reader in
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { offset, text in
                        Row(text: text).id(offset)
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 110)
            .darkWell()
            .onChange(of: lines.count) { _, count in
                withAnimation(.snappy) { reader.scrollTo(max(count - 1, 0), anchor: .bottom) }
            }
        }
        .transition(.scale(scale: 0.98, anchor: .top).combined(with: .opacity))
    }

    private struct Row: View {
        let text: String

        var body: some View {
            Text(text)
                .small(.caption2.monospaced(), text.contains("FAILED") ? .red : .secondary)
                .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }
}

// MARK: - The button under it

/// Install Now or Try Again, or the restart countdown once the files are in and a restart is due.
private struct UpdateAction: View {
    let setup: PushSetupModel
    let runtime: GatewayRuntime

    var body: some View {
        if setup.updating {
            EmptyView()
        } else if setup.updateNeedsRestart {
            RestartCountdownRows(setup: setup, runtime: runtime)
        } else if setup.updateOutcome?.ok != true {
            installButton
        }
    }

    private var installButton: some View {
        let words = setup.updateOutcome == nil ? String(localized: "Install Now") : String(localized: "Try Again")
        return Button(action: install) {
            Text(words)
                .frame(maxWidth: .infinity)
                .font(.body.bold())
                .inset(v: 6)
        }
        .buttonBorderShape(.roundedRectangle(radius: 12))
        .buttonStyle(.borderedProminent)
    }

    private func install() {
        Task { await setup.updateCompanion(runtime: runtime) }
    }
}

// MARK: - Restart

/// Buttons side by side, each filling half the width. The first may be the prominent one.
private struct ButtonPair: View {
    struct Choice {
        let title: String
        var prominent = false
        let action: () -> Void
    }

    let choices: [Choice]

    var body: some View {
        HStack {
            ForEach(choices.indices, id: \.self) { index in
                half(choices[index])
            }
        }
    }

    @ViewBuilder private func half(_ choice: Choice) -> some View {
        let button = Button(action: choice.action) { Text(choice.title).frame(maxWidth: .infinity) }
        if choice.prominent {
            button.buttonStyle(.borderedProminent)
        } else {
            button.buttonStyle(.bordered)
        }
    }
}

/// What the restart row is doing right now.
private enum RestartPhase {
    case waiting, counting(Date), reminder, none
}

/// Countdown rows that count down to a gateway restart, offering Restart now and Later. Choosing Later
/// leaves a quiet note that nothing runs until the gateway has restarted.
struct RestartCountdownRows: View {
    @Bindable var setup: PushSetupModel
    let runtime: GatewayRuntime

    private var phase: RestartPhase {
        if setup.restarting { return .waiting }
        if let end = setup.restartCountdownEnd { return .counting(end) }
        return setup.restartPending ? .reminder : .none
    }

    private func restart() { Task { await setup.restartNow(runtime: runtime) } }
    private func recheck() { Task { await setup.checkRestartNow(runtime: runtime) } }

    var body: some View {
        switch phase {
        case .waiting: waiting
        case .counting(let end): countdown(until: end)
        case .reminder: reminder
        case .none: EmptyView()
        }
    }

    // MARK: Waiting for the gateway

    private var waiting: some View {
        VStack(alignment: .leading, spacing: 8) {
            SpinnerLabel(String(localized: "Restarting the gateway…"))
            if let began = setup.restartBegan {
                TimelineView(.periodic(from: .now, by: 1)) { tick in
                    waitingDetail(seconds: Int(tick.date.timeIntervalSince(began)))
                }
            }
        }
        .inset(v: 4)
    }

    private func waitingDetail(seconds: Int) -> some View {
        let stage = setup.restartStage.isEmpty ? String(localized: "Working", comment: "A restart is under way") : setup.restartStage
        return VStack(alignment: .leading, spacing: 6) {
            Text("\(stage) · " + String(format: "%d:%02d", seconds / 60, seconds % 60)).note()
            if seconds >= 60 {
                Text("Still waiting. A gateway is usually back within a minute, and this gives it up to three. You can check now or finish later, and the files stay installed either way.")
                    .note(.warning)
                ButtonPair(choices: [
                    .init(title: String(localized: "Check now"), action: recheck),
                    .init(title: String(localized: "Finish later")) { withAnimation(.snappy) { setup.stopWaitingForRestart() } },
                ])
            }
        }
    }

    // MARK: Counting down

    private func countdown(until end: Date) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            countdownHeader(end: end)
            ProgressView(timerInterval: span(to: end, from: .now), countsDown: true, label: { EmptyView() }, currentValueLabel: { EmptyView() })
                .tint(.orange)
            ButtonPair(choices: [
                .init(title: String(localized: "Restart now"), prominent: true, action: restart),
                .init(title: String(localized: "Later", comment: "Restart the gateway later")) { withAnimation(.snappy) { setup.restartLater() } },
            ])
            Text("Turns in progress pause for a few seconds, and the companion does nothing until the gateway restarts.").note()
        }
        .inset(v: 4)
        .transition(.move(edge: .top).combined(with: .opacity))
    }

    /// Time remaining, never counting backwards. The tick that hits zero renders with `now` already
    /// beyond `end`, so the start is clamped.
    private func span(to end: Date, from start: Date) -> ClosedRange<Date> { min(start, end)...end }

    private func countdownHeader(end: Date) -> some View {
        HStack {
            Label(title: { Text("Restarting the gateway in") }, icon: { Image(systemName: "arrow.clockwise.circle") })
                .font(.footnote.weight(.medium))
            Spacer()
            TimelineView(.periodic(from: .now, by: 1)) { tick in
                Text(timerInterval: span(to: end, from: tick.date), countsDown: true)
                    .font(.title3.weight(.semibold).monospacedDigit())
                    .onChange(of: tick.date >= end) { _, due in
                        if due { restart() }
                    }
            }
        }
    }

    // MARK: After Later

    private var signInAgainNeeded: Bool {
        guard let failure = setup.restartError else { return false }
        return ["expired", "401"].contains(where: failure.localizedCaseInsensitiveContains)
    }

    @ViewBuilder private var reminder: some View {
        let headline = setup.restartError.map { String(localized: "The restart failed: \($0)") }
            ?? String(localized: "A restart is needed. The files are on the gateway, but nothing works until it restarts.")
        StatusNote(headline, symbol: "exclamationmark.triangle.fill", tone: .warning)
        ActionRow(String(localized: "Restart gateway now"), symbol: "arrow.clockwise", action: restart)
        ActionRow(String(localized: "Check now"), symbol: "waveform.path.ecg", action: recheck)
        if signInAgainNeeded {
            let hint = String(localized: "If the gateway has already come back, Settings, Advanced, Companion will show it running. Sign in again and no restart is needed.")
            NavigationLink(destination: { GatewayFormView(existing: runtime.connection) },
                           label: { ActionLabel(title: String(localized: "Sign in again"), symbol: "person.badge.key") })
            Text(hint).note()
        }
    }
}

/// A title with a symbol, for rows that are not buttons themselves.
private struct ActionLabel: View {
    let title: String
    let symbol: String

    var body: some View { Label(title, systemImage: symbol) }
}
