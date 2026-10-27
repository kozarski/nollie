import SwiftUI
import NollieCore

/// One ready-made helper's page, from its tile: the character with its name and one line, the
/// one Add, what it helps with, what it always asks you first, and its schedule's switch, off
/// until the person turns it on.
struct HelperDetailView: View {
    var helper: ReadyMadeHelper
    var runtime: GatewayRuntime
    var gallery: HelperGallery
    var add: () -> Void
    var undo: () -> Void

    @Environment(AppModel.self) private var app

    private var state: HelperGallery.TileState {
        gallery.state(of: helper, bots: Set(runtime.profiles.map(\.name)))
    }

    /// The bot this helper became, once there is one: added during this visit, or already there.
    private var profile: String? {
        if let added = gallery.added.first(where: { $0.helper == helper.id }) { return added.profile }
        return state == .inCrew ? helper.id : nil
    }

    private var coat: Color {
        Color(botHex: CharacterCatalog.shared.look(helper.look).colour) ?? Ink.text2
    }

    var body: some View {
        ScrollViewReader { reader in
            page
            #if DEBUG
            // Pictures of the lower half: `-nollie-demo-scroll-end`.
            .task {
                guard DemoMode.isOn, ProcessInfo.processInfo.arguments.contains("-nollie-demo-scroll-end") else { return }
                try? await Task.sleep(for: .milliseconds(1200))
                reader.scrollTo("helper.end", anchor: .bottom)
            }
            #endif
        }
    }

    private var page: some View {
        ScrollView {
            VStack(spacing: 36) {
                hero
                HelperAddPill(helper: helper, state: state, working: gallery.working == helper.id,
                              locked: app.lock.isLocked || gallery.working != nil, prominent: true,
                              add: add, undo: undo)
                part("Helps with") {
                    FactStrip(facts: helper.helpsWith, tint: coat, id: "helper.helps")
                }
                part("Asks first") {
                    FactStrip(facts: ReadyMadeHelper.asksFirst, tint: Ink.text, id: "helper.asks")
                }
                if let routine = helper.routine {
                    part("Schedule") {
                        HelperRoutineRow(helper: helper, routine: routine, runtime: runtime, profile: profile)
                    }
                }
                Color.clear.frame(height: 1).id("helper.end")
            }
            .frame(maxWidth: 560)
            .padding(EdgeInsets(top: 12, leading: 24, bottom: 40, trailing: 24))
            .frame(maxWidth: .infinity)
            .animation(.snappy, value: state)
        }
        .background(Ink.canvas.ignoresSafeArea())
        #if os(iOS)
        // The floating back button: the character scrolled under it fades out instead of showing through.
        .scrollEdgeEffectStyle(.hard, for: .top)
        #endif
        .untitledPage()
        .testID("helper.page.\(helper.id)")
    }

    private var hero: some View {
        VStack(spacing: 12) {
            CharacterView(look: helper.look, state: pose, size: 120, seed: CharacterLookID.seed(helper.id))
                .frame(width: 136, height: 136)
                .accessibilityHidden(true)
            Text(helper.name)
                .font(.largeTitle.weight(.bold))
                .foregroundStyle(Ink.text)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            Text(helper.promise)
                .font(.title3)
                .foregroundStyle(Ink.text2)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
    }

    private var pose: CharacterState {
        if gallery.working == helper.id { return .thinking }
        return state == .justAdded ? .done : .idle
    }

    private func part<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: 18) {
            PageHeading(title)
            content()
        }
    }
}

/// A tile's or a page's one pill: Add, then Undo until the sheet closes, or Added.
struct HelperAddPill: View {
    var helper: ReadyMadeHelper
    var state: HelperGallery.TileState
    var working: Bool
    var locked: Bool
    /// The page's pill is the ink one; a tile's is glass.
    var prominent = false
    var add: () -> Void
    var undo: () -> Void

    var body: some View {
        switch state {
        case .available, .full:
            Button(action: add) {
                Label("Add", systemImage: "plus")
            }
            .modifier(PillStyle(prominent: prominent))
            .disabled(locked || state == .full)
            .accessibilityLabel("Add \(helper.name)")
            .testID("gallery.add.\(helper.id)")
        case .justAdded:
            Button(action: undo) {
                Label("Undo", systemImage: "arrow.uturn.backward")
            }
            .buttonStyle(OutlinePillStyle())
            .disabled(locked)
            .accessibilityLabel("Undo adding \(helper.name)")
            .testID("gallery.undo.\(helper.id)")
        case .inCrew:
            Label("Added", systemImage: "checkmark")
                .font(.body.weight(.medium))
                .foregroundStyle(Ink.text2)
                .padding(.vertical, 12)
                .accessibilityLabel("\(helper.name) is in your crew")
                .testID("gallery.added.\(helper.id)")
        }
    }

    private struct PillStyle: ViewModifier {
        var prominent: Bool
        func body(content: Content) -> some View {
            if prominent { content.buttonStyle(InkPillStyle()) } else { content.buttonStyle(OutlinePillStyle()) }
        }
    }
}

/// The helper's schedule: its name and when, and one switch on a glass capsule. It can only be
/// turned on once the helper is there.
private struct HelperRoutineRow: View {
    var helper: ReadyMadeHelper
    var routine: HelperRoutine
    var runtime: GatewayRuntime
    var profile: String?

    @Environment(AppModel.self) private var app
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var routineSwitch: HelperRoutineSwitch

    init(helper: ReadyMadeHelper, routine: HelperRoutine, runtime: GatewayRuntime, profile: String?) {
        self.helper = helper
        self.routine = routine
        self.runtime = runtime
        self.profile = profile
        _routineSwitch = State(initialValue: HelperRoutineSwitch(helper: helper, routine: routine))
    }

    private var usable: Bool {
        profile != nil && !app.lock.isLocked && !routineSwitch.busy
            && (routineSwitch.standing == .on || routineSwitch.standing == .off)
    }

    var body: some View {
        VStack(spacing: 14) {
            Toggle(isOn: Binding(get: { routineSwitch.isOn }, set: { on in Task { await set(on) } })) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(routine.title).font(.headline).foregroundStyle(Ink.text)
                    Text(routine.when()).font(.subheadline).foregroundStyle(Ink.text2)
                }
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .toggleStyle(.switch)
            .disabled(!usable)
            .inset(h: 22, v: 12)
            .frame(maxWidth: .infinity)
            .nollieGlass(.regular, in: shape, solid: Ink.card)
            .testID("helper.schedule.\(helper.id)")
            if profile == nil {
                PageNote("Add \(helper.name) first.", id: "helper.schedule.first")
            } else if let problem = routineSwitch.problem {
                PageNote(problem, symbol: "exclamationmark.circle", tint: .red, id: "helper.schedule.issue")
            } else if routineSwitch.standing == .unavailable {
                PageNote("Couldn't check Schedules.", id: "helper.schedule.issue")
            }
        }
        .task(id: profile) {
            guard let profile else { return }
            await routineSwitch.load(profile: profile, .gateway(runtime))
        }
    }

    /// A capsule, or a softly rounded box once large text wraps the words onto more lines.
    private var shape: AnyShape {
        typeSize.isAccessibilitySize ? AnyShape(.rect(cornerRadius: 26, style: .continuous)) : AnyShape(Capsule())
    }

    private func set(_ on: Bool) async {
        guard let profile else { return }
        await routineSwitch.set(on, profile: profile, .gateway(runtime),
                                allowed: { !app.lock.isLocked && app.runtime === runtime })
    }
}
