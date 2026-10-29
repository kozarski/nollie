import SwiftUI
import NollieCore

extension ChatSession {
    /// Asks the gateway which models are on offer. The list belongs to this chat's own bot, since each
    /// bot has its own providers and keys, and not to whichever bot is selected right now.
    func modelOptions() async throws -> ModelOptionsResult {
        let owner = Self.modelOptionsProfile(chat: profile, selected: runtime.selectedProfile)
        return try await runtime.api.get("/api/model/options", profile: owner)
    }

    /// Whose list to ask: the chat's bot if it has one on record, otherwise the selected bot.
    nonisolated static func modelOptionsProfile(chat: String?, selected: String?) -> String? {
        if let chat { return chat }
        return selected
    }

    /// Reasoning and fast-mode support for the chat's current model. Nil until the gateway answers.
    func modelCapabilities() async -> ModelCapabilities? {
        guard let options = try? await modelOptions() else { return nil }
        let provider = options.providers.first { $0.slug == info?.provider }
        return provider?.capabilities?[modelName]
    }
}

/// Two toggles in the chat menu. Fast mode shows only where the model supports it, and YOLO stops
/// asking for approval until the session ends.
struct ChatModeToggles: View {
    @Bindable var chat: ChatSession
    @State private var capabilities: ModelCapabilities?

    var body: some View {
        Group {
            if capabilities?.fast == true {
                Toggle("Fast mode", isOn: binding(\.fast, apply: chat.setFast))
            }
            Toggle("YOLO (no approvals for this session)", isOn: binding(\.yolo, apply: chat.setYolo))
        }
        .task { capabilities = await chat.modelCapabilities() }
    }

    /// Reads one flag off the live chat info and, on change, asks the gateway to flip it.
    private func binding(_ flag: KeyPath<SessionLiveInfo, Bool?>, apply: @escaping (Bool) async throws -> Void) -> Binding<Bool> {
        Binding {
            chat.info?[keyPath: flag] ?? false
        } set: { newValue in
            Task { try? await apply(newValue) }
        }
    }
}

/// Builds the reasoning choices for the chat menu. A model with no such setting hides the submenu;
/// before models have loaded it is simply shown.
enum ReasoningEffort {
    /// Levels always listed.
    static let standard: [String] = ["low", "medium", "high"]
    /// Every level we know, from weakest to strongest.
    static let byStrength: [String] = ["minimal"] + standard + ["xhigh", "max"]

    /// The standard levels plus any the gateway's schema adds. Known ones come in strength order,
    /// then levels only the gateway knows about in its own order. No duplicates, no blank entries.
    static func levels(offered: [String]?) -> [String] {
        var seen = Set<String>()
        var fromGateway: [String] = []
        for raw in offered ?? [] {
            let level = raw.trimmingCharacters(in: .whitespaces)
            if !level.isEmpty && seen.insert(level).inserted { fromGateway.append(level) }
        }
        let known = byStrength.filter { standard.contains($0) || fromGateway.contains($0) }
        return known + fromGateway.filter { !known.contains($0) }
    }

    /// Title for the menu: the level in use, or a note that none is set.
    static func title(current: String?) -> String {
        let trimmed = (current ?? "").trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return String(localized: "Reasoning: not set") }
        return String(localized: "Reasoning: \(trimmed)", comment: "The reasoning level in use, a config value like high")
    }

    /// Reads the level choices out of the gateway's config schema, if it lists any.
    static func offered(in schema: JSONValue) -> [String]? {
        guard let choices = schema["fields"]?["agent.reasoning_effort"]?["options"]?.arrayValue else { return nil }
        return choices.compactMap { $0.stringValue }
    }
}

/// The Reasoning submenu of the chat menu.
struct ReasoningEffortMenu: View {
    @State private var loaded = false
    @State private var choices: [String]?
    @State private var supported: ModelCapabilities?
    @Bindable var chat: ChatSession

    var body: some View {
        if supported?.reasoning != false {
            Menu {
                ForEach(ReasoningEffort.levels(offered: choices), id: \.self, content: levelButton)
            } label: {
                Label(menuTitle, systemImage: "brain")
            }
            .accessibilityIdentifier("chat.reasoning")
            .task { await loadOnce() }
        }
    }

    private var menuTitle: String {
        let current = chat.info?.reasoningEffort
        return ReasoningEffort.title(current: current)
    }

    private func levelButton(_ level: String) -> some View {
        Button {
            apply(level)
        } label: {
            if level == chat.info?.reasoningEffort {
                Label(level, systemImage: "checkmark")
            } else {
                Text(level)
            }
        }
    }

    private func apply(_ level: String) {
        Task { await change(to: level) }
    }

    private func change(to level: String) async {
        do {
            try await chat.setReasoning(level)
        } catch let failure {
            chat.banner = failure.localizedDescription
        }
    }

    private func loadOnce() async {
        if loaded { return }
        loaded = true
        supported = await chat.modelCapabilities()
        let owner = ChatSession.modelOptionsProfile(chat: chat.profile, selected: chat.runtime.selectedProfile)
        guard let schema: JSONValue = try? await chat.runtime.api.get("/api/config/schema", profile: owner) else { return }
        choices = ReasoningEffort.offered(in: schema)
    }
}
