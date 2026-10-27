#if os(macOS)
import SwiftUI

/// Using this Mac, as the page says it first: off, waiting for a model or for apps, or ready.
enum ComputerAppsState: Equatable {
    case off, tooSmall, needsModel, needsApps, ready(Int)

    init(on: Bool, hasModel: Bool, picked: Int, bigEnough: Bool = ComputerScreenModels.macIsBigEnough()) {
        self = !on ? .off : !bigEnough ? .tooSmall : !hasModel ? .needsModel : picked == 0 ? .needsApps : .ready(picked)
    }

    var title: String {
        switch self {
        case .off: String(localized: "Off", comment: "Using this Mac is switched off")
        case .tooSmall: String(localized: "Needs more memory")
        case .needsModel: String(localized: "Needs a model")
        case .needsApps: String(localized: "Pick apps")
        case let .ready(count): String(localized: "In \(count) apps", comment: "Bots can use this Mac in this many apps")
        }
    }

    var line: String {
        switch self {
        case .off: String(localized: "Bots can't use this Mac.")
        case .tooSmall: String(localized: "Using this Mac needs 32 GB or more.")
        case .needsModel: String(localized: "One that runs on this Mac.", comment: "Under 'Needs a model': a model that runs on this Mac")
        case .needsApps: String(localized: "Bots use only the apps you pick.")
        case .ready: String(localized: "A model on this Mac does the clicking.")
        }
    }

    var tint: Color {
        switch self {
        case .off: Ink.text2
        case .tooSmall, .needsModel, .needsApps: .orange
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
    var bigEnough = ComputerScreenModels.macIsBigEnough()
    var toggle: (ComputerPickedApps.Candidate, Bool) -> Void

    private var state: ComputerAppsState {
        ComputerAppsState(on: on, hasModel: modelName != nil,
                          picked: (candidates ?? []).filter { picked.contains($0.id) }.count, bigEnough: bigEnough)
    }

    var body: some View {
        PageHero(symbol: "macwindow.and.cursorarrow", title: .verbatim(state.title), line: .verbatim(state.line), tint: state.tint,
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
        if on, state != .tooSmall {
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
