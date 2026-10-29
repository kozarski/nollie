import Foundation

/// A model Hermes may move to when the main one stops answering: one entry of its `fallback_providers` list.
public struct BackupRoute: Hashable, Sendable {
    public var provider: String
    public var model: String
    public var baseURL: String?

    public init(provider: String, model: String, baseURL: String? = nil) {
        self.provider = provider
        self.model = model
        self.baseURL = baseURL
    }

    /// Providers that run the model on the assistant's own computer.
    public static let localProviders: Set<String> = ["ollama", "llamacpp", "llama.cpp", "llama-cpp", "lmstudio", "lm-studio", "mlx", "local"]

    public var isLocal: Bool { Self.localProviders.contains(provider.lowercased()) }

    /// A plan people already pay for and sign in to.
    public static func isPlan(_ provider: String) -> Bool {
        provider == "openai-codex" || provider.hasPrefix("claude-subscription")
    }

    /// The model's family in a word: "llama-3.2-3b-instruct-q4_k_m" reads "Llama".
    public static func shortName(_ model: String) -> String {
        let last = model.split(separator: "/").last.map(String.init) ?? model
        let letters = String(last.lowercased().prefix { $0.isLetter })
        let known = ["llama": "Llama", "qwen": "Qwen", "gemma": "Gemma", "mistral": "Mistral", "mixtral": "Mixtral",
                     "phi": "Phi", "gpt": "GPT", "deepseek": "DeepSeek", "glm": "GLM", "hermes": "Hermes", "claude": "Claude",
                     "gemini": "Gemini", "granite": "Granite", "smollm": "SmolLM", "olmo": "OLMo", "kimi": "Kimi"]
        if let name = known[letters] { return name }
        guard !letters.isEmpty else { return last }
        return letters.prefix(1).uppercased() + letters.dropFirst()
    }
}

/// Reading and writing the backup in a bot's Hermes config, through `GET` and `PUT /api/config?profile=`.
///
/// Hermes reads `fallback_providers` (an ordered list of `{provider, model, base_url?}`) and then any older
/// `fallback_model`. Nollie's choice is the first entry: choosing one replaces only that entry and keeps the rest,
/// and turning it off empties the list and clears the older key, so nothing switches by itself afterwards.
/// A PUT deep-merges into the file on disk, and a list replaces the old one whole.
public enum BackupModelConfig {
    /// The chain as Hermes reads it, from `/api/config` with or without its `config` wrapper.
    public static func chain(in answer: JSONValue) -> [BackupRoute] {
        let config = answer["config"] ?? answer
        var seen = Set<BackupRoute>()
        return (entries(config["fallback_providers"]) + entries(config["fallback_model"])).filter { seen.insert($0).inserted }
    }

    /// The backup in use now: the chain's first entry.
    public static func current(in answer: JSONValue) -> BackupRoute? { chain(in: answer).first }

    /// The `PUT /api/config` body that makes `choice` the backup, or turns backups off when it is nil.
    public static func update(choosing choice: BackupRoute?, in answer: JSONValue) -> JSONValue {
        var fields: [String: JSONValue] = [:]
        if let choice {
            let rest = chain(in: answer).dropFirst().filter { $0 != choice }
            fields["fallback_providers"] = .array(([choice] + rest).map(json))
        } else {
            fields["fallback_providers"] = .array([])
        }
        let config = answer["config"] ?? answer
        if let legacy = config["fallback_model"], !legacy.isNull { fields["fallback_model"] = .null }
        return .object(["config": .object(fields)])
    }

    private static func entries(_ value: JSONValue?) -> [BackupRoute] {
        let items = value?.arrayValue ?? (value?.objectValue != nil ? [value!] : [])
        return items.compactMap { item in
            guard let provider = item["provider"]?.stringValue?.trimmingCharacters(in: .whitespaces), !provider.isEmpty,
                  let model = item["model"]?.stringValue?.trimmingCharacters(in: .whitespaces), !model.isEmpty else { return nil }
            let base = item["base_url"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
            return BackupRoute(provider: provider, model: model, baseURL: base)
        }
    }

    private static func json(_ route: BackupRoute) -> JSONValue {
        var fields: [String: JSONValue] = ["provider": .string(route.provider), "model": .string(route.model)]
        if let base = route.baseURL { fields["base_url"] = .string(base) }
        return .object(fields)
    }
}

/// Hermes saying it moved a chat to its backup model, or back, read into the one line the chat shows:
/// "Your Claude plan hit its limit, so Nollie is using Llama on your Mac until 3:00 PM."
///
/// Hermes has no event of its own for this. It says so in a `status.update` once the reply is done
/// (agent/chat_completion_helpers.py and agent/agent_runtime_helpers.py in v0.22.2), and moves back by itself at
/// the start of the next turn after the time it gives, or of the next turn when it gives none.
public enum BackupSwitch: Equatable, Sendable {
    case switched(from: BackupRoute, to: BackupRoute, reason: Reason, retryAt: Date?)
    case restored(BackupRoute)

    public enum Reason: Equatable, Sendable {
        /// Rate limits, quotas and an empty balance.
        case limit
        /// Overloaded, a server error or no answer in time.
        case busy
        case signIn
        case other
    }

    /// Hermes's words, or nil for any other status. They are, from Hermes v0.22.2:
    /// - "⚠️ Model fallback: {model} via {provider} unavailable ({reason}); using {model} via {provider}." and, when
    ///   it waits before trying the main one again, " Primary retry eligible in ~{n} s; recovery is not guaranteed."
    /// - "⚠️ Provider fallback: {provider/model} unavailable; using {provider/model} for this response."
    /// - "✅ Primary model restored: {model} via {provider}; fallback {model} via {provider} is no longer active."
    public static func read(kind: String, text: String, now: Date = Date()) -> BackupSwitch? {
        if let match = text.firstMatch(of: /Model fallback: (\S+) via (\S+) unavailable \(([^)]*)\); using (\S+) via (\S+?)\.(?: Primary retry eligible in ~(\d+) s)?/) {
            let retry = match.output.6.flatMap { Double($0) }.map { now.addingTimeInterval($0) }
            return .switched(from: BackupRoute(provider: String(match.output.2), model: String(match.output.1)),
                             to: BackupRoute(provider: String(match.output.5), model: String(match.output.4)),
                             reason: reason(String(match.output.3)), retryAt: retry)
        }
        if let match = text.firstMatch(of: /Provider fallback: (\S+) unavailable; using (\S+) for this response/) {
            return .switched(from: route(String(match.output.1)), to: route(String(match.output.2)), reason: .other, retryAt: nil)
        }
        if let match = text.firstMatch(of: /Primary model restored: (\S+) via (\S+?);/) {
            return .restored(BackupRoute(provider: String(match.output.2), model: String(match.output.1)))
        }
        return nil
    }

    /// Where a local model runs, in a sentence, on this device.
    public static var here: String {
        #if os(macOS)
        String(localized: "on this Mac", table: "Core", comment: "Where a model runs, as in: Llama on this Mac")
        #else
        String(localized: "on your Mac", table: "Core", comment: "Where a model runs, as in: Llama on your Mac")
        #endif
    }

    /// The chat's line. `here` is where a local model runs, in a sentence: "on this Mac" or "on your Mac". One whole
    /// sentence for each reason, with and without a time; the models fill its places.
    public func line(here: String, clock: SleepNote.Clock = SleepNote.clock) -> String {
        switch self {
        case let .switched(from, to, reason, retryAt):
            let main = Self.owner(from), backup = Self.place(to, here: here)
            if let retryAt {
                let time = clock(retryAt)
                return switch reason {
                case .limit: String(localized: "\(main) hit its limit, so Nollie is using \(backup) until \(time).", table: "Core")
                case .busy: String(localized: "\(main) is busy, so Nollie is using \(backup) until \(time).", table: "Core")
                case .signIn: String(localized: "\(main) needs signing in again, so Nollie is using \(backup) until \(time).", table: "Core")
                case .other: String(localized: "\(main) isn't answering, so Nollie is using \(backup) until \(time).", table: "Core")
                }
            }
            return switch reason {
            case .limit: String(localized: "\(main) hit its limit, so Nollie is using \(backup) for this reply.", table: "Core")
            case .busy: String(localized: "\(main) is busy, so Nollie is using \(backup) for this reply.", table: "Core")
            case .signIn: String(localized: "\(main) needs signing in again, so Nollie is using \(backup) for this reply.", table: "Core")
            case .other: String(localized: "\(main) isn't answering, so Nollie is using \(backup) for this reply.", table: "Core")
            }
        case .restored(let main):
            let owner = Self.owner(main, inSentence: true)
            return String(localized: "Back on \(owner).", table: "Core", comment: "The person's main model is answering again: Back on your Claude plan.")
        }
    }

    // MARK: Words

    /// "Your Claude plan", "Your OpenRouter account", "Your model on this Mac", "Your main model".
    /// The same inside a sentence: "your Claude plan".
    static func owner(_ route: BackupRoute, inSentence: Bool = false) -> String {
        if let plan = Papertrail.providerLabel(route.provider), BackupRoute.isPlan(route.provider) {
            return inSentence ? String(localized: "your \(plan)", table: "Core", comment: "A model plan inside a sentence: your Claude plan")
                : String(localized: "Your \(plan)", table: "Core", comment: "A model plan at the start of a sentence: Your Claude plan")
        }
        if route.isLocal {
            let name = BackupRoute.shortName(route.model)
            return inSentence ? String(localized: "your \(name) model", table: "Core", comment: "Inside a sentence: your Llama model")
                : String(localized: "Your \(name) model", table: "Core", comment: "At the start of a sentence: Your Llama model")
        }
        if let label = Papertrail.providerLabel(route.provider) {
            return inSentence ? String(localized: "your \(label) account", table: "Core", comment: "Inside a sentence: your OpenRouter account")
                : String(localized: "Your \(label) account", table: "Core", comment: "At the start of a sentence: Your OpenRouter account")
        }
        return inSentence ? String(localized: "your main model", table: "Core", comment: "Inside a sentence")
            : String(localized: "Your main model", table: "Core", comment: "At the start of a sentence")
    }

    /// "Llama on your Mac", "your ChatGPT plan", "OpenRouter".
    static func place(_ route: BackupRoute, here: String) -> String {
        if route.isLocal {
            let name = BackupRoute.shortName(route.model)
            return String(localized: "\(name) \(here)", table: "Core", comment: "A model's name, then where it runs: Llama on your Mac")
        }
        if let label = Papertrail.providerLabel(route.provider) {
            return BackupRoute.isPlan(route.provider) ? String(localized: "your \(label)", table: "Core", comment: "A model plan inside a sentence: your Claude plan") : label
        }
        return BackupRoute.shortName(route.model)
    }

    static func reason(_ words: String) -> Reason {
        let words = words.lowercased()
        if words.contains("rate limit") || words.contains("quota") || words.contains("billing") || words.contains("credit") {
            return .limit
        }
        if words.contains("overloaded") || words.contains("server error") || words.contains("timeout") { return .busy }
        if words.contains("authentication") { return .signIn }
        return .other
    }

    /// "provider/model", as Hermes joins them before a chat's model exists.
    private static func route(_ joined: String) -> BackupRoute {
        let parts = joined.split(separator: "/", maxSplits: 1).map(String.init)
        return BackupRoute(provider: parts.first ?? joined, model: parts.count > 1 ? parts[1] : joined)
    }
}
