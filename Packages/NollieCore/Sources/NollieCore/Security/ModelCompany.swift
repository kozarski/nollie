import Foundation

/// The company an online model sends a helper's words to, named the way people know it. The app asks
/// before anything first goes to one, so each is named here with its own privacy policy.
public struct ModelCompany: Hashable, Sendable, Identifiable {
    /// The same for every way of reaching the company: a Claude plan and an Anthropic key are both "anthropic".
    public let id: String
    public let name: String
    public let privacyPolicy: URL?

    public init(id: String, name: String, privacyPolicy: URL? = nil) {
        self.id = id
        self.name = name
        self.privacyPolicy = privacyPolicy
    }

    /// The company behind a Hermes provider, or nil for a model on the assistant's own computer. A provider
    /// this list doesn't know keeps Hermes's display name for it, then its slug.
    public static func behind(_ provider: String, listedName: String? = nil) -> ModelCompany? {
        let slug = provider.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !slug.isEmpty, !BackupRoute.localProviders.contains(slug) else { return nil }
        if slug.hasPrefix("claude-subscription") { return known["anthropic"] }
        if let id = aliases[slug], let company = known[id] { return company }
        let listed = listedName?.trimmingCharacters(in: .whitespacesAndNewlines)
        return ModelCompany(id: slug, name: listed?.isEmpty == false ? listed! : slug)
    }

    private static let aliases: [String: String] = [
        "anthropic": "anthropic",
        "openai": "openai", "openai-api": "openai", "openai-codex": "openai",
        "openrouter": "openrouter",
        "nous": "nous",
        "gemini": "google", "google": "google", "google-gemini": "google", "google-ai-studio": "google", "vertex": "google",
        "xai": "xai", "xai-oauth": "xai",
        "github-copilot": "github", "copilot": "github", "copilot-acp": "github",
        "deepseek": "deepseek",
        "zai": "zai",
        "kimi-for-coding": "moonshot",
        "minimax": "minimax", "minimax-oauth": "minimax", "minimax-cn": "minimax",
        "huggingface": "huggingface",
        "bedrock": "amazon",
        "ollama-cloud": "ollama",
    ]

    private static let known: [String: ModelCompany] = {
        let list: [(String, String, String?)] = [
            ("anthropic", "Anthropic", "https://www.anthropic.com/legal/privacy"),
            ("openai", "OpenAI", "https://openai.com/policies/privacy-policy/"),
            ("openrouter", "OpenRouter", "https://openrouter.ai/privacy"),
            ("nous", "Nous Research", "https://portal.nousresearch.com/privacy"),
            ("google", "Google", "https://policies.google.com/privacy"),
            ("xai", "xAI", "https://x.ai/legal/privacy-policy"),
            ("github", "GitHub", "https://docs.github.com/en/site-policy/privacy-policies/github-general-privacy-statement"),
            ("deepseek", "DeepSeek", "https://cdn.deepseek.com/policies/en-US/deepseek-privacy-policy.html"),
            ("zai", "Z.ai", nil),
            ("moonshot", "Moonshot AI", nil),
            ("minimax", "MiniMax", nil),
            ("huggingface", "Hugging Face", "https://huggingface.co/privacy"),
            ("amazon", "Amazon Web Services", "https://aws.amazon.com/privacy/"),
            ("ollama", "Ollama", "https://ollama.com/privacy"),
        ]
        return Dictionary(uniqueKeysWithValues: list.map { id, name, page in
            (id, ModelCompany(id: id, name: name, privacyPolicy: page.flatMap(URL.init(string:))))
        })
    }()
}
