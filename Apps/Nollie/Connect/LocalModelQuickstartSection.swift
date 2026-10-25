import SwiftUI
import NollieCore

/// Where the download on this Mac stands, as the Models page's hero says it.
enum LocalModelStage: Equatable {
    case getting(String?), finishing, paused(String?), didntFinish, unsure, readyToTry, ready

    @MainActor init?(_ setup: LocalModelQuickstart) {
        let words = LocalModelDownload.progressWords(setup.job)
        switch setup.state {
        case .idle: return nil
        case .starting, .installing: self = .getting(words)
        case .checkingSelection: self = .finishing
        case .paused: self = .paused(words)
        case .interrupted, .failed: self = .didntFinish
        case .uncertain: self = .unsure
        case .selected, .checkingReply: self = .readyToTry
        case .ready: self = .ready
        }
    }

    var symbol: String {
        switch self {
        case .getting, .finishing: "arrow.down.circle.fill"
        case .paused: "pause.circle.fill"
        case .didntFinish: "exclamationmark.circle.fill"
        case .unsure: "questionmark.circle.fill"
        case .readyToTry, .ready: "desktopcomputer"
        }
    }
    var title: String {
        switch self {
        case .getting, .finishing: "Getting your model"
        case .paused: "Download paused"
        case .didntFinish: "Didn't finish"
        case .unsure: "Check your download"
        case .readyToTry, .ready: ModelPlace.here
        }
    }
    var line: String? {
        switch self {
        case .getting(let words), .paused(let words): words
        case .finishing: "Almost ready."
        case .didntFinish: "Downloaded parts are kept."
        case .unsure: "It may still be going."
        case .readyToTry: "Ready to try."
        case .ready: "Ready."
        }
    }
    var tint: Color {
        switch self {
        case .getting, .finishing: .blue
        case .paused, .didntFinish, .unsure: .orange
        case .readyToTry, .ready: .green
        }
    }
}

/// The download on this Mac, shared by the Models page, its hero and its Advanced page so all
/// three tell the same story. The page's section makes the setup; this only holds it.
@MainActor @Observable
final class LocalModelDownload {
    private(set) var setup: LocalModelQuickstart?
    private(set) var scopeKey: String?
    /// The model Download and use gets: the recommended one, unless someone picks another.
    var selectedID = ""

    init() {}

    #if DEBUG
    init(picture: LocalModelQuickstart, snapshot: LocalModelSetupSnapshot) {
        setup = picture
        selectedID = Self.chosen(in: snapshot, id: "")?.id ?? ""
    }
    #endif

    /// Holds the section's setup for one install scope; a new scope starts from the recommended model.
    func attach(_ setup: LocalModelQuickstart, scope: LocalModelInstallScope, snapshot: LocalModelSetupSnapshot) {
        if scopeKey != scope.storageKey { selectedID = "" }
        self.setup = setup
        scopeKey = scope.storageKey
        if !Self.choices(in: snapshot).contains(where: { $0.id == selectedID }) {
            selectedID = Self.chosen(in: snapshot, id: "")?.id ?? ""
        }
    }

    /// The setup, only while it belongs to this scope.
    func setup(for scope: LocalModelInstallScope?) -> LocalModelQuickstart? {
        guard let scope, scope.storageKey == scopeKey else { return nil }
        return setup
    }

    /// What the hero says for this scope, or nil when there is no download to talk about.
    func stage(for scope: LocalModelInstallScope?) -> LocalModelStage? {
        setup(for: scope).flatMap(LocalModelStage.init)
    }

    func chosen(in snapshot: LocalModelSetupSnapshot) -> LocalModelCatalogEntry? {
        Self.chosen(in: snapshot, id: selectedID)
    }

    static func choices(in snapshot: LocalModelSetupSnapshot) -> [LocalModelCatalogEntry] {
        snapshot.models.filter(\.isInstallableCandidate)
    }

    static func chosen(in snapshot: LocalModelSetupSnapshot, id: String) -> LocalModelCatalogEntry? {
        let choices = choices(in: snapshot)
        return choices.first { $0.id == id } ?? snapshot.recommended ?? choices.first
    }

    /// The model the setup selected, as the catalog names it.
    static func entry(for selected: String?, in snapshot: LocalModelSetupSnapshot) -> LocalModelCatalogEntry? {
        guard let selected else { return nil }
        return snapshot.models.first { $0.modelId == selected || $0.downloadedModelId == selected || $0.id == selected }
    }

    /// "1.4 of 3.5 GB", in the total's own unit, or nil before the size is known.
    nonisolated static func progressWords(_ job: LocalModelJob?) -> String? {
        guard let job, let total = job.totalBytes, total > 0 else { return nil }
        let unit: ByteCountFormatter.Units = total >= 1_000_000_000 ? .useGB : total >= 1_000_000 ? .useMB : .useKB
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = unit
        formatter.allowsNonnumericFormatting = false
        let whole = formatter.string(fromByteCount: Int64(clamping: total))
        formatter.includesUnit = false
        let done = formatter.string(fromByteCount: Int64(clamping: min(job.doneBytes, total)))
        return "\(done) of \(whole)"
    }
}

/// The model on this Mac on the Models page: the recommended one as a clear choice, one Download
/// and use, and the download's progress on glass. Other models, details and the first reply wait
/// on the Advanced page.
struct LocalModelQuickstartSection: View {
    let runtime: GatewayRuntime
    let snapshot: LocalModelSetupSnapshot
    let download: LocalModelDownload
    var onModelChanged: () -> Void = {}
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var setup: LocalModelQuickstart?
    @State private var proposed: LocalModelCatalogEntry?
    @State private var confirming = false
    private var fixtureMode = false

    init(runtime: GatewayRuntime, snapshot: LocalModelSetupSnapshot, download: LocalModelDownload,
         onModelChanged: @escaping () -> Void = {}) {
        self.runtime = runtime; self.snapshot = snapshot; self.download = download; self.onModelChanged = onModelChanged
    }

    #if DEBUG
    init(runtime: GatewayRuntime, snapshot: LocalModelSetupSnapshot, picture: LocalModelQuickstart) {
        self.runtime = runtime; self.snapshot = snapshot
        download = LocalModelDownload(picture: picture, snapshot: snapshot)
        _setup = State(initialValue: picture)
        fixtureMode = true
    }
    #endif

    static func scope(for runtime: GatewayRuntime?) -> LocalModelInstallScope? {
        #if os(macOS) && NOLLIE_DIRECT
        guard let runtime else { return nil }
        #if DEBUG
        let demo = DemoMode.isOn
        #else
        let demo = false
        #endif
        return LocalModelInstallScope.managed(runtime.connection, profile: runtime.selectedProfile ?? "default", isDemo: demo)
        #else
        return nil
        #endif
    }

    var body: some View {
        VStack(spacing: 16) {
            if model.lock.isLocked {
                PageNote("Unlock Nollie to continue.", symbol: "lock.fill")
            } else if let setup {
                if setup.canBegin, let chosen = download.chosen(in: snapshot) { offer(chosen) }
                if [.starting, .installing, .paused, .checkingSelection].contains(setup.state) { progress(setup) }
                controls(setup)
                if [.selected, .checkingReply, .ready].contains(setup.state) { done(setup) }
                if let message = setup.message { PageNote(message, id: "models.local.message") }
                if [.starting, .installing, .paused].contains(setup.state) {
                    PageNote("Closing this page won't stop the download.")
                }
            }
        }
        .frame(maxWidth: .infinity)
        .allowsHitTesting(!fixtureMode)
        .task { if !fixtureMode { prepare() } }
        .onDisappear { setup?.stopObserving() }
        .onChange(of: model.lock.isLocked) { _, locked in
            guard !fixtureMode else { return }
            if locked { setup?.stopObserving() } else { setup?.restore() }
        }
        .onChange(of: scenePhase) { _, phase in
            guard !fixtureMode else { return }
            if phase == .background { setup?.stopObserving() }
            else if phase == .active { setup?.restore() }
        }
        .onChange(of: setup?.selectedModel) { _, value in if value != nil { onModelChanged() } }
        .confirmationDialog("Set up this local model?", isPresented: $confirming, titleVisibility: .visible, presenting: proposed) { entry in
            Button("Download and use \(entry.displayName)") { setup?.install(entry) }
            Button("Cancel", role: .cancel) {}
        } message: { entry in
            Text("About \(entry.downloadLabel), once. Runs on this Mac, no account needed.")
        }
    }

    /// The model to get, chosen already, and the one way to get it.
    private func offer(_ entry: LocalModelCatalogEntry) -> some View {
        VStack(spacing: 14) {
            LocalModelCapsule(symbol: "cpu", tint: .accentColor, title: entry.displayName,
                              line: entry.id == snapshot.recommended?.id ? "Recommended for this Mac" : "Fits this Mac",
                              value: entry.downloadLabel, chosen: true)
                .testID("models.local.recommendation")
            Button { proposed = entry; confirming = true } label: {
                Label("Download and use", systemImage: "arrow.down.circle.fill")
                    .fullWidthLabel()
            }
            .buttonStyle(.nollieGlassProminent)
            .buttonBorderShape(.capsule)
            .controlSize(.large)
            .testID("models.local.install")
        }
    }

    /// The download on one glass capsule: a symbol, the bar, and how far it has come.
    private func progress(_ setup: LocalModelQuickstart) -> some View {
        let paused = setup.state == .paused
        let tint: Color = paused ? .orange : .blue
        let words = LocalModelDownload.progressWords(setup.job)
            ?? (setup.state == .checkingSelection ? "Almost ready" : "Getting ready")
        let large = typeSize.isAccessibilitySize
        let layout = large ? AnyLayout(VStackLayout(alignment: .leading, spacing: 10)) : AnyLayout(HStackLayout(spacing: 14))
        return layout {
            Image(systemName: paused ? "pause.circle.fill" : "arrow.down.circle.fill")
                .font(.title3.weight(.semibold))
                .foregroundStyle(tint)
                .accessibilityHidden(true)
            Group {
                if let value = setup.job?.fractionCompleted, setup.state != .starting {
                    ProgressView(value: value).tint(tint)
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityLabel("Download progress")
            Text(words)
                .font(.body.weight(.medium))
                .monospacedDigit()
                .foregroundStyle(Ink.text)
                .fixedSize(horizontal: !large, vertical: true)
        }
        .inset(h: 22, v: 14)
        .frame(maxWidth: .infinity, minHeight: 54, alignment: .leading)
        .nollieGlass(.regular, in: shape, solid: Ink.card)
        .accessibilityElement(children: .combine)
        .testID("models.local.status")
    }

    /// Pause, resume or check, each on its own capsule, only when it can help.
    @ViewBuilder private func controls(_ setup: LocalModelQuickstart) -> some View {
        if setup.job?.canPause == true && setup.state == .installing {
            GlassButton("Pause download", symbol: "pause.fill", id: "models.local.pause") { setup.pause() }
        }
        if setup.state == .paused, setup.job?.canResume == true {
            GlassButton("Resume download", symbol: "play.fill", id: "models.local.resume") { setup.resume() }
                .disabled(setup.busy).opacity(setup.busy ? 0.5 : 1)
        }
        if setup.state == .uncertain || setup.state == .interrupted {
            GlassButton("Check progress", symbol: "arrow.clockwise", id: "models.local.check") { setup.checkProgress() }
                .disabled(setup.busy).opacity(setup.busy ? 0.5 : 1)
        }
    }

    /// The model it downloaded and chose, and where to check that it answers.
    @ViewBuilder private func done(_ setup: LocalModelQuickstart) -> some View {
        let entry = LocalModelDownload.entry(for: setup.selectedModel, in: snapshot)
        let line: String = switch setup.state {
        case .ready: "Answered a first reply."
        case .checkingReply: "Waiting for its first reply."
        default: "Chosen for new chats."
        }
        LocalModelCapsule(symbol: setup.state == .ready ? "checkmark.circle.fill" : "cpu", tint: .green,
                          title: entry?.displayName ?? "Your model", line: line)
            .testID("models.local.status")
        if setup.state == .selected {
            PageNote("To check it answers, try a first reply under Advanced.")
        }
    }

    private var shape: AnyShape {
        typeSize.isAccessibilitySize ? AnyShape(.rect(cornerRadius: 26, style: .continuous)) : AnyShape(Capsule())
    }

    private func prepare() {
        guard let scope = Self.scope(for: runtime) else { return }
        if setup == nil {
            let current: @MainActor () -> Bool = {
                model.runtime === runtime && (runtime.selectedProfile ?? "default") == "default" &&
                runtime.socketState.isOpen && !model.lock.isLocked && Self.scope(for: runtime) == scope
            }
            setup = LocalModelQuickstart(api: LocalModelAPI(api: runtime.api, profile: "default"), scope: scope,
                persistence: .preferences(.standard, scope: scope),
                inspect: { try await LocalModelSetupClient(api: runtime.api).inspect() },
                isCurrent: current,
                checkReply: { name in try await LocalModelReplyCheck.run(api: LocalModelAPI(api: runtime.api, profile: "default"), model: name, isCurrent: current) })
        }
        if let setup { download.attach(setup, scope: scope, snapshot: snapshot) }
        setup?.restore()
    }
}

/// One model on a glass capsule: a symbol, its name, a line, and its size on the right.
private struct LocalModelCapsule: View {
    var symbol: String
    var tint: Color
    var title: String
    var line: String? = nil
    var value: String? = nil
    var chosen = false
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        let large = typeSize.isAccessibilitySize
        HStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.title3.weight(.semibold))
                .foregroundStyle(tint)
                .frame(width: 30)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline).foregroundStyle(Ink.text)
                    .fixedSize(horizontal: false, vertical: true)
                if let line {
                    Text(line).font(.body).foregroundStyle(Ink.text2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                // At the largest text sizes the size sits under the name instead of beside it.
                if large, let value { Text(value).font(.body.weight(.medium)).foregroundStyle(Ink.text2) }
            }
            Spacer(minLength: 8)
            if !large, let value {
                Text(value).font(.body.weight(.medium)).foregroundStyle(Ink.text2).fixedSize()
            }
        }
        .inset(h: 22, v: 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .nollieGlass(chosen ? Glass.regular.tint(Color.accentColor.opacity(0.18)) : Glass.regular,
                     in: large ? AnyShape(.rect(cornerRadius: 26, style: .continuous)) : AnyShape(Capsule()),
                     solid: Ink.card)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(chosen ? .isSelected : [])
    }
}
