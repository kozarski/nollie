import Foundation
import NollieCore

/// Only setup choices live here. Connections and credentials keep their existing stores;
/// permission and service checks are read again whenever setup resumes.
struct OnboardingPreferences: Codable, Equatable, Sendable {
    var assistantName = "Nollie"
    var includeHelpers = false
    var modelMode: ModelSetupMode = .local

    init(assistantName: String = "Nollie", includeHelpers: Bool = false, modelMode: ModelSetupMode = .local) {
        self.assistantName = assistantName
        self.includeHelpers = includeHelpers
        self.modelMode = modelMode
    }

    private enum CodingKeys: String, CodingKey { case assistantName, includeHelpers, modelMode }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        assistantName = try values.decodeIfPresent(String.self, forKey: .assistantName) ?? "Nollie"
        includeHelpers = try values.decodeIfPresent(Bool.self, forKey: .includeHelpers) ?? false
        modelMode = try values.decodeIfPresent(ModelSetupMode.self, forKey: .modelMode) ?? .local
    }

    var resolvedAssistantName: String {
        let name = assistantName.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return name.isEmpty ? "Nollie" : String(name.prefix(32))
    }
}

struct OnboardingProgress: Codable, Equatable, Sendable {
    static let storageKey = "nollie.onboarding.progress.v1"

    enum Step: String, Codable, CaseIterable, Sendable {
        case welcome, home, howItWorks, team, connection, model, computer, permissions, ready
    }
    enum Route: String, Codable, Sendable { case existing, importCopy, new }
    enum Completion: String, Codable, Sendable { case inProgress, completed, skipped }

    var step: Step = .welcome
    var route: Route?
    var preferences = OnboardingPreferences()
    var connectionID: UUID?
    var deferred: Set<Step> = []
    var completion: Completion = .inProgress

    var encoded: String {
        guard let data = try? JSONEncoder().encode(self) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    static func parse(_ raw: String) -> Self {
        guard let data = raw.data(using: .utf8), let saved = try? JSONDecoder().decode(Self.self, from: data) else { return Self() }
        return saved
    }

    static func shouldPresent(hasConnections: Bool, raw: String) -> Bool {
        guard !raw.isEmpty, let data = raw.data(using: .utf8),
              let saved = try? JSONDecoder().decode(Self.self, from: data) else { return !hasConnections }
        return saved.completion == .inProgress
    }

    var steps: [Step] {
        route == .new
            ? [.welcome, .home, .howItWorks, .team, .connection, .model, .computer, .permissions, .ready]
            : [.welcome, .home, .howItWorks, .connection, .model, .computer, .permissions, .ready]
    }

    var previous: Step? {
        guard let index = steps.firstIndex(of: step), index > 0 else { return nil }
        return steps[index - 1]
    }

    mutating func choose(_ route: Route) {
        self.route = route
        step = .howItWorks
    }

    mutating func connected(_ id: UUID) {
        connectionID = id
        completion = .inProgress
        step = .model
    }

    mutating func paired(_ id: UUID) {
        connected(id)
        route = .existing
        deferred = []
        step = .ready
    }

    /// Phone setup connects to an assistant. Installation and model choices stay on the Mac.
    mutating func resumeOnPhone(hasConnection: Bool) {
        guard completion == .inProgress, step != .welcome else { return }
        if hasConnection {
            step = .ready
        } else {
            step = .home
            connectionID = nil
        }
    }

    mutating func advance(deferStep: Bool = false) {
        if deferStep { deferred.insert(step) } else { deferred.remove(step) }
        guard let index = steps.firstIndex(of: step), index + 1 < steps.count else { return }
        step = steps[index + 1]
    }

    mutating func resume(hasConnection: Bool) {
        guard completion == .inProgress else { return }
        if !hasConnection, [.model, .computer, .permissions, .ready].contains(step) {
            step = .connection
            connectionID = nil
        }
    }

    mutating func finish(connected: Bool) {
        guard connected else { return }
        completion = .completed
    }

    mutating func skip() { completion = .skipped }
}

enum OnboardingModelStatus: Equatable {
    case notConfigured
    case needsSignIn(model: String)
    case unverified(model: String)
    case ready(model: String)

    static func read(_ options: ModelOptionsResult) -> Self {
        guard let name = options.model?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else { return .notConfigured }
        let selected = options.provider?.trimmingCharacters(in: .whitespacesAndNewlines)
        let provider: ModelProvider?
        if let selected, !selected.isEmpty {
            provider = options.providers.first { $0.slug == selected }
        } else {
            provider = options.providers.first { $0.isCurrent == true }
        }
        switch provider?.authenticated {
        case true: return .ready(model: name)
        case false: return .needsSignIn(model: name)
        default: return .unverified(model: name)
        }
    }

    var isReady: Bool { if case .ready = self { return true }; return false }
}
