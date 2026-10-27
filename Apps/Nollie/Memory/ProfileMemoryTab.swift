import SwiftUI
import NollieCore

/// Memory: what this helper remembers about you, newest first, as plain rows to open, change or
/// forget, and its one switch. About you is its USER.md; its own notes are its MEMORY.md. Moss is
/// never read, and another private bot's memory shows only in Nollie on the Mac that runs it.
struct ProfileMemoryTab: View {
    var state: ProfileCardState
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var memory = HelperMemoryModel(undoWindow: Self.undoWindow)
    @State private var draft: HelperMemoryModel.Draft?

    private var runtime: GatewayRuntime? { model.runtime }
    private var access: HelperMemoryAccess { Self.access(state: state, runtime: runtime) }
    private var onThisMac: Bool { access == .shownOnThisMac }
    private var scope: String {
        "\(state.name)/\(runtime?.connection.id.uuidString ?? "")/\(access)/\(model.lock.isLocked)"
    }
    private var motion: Animation? { reduceMotion ? nil : .snappy }

    /// Five seconds to undo a forget; a minute in the demo copy's picture of it.
    private static var undoWindow: Duration {
        #if DEBUG
        if DemoMode.isOn, ProcessInfo.processInfo.arguments.contains("forget") { return .seconds(60) }
        #endif
        return .seconds(5)
    }

    /// Where this bot's memory may be shown from here.
    static func access(state: ProfileCardState, runtime: GatewayRuntime?) -> HelperMemoryAccess {
        HelperMemoryAccess.decide(bot: state.name, isPrivate: state.isHidden, onThisMac: isThisMac(runtime))
    }

    /// Nollie on the Mac whose gateway is this very Mac.
    static func isThisMac(_ runtime: GatewayRuntime?) -> Bool {
        #if os(macOS)
        runtime?.gatewayIsOnThisMac ?? false
        #else
        false
        #endif
    }

    var body: some View {
        Group {
            if access != .hidden, runtime != nil, !model.lock.isLocked { content }
        }
        .animation(motion, value: memory.shownCount)
        .animation(motion, value: memory.forgetting)
        .task(id: scope) {
            await memory.sendForget()
            memory.reset()
            guard let runtime, access != .hidden, !model.lock.isLocked else { return }
            await memory.load(HelperMemoryModel.door(runtime: runtime, bot: state.name, onThisMac: onThisMac))
            showForDemo()
        }
        .onDisappear { Task { await memory.sendForget() } }
        .sheet(item: $draft) { opened in
            MemoryEditor(draft: opened, label: state.label, memory: memory)
                .sheetFrame()
                .withAppModel()
        }
    }

    /// The demo copy's `-nollie-demo-memory edit|new|forget`: the editor open on the newest entry, a new
    /// one, or the newest just forgotten, for its picture.
    private func showForDemo() {
        #if DEBUG
        let args = ProcessInfo.processInfo.arguments
        guard DemoMode.isOn, let at = args.firstIndex(of: "-nollie-demo-memory"), at + 1 < args.count else { return }
        let newest = memory.rows(.user).first
        switch args[at + 1] {
        case "edit": if let newest { draft = .editing(newest, in: .user) }
        case "new": draft = .new()
        case "forget": if let newest { memory.forget(newest, in: .user) }
        default: break
        }
        #endif
    }

    @ViewBuilder private var content: some View {
        switch memory.phase {
        case .loading:
            ProgressView().spread(.center).padding(.vertical, 40)
        case .unavailable:
            CardHeadline(symbol: "brain.head.profile", tint: Ink.text2, title: "Not on your Mac yet",
                         line: "Update Nollie on your Mac to see this.", id: "profile.memory.hero")
        case .failed:
            CardHeadline(symbol: "wifi.exclamationmark", tint: .orange, title: "Couldn't read this",
                         line: "Your Mac didn't answer this time.", id: "profile.memory.hero")
            retry
        case .ready:
            if memory.isEmpty { emptyState } else { filled }
        }
    }

    // MARK: Nothing yet

    private var emptyState: some View {
        VStack(spacing: 28) {
            VStack(spacing: 14) {
                BotAvatar(profile: state.name, size: 120, state: .listening)
                Text("Nothing yet")
                    .font(.title2.weight(.bold)).foregroundStyle(Ink.text)
                    .accessibilityAddTraits(.isHeader)
                    .testID("profile.memory.hero")
                Text("\(state.label) keeps what it learns as you chat.")
                    .font(.body).foregroundStyle(Ink.text2)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .spread(.center)
            .accessibilityElement(children: .contain)
            addButton(prominent: true)
            onSwitch
            notes
        }
    }

    // MARK: Remembered things

    @ViewBuilder private var filled: some View {
        CardHeadline(symbol: "brain.head.profile", tint: memory.isOn ? state.tint : Ink.text2,
                     title: LocalizedStringResource("What \(state.label) knows about you"), line: .verbatim(headlineLine), id: "profile.memory.hero")
        onSwitch
        addButton(prominent: false)
        ForEach(HelperMemoryKind.allCases) { kind in
            let rows = memory.rows(kind)
            if !rows.isEmpty || memory.forgetting?.kind == kind { section(kind) }
        }
        notes
        // Where the demo copy's `-nollie-demo-bot-scroll memoryEnd` scrolls to, for a picture of the rows.
        Color.clear.frame(height: 1).id("memoryEnd").accessibilityHidden(true)
    }

    private var headlineLine: String {
        guard memory.isOn else { return String(localized: "Off. It won't use these.", comment: "Memory is switched off") }
        return String(localized: "\(memory.shownCount) things", comment: "How many things a bot remembers")
    }

    private var onSwitch: some View {
        GlassSwitch("Remember things", isOn: Binding(get: { memory.isOn }, set: { on in
            Task { await memory.setOn(on) }
        }), id: "profile.memory.on")
        .disabled(memory.switching)
    }

    @ViewBuilder private func addButton(prominent: Bool) -> some View {
        if prominent { prominentAdd } else {
            GlassButton("Tell \(state.label) something to remember", symbol: "plus", id: "profile.memory.add") { draft = .new() }
        }
    }

    private var prominentAdd: some View {
        Button { draft = .new() } label: {
            Label("Tell \(state.label) something to remember", systemImage: "plus")
                .font(.headline)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .inset(v: 6)
        }
        .buttonStyle(.nollieGlassProminent)
        .buttonBorderShape(.capsule)
        .testID("profile.memory.add")
    }

    private func section(_ kind: HelperMemoryKind) -> some View {
        VStack(spacing: 4) {
            PageHeading(kind == .user ? "About you" : "Its own notes")
            VStack(spacing: 0) {
                ForEach(memory.rowsWithForgetting(kind)) { row in
                    if row.forgetting {
                        ForgottenRow(undo: { withAnimation(motion) { memory.undo() } })
                            .transition(.opacity)
                    } else {
                        MemoryRow(entry: row.entry,
                                  open: { draft = .editing(row.entry, in: kind) },
                                  forget: { withAnimation(motion) { memory.forget(row.entry, in: kind) } })
                        .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                    if row.id != memory.rowsWithForgetting(kind).last?.id { MemoryRule() }
                }
            }
        }
        .testID("profile.memory.\(kind.rawValue)")
    }

    @ViewBuilder private var notes: some View {
        if !(memory.memory?.provider.isEmpty ?? true) {
            PageNote("It also remembers through another service, not shown here.", symbol: "info.circle",
                     id: "profile.memory.provider")
        }
        if onThisMac {
            PageNote("Private. Shown only on this Mac.", symbol: "lock.fill", tint: .purple, id: "profile.memory.private")
        }
        if let problem = memory.problem {
            PageNote(.verbatim(problem), symbol: "exclamationmark.triangle.fill", tint: .orange, id: "profile.memory.problem")
        }
    }

    private var retry: some View {
        GlassButton("Try again", symbol: "arrow.clockwise", id: "profile.memory.retry") {
            guard let runtime else { return }
            Task { await memory.load(HelperMemoryModel.door(runtime: runtime, bot: state.name, onThisMac: onThisMac)) }
        }
    }
}

/// One remembered thing: its words, plain on the page. A tap opens it; holding it offers Forget.
private struct MemoryRow: View {
    var entry: HelperMemoryEntry
    var open: () -> Void
    var forget: () -> Void

    var body: some View {
        Button(action: open) {
            Text(entry.text)
                .font(.body)
                .foregroundStyle(Ink.text)
                .multilineTextAlignment(.leading)
                .lineLimit(8)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
                .padding(.vertical, 14)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Edit", systemImage: "pencil", action: open)
            Button("Forget", systemImage: "trash", role: .destructive, action: forget)
        }
        .accessibilityHint("Opens it to change or forget")
        .accessibilityAction(named: "Forget", forget)
        .testID("profile.memory.row")
    }
}

/// Where a forgotten thing was, for a few seconds: Undo puts it back.
private struct ForgottenRow: View {
    var undo: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "trash").foregroundStyle(Ink.text3).accessibilityHidden(true)
            Text("Forgotten").font(.body).foregroundStyle(Ink.text2)
            Spacer(minLength: 8)
            Button("Undo", action: undo)
                .font(.headline)
                .buttonStyle(.nollieGlass)
                .buttonBorderShape(.capsule)
                .testID("profile.memory.undo")
        }
        .frame(minHeight: 28)
        .padding(.vertical, 10)
        .accessibilityElement(children: .combine)
    }
}

/// The fine line between two rows.
private struct MemoryRule: View {
    var body: some View {
        Rectangle().fill(Ink.line).frame(height: 1 / 2).accessibilityHidden(true)
    }
}

extension HelperMemoryModel {
    struct Row: Identifiable {
        var entry: HelperMemoryEntry
        var forgetting: Bool
        var id: String { entry.id + (forgetting ? "/gone" : "") }
    }

    /// The rows in place, with the one waiting for Undo where it was.
    func rowsWithForgetting(_ kind: HelperMemoryKind) -> [Row] {
        let shown = Set(rows(kind).map(\.text))
        return (memory?.list(kind).newestFirst ?? []).compactMap { entry in
            if forgetting?.kind == kind, forgetting?.entry.text == entry.text { return Row(entry: entry, forgetting: true) }
            return shown.contains(entry.text) ? Row(entry: entry, forgetting: false) : nil
        }
    }
}
