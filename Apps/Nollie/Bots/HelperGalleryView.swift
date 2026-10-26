import SwiftUI
import NollieCore

/// The ready-made helpers: a grid of characters, each with its name, one line and one Add. A tap
/// adds the helper with its look and instructions; its character drops into the crew along the
/// bottom, and the same pill becomes Undo until the sheet closes. The last tile makes your own.
struct HelperGalleryView: View {
    var runtime: GatewayRuntime
    var gallery: HelperGallery
    var makeOwn: () -> Void

    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Bots shown in the crew, never one on the Private list. (Bots on a local model count as
    /// private elsewhere; crew helpers run locally and belong here.)
    private var crew: [ProfileInfo] {
        runtime.profiles.filter { $0.name != "private" && !PrivateBots.isPrivate($0.name, connection: runtime.connection.id) }
    }

    private var botNames: Set<String> { Set(runtime.profiles.map(\.name)) }

    /// As many tiles a row as fit, so a phone shows two and a wide sheet three or more. One a
    /// row at the largest text sizes.
    private var columns: [GridItem] {
        let narrowest: CGFloat = typeSize.isAccessibilitySize ? 280 : 148
        return [GridItem(.adaptive(minimum: narrowest), spacing: 18, alignment: .top)]
    }

    var body: some View {
        ScrollViewReader { scroller in
            grid
            #if DEBUG
            // For pictures: `-nollie-demo-gallery-end` shows the last tile.
            .task {
                guard DemoMode.isOn, ProcessInfo.processInfo.arguments.contains("-nollie-demo-gallery-end") else { return }
                try? await Task.sleep(for: .seconds(1.5))
                scroller.scrollTo("gallery.own", anchor: .bottom)
            }
            #endif
        }
    }

    private var grid: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 34) {
                ForEach(ReadyMadeHelper.gallery) { helper in
                    HelperTile(helper: helper, state: gallery.state(of: helper, bots: botNames),
                               working: gallery.working == helper.id, locked: app.lock.isLocked || gallery.working != nil,
                               add: { Task { await add(helper) } }, undo: { Task { await undo(helper) } })
                }
                OwnHelperTile(action: makeOwn).id("gallery.own")
            }
            .padding(.horizontal, 20).padding(.top, 14).padding(.bottom, 28)
            .frame(maxWidth: 760)
            .frame(maxWidth: .infinity)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { crewBar }
        // The crew below needs the bots; a gateway opened straight into this sheet may not have them yet.
        .task { if runtime.profiles.isEmpty { await runtime.loadProfiles() } }
        #if DEBUG
        // For pictures: `-nollie-demo-gallery-add <id>` adds that helper once the sheet has settled.
        .task {
            let words = ProcessInfo.processInfo.arguments
            guard DemoMode.isOn, let flag = words.firstIndex(of: "-nollie-demo-gallery-add"), words.indices.contains(flag + 1),
                  let helper = ReadyMadeHelper.gallery.first(where: { $0.id == words[flag + 1] }) else { return }
            try? await Task.sleep(for: .seconds(2.5))
            await add(helper)
        }
        #endif
    }

    // MARK: The crew along the bottom

    private var crewBar: some View {
        VStack(spacing: 8) {
            if let problem = gallery.problem {
                Text(problem)
                    .small(.footnote, .red)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .testID("gallery.issue")
            } else if gallery.room == 0, gallery.added.isEmpty {
                Text("Your crew is full.").small(.footnote)
            }
            if !crew.isEmpty || !gallery.added.isEmpty { faces }
        }
        .padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 10)
        .frame(maxWidth: 560)
        .frame(maxWidth: .infinity)
    }

    private var faces: some View {
        HStack(spacing: 12) {
            CrewFaces(bots: crew, reduceMotion: reduceMotion)
            Spacer(minLength: 8)
            if !gallery.added.isEmpty {
                Button("Done") { dismiss() }
                    .buttonStyle(InkPillStyle())
                    .transition(.opacity.combined(with: .scale(scale: 0.8)))
                    .testID("gallery.done")
            }
        }
        .padding(.leading, 14).padding(.trailing, 10).padding(.vertical, 8)
        .frame(minHeight: 60)
        .nollieGlass(.regular, in: Capsule(), solid: Ink.card)
        .animation(.snappy, value: gallery.added.isEmpty)
    }

    // MARK: Adding and taking back

    private func add(_ helper: ReadyMadeHelper) async {
        let stillAllowed = { !app.lock.isLocked && app.runtime === runtime }
        let profile = await gallery.add(helper, .gateway(runtime), allowed: stillAllowed)
        // Read the bots either way: an add whose answer was lost may still have happened.
        await runtime.loadProfiles()
        if profile != nil { NotificationCenter.default.post(name: .hermesSessionsChanged, object: nil) }
    }

    private func undo(_ helper: ReadyMadeHelper) async {
        guard await gallery.undo(helper, .gateway(runtime)) != nil else { return }
        await runtime.loadProfiles()
        NotificationCenter.default.post(name: .hermesSessionsChanged, object: nil)
    }
}

// MARK: - A tile

/// One ready-made helper: the character carries it, with the name, one line and a single pill.
private struct HelperTile: View {
    var helper: ReadyMadeHelper
    var state: HelperGallery.TileState
    var working: Bool
    var locked: Bool
    var add: () -> Void
    var undo: () -> Void

    private var pose: CharacterState {
        if working { return .thinking }
        return state == .justAdded ? .done : .idle
    }

    var body: some View {
        VStack(spacing: 10) {
            CharacterView(look: helper.look, state: pose, size: 92, seed: CharacterLookID.seed(helper.id))
                .frame(width: 104, height: 104)
                .accessibilityHidden(true)
            VStack(spacing: 4) {
                Text(helper.name)
                    .font(.headline)
                    .foregroundStyle(Ink.text)
                Text(helper.promise)
                    .font(.subheadline)
                    .foregroundStyle(Ink.text2)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)
            Spacer(minLength: 0)
            pill
        }
        .frame(maxWidth: .infinity)
        .animation(.snappy, value: state)
    }

    @ViewBuilder private var pill: some View {
        switch state {
        case .available, .full:
            Button(action: add) {
                Label("Add", systemImage: "plus")
            }
            .buttonStyle(OutlinePillStyle())
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
}

/// The last tile: start from nothing, with your own name, look and words.
private struct OwnHelperTile: View {
    var action: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "plus")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(Ink.text2)
                .frame(width: 84, height: 84)
                .nollieGlass(.regular, in: Circle(), solid: Ink.card)
                .frame(width: 104, height: 104)
                .accessibilityHidden(true)
            VStack(spacing: 4) {
                Text("Your own").font(.headline).foregroundStyle(Ink.text)
                Text("Your name, your words.")
                    .font(.subheadline)
                    .foregroundStyle(Ink.text2)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)
            Spacer(minLength: 0)
            Button(action: action) {
                Text("Make")
            }
            .buttonStyle(OutlinePillStyle())
            .accessibilityLabel("Make your own bot")
            .testID("newBot.custom")
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - The crew

/// The crew's faces in a row, slightly overlapping, newest last. A newcomer drops in from above
/// with a bounce; with Reduce Motion it fades in.
private struct CrewFaces: View {
    var bots: [ProfileInfo]
    var reduceMotion: Bool

    /// The most faces shown; the rest are a count.
    private let shown = 6

    var body: some View {
        HStack(spacing: -8) {
            ForEach(bots.prefix(shown)) { bot in
                BotAvatar(profile: bot.name, size: 40)
                    .transition(arrival)
            }
            if bots.count > shown {
                Text("+\(bots.count - shown)")
                    .font(.subheadline.weight(.semibold).monospacedDigit())
                    .foregroundStyle(Ink.text2)
                    .padding(.leading, 14)
            }
        }
        // The bounce: a spring that overshoots a little as the newcomer lands.
        .animation(reduceMotion ? .easeInOut(duration: 0.2) : .spring(response: 0.5, dampingFraction: 0.6),
                   value: bots.map(\.name))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Your crew")
        .accessibilityValue(bots.map(\.shownName).joined(separator: ", "))
        .testID("gallery.crew")
    }

    private var arrival: AnyTransition {
        reduceMotion ? .opacity : .asymmetric(
            insertion: .offset(y: -90).combined(with: .scale(scale: 0.4)).combined(with: .opacity),
            removal: .scale(scale: 0.4).combined(with: .opacity))
    }
}
