#if os(macOS)
import SwiftUI

/// Using this Mac, as the page says it first: off, waiting for a model or for apps, or ready.
enum ComputerAppsState: Equatable {
    case off, needsModel, needsApps, ready(Int)

    init(on: Bool, hasModel: Bool, picked: Int) {
        self = !on ? .off : !hasModel ? .needsModel : picked == 0 ? .needsApps : .ready(picked)
    }

    var title: String {
        switch self {
        case .off: "Off"
        case .needsModel: "Needs a model"
        case .needsApps: "Pick apps"
        case let .ready(count): count == 1 ? "In 1 app" : "In \(count) apps"
        }
    }

    var line: String {
        switch self {
        case .off: "Bots can't use this Mac."
        case .needsModel: "One that runs on this Mac."
        case .needsApps: "Bots use only the apps you pick."
        case .ready: "A model on this Mac does the clicking."
        }
    }

    var tint: Color {
        switch self {
        case .off: Ink.text2
        case .needsModel, .needsApps: .orange
        case .ready: .green
        }
    }
}

/// Settings for using this Mac: what is true now, one switch, the model on this Mac that does the
/// clicking, and the apps a bot may use, each with its own switch. Off, and no apps, to start.
struct ComputerAppsPage: View {
    @AppStorage(ComputerCenter.enabledKey) private var on = false
    @State private var picked = ComputerPickedApps.read()
    @State private var candidates: [ComputerPickedApps.Candidate]?
    @State private var model: ComputerScreenModel?

    var body: some View {
        SettingsPage("computer.apps.page") {
            ComputerAppsContent(on: on, modelName: model?.shownName, candidates: candidates, picked: picked) { app, isOn in
                ComputerPickedApps.set(app.info.bundleID, picked: isOn)
                picked = ComputerPickedApps.read()
            }
        }
        .untitledPage()
        .task {
            async let found = Task.detached { ComputerPickedApps.candidates(find: ComputerApps.find) }.value
            async let local = Task.detached { ComputerScreenModels.find() }.value
            (candidates, model) = await (found, local)
        }
    }
}

/// The page itself, from plain values, so pictures and tests need no Mac state.
struct ComputerAppsContent: View {
    var on: Bool
    var modelName: String?
    var candidates: [ComputerPickedApps.Candidate]?
    var picked: Set<String>
    var toggle: (ComputerPickedApps.Candidate, Bool) -> Void

    private var state: ComputerAppsState {
        ComputerAppsState(on: on, hasModel: modelName != nil,
                          picked: (candidates ?? []).filter { picked.contains($0.id) }.count)
    }

    var body: some View {
        PageHero(symbol: "macwindow.and.cursorarrow", title: state.title, line: state.line, tint: state.tint,
                 id: "computer.apps.hero")
        FactStrip(facts: [Fact(symbol: "cpu", word: "Model on Mac"), Fact(symbol: "eye.slash", word: "Screens stay"),
                          Fact(symbol: "hand.raised", word: "Asks first")],
                  tint: state == .off ? Ink.text3 : state.tint, id: "computer.apps.facts")
        ComputerBetaToggle()
            .toggleStyle(.switch)
            .font(.headline)
            .foregroundStyle(Ink.text)
            .inset(h: 22, v: 14)
            .spread(.center)
            .nollieGlass(.regular, in: Capsule(), solid: Ink.card)
        if on {
            if let modelName {
                Label(modelName, systemImage: "cpu")
                    .font(.headline)
                    .foregroundStyle(Ink.text2)
                    .testID("computer.apps.model")
            } else {
                GlassLink("Get a model", symbol: "arrow.down.circle", id: "computer.apps.getModel") {
                    ModelPreferencesView().untitledPage()
                }
            }
            apps
        }
    }

    @ViewBuilder private var apps: some View {
        PageHeading("Apps")
        if let candidates {
            GlassStack {
                ForEach(candidates) { app in
                    ComputerPickRow(app: app, isOn: Binding(get: { picked.contains(app.id) }, set: { toggle(app, $0) }))
                }
            }
        } else {
            ProgressView().frame(maxWidth: .infinity, minHeight: 60)
        }
    }
}

/// One app: its icon and name on a glass capsule, and its switch.
struct ComputerPickRow: View {
    var app: ComputerPickedApps.Candidate
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            HStack(spacing: 14) {
                ComputerAppIcon(bundleID: app.info.bundleID, size: 34)
                VStack(alignment: .leading, spacing: 1) {
                    Text(app.name).font(.headline).foregroundStyle(Ink.text)
                    if app.viewOnly { Text("View only").font(Ink.chip).foregroundStyle(Ink.text2) }
                }
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .toggleStyle(.switch)
        .inset(h: 14, v: 10)
        .padding(.trailing, 8)
        .frame(maxWidth: .infinity)
        .nollieGlass(.regular, in: Capsule(), solid: Ink.card)
        .accessibilityLabel(app.name)
        .testID("computer.apps.\(app.id)")
    }
}
#endif
