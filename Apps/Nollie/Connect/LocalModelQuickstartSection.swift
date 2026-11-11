import SwiftUI
import NollieCore

/// Where the download on this Mac stands, as the Models page's hero says it.
enum LocalModelStage: Equatable {
    case getting(String?), finishing, paused(String?), didntFinish(String), unsure, readyToTry, sayingHello, ready

    @MainActor init?(_ setup: LocalModelQuickstart, name: String? = nil) {
        switch setup.state {
        case .idle: return nil
        case .starting, .installing: self = .getting(name)
        case .checkingSelection: self = .finishing
        case .paused: self = .paused(name)
        case .failed: self = .didntFinish(setup.failure?.line ?? LocalModelFailure.other.line)
        case .interrupted: self = .didntFinish(LocalModelFailure.other.line)
        case .uncertain: self = .unsure
        case .selected: self = .readyToTry
        case .checkingReply: self = .sayingHello
        case .ready: self = .ready
        }
    }

    var symbol: String {
        switch self {
        case .getting, .finishing: "arrow.down.circle.fill"
        case .paused: "pause.circle.fill"
        case .didntFinish: "exclamationmark.circle.fill"
        case .unsure: "questionmark.circle.fill"
        case .readyToTry, .sayingHello: "desktopcomputer"
        case .ready: "checkmark.circle.fill"
        }
    }
    var title: String {
        switch self {
        case .getting, .finishing: String(localized: "Getting your model")
        case .paused: String(localized: "Download paused")
        case .didntFinish: String(localized: "Didn't finish")
        case .unsure: String(localized: "Check your download")
        case .readyToTry, .sayingHello: ModelPlace.here
        case .ready: String(localized: "Ready", comment: "The downloaded model answered and is ready")
        }
    }
    var line: String? {
        switch self {
        case .getting(let words), .paused(let words): words
        case .finishing: String(localized: "Almost ready.")
        case .didntFinish(let why): why
        case .unsure: String(localized: "It may still be going.")
        case .readyToTry: String(localized: "Ready to try.")
        case .sayingHello: String(localized: "Saying hello…")
        case .ready: ModelPlace.sentence(mac: String(localized: "Your model answers on this Mac."),
                                         phone: String(localized: "Your model answers on your Mac."))
        }
    }
    var tint: Color {
        switch self {
        case .getting, .finishing: .blue
        case .paused, .didntFinish, .unsure: .orange
        case .readyToTry, .sayingHello, .ready: .green
        }
    }
}

/// The download on this Mac, shared by the Models page, its hero and its Advanced page so all
/// three tell the same story. The page's section makes the setup; this only holds it.
@MainActor @Observable
final class LocalModelDownload {
    private(set) var setup: LocalModelQuickstart?
    private(set) var scopeKey: String?
    /// The model Download and use gets: Quick start, unless someone picks another.
    var selectedID = ""

    init() {}

    #if DEBUG
    init(picture: LocalModelQuickstart, snapshot: LocalModelSetupSnapshot) {
        setup = picture
        selectedID = LocalModelChoices(snapshot).quickStart?.id ?? ""
    }
    #endif

    /// Holds the section's setup for one install scope; a new scope starts from Quick start.
    func attach(_ setup: LocalModelQuickstart, scope: LocalModelInstallScope, snapshot: LocalModelSetupSnapshot) {
        if scopeKey != scope.storageKey { selectedID = "" }
        self.setup = setup
        scopeKey = scope.storageKey
        selectedID = LocalModelChoices(snapshot).chosen(selectedID)?.id ?? ""
    }

    /// The setup, only while it belongs to this scope.
    func setup(for scope: LocalModelInstallScope?) -> LocalModelQuickstart? {
        guard let scope, scope.storageKey == scopeKey else { return nil }
        return setup
    }

    /// What the hero says for this scope, or nil when there is no download to talk about.
    func stage(for scope: LocalModelInstallScope?, snapshot: LocalModelSetupSnapshot?) -> LocalModelStage? {
        guard let setup = setup(for: scope) else { return nil }
        let name = snapshot.flatMap { local in local.models.first { $0.id == setup.receipt?.catalogID } }?.displayName
        return LocalModelStage(setup, name: name)
    }

    func chosen(in snapshot: LocalModelSetupSnapshot) -> LocalModelCatalogEntry? {
        LocalModelChoices(snapshot).chosen(selectedID)
    }

    /// The model the setup selected, as the catalog names it.
    static func entry(for selected: String?, in snapshot: LocalModelSetupSnapshot) -> LocalModelCatalogEntry? {
        guard let selected else { return nil }
        return snapshot.models.first { $0.modelId == selected || $0.downloadedModelId == selected || $0.id == selected }
    }

    /// "6.6 of 18.5 GB", in the total's own unit, or nil before the size is known.
    nonisolated static func progressWords(_ job: LocalModelJob?) -> String? {
        guard let job, let total = job.totalBytes, total > 0 else { return nil }
        let gigabytes = total >= 1_000_000_000
        let unit: UnitInformationStorage = gigabytes ? .gigabytes : .megabytes
        let scale = gigabytes ? 1e9 : 1e6
        let digits = gigabytes && Double(total) / scale < 100 ? 1 : 0
        let style = FloatingPointFormatStyle<Double>.number.precision(.fractionLength(digits))
        let whole = Measurement(value: Double(total) / scale, unit: unit)
            .formatted(.measurement(width: .abbreviated, usage: .asProvided, numberFormatStyle: style))
        let done = (Double(min(job.doneBytes, total)) / scale).formatted(style)
        return String(localized: "\(done) of \(whole)", comment: "Download progress, such as 6.6 of 18.5 GB")
    }

    /// What the job is doing, in a few words: the bytes while the model downloads, else its step.
    nonisolated static func stepWords(_ job: LocalModelJob?) -> String {
        switch job?.phase {
        case "installing-runtime", "downloading-runtime", "unpacking-runtime", "verifying-runtime":
            String(localized: "Getting the engine")
        case "downloading": progressWords(job) ?? String(localized: "Getting ready")
        case "starting-server", "restarting": String(localized: "Starting your model")
        case "setting-default", "done": String(localized: "Almost ready")
        default: String(localized: "Getting ready")
        }
    }
}

/// The model on this Mac: two clear choices (Quick start, and the best for this Mac when it
/// differs), the rest under More models, one Download and use, then the download on glass with
/// its time left, and a first hello the moment the model is ready.
struct LocalModelQuickstartSection: View {
    let runtime: GatewayRuntime
    let snapshot: LocalModelSetupSnapshot
    let download: LocalModelDownload
    var onModelChanged: () -> Void = {}
    /// Shown as Continue once the model has answered, when the section sits in setup's sheet.
    var onFinished: (() -> Void)? = nil
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var setup: LocalModelQuickstart?
    private var fixtureMode = false

    init(runtime: GatewayRuntime, snapshot: LocalModelSetupSnapshot, download: LocalModelDownload,
         onModelChanged: @escaping () -> Void = {}, onFinished: (() -> Void)? = nil) {
        self.runtime = runtime; self.snapshot = snapshot; self.download = download
        self.onModelChanged = onModelChanged; self.onFinished = onFinished
    }

    #if DEBUG
    init(runtime: GatewayRuntime, snapshot: LocalModelSetupSnapshot, picture: LocalModelQuickstart, onFinished: (() -> Void)? = nil) {
        self.runtime = runtime; self.snapshot = snapshot
        download = LocalModelDownload(picture: picture, snapshot: snapshot)
        self.onFinished = onFinished
        _setup = State(initialValue: picture)
        fixtureMode = true
    }
    #endif

    static func scope(for runtime: GatewayRuntime?) -> LocalModelInstallScope? {
        #if os(macOS) && NOLLIE_DIRECT
        guard let runtime else { return nil }
        #if DEBUG
        if LocalModelDemo.isOn {
            let profile = runtime.selectedProfile ?? "default"
            // The demo makes its connection afresh at each launch; a fixed one lets a download outlive a relaunch.
            return profile == "default" ? LocalModelInstallScope(installationID: LocalModelDemo.installationID,
                                                                  connectionID: LocalModelDemo.installationID, profile: profile) : nil
        }
        let demo = DemoMode.isOn
        #else
        let demo = false
        #endif
        return LocalModelInstallScope.managed(runtime.connection, profile: runtime.selectedProfile ?? "default", isDemo: demo)
        #else
        return nil
        #endif
    }

    private var state: LocalModelQuickstart.State { setup?.state ?? .idle }

    var body: some View {
        VStack(spacing: 16) {
            if model.lock.isLocked {
                PageNote("Unlock Nollie to continue.", symbol: "lock.fill")
            } else {
                switch state {
                case .idle, .failed, .interrupted: offer(LocalModelChoices(snapshot))
                case .starting, .installing, .paused, .checkingSelection: if let setup { progress(setup) }
                case .selected, .checkingReply, .ready: if let setup { done(setup) }
                case .uncertain: if let setup { uncertain(setup) }
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
        // The moment the model is chosen, it says hello once. A failed hello waits for Say hello.
        .task(id: setup?.state) {
            guard !fixtureMode, let setup, setup.state == .selected, setup.reply == nil, setup.message == nil else { return }
            setup.testReply()
        }
    }

    // MARK: Choosing

    private func offer(_ choices: LocalModelChoices) -> some View {
        let chosen = download.chosen(in: snapshot)
        let retrying = [.failed, .interrupted].contains(state) && chosen != nil && chosen?.id == setup?.receipt?.catalogID
        return VStack(spacing: 12) {
            if let quick = choices.quickStart ?? choices.smallestShort {
                choice(quick, kicker: String(localized: "Quick start"), symbol: "bolt.fill", choices: choices, chosen: chosen)
                    .testID("models.local.quickStart")
            }
            if let best = choices.best {
                choice(best, kicker: String(localized: "Best for this Mac"), symbol: "sparkles", choices: choices, chosen: chosen)
                    .testID("models.local.best")
            }
            if !choices.more.isEmpty {
                GlassLink("More models", symbol: "square.stack.3d.up", value: "\(choices.more.count)", id: "models.local.more") {
                    LocalModelMoreModels(snapshot: snapshot, download: download).untitledPage()
                }
            }
            if choices.quickStart == nil { PageNote(.verbatim(noneFits(choices)), id: "models.local.none") }
            // A download that stopped says why once, at the top; any other note goes here.
            if ![.failed, .interrupted].contains(state), let message = setup?.message {
                PageNote(.verbatim(message), id: "models.local.message")
            }
            // With nothing that can start, the line above is the last word, not a dead button.
            if let chosen { Button {
                setup?.install(chosen)
            } label: {
                PageActionLabel(retrying ? "Try again" : "Download and use",
                                symbol: retrying ? "arrow.clockwise" : "arrow.down.circle.fill")
            }
            .buttonStyle(LocalModelActionStyle())
            .disabled(setup?.canBegin != true)
            .padding(.top, 8)
            .testID("models.local.install") }
        }
    }

    private func choice(_ entry: LocalModelCatalogEntry, kicker: String?, symbol: String,
                        choices: LocalModelChoices, chosen: LocalModelCatalogEntry?) -> some View {
        VStack(spacing: 8) {
            Button { download.selectedID = entry.id } label: {
                LocalModelChoiceLabel(kicker: kicker, title: entry.displayName, detail: choices.detail(entry), symbol: symbol,
                                      selected: chosen?.id == entry.id, enabled: choices.canStart(entry))
            }
            .buttonStyle(.plain)
            .disabled(!choices.canStart(entry))
            if let short = LocalModelDisk.shortfall(entry, free: choices.freeDisk) {
                PageNote(.verbatim(short), symbol: "externaldrive.fill.badge.exclamationmark", tint: .orange)
            }
        }
    }

    private func noneFits(_ choices: LocalModelChoices) -> String {
        if !choices.all.isEmpty {
            return ModelPlace.sentence(mac: String(localized: "No model fits the free space on this Mac. A plan needs none."),
                                       phone: String(localized: "No model fits the free space on your Mac. A plan needs none."))
        }
        return ModelPlace.sentence(mac: String(localized: "No model here fits this Mac's memory. A plan works well."),
                                   phone: String(localized: "No model here fits your Mac's memory. A plan works well."))
    }

    // MARK: Downloading

    /// The download on one glass capsule, the time left from its real speed, and one control.
    private func progress(_ setup: LocalModelQuickstart) -> some View {
        let paused = setup.state == .paused
        let tint: Color = paused ? .orange : .blue
        let large = typeSize.isAccessibilitySize
        let layout = large ? AnyLayout(VStackLayout(alignment: .leading, spacing: 10)) : AnyLayout(HStackLayout(spacing: 14))
        return VStack(spacing: 14) {
            layout {
                Image(systemName: paused ? "pause.circle.fill" : "arrow.down.circle.fill")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(tint)
                    .accessibilityHidden(true)
                Group {
                    if let value = setup.job?.fractionCompleted, setup.state != .starting, setup.job?.phase == "downloading" {
                        ProgressView(value: value).tint(tint)
                    } else {
                        ProgressView().controlSize(.small)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityLabel("Download progress")
                Text(LocalModelDownload.stepWords(setup.job))
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
            if let left = LocalModelTime.left(setup.job) {
                Text(left).font(.body).foregroundStyle(Ink.text2).monospacedDigit()
                    .testID("models.local.timeLeft")
            }
            if setup.state == .paused, setup.job?.canResume == true {
                Button { setup.resume() } label: { PageActionLabel("Resume download", symbol: "play.fill") }
                    .buttonStyle(LocalModelActionStyle())
                    .disabled(setup.busy)
                    .padding(.top, 8)
                    .testID("models.local.resume")
            } else if setup.job?.canPause == true, setup.state == .installing {
                GlassButton("Pause download", symbol: "pause.fill", id: "models.local.pause") { setup.pause() }
            }
            PageNote("Closing this won't stop the download.")
        }
    }

    private func uncertain(_ setup: LocalModelQuickstart) -> some View {
        VStack(spacing: 12) {
            if let message = setup.message { PageNote(.verbatim(message), id: "models.local.message") }
            GlassButton("Check progress", symbol: "arrow.clockwise", id: "models.local.check") { setup.checkProgress() }
                .disabled(setup.busy).opacity(setup.busy ? 0.5 : 1)
        }
    }

    // MARK: Ready

    /// The model it chose, its first hello, and Continue once it has answered.
    @ViewBuilder private func done(_ setup: LocalModelQuickstart) -> some View {
        let entry = LocalModelDownload.entry(for: setup.selectedModel, in: snapshot)
        let line: String = switch setup.state {
        case .ready: String(localized: "Answered hello.")
        case .checkingReply: String(localized: "Saying hello…")
        default: String(localized: "Chosen for new chats.")
        }
        LocalModelChoiceLabel(kicker: nil, title: entry?.displayName ?? String(localized: "Your model"), detail: line,
                              symbol: setup.state == .ready ? "checkmark.circle.fill" : "desktopcomputer",
                              tint: .green, selected: false, enabled: true, showsMark: false, busy: setup.state == .checkingReply)
            .testID("models.local.status")
        if let reply = setup.reply {
            Text(reply)
                .font(.title3)
                .foregroundStyle(Ink.text)
                .textSelection(.enabled)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .inset(h: 24, v: 16)
                .frame(maxWidth: .infinity)
                .nollieGlass(Glass.regular.tint(Color.green.opacity(0.14)), in: .rect(cornerRadius: 26, style: .continuous), solid: Ink.card)
                .testID("models.local.reply")
        }
        if setup.state == .selected, setup.message != nil {
            PageNote("It didn't answer yet. The first reply can take a minute.", id: "models.local.message")
            GlassButton("Say hello", symbol: "text.bubble", id: "models.local.test") { setup.testReply() }
                .disabled(setup.busy).opacity(setup.busy ? 0.5 : 1)
        }
        if setup.state == .ready, let onFinished {
            Button(action: onFinished) { PageActionLabel("Continue", symbol: "arrow.right") }
                .buttonStyle(LocalModelActionStyle())
                .padding(.top, 8)
                .testID("models.local.continue")
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

/// Every model that fits this Mac, to pick one for Download and use.
struct LocalModelMoreModels: View {
    let snapshot: LocalModelSetupSnapshot
    let download: LocalModelDownload
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let choices = LocalModelChoices(snapshot)
        let chosen = download.chosen(in: snapshot)
        SettingsPage("models.local.more.page") {
            PageHero(symbol: "square.stack.3d.up", title: "More models", tint: .blue, id: "models.local.more.hero")
            VStack(spacing: 12) {
                ForEach(choices.all) { entry in
                    let kicker: String? = entry.id == (choices.quickStart ?? choices.smallestShort)?.id ? String(localized: "Quick start")
                        : entry.id == choices.best?.id ? String(localized: "Best for this Mac") : nil
                    VStack(spacing: 8) {
                        Button { download.selectedID = entry.id; dismiss() } label: {
                            LocalModelChoiceLabel(kicker: kicker, title: entry.displayName, detail: choices.detail(entry),
                                                  symbol: "cpu", selected: chosen?.id == entry.id, enabled: choices.canStart(entry))
                        }
                        .buttonStyle(.plain)
                        .disabled(!choices.canStart(entry))
                        if let short = LocalModelDisk.shortfall(entry, free: choices.freeDisk) {
                            PageNote(.verbatim(short), symbol: "externaldrive.fill.badge.exclamationmark", tint: .orange)
                        }
                    }
                }
            }
        }
    }
}

/// One model on a glass capsule: a symbol, a small kicker, its name, its size and time, and a
/// check when it is the one Download and use gets.
private struct LocalModelChoiceLabel: View {
    var kicker: String?
    var title: String
    var detail: String
    var symbol: String
    var tint: Color = .accentColor
    var selected: Bool
    var enabled: Bool
    var showsMark = true
    var busy = false
    @Environment(\.dynamicTypeSize) private var typeSize

    private var shape: AnyShape {
        typeSize.isAccessibilitySize ? AnyShape(.rect(cornerRadius: 28, style: .continuous)) : AnyShape(Capsule())
    }

    var body: some View {
        HStack(spacing: 14) {
            Group {
                if busy { ProgressView().controlSize(.small) }
                else {
                    Image(systemName: symbol)
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(enabled ? tint : Ink.text3)
                }
            }
            .frame(width: 30)
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                if let kicker {
                    Text(kicker).font(.subheadline.weight(.semibold))
                        .foregroundStyle(enabled ? tint : Ink.text3)
                }
                Text(title).font(.headline).foregroundStyle(enabled ? Ink.text : Ink.text2)
                    .fixedSize(horizontal: false, vertical: true)
                Text(detail).font(.body).foregroundStyle(Ink.text2).monospacedDigit()
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if showsMark {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.title2)
                    .foregroundStyle(selected ? Color.accentColor : Ink.text3)
                    .contentTransition(.symbolEffect(.replace))
                    .accessibilityHidden(true)
            }
        }
        .inset(h: 24, v: 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(shape)
        .nollieGlass(selected ? Glass.regular.tint(Color.accentColor.opacity(0.18)) : Glass.regular, in: shape, solid: Ink.card)
        .opacity(enabled ? 1 : 0.85)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }
}

/// The one thing to press next, in full blue on a glass capsule whether or not the window is in
/// front: the system's prominent style turns grey in a window that isn't key, which reads as off.
struct LocalModelActionStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.self) private var environment

    func makeBody(configuration: Configuration) -> some View {
        let blue = Color.blue.readable(against: .white, ratio: 4.5, in: environment)
        configuration.label
            .foregroundStyle(.white.opacity(isEnabled ? 1 : 0.8))
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, minHeight: 48)
            .background(blue.opacity(isEnabled ? (configuration.isPressed ? 0.82 : 1) : 0.4), in: Capsule())
            .glassEffect(.regular.tint(blue.opacity(isEnabled ? 0.6 : 0.2)).interactive(), in: Capsule())
            .contentShape(Capsule())
            .animation(.snappy(duration: 0.15), value: configuration.isPressed)
    }
}
