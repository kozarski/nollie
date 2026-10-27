import SwiftUI
import NollieCore

/// Everything a bot's card edits and reports: the saved facts, the notes shown after a save, and the
/// dashboard calls (description and model updates are PUTs under `/api/profiles/{name}`; removal is
/// a DELETE on the same path).
@MainActor @Observable
final class ProfileCardState {
    let name: String
    /// The gateway the card talks to; the card sets it as it appears and when the gateway changes.
    var runtime: GatewayRuntime?
    var blurb = ""
    var isPrivate = false
    var savingPrivacy = false
    /// A Private choice is kept on this device but the gateway hasn't heard it. The card offers another try.
    var privacyNeedsRetry = false
    var tint: Color = .accentColor
    var avatar: CharacterChoice = .look(.main)
    var options: ModelOptionsResult?
    /// "Saved…" in green or what went wrong in orange, under the open tab.
    var note: String?
    /// The note says a save went through (green), not what went wrong.
    var noteSaved = false
    /// What went wrong last, word for word, for the Advanced pages.
    var lastProblem: String?
    var deleting = false
    /// System control has been read since the Computer tab opened.
    var controlChecked = false
    let ownComputer: HelperComputerModel
    /// Called when the bot is gone and the card has nothing left to show.
    var leave: () -> Void = {}
    private var started = false

    init(name: String) {
        self.name = name
        ownComputer = HelperComputerModel(profile: name)
    }

    // MARK: What is known

    var info: ProfileInfo? { runtime?.profiles.first { $0.name == name } }
    var label: String { info?.shownName ?? name }
    var isHidden: Bool { PrivateBots.isPrivate(name, connection: runtime?.connection.id) }
    var savedBlurb: String { (info?.description ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }

    /// The provider and model as saved, or "Not set".
    var savedModel: String {
        let parts = [info?.provider, info?.model].compactMap { $0 }.filter { !$0.isEmpty }
        return parts.isEmpty ? String(localized: "Not set", comment: "No model is saved for a bot") : parts.joined(separator: "/")
    }

    /// The model's last path part, as a choice shows it.
    var shortModel: String? {
        info?.model.flatMap { $0.isEmpty ? nil : ModelNames.tail($0) }
    }

    /// Reads the bot's saved look, colour and privacy once, as the card first appears.
    func start() {
        guard !started else { return }
        started = true
        blurb = info?.description ?? ""
        isPrivate = isHidden
        privacyNeedsRetry = runtime?.privateSyncPending() == true
        tint = BotColors.color(for: name)
        avatar = BotAvatarStore.choice(for: name)
    }

    func refreshTint() { tint = BotColors.color(for: name) }

    // MARK: Where it thinks, what it may touch

    var thinks: CardThinks {
        let provider = (info?.provider ?? "").trimmingCharacters(in: .whitespaces)
        guard !provider.isEmpty, !(info?.model ?? "").isEmpty else { return .unset }
        if ModelNames.isLocal(provider) { return .mac }
        if ModelNames.isPlan(provider) {
            return .plan(Papertrail.providerLabel(provider)
                         ?? String(localized: "Your plan", comment: "A paid plan, like a Claude or ChatGPT plan, when its name is unknown"))
        }
        return .key(Papertrail.providerLabel(provider) ?? options?.providers.first { $0.slug == provider }?.name)
    }

    var computer: CardComputer {
        let control = SystemControl.shared
        if control.isOn(name, runtime) {
            guard let runtime else { return .canUseMac }
            let onMac = BotComputerActivity.isActive(runtime: runtime, profile: name)
                && !BotComputerActivity.usesOwnComputer(runtime: runtime, profile: name)
            return onMac ? .usingMac : .canUseMac
        }
        if let own = ownComputer.status, own.on { return .ownComputer(gettingReady: own.state == .gettingReady) }
        if control.state(name, runtime) == nil { return controlChecked ? .unknown : .checking }
        return .handsOff
    }

    /// A computer of its own. Never for a private bot: the add-on refuses it and lists nothing of it.
    var mayHaveOwnComputer: Bool { !isHidden && info?.isPrivateBot(on: runtime?.connection.id) != true }

    var mayDelete: Bool { info.map { $0.isDefault != true && !$0.isPrivateBot(on: runtime?.connection.id) } ?? false }

    // MARK: Saving

    private func failed(_ words: String, _ error: Error) {
        note = words
        noteSaved = false
        lastProblem = error.localizedDescription
    }

    /// Sends one change to the bot's profile and reloads the profiles. A failure leaves a word
    /// for the person and the raw error for Advanced.
    private func put(_ part: String, _ fields: [String: JSONValue]) async -> Bool {
        guard let runtime else { return false }
        do {
            let _: JSONValue = try await runtime.api.send("PUT", "/api/profiles/\(name)/\(part)", json: .object(fields))
            await runtime.loadProfiles()
            return true
        } catch {
            failed(String(localized: "Couldn't save that. Try again."), error)
            return false
        }
    }

    func saveBlurb() async {
        if await put("description", ["description": .string(blurb)]) {
            note = String(localized: "Saved description.")
            noteSaved = true
        }
    }

    func saveModel(provider: String, model: String) async {
        guard await put("model", ["provider": .string(provider), "model": .string(model)]) else { return }
        note = String(localized: "Saved. \(label) uses \(ModelNames.tail(model)) from now on.", comment: "A bot's name, then a model's name")
        noteSaved = true
    }

    func setPrivacy(_ on: Bool) async {
        guard let runtime else { isPrivate = isHidden; return }
        guard on != isHidden else { return }
        savingPrivacy = true
        defer { savingPrivacy = false }
        do {
            try await runtime.setPrivate(name, on)
            privacyNeedsRetry = false
        } catch {
            privacyFailed(error)
        }
    }

    /// Sends a Private choice the gateway hasn't heard yet.
    func retryPrivacy() async {
        guard let runtime else { return }
        savingPrivacy = true
        defer { savingPrivacy = false }
        do {
            try await runtime.retryPrivateSync()
            privacyNeedsRetry = false
            note = String(localized: "Saved. \(label) is private.")
            noteSaved = true
        } catch {
            privacyFailed(error)
        }
    }

    /// The switch shows what is true now: turned on here and kept, or still on because turning it
    /// off needs the gateway's yes.
    private func privacyFailed(_ error: Error) {
        let sync = error as? PrivateBotsSyncError
        note = sync?.errorDescription ?? String(localized: "Couldn't save that. Try again.")
        noteSaved = false
        lastProblem = sync?.detail ?? error.localizedDescription
        privacyNeedsRetry = sync?.kind == .notTold
        isPrivate = isHidden
    }

    func deleteBot() async {
        guard let runtime, mayDelete else { return }
        deleting = true
        defer { deleting = false }
        do {
            let _: JSONValue = try await runtime.api.send("DELETE", "/api/profiles/" + name, body: EmptyBody())
            // If the deleted bot was the selected one, move to the first public bot left.
            if runtime.selectedProfile == name {
                let heir = runtime.profiles.first(where: { $0.name != name && !$0.isPrivateBot(on: runtime.connection.id) })
                runtime.selectedProfile = heir?.name
            }
            await runtime.loadProfiles()
            NotificationCenter.default.post(name: .hermesSessionsChanged, object: nil)
            leave()
        } catch {
            failed(String(localized: "Couldn't delete \(label). Try again."), error)
        }
    }

    // MARK: Looks

    func chooseLook(_ choice: CharacterChoice) {
        avatar = choice
        BotAvatarStore.set(choice, for: name)
        BotLookSharing.share(name, runtime: runtime)
    }

    func chooseColour(_ hex: String) {
        var colours = BotColors.stored()
        colours[name] = hex
        BotColors.save(colours)
        BotLookSharing.share(name, runtime: runtime)
        tint = Color(hex: hex) ?? tint
    }

    func resetLook() {
        avatar = .look(.defaultLook(forProfile: name))
        var looks = BotAvatarStore.stored()
        looks[name] = nil
        BotAvatarStore.save(looks)
        var colours = BotColors.stored()
        colours[name] = nil
        BotColors.save(colours)
        BotLookSharing.share(name, runtime: runtime)
        refreshTint()
    }
}

/// How model providers are told apart and named.
enum ModelNames {
    private static let local: Set<String> = ["ollama", "llamacpp", "llama.cpp", "llama-cpp", "lmstudio", "lm-studio", "mlx", "local"]

    static func isLocal(_ slug: String) -> Bool { local.contains(slug.lowercased()) }
    static func isPlan(_ slug: String) -> Bool { slug.hasPrefix("claude-subscription") || slug == "openai-codex" }

    /// The last part of a model's path: "anthropic/sonnet" shows as "sonnet".
    static func tail(_ model: String) -> String { model.split(separator: "/").last.map(String.init) ?? model }

    /// The models a plain choice offers: the featured ones, else the first dozen.
    static func offered(_ provider: ModelProvider) -> [String] {
        if let featured = provider.featuredModels, !featured.isEmpty { return featured }
        return Array((provider.models ?? []).prefix(12))
    }
}
