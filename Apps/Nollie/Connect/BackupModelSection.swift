import SwiftUI
import NollieCore

/// A model the person can pick as the backup, in the words the picker shows.
struct BackupChoice: Hashable {
    var route: BackupRoute
    var title: String

    /// What can stand in for the main model: models downloaded to the assistant's computer first, then other
    /// plans and keys the assistant is signed in to. A private bot only ever gets a local one. The backup chosen
    /// before stays on offer even when Nollie can't list it.
    static func all(options: ModelOptionsResult?, local: LocalModelSetupSnapshot?, current: BackupRoute?,
                    privateBot: Bool) -> [BackupChoice] {
        let mainProvider = options.flatMap(ModelPlace.provider)
        let mainModel = options?.model
        var found: [BackupChoice] = []
        for entry in local?.models ?? [] where entry.downloaded == true {
            let id = entry.downloadedModelId ?? entry.modelId ?? entry.id
            guard !(ModelPlace.isLocal(mainProvider) && mainModel == id) else { continue }
            found.append(BackupChoice(route: BackupRoute(provider: "llamacpp", model: id),
                                      title: "\(entry.displayName) \(ModelPlace.hereInSentence)"))
        }
        if !privateBot {
            for provider in options?.providers ?? [] where provider.authenticated == true && provider.slug != mainProvider
                && !ModelPlace.isLocal(provider.slug) {
                guard let model = provider.featuredModels?.first ?? provider.models?.first else { continue }
                let name = Papertrail.providerLabel(provider.slug) ?? provider.name
                found.append(BackupChoice(route: BackupRoute(provider: provider.slug, model: model), title: name))
            }
        }
        if let current, !found.contains(where: { $0.route == current }) {
            found.insert(BackupChoice(route: current, title: current.isLocal
                                      ? "\(BackupRoute.shortName(current.model)) \(ModelPlace.hereInSentence)"
                                      : Papertrail.providerLabel(current.provider) ?? BackupRoute.shortName(current.model)), at: 0)
        }
        return found
    }
}

/// The bot's backup as its Hermes config holds it, read and changed over `/api/config`.
@MainActor @Observable
final class BackupModelSetting {
    private(set) var answer: JSONValue?
    private(set) var busy = false
    private(set) var problem: String?
    private var identity: String?

    var current: BackupRoute? { answer.flatMap(BackupModelConfig.current) }

    func load(_ runtime: GatewayRuntime, profile: String) async {
        let key = "\(runtime.connection.id)/\(profile)"
        if identity != key { answer = nil; problem = nil; identity = key }
        guard let read: JSONValue = try? await runtime.api.get("/api/config", profile: profile), identity == key else { return }
        answer = read
    }

    /// Makes `choice` the backup, or none. Reads the config again afterwards, so the switch shows what Hermes keeps.
    func set(_ choice: BackupRoute?, _ runtime: GatewayRuntime, profile: String) async {
        guard !busy, let answer else { return }
        busy = true
        problem = nil
        defer { busy = false }
        do {
            let _: JSONValue = try await runtime.api.send("PUT", "/api/config", profile: profile,
                                                          json: BackupModelConfig.update(choosing: choice, in: answer))
            await load(runtime, profile: profile)
            if current != choice { problem = "Your assistant didn't keep that. Try again." }
        } catch {
            problem = "Couldn't change it. Nothing was changed."
        }
    }
}

/// Models › If my plan runs out: off until chosen. When the main model hits a limit or stops answering, Hermes
/// moves to this one and the chat says so in one line; it goes back by itself once the main one works again.
struct BackupModelSection: View {
    var check: ModelCheck
    @Environment(AppModel.self) private var model
    @State private var setting = BackupModelSetting()

    private var runtime: GatewayRuntime? { model.runtime }
    private var profile: String { runtime?.selectedProfile ?? "default" }
    private var key: String { "\(runtime?.connection.id.uuidString ?? "")/\(profile)/\(runtime?.socketState.isOpen == true)" }

    private var choices: [BackupChoice] {
        BackupChoice.all(options: check.options, local: check.local, current: setting.current,
                         privateBot: PrivateBots.isPrivate(runtime?.selectedProfile, connection: runtime?.connection.id))
    }

    var body: some View {
        // Shown once the bot's config is read. A phone linked through Nollie Link can't read it, so it shows nothing.
        if setting.answer != nil { section } else { Color.clear.frame(height: 0).task(id: key) { await load() } }
    }

    private func load() async {
        guard let runtime, runtime.socketState.isOpen else { return }
        await setting.load(runtime, profile: profile)
    }

    private var section: some View {
        VStack(spacing: 12) {
            GlassSwitch("If my plan runs out", isOn: Binding(get: { setting.current != nil }, set: turn), id: "models.backup")
                .disabled(setting.busy || (setting.current == nil && choices.isEmpty))
            if let current = setting.current {
                GlassChoice("Use", selection: Binding(get: { current }, set: { choose($0) }),
                            options: choices.map { ($0.route, $0.title) }, id: "models.backup.choice")
                    .disabled(setting.busy)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            } else if choices.isEmpty {
                PageNote("Download a model \(ModelPlace.hereInSentence) to have one ready.", symbol: "arrow.down.circle",
                         id: "models.backup.none")
            }
            if let problem = setting.problem { PageNote(problem, id: "models.backup.problem") }
        }
        .animation(.snappy, value: setting.current)
        .accessibilityElement(children: .contain)
        .task(id: key) { await load() }
    }

    private func turn(_ on: Bool) {
        guard let runtime else { return }
        let choice = on ? choices.first?.route : nil
        guard !on || choice != nil else { return }
        Task { await setting.set(choice, runtime, profile: profile) }
    }

    private func choose(_ route: BackupRoute) {
        guard let runtime, route != setting.current else { return }
        Task { await setting.set(route, runtime, profile: profile) }
    }
}
