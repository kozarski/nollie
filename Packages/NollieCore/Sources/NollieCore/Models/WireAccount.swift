import Foundation

// Models, bots (profiles), and signing in.

// MARK: Models

/// What a model can do beyond the basics.
public struct ModelCapabilities: Codable, Hashable, Sendable {
    public let fast: Bool?
    public let reasoning: Bool?
    public let canDisableReasoning: Bool?
}

/// A company or service that offers models, with the ones it lists.
public struct ModelProvider: Identifiable, Sendable, Hashable, Codable {
    public var slug: String
    public var name: String
    /// Set when the provider is listed but cannot be used yet, with the reason.
    public var warning: String?
    public var capabilities: [String: ModelCapabilities]?
    public var featuredModels: [String]?
    public var models: [String]?
    public var authenticated: Bool?
    public var isCurrent: Bool?

    public var id: String { slug }

    /// A provider as the gateway lists it. The model lists and warnings come only from decoding.
    public init(slug: String, name: String, isCurrent: Bool? = nil, authenticated: Bool? = nil) {
        self.authenticated = authenticated
        self.isCurrent = isCurrent
        self.name = name
        self.slug = slug
    }
}

/// The model choices on offer, and the model and provider chosen now.
public struct ModelOptionsResult: Hashable, Sendable, Codable {
    public var provider: String?
    public var model: String?
    public var providers: [ModelProvider]

    public init(providers: Array<ModelProvider>, model: Optional<String> = nil, provider: Optional<String> = nil) {
        self.model = model
        self.provider = provider
        self.providers = providers
    }
}

// MARK: Bots

/// A Hermes profile, which the app calls a bot.
public struct ProfileInfo: Hashable, Sendable, Identifiable, Codable {
    public var skillCount: Int?
    public var path: String?
    public var model: String?
    public var botTitle: String?
    public var description: String?
    public var provider: String?
    public var isDefault: Bool?
    public var displayName: String?
    public var name: String

    public init(name: String,
                displayName: Optional<String> = nil,
                isDefault: Optional<Bool> = nil,
                provider: Optional<String> = nil,
                description: Optional<String> = nil,
                botTitle: Optional<String> = nil,
                model: Optional<String> = nil,
                path: Optional<String> = nil,
                skillCount: Optional<Int> = nil) {
        self.skillCount = skillCount
        self.path = path
        self.model = model
        self.botTitle = botTitle
        self.description = description
        self.provider = provider
        self.isDefault = isDefault
        self.displayName = displayName
        self.name = name
    }

    public var id: String { name }

    /// The display name when there is one, else the profile's name.
    public var label: String {
        guard let displayName, !displayName.isEmpty else { return name }
        return displayName
    }
}

public struct ProfilesResponse: Codable, Sendable {
    public let profiles: [ProfileInfo]
    public let installId: String?
}

public struct ActiveProfileResponse: Codable, Sendable {
    public let active: String?
    public let current: String?
}

// MARK: Signing in

public struct AuthMeResponse: Codable, Sendable {
    public let expiresAt: Double?
    public let userId: String?
    public let email: String?
    public let displayName: String?
    public let provider: String?
}

public struct AuthProvider: Codable, Hashable, Sendable, Identifiable {
    public let name: String
    public let displayName: String?
    public let supportsPassword: Bool?

    public var id: String { name }
}

public struct AuthProvidersResponse: Codable, Sendable {
    public let providers: [AuthProvider]
}

public struct GatewayStatusResponse: Codable, Sendable {
    public let authRequired: Bool?
    public let gatewayRunning: Bool?
    public let activeSessions: Int?
    public let authProviders: [String]?
    public let authFlows: [String]?
    public let installId: String?
    public let version: String?
    public let gatewayState: String?
}

public struct NativeTokenResponse: Codable, Sendable {
    public let expiresAt: Double?
    public let accessToken: String
    public let refreshToken: String?
    public let tokenType: String?
    public let provider: String?
    public let userId: String?
}
