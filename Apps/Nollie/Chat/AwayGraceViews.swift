import SwiftUI
import NollieCore

/// Holds the gateway's "keep work running" wait and tracks a save in flight.
@MainActor @Observable
final class AwayGraceState {
    let runtime: GatewayRuntime
    private(set) var current: AwayGrace?
    private(set) var problem: String?
    private(set) var saving = false
    private(set) var saved = false

    init(runtime: GatewayRuntime) {
        self.runtime = runtime
    }

    func load() async {
        let bot = runtime.selectedProfile
        do {
            let config: JSONValue = try await runtime.api.get("/api/config", profile: bot)
            var value = AwayGrace.read(config: config)
            // An environment setting on the gateway takes priority, so report that instead of a control that does nothing.
            let env: [String: EnvVarInfo]? = try? await runtime.api.get("/api/env", profile: bot)
            value.envOverride = env?[AwayGrace.envKey]?.hasValue == true || value.envOverride
            current = value
            problem = nil
        } catch {
            problem = "Nollie could not read this from the gateway: \(error.localizedDescription)"
        }
    }

    func save(_ seconds: Double) async {
        if current?.effective == seconds { return }
        saving = true
        defer { saving = false }
        let change = AwayGrace.writeBody(seconds: seconds)
        let bot = runtime.selectedProfile
        do {
            let _: JSONValue = try await runtime.api.send("PUT", "/api/config", profile: bot, json: change)
            current?.seconds = seconds
            saved = true
            problem = nil
        } catch {
            problem = "That did not save: \(error.localizedDescription)"
        }
    }

    /// The usual waits, plus the gateway's current one if it is something else. "No limit" (0) goes last.
    func choices(including value: Double) -> [Double] {
        var all = AwayGrace.choices
        if !all.contains(value) { all.append(value) }
        let rank: (Double) -> Double = { $0 == 0 ? .greatestFiniteMagnitude : $0 }
        return all.sorted { rank($0) < rank($1) }
    }
}

/// The wait the gateway gives a turn once no app is connected. Reads it from the gateway's config
/// and stores changes there. An interrupted turn's card links to it as well.
struct AwayGraceSection: View {
    @State private var state: AwayGraceState

    init(runtime: GatewayRuntime) {
        _state = State(initialValue: AwayGraceState(runtime: runtime))
    }

    private var awayCause: String { DeviceWords.isMac ? "this Mac sleeps" : "Nollie leaves the screen" }

    private var footerText: String {
        "This is how long the gateway lets a turn carry on after the last app disconnects, for example once \(awayCause). "
        + "Newer Hermes already lets a busy turn finish alone. On an older one, a short wait cuts long tasks off "
        + "with \u{201C}Operation interrupted\u{201D}. It lives in the gateway's config as dashboard.ws_orphan_reap_grace_s "
        + "and is read when the dashboard starts, which also happens when Hermes is updated from here."
    }

    var body: some View {
        Section {
            content
            if let problem = state.problem { Text(problem).quiet(.footnote, .red) }
            if state.saved {
                line("Saved. It applies the next time the dashboard restarts on the gateway computer.",
                     symbol: "checkmark.circle", tint: .secondary)
            }
        } header: {
            Text("While the app is away")
        } footer: {
            Text(footerText)
        }
        .task(id: state.runtime.connection.id) { await state.load() }
    }

    @ViewBuilder private var content: some View {
        if let grace = state.current {
            picker(for: grace)
            if grace.isShort && !state.saved {
                line("That is short. On Hermes from before September 2026, a long task stops about \(AwayGrace.label(grace.effective)) after the app goes.",
                     symbol: "exclamationmark.triangle", tint: .orange)
            }
            if grace.envOverride {
                Text("The gateway's environment sets \(AwayGrace.envKey), and that wins. Change or remove it under Settings, then Environment.")
                    .quiet(.footnote)
            }
        } else if state.problem == nil {
            HStack {
                title
                Spacer()
                ProgressView().controlSize(.small)
            }
        }
    }

    private var title: some View { Label("Keep work running", systemImage: "hourglass") }

    private func line(_ words: String, symbol: String, tint: some ShapeStyle) -> some View {
        Label(words, systemImage: symbol).quiet(.footnote, tint)
    }

    private func picker(for grace: AwayGrace) -> some View {
        let selection = Binding(get: { grace.effective }, set: { new in Task { await state.save(new) } })
        return Picker(selection: selection) {
            ForEach(state.choices(including: grace.effective), id: \.self) { seconds in
                Text(AwayGrace.label(seconds)).tag(seconds)
            }
        } label: {
            title
        }
        .disabled(state.saving || grace.envOverride)
        .accessibilityIdentifier("system.awayGrace")
    }
}

/// The same setting on its own sheet.
struct AwayGraceSheet: View {
    var runtime: GatewayRuntime

    var body: some View {
        NavigationStack {
            Form { AwayGraceSection(runtime: runtime) }
                .navigationTitle("Keep Work Running")
                .formStyle(.grouped)
                .doneToolbar()
        }
    }
}
