import Foundation

// Settings and tooling: toolsets, skills, keys, MCP servers, scheduled jobs, the config form,
// context use, files, slash commands, usage analytics and plugins.

// MARK: Capabilities

public struct ToolsetInfo: Identifiable, Sendable, Hashable, Codable {
    public var platform: String?
    public var description: String?
    public var label: String?
    public var name: String
    public var tools: [String]?
    public var configured: Bool?
    public var enabled: Bool

    public var id: String { name }

    public init(name: String, label: Optional<String> = nil, description: Optional<String> = nil, enabled: Bool) {
        self.enabled = enabled
        self.description = description
        self.label = label
        self.name = name
    }
}

public struct SkillInfo: Identifiable, Sendable, Hashable, Codable {
    public var provenance: String?
    public var category: String?
    public var description: String?
    public var name: String
    public var usage: Int?
    public var enabled: Bool?

    public var id: String { name }
}

public struct MCPServerInfo: Identifiable, Sendable, Hashable, Codable {
    public var transport: String?
    public var command: String?
    public var url: String?
    public var name: String
    public var args: [String]?
    public var enabled: Bool?

    public var id: String { name }
}

/// A row from `GET /api/env`, describing one setting that the gateway takes from its environment.
///
/// Newer gateways use `is_set` and `redacted_value`. Older ones named them `set` and `redacted`,
/// and those are still understood.
public struct EnvVarInfo: Sendable, Hashable, Codable {
    public var providerLabel: String?
    public var provider: String?
    public var url: String?
    public var docsUrl: String?
    public var category: String?
    public var description: String?
    public var redacted: String?
    public var redactedValue: String?
    public var isPassword: Bool?
    public var set: Bool?
    public var isSet: Bool?

    /// Whether the gateway holds a value, whichever name it used for that.
    public var hasValue: Bool { isSet ?? set ?? false }

    /// A hint at the value, without the `«redacted:…»` wrapping the gateway puts around it.
    public var preview: String? {
        guard let raw = redactedValue ?? redacted, !raw.isEmpty else { return nil }
        let opening = "«redacted:", closing = "»"
        var shown = Substring(raw)
        if shown.hasPrefix(opening) { shown = shown.dropFirst(opening.count) }
        if shown.hasSuffix(closing) { shown = shown.dropLast(closing.count) }
        return String(shown)
    }
}

// MARK: Scheduled jobs

public struct CronJob: Identifiable, Sendable, Hashable, Codable {
    public var lastStatus: String?
    public var lastRunAt: String?
    public var nextRunAt: String?
    public var state: String?
    public var deliver: String?
    public var promptPreview: String?
    public var prompt: String?
    public var schedule: String?
    public var name: String?
    public var jobId: String?
    public var id: String?
    public var enabled: Bool?

    /// A job as the app reads it from the gateway's raw answer. `deliver` is set afterwards.
    public init(id: Optional<String> = nil,
                jobId: Optional<String> = nil,
                name: Optional<String> = nil,
                schedule: Optional<String> = nil,
                prompt: Optional<String> = nil,
                promptPreview: Optional<String> = nil,
                enabled: Optional<Bool> = nil,
                state: Optional<String> = nil,
                nextRunAt: Optional<String> = nil,
                lastRunAt: Optional<String> = nil,
                lastStatus: Optional<String> = nil) {
        self.id = id
        self.jobId = jobId
        self.name = name
        self.schedule = schedule
        self.prompt = prompt
        self.promptPreview = promptPreview
        self.enabled = enabled
        self.state = state
        self.nextRunAt = nextRunAt
        self.lastRunAt = lastRunAt
        self.lastStatus = lastStatus
    }

    /// A stable name for the job: its job id, else id, else name. A job with none of them
    /// gets a fresh one each time it is asked.
    public var identity: String { jobId ?? id ?? name ?? UUID().uuidString }
}

// MARK: Config form

public struct ConfigSchemaField: Sendable, Hashable, Codable {
    public var category: String?
    public var description: String?
    public var type: String
    public var options: [String]?
    public var clearable: Bool?
    public var searchable: Bool?
}

public struct ConfigSchemaResponse: Sendable, Codable {
    public var categoryOrder: [String]?
    public var fields: [String: ConfigSchemaField]
}

// MARK: Context

public struct ContextCategory: Identifiable, Sendable, Hashable, Codable {
    public var color: String?
    public var label: String
    public var id: String
    public var tokens: Int
}

public struct ContextBreakdown: Sendable, Hashable, Codable {
    public var model: String?
    public var categories: [ContextCategory]
    public var estimatedTotal: Int?
    public var contextUsed: Int
    public var contextPercent: Int
    public var contextMax: Int
}

// MARK: Files

public struct FileEntry: Identifiable, Sendable, Hashable, Codable {
    public var mimeType: String?
    public var path: String
    public var name: String
    public var modifiedAt: Double?
    public var size: Int?
    public var isDirectory: Bool

    public var id: String { path }
}

public struct FilesListing: Sendable, Codable {
    public var lockedRoot: String?
    public var root: String?
    public var parent: String?
    public var path: String
    public var entries: [FileEntry]
}

public struct ManagedUploadResult: Sendable, Codable {
    public var path: String
    public var ok: Bool?
}

// MARK: Slash commands

public struct CommandCategory: Sendable, Hashable, Codable {
    public var pairs: [[String]]?
    public var name: String
}

/// The slash commands the gateway offers, with what the app needs to know to run them.
public struct CommandsCatalog: Sendable, Hashable, Codable {
    /// What one command ("/name") allows. `desktop` nil means a client that isn't a terminal
    /// may run it, "hidden" means it may but it isn't listed, and any other text is the reason
    /// it may not.
    public struct Meta: Sendable, Hashable, Codable {
        public var desktop: String?
        public var argumentMode: String?
    }

    /// Used by the gateway's own menus to rank and trim skill commands: how often one is used and
    /// its origin ("bundled", "hub" or "local"). Older gateways leave it out.
    public struct SkillMeta: Sendable, Hashable, Codable {
        public var origin: String?
        public var usage: Int?
    }

    public var warning: String?
    public var skills: [String: SkillMeta]?
    public var commands: [String: Meta]?
    public var canon: [String: String]?
    public var categories: [CommandCategory]?
    public var pairs: [[String]]?

    /// Every command with its description, which may be empty.
    public var allPairs: [(name: String, description: String)] {
        (pairs ?? []).compactMap { pair in
            guard let name = pair.first else { return nil }
            return (name, pair.dropFirst().first ?? "")
        }
    }
}

public struct CommandDispatchResult: Sendable, Hashable, Codable {
    public var display: String?
    public var notice: String?
    public var message: String?
    public var target: String?
    public var output: String?
    public var type: String
}

// MARK: Usage over time

/// Reply of `/api/analytics/usage?days=N`: usage totals for one bot, as counted on the gateway.
public struct UsageAnalytics: Sendable, Codable {
    public struct Day: Sendable, Hashable, Codable {
        public var day: String
        public var actualCost: Double?
        public var estimatedCost: Double?
        public var apiCalls: Int?
        public var sessions: Int?
        public var reasoningTokens: Int?
        public var cacheReadTokens: Int?
        public var outputTokens: Int?
        public var inputTokens: Int?
    }

    public struct Model: Sendable, Hashable, Codable {
        public var model: String?
        public var estimatedCost: Double?
        public var apiCalls: Int?
        public var sessions: Int?
        public var outputTokens: Int?
        public var inputTokens: Int?
    }

    public struct Totals: Sendable, Hashable, Codable {
        public var totalActualCost: Double?
        public var totalEstimatedCost: Double?
        public var totalApiCalls: Int?
        public var totalSessions: Int?
        public var totalReasoning: Int?
        public var totalCacheRead: Int?
        public var totalOutput: Int?
        public var totalInput: Int?
    }

    public var totals: Totals?
    public var byModel: [Model]?
    public var daily: [Day]?
    public var periodDays: Int?
}

// MARK: Plugins hub

/// The dashboard plugins page, from `GET /api/dashboard/plugins/hub`. It lists agent plugins
/// (user-folder, shipped with Hermes, or disabled) and the dashboard's own extensions.
public struct PluginsHub: Sendable, Codable {
    public struct Plugin: Identifiable, Hashable, Sendable, Codable {
        public var removedReason: String?
        public var authCommand: String?
        public var path: String?
        /// "enabled", "disabled", "bundled" or "".
        public var runtimeStatus: String?
        /// Origin of the plugin: "user", "bundled", "git" and similar.
        public var source: String?
        public var description: String?
        public var version: String?
        public var name: String
        public var canUpdateGit: Bool?
        public var canRemove: Bool?
        public var authRequired: Bool?
        public var userHidden: Bool?
        public var hasDashboardManifest: Bool?

        public var id: String { name }
    }

    public var plugins: [Plugin]
}
