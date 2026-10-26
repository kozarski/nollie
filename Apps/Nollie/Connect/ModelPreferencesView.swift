import SwiftUI
import NollieCore

enum ModelPreferenceStore {
    static let key = "nollie.models.preferredMode"
}

/// Where the assistant's model runs, in the words people use: "On this Mac", "ChatGPT plan", or
/// the provider's own name.
enum ModelPlace {
    /// Providers that run the model on the assistant's own computer.
    static let localProviders = BackupRoute.localProviders

    static func isLocal(_ provider: String?) -> Bool {
        guard let provider = provider?.lowercased() else { return false }
        return localProviders.contains(provider)
    }

    /// A plan people already pay for and sign in to.
    static func isPlan(_ provider: String) -> Bool { BackupRoute.isPlan(provider) }

    /// "On this Mac" on the Mac, "On your Mac" on the phone.
    static var here: String {
        #if os(macOS)
        "On this Mac"
        #else
        "On your Mac"
        #endif
    }

    /// The same, inside a sentence: "on this Mac".
    static var hereInSentence: String {
        #if os(macOS)
        "on this Mac"
        #else
        "on your Mac"
        #endif
    }

    /// The provider in use: the one Hermes names, else the one marked current.
    static func provider(_ options: ModelOptionsResult) -> String? {
        if let named = options.provider?.trimmingCharacters(in: .whitespacesAndNewlines), !named.isEmpty { return named }
        return options.providers.first { $0.isCurrent == true }?.slug
    }

    /// What runs now in a word or two, or nil when no model is chosen.
    static func word(_ options: ModelOptionsResult) -> String? {
        guard let chosen = options.model?.trimmingCharacters(in: .whitespacesAndNewlines), !chosen.isEmpty,
              let slug = provider(options) else { return nil }
        if isLocal(slug) { return here }
        return Papertrail.providerLabel(slug) ?? options.providers.first { $0.slug == slug }?.name ?? slug
    }

    /// Reads the assistant's current model for the bot in use.
    @MainActor static func read(_ runtime: GatewayRuntime) async -> ModelOptionsResult? {
        try? await runtime.api.get("/api/model/options", profile: runtime.selectedProfile)
    }
}

/// What Nollie last learned about the model, kept apart from the page so its Advanced page shows
/// the same answer.
@MainActor @Observable
final class ModelCheck {
    var options: ModelOptionsResult?
    var local: LocalModelSetupSnapshot?
    var loading = false
    var error: String?
    private var requestID: UUID?

    func refreshCurrentModel(_ model: AppModel, identity: @escaping @MainActor () -> String) async {
        let expected = identity()
        guard let runtime = model.runtime, runtime.socketState.isOpen, !model.lock.isLocked else { return }
        guard let result: ModelOptionsResult = try? await runtime.api.get("/api/model/options", profile: runtime.selectedProfile),
              !Task.isCancelled, identity() == expected, !model.lock.isLocked else { return }
        options = result
    }

    func refresh(_ model: AppModel, identity: @escaping @MainActor () -> String) async {
        let id = UUID()
        let expected = identity()
        requestID = id
        options = nil
        local = nil
        error = nil
        guard let runtime = model.runtime, runtime.socketState.isOpen else { loading = false; return }
        loading = true
        defer { if requestID == id { loading = false } }
        do {
            let result: ModelOptionsResult = try await runtime.api.get("/api/model/options", profile: runtime.selectedProfile)
            guard !Task.isCancelled, requestID == id, identity() == expected else { return }
            options = result
            let snapshot = try await LocalModelSetupClient(api: runtime.api).inspect()
            guard !Task.isCancelled, requestID == id, identity() == expected else { return }
            local = snapshot
        } catch {
            guard !Task.isCancelled, requestID == id, identity() == expected else { return }
            self.error = "Couldn't check the current setup. Nothing was changed."
        }
    }
}

/// Settings › Connection › Models: what runs now, then the choice of where Nollie thinks, On this
/// Mac first. A choice is only a preference: it never switches the model on Hermes by itself.
struct ModelPreferencesView: View {
    let showsPreference: Bool
    @Environment(AppModel.self) private var model
    @AppStorage(ModelPreferenceStore.key) private var savedMode = ModelSetupMode.local.rawValue
    @State private var check = ModelCheck()
    @State private var download = LocalModelDownload()

    init(showsPreference: Bool = true) {
        self.showsPreference = showsPreference
    }

    private var mode: ModelSetupMode { ModelSetupMode(rawValue: savedMode) ?? .local }
    private var runtime: GatewayRuntime? { model.runtime }
    private var identity: String { "\(runtime?.connection.id.uuidString ?? "")/\(runtime?.selectedProfile ?? "default")/\(runtime?.socketState.isOpen == true)" }
    private var currentProvider: String? { check.options.flatMap(ModelPlace.provider) }

    private var hero: ModelsHero.State {
        guard runtime?.socketState.isOpen == true else { return .notConnected }
        // A download on this Mac says where it stands while the page shows it.
        if mode != .cloud, check.local != nil,
           let stage = download.stage(for: LocalModelQuickstartSection.scope(for: runtime)) { return .download(stage) }
        guard let options = check.options else { return check.error == nil ? .checking : .couldntCheck }
        guard let word = ModelPlace.word(options), let slug = ModelPlace.provider(options) else { return .choose }
        let status = OnboardingModelStatus.read(options)
        if case .needsSignIn = status { return .needsSignIn(word) }
        if ModelPlace.isLocal(slug) {
            let selected = options.model ?? ""
            let name = check.local?.models.first { $0.modelId == selected || $0.downloadedModelId == selected || $0.id == selected }?.displayName
            return .local(name)
        }
        if case .unverified = status { return .unconfirmed(word) }
        return ModelPlace.isPlan(slug) ? .plan(word) : .online(word)
    }

    var body: some View {
        SettingsPage("models.page") {
            ModelsHero(state: hero)
            if showsPreference {
                ModelsComparison()
                choices
                notes
                if runtime?.socketState.isOpen == true { BackupModelSection(check: check) }
            }
            if mode != .cloud { localArea }
            AdvancedLink(id: "models.advanced") {
                ModelsAdvancedView(check: check, download: download, showsPreference: showsPreference,
                                   refresh: { Task { await check.refresh(model, identity: { identity }) } })
                    .untitledPage()
            }
        }
        .animation(.snappy, value: savedMode)
        .task(id: identity) { await check.refresh(model, identity: { identity }) }
    }

    /// The two choices, in order: this Mac first, recommended and chosen unless someone picks
    /// otherwise; then a plan they already pay for.
    private var choices: some View {
        VStack(spacing: 12) {
            ModelChoiceRow(title: ModelPlace.here, line: "Private and free.", symbol: "desktopcomputer",
                           recommended: true, selected: mode != .cloud, id: "models.mode.local") {
                savedMode = ModelSetupMode.local.rawValue
            }
            ModelChoiceRow(title: "Sign in with ChatGPT or Claude", line: "Uses a plan you already have.",
                           symbol: "person.crop.circle.badge.checkmark",
                           selected: mode != .local, id: "models.mode.cloud") {
                savedMode = ModelSetupMode.cloud.rawValue
            }
        }
        .accessibilityElement(children: .contain)
        .testID("models.mode")
    }

    /// Plain words for what a choice does and does not do, only when they are needed.
    @ViewBuilder private var notes: some View {
        if PrivateBots.isPrivate(runtime?.selectedProfile, connection: runtime?.connection.id) && mode != .local {
            PageNote("This choice never turns on online models for a private bot.", symbol: "lock.fill", id: "models.private")
        }
        if let options = check.options, let provider = currentProvider, let word = ModelPlace.word(options) {
            if mode == .local && !ModelPlace.isLocal(provider) {
                PageNote("Right now Nollie uses \(word). Choosing here doesn't switch it.", id: "models.current")
            } else if mode == .cloud && ModelPlace.isLocal(provider) {
                PageNote("Right now the model runs \(ModelPlace.hereInSentence). Choosing here doesn't switch it.", id: "models.current")
            }
        }
        if mode != .local && !signedInToPlan {
            PageNote("Signing in from Nollie isn't ready yet. Your assistant keeps the sign-in it has.", id: "models.signInSoon")
        }
    }

    /// The assistant already uses a ChatGPT or Claude plan it is signed in to.
    private var signedInToPlan: Bool {
        guard let options = check.options, let provider = currentProvider else { return false }
        return ModelPlace.isPlan(provider) && OnboardingModelStatus.read(options).isReady
    }

    /// The model on this Mac: the download and its progress where Nollie set Hermes up itself,
    /// else where to set one up.
    @ViewBuilder private var localArea: some View {
        if let local = check.local, let runtime, let scope = LocalModelQuickstartSection.scope(for: runtime) {
            VStack(alignment: .leading, spacing: 14) {
                LocalModelQuickstartSection(runtime: runtime, snapshot: local, download: download) {
                    Task { await check.refreshCurrentModel(model, identity: { identity }) }
                }
                .id(scope.storageKey)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .contain)
            .testID("models.local")
        } else if check.options != nil, !ModelPlace.isLocal(currentProvider) {
            #if os(macOS)
            PageNote("Downloads work with the assistant Nollie set up on this Mac.", symbol: "arrow.down.circle", id: "models.local.elsewhere")
            #else
            PageNote("Set one up in Nollie on your Mac.", symbol: "desktopcomputer", id: "models.local.elsewhere")
            #endif
        }
    }
}

/// The top of the Models page: what runs now, in its own colour.
struct ModelsHero: View {
    enum State: Equatable {
        case checking, notConnected, couldntCheck, choose
        case local(String?), plan(String), online(String), needsSignIn(String), unconfirmed(String)
        case download(LocalModelStage)

        var symbol: String {
            switch self {
            case .checking, .choose: "cpu"
            case .notConnected: "wifi.exclamationmark"
            case .couldntCheck: "exclamationmark.triangle.fill"
            case .local: "desktopcomputer"
            case .plan: "person.crop.circle.badge.checkmark"
            case .online: "cloud.fill"
            case .needsSignIn: "person.badge.key.fill"
            case .unconfirmed: "questionmark.circle.fill"
            case .download(let stage): stage.symbol
            }
        }
        var title: String {
            switch self {
            case .checking: "Checking"
            case .notConnected: "Not connected"
            case .couldntCheck: "Couldn't check"
            case .choose: "Choose how Nollie thinks"
            case .local: ModelPlace.here
            case .plan(let word), .online(let word), .unconfirmed(let word): word
            case .needsSignIn: "Sign in needed"
            case .download(let stage): stage.title
            }
        }
        var line: String? {
            switch self {
            case .checking: nil
            case .notConnected: "Connect to see your model."
            case .couldntCheck: "Nothing was changed."
            case .choose: "\(ModelPlace.here) is free and private."
            case .local(let name): name ?? "Private and free."
            case .plan: "Signed in."
            case .online: "Runs online."
            case .needsSignIn(let word): "\(word) is signed out."
            case .unconfirmed: "Couldn't confirm the sign-in."
            case .download(let stage): stage.line
            }
        }
        var tint: Color {
            switch self {
            case .checking: Ink.text2
            case .notConnected: .red
            case .couldntCheck, .needsSignIn, .unconfirmed: .orange
            case .choose: .blue
            case .local, .plan, .online: .green
            case .download(let stage): stage.tint
            }
        }
    }

    var state: State

    var body: some View {
        PageHero(symbol: state.symbol, title: state.title, line: state.line, tint: state.tint, id: "models.hero")
    }
}

/// On this Mac and signed in, side by side: a few symbols and a word each. Stacked at the
/// largest text sizes.
struct ModelsComparison: View {
    @Environment(\.dynamicTypeSize) private var typeSize

    private var here: FactTile {
        FactTile(title: ModelPlace.here, tint: .green,
                 facts: [Fact(symbol: "lock.fill", word: "Private"), Fact(symbol: "gift.fill", word: "Free"),
                         Fact(symbol: "person.crop.circle.badge.xmark", word: "No account")],
                 id: "models.compare.local")
    }
    private var signedIn: FactTile {
        FactTile(title: "Signed in", tint: Ink.text2,
                 facts: [Fact(symbol: "creditcard.fill", word: "Your plan"), Fact(symbol: "sparkles", word: "Bigger models"),
                         Fact(symbol: "wifi", word: "Online")],
                 id: "models.compare.cloud")
    }

    var body: some View {
        if typeSize.isAccessibilitySize {
            VStack(spacing: 14) { here; signedIn }
        } else {
            FactTiles(leading: here, trailing: signedIn)
        }
    }
}

/// One choice on a glass capsule: a symbol, its name and a short line, and a check when chosen.
private struct ModelChoiceRow: View {
    var title: String
    var line: String
    var symbol: String
    var recommended = false
    var selected: Bool
    var id: String
    var action: () -> Void
    @Environment(\.dynamicTypeSize) private var typeSize

    /// A capsule, until the text is large enough to wrap: then softer corners keep it inside.
    private var shape: AnyShape {
        typeSize.isAccessibilitySize ? AnyShape(.rect(cornerRadius: 28, style: .continuous)) : AnyShape(Capsule())
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: symbol)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(selected ? Color.accentColor : Ink.text2)
                    .frame(width: 30)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.headline).foregroundStyle(Ink.text)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(line).font(.body).foregroundStyle(Ink.text2)
                        .fixedSize(horizontal: false, vertical: true)
                    if recommended {
                        Text("Recommended")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.green)
                            .padding(.top, 2)
                    }
                }
                Spacer(minLength: 8)
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.title2)
                    .foregroundStyle(selected ? Color.accentColor : Ink.text3)
                    .contentTransition(.symbolEffect(.replace))
                    .accessibilityHidden(true)
            }
            .inset(h: 22, v: 16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(shape)
            .nollieGlass(selected ? Glass.regular.tint(Color.accentColor.opacity(0.18)) : Glass.regular, in: shape, solid: Ink.card)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .testID(id)
    }
}

/// Models › Advanced: the model in use and where it runs at the top, then the other ways to choose,
/// the download's own extras, and the computer it runs on.
struct ModelsAdvancedView: View {
    var check: ModelCheck
    var download: LocalModelDownload
    var showsPreference = true
    var refresh: () -> Void
    @Environment(AppModel.self) private var model
    @AppStorage(ModelPreferenceStore.key) private var savedMode = ModelSetupMode.local.rawValue

    private var mode: ModelSetupMode { ModelSetupMode(rawValue: savedMode) ?? .local }
    private var runtime: GatewayRuntime? { model.runtime }
    /// The download on this Mac, while it belongs to the assistant in use.
    private var setup: LocalModelQuickstart? { download.setup(for: LocalModelQuickstartSection.scope(for: runtime)) }

    var body: some View {
        SettingsPage("models.advanced.page") {
            hero
            if showsPreference {
                VStack(spacing: 12) {
                    GlassSwitch("Use both", isOn: Binding(
                        get: { mode == .both },
                        set: { savedMode = ($0 ? ModelSetupMode.both : .local).rawValue }), id: "models.mode.both")
                    PageNote("Keeps both on offer. Nothing switches by itself.")
                }
                VStack(alignment: .leading, spacing: 12) {
                    PageHeading("Use an API key")
                    PageNote("Add a key in Hermes \(ModelPlace.hereInSentence). Nollie uses whichever key your assistant has.",
                             symbol: "key.fill")
                }
            }
            currentModel
            downloaded
            computer
            if showsPreference {
                VStack(alignment: .leading, spacing: 12) {
                    PageHeading("What your choice means")
                    PageNote(mode.detail)
                    if mode != .local {
                        PageNote("Online models may cost money. Checking which model runs uses no online account.")
                    }
                }
            }
            VStack(spacing: 12) {
                GlassButton("Check again", symbol: "arrow.clockwise", id: "models.refresh", action: refresh)
                    .disabled(check.loading || runtime?.socketState.isOpen != true)
                    .opacity(check.loading || runtime?.socketState.isOpen != true ? 0.5 : 1)
                if let error = check.error { PageNote(error, id: "models.error") }
            }
        }
    }

    /// What is true in this layer: the model's own name and where it runs.
    private var hero: some View {
        let shown: (symbol: String, title: String, line: String?, tint: Color)
        if runtime?.socketState.isOpen != true {
            shown = ("wifi.exclamationmark", "Not connected", "Connect to see its model.", Ink.text2)
        } else if let options = check.options {
            if let selected = options.model?.trimmingCharacters(in: .whitespacesAndNewlines), !selected.isEmpty,
               let slug = ModelPlace.provider(options), let word = ModelPlace.word(options) {
                if ModelPlace.isLocal(slug) {
                    let name = check.local.flatMap { LocalModelDownload.entry(for: selected, in: $0) }?.displayName
                    shown = ("desktopcomputer", name ?? selected, "Runs \(ModelPlace.hereInSentence).", .green)
                } else {
                    shown = ("cloud.fill", selected,
                             ModelPlace.isPlan(slug) ? "Runs online with your \(word)." : "Runs online through \(word).", Ink.text2)
                }
            } else {
                shown = ("cpu", "No model yet", "Your assistant hasn't picked one.", Ink.text2)
            }
        } else if check.error != nil {
            shown = ("exclamationmark.triangle.fill", "Couldn't check", "Nothing was changed.", .orange)
        } else {
            shown = ("cpu", "Checking", nil, Ink.text2)
        }
        return PageHero(symbol: shown.symbol, title: shown.title, line: shown.line, tint: shown.tint, id: "models.advanced.hero")
    }

    /// The model Hermes uses now: its name, the identifier Hermes knows it by, and the sign-in.
    @ViewBuilder private var currentModel: some View {
        VStack(alignment: .leading, spacing: 12) {
            PageHeading("Current model")
            if let options = check.options {
                if let selected = options.model, !selected.isEmpty {
                    let name = check.local.flatMap { LocalModelDownload.entry(for: selected, in: $0) }?.displayName
                    ModelsDetailRow(name: "Model", value: name ?? "Chosen")
                    ModelsDetailRow(name: "Model identifier", value: selected, selectable: true)
                } else {
                    ModelsDetailRow(name: "Model", value: "Not chosen")
                }
                ModelsDetailRow(name: "Account", value: Self.accountDetail(options))
            } else if check.loading {
                ProgressView("Checking your connection")
                    .frame(maxWidth: .infinity)
            } else {
                PageNote(runtime?.socketState.isOpen == true ? "Not checked yet." : "Connect an assistant to check its model.")
            }
        }
    }

    /// The download's extras: the identifier it chose, trying a first reply, and other models
    /// that fit, each only when it applies.
    @ViewBuilder private var downloaded: some View {
        if let setup, let local = check.local {
            let choices = LocalModelDownload.choices(in: local)
            let canTry = [.selected, .checkingReply, .ready].contains(setup.state)
            let canChoose = setup.canBegin && choices.count > 1
            if setup.selectedModel != nil || canTry || canChoose {
                VStack(alignment: .leading, spacing: 12) {
                    PageHeading("Your model \(ModelPlace.hereInSentence)")
                    if let selected = setup.selectedModel {
                        ModelsDetailRow(name: "Downloaded", value: selected, selectable: true)
                            .testID("models.local.details")
                    }
                    if canTry { firstReply(setup) }
                    if canChoose { otherModels(choices, recommended: local.recommended?.id) }
                }
            }
        }
    }

    /// A short greeting to check the downloaded model answers, and its reply.
    @ViewBuilder private func firstReply(_ setup: LocalModelQuickstart) -> some View {
        if setup.state == .selected {
            GlassButton("Try a first reply", symbol: "text.bubble", id: "models.local.test") { setup.testReply() }
                .disabled(setup.busy).opacity(setup.busy ? 0.5 : 1)
            PageNote("Uses only your local model, without tools or chat history. The first reply can take a few minutes.")
        } else if setup.state == .checkingReply {
            PageNote("Waiting for its first reply.", symbol: "hourglass")
        }
        if let reply = setup.reply {
            Text(reply)
                .font(.body)
                .foregroundStyle(Ink.text)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .inset(h: 20, v: 14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .nollieGlass(.regular, in: .rect(cornerRadius: 26, style: .continuous), solid: Ink.card)
                .testID("models.local.reply")
        }
        if setup.state == .selected, let message = setup.message { PageNote(message) }
    }

    /// Another model that fits, for Download and use on the Models page.
    private func otherModels(_ choices: [LocalModelCatalogEntry], recommended: String?) -> some View {
        VStack(spacing: 12) {
            GlassChoice("Other models", selection: Binding(get: { download.selectedID }, set: { download.selectedID = $0 }),
                        options: choices.map { ($0.id, $0.displayName + ($0.id == recommended ? " (recommended)" : "")) },
                        id: "models.local.choice")
            PageNote("Download and use gets the one you pick.")
        }
        .accessibilityElement(children: .contain)
        .testID("models.local.otherModels")
    }

    /// The computer the model runs on, and the model Hermes suggests for it.
    @ViewBuilder private var computer: some View {
        if let local = check.local {
            VStack(alignment: .leading, spacing: 12) {
                PageHeading("The computer")
                if let hardware = local.hardware { PageNote(hardware.summary, symbol: "memorychip") }
                if let fit = local.recommended?.fitSummary { PageNote(fit) }
                if let recommended = local.recommended, LocalModelQuickstartSection.scope(for: runtime) == nil {
                    ModelsDetailRow(name: "Suggested", value: recommended.displayName)
                    ModelsDetailRow(name: "Download", value: recommended.downloadLabel)
                    PageNote("Downloads work with the assistant Nollie set up on this Mac. Your setup stays as it is.")
                } else if local.recommended == nil {
                    PageNote(local.summary)
                }
            }
        } else if runtime == nil, let hardware = MacModelHardware.current() {
            VStack(alignment: .leading, spacing: 12) {
                PageHeading("The computer")
                PageNote(hardware.summary, symbol: "memorychip")
                PageNote("This is the Mac running Nollie. A remote assistant uses its own computer.")
            }
        }
    }

    static func accountDetail(_ options: ModelOptionsResult) -> String {
        switch OnboardingModelStatus.read(options) {
        case .ready: "Connected"
        case .needsSignIn: "Sign-in needed"
        case .notConfigured: "No model selected"
        case .unverified: "Sign-in not verified"
        }
    }
}

/// A name and its value on a glass capsule, side by side while they fit, else one over the other.
private struct ModelsDetailRow: View {
    var name: String
    var value: String
    var selectable = false

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                label
                Spacer(minLength: 8)
                valueText.multilineTextAlignment(.trailing)
            }
            .inset(h: 22, v: 14)
            .frame(maxWidth: .infinity, minHeight: 54)
            .nollieGlass(.regular, in: Capsule(), solid: Ink.card)
            VStack(alignment: .leading, spacing: 4) {
                label
                valueText
            }
            .inset(h: 20, v: 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .nollieGlass(.regular, in: .rect(cornerRadius: 26, style: .continuous), solid: Ink.card)
        }
        .accessibilityElement(children: .combine)
    }

    private var label: some View {
        Text(name).font(.headline).foregroundStyle(Ink.text)
    }

    @ViewBuilder private var valueText: some View {
        let text = Text(value).font(.body).foregroundStyle(Ink.text2).fixedSize(horizontal: false, vertical: true)
        if selectable { text.textSelection(.enabled) } else { text }
    }
}
