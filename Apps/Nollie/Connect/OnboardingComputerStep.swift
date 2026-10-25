#if os(macOS)
import NollieCore
import SwiftUI

/// The Mac setup's computer step: one toggle that gets Cua, sets it up and gives the main
/// helper its own computer. Turning it on is the one yes; everything after runs by itself.
struct OnboardingComputerStep: View {
    var runtime: GatewayRuntime
    var profile: String
    var name: String
    /// Whether the toggle is on, for the step's Continue.
    var onChange: (Bool) -> Void
    @State private var computer: HelperComputerModel

    init(runtime: GatewayRuntime, profile: String, name: String, onChange: @escaping (Bool) -> Void) {
        self.runtime = runtime
        self.profile = profile
        self.name = name
        self.onChange = onChange
        _computer = State(initialValue: HelperComputerModel(profile: profile))
    }

    private var setup: CuaSetup { .shared }

    private var switchIsOn: Bool {
        HelperComputerPresentation.switchIsOn(computer.status, wantsOn: computer.wantsOn)
    }

    private var switchIsLocked: Bool {
        computer.status == nil || computer.sending || computer.status?.busy == true
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Toggle(isOn: Binding(get: { switchIsOn }, set: flip)) {
                StepHeading(
                    title: "Give your helpers their own computers",
                    note: "Each helper works on a computer inside your Mac, so your files stay out of reach. Nollie uses Cua, a free tool, to make them.")
            }
            .toggleStyle(.switch)
            .controlSize(.large)
            .disabled(switchIsLocked)
            .glassCard(inset: 18, corner: Ink.cardRadius)
            .testID("onboarding.ownComputers")
            ComputerProgress(
                screen: HelperComputerPresentation.screen(
                    status: computer.status, error: computer.error, wantsOn: computer.wantsOn,
                    onMac: true, run: setup.run, working: false, name: name),
                name: name, act: run)
        }
        .task(id: runtime.connection.id) {
            await setup.refresh()
            await computer.watch(runtime) { CuaSetup.shared.isWorking }
        }
        .onChange(of: switchIsOn, initial: true) { _, on in onChange(on) }
        .onChange(of: setup.run) { _, state in
            if state == .done { Task { await settleAfterSetup() } }
        }
    }

    private func flip(_ on: Bool) {
        Task {
            await computer.setSwitch(on, runtime)
            // A Cua that isn't running is woken the same way: Nollie Runtime starts its background part.
            if on, let status = computer.status, status.setup != .ready { await setup.start() }
        }
    }

    private func settleAfterSetup() async {
        #if DEBUG
        if DemoMode.isOn {
            let _: JSONValue? = try? await runtime.api.send("POST", "/api/_mock/own-computer", json: ["setup": "ready"])
        }
        #endif
        await computer.load(runtime)
    }

    private func run(_ action: HelperComputerAction) {
        Task {
            switch action {
            case .setUp, .update, .finish, .tryAgain, .startCua: await setup.start()
            case .quitCua: await setup.quitCuaThenUpdate()
            case .getCua: setup.openDownloadPage()
            case .notNow: computer.notNow()
            }
        }
    }
}

/// The card under the toggle: what the computer is doing, or what it needs from the person.
private struct ComputerProgress: View {
    var screen: HelperComputerScreen
    var name: String
    var act: (HelperComputerAction) -> Void

    var body: some View {
        switch screen {
        case .loading, .off:
            EmptyView()
        case .settingUp(let title, let fraction):
            card("settingUp") {
                Text(title).font(.headline)
                if let fraction { ProgressView(value: fraction) } else { ProgressView().progressViewStyle(.linear) }
                Text("You can keep going. Nollie finishes this in the background.")
                    .font(.body).foregroundStyle(.secondary)
            }
        case .gettingReady(let text):
            card("gettingReady") {
                HStack(alignment: .top, spacing: 12) {
                    ProgressView().controlSize(.small)
                    Text(text).font(.body)
                }
            }
        case .card(let word, _):
            let needsYou = word == .needsYou
            card {
                Label {
                    Text("\(HelperComputerPresentation.cardTitle(name)): \(word.rawValue)").font(.headline)
                } icon: {
                    Image(systemName: needsYou ? "exclamationmark.circle" : "checkmark.circle.fill")
                        .foregroundStyle(needsYou ? Color.orange : Color.readableGreen)
                        .accessibilityHidden(true)
                }
            }
        case .setup(let prompt):
            card {
                Text(prompt.line).font(.body).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 10) {
                    pill(prompt.action, prominent: true)
                    pill(prompt.secondary == .notNow ? nil : prompt.secondary, prominent: false)
                }
                .buttonBorderShape(.capsule)
                .controlSize(.large)
            }
        case .unavailable(let text):
            card { Text(text).font(.body) }
        }
    }

    @ViewBuilder private func pill(_ action: HelperComputerAction?, prominent: Bool) -> some View {
        if let action {
            let button = Button(action.title) { act(action) }
            Group {
                if prominent { button.buttonStyle(.nollieGlassProminent) } else { button.buttonStyle(.nollieGlass) }
            }
            .testID("onboarding.ownComputers.action." + action.rawValue)
        }
    }

    @ViewBuilder private func card<Content: View>(_ tag: String? = nil, @ViewBuilder _ content: () -> Content) -> some View {
        let body = VStack(alignment: .leading, spacing: 12, content: content)
            .glassCard(inset: 18, corner: Ink.cardRadius)
        if let tag { body.testID("onboarding.ownComputers." + tag) } else { body }
    }
}
#endif
