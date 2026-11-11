import Foundation
import NollieCore

/// Only setup choices live here. Connections and credentials keep their existing stores;
/// permission and service checks are read again whenever setup resumes.
struct OnboardingPreferences: Codable, Equatable, Sendable {
    var assistantName = "Nollie"
    var includeHelpers = false
    var modelMode: ModelSetupMode = .local
    /// The person picked where Nollie thinks (on the model step or in Settings), so setup never
    /// changes it for them.
    var modelModeChosen = false

    init(assistantName: String = "Nollie", includeHelpers: Bool = false, modelMode: ModelSetupMode = .local,
         modelModeChosen: Bool = false) {
        self.assistantName = assistantName
        self.includeHelpers = includeHelpers
        self.modelMode = modelMode
        self.modelModeChosen = modelModeChosen
    }

    private enum CodingKeys: String, CodingKey { case assistantName, includeHelpers, modelMode, modelModeChosen }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        assistantName = try values.decodeIfPresent(String.self, forKey: .assistantName) ?? "Nollie"
        includeHelpers = try values.decodeIfPresent(Bool.self, forKey: .includeHelpers) ?? false
        modelMode = try values.decodeIfPresent(ModelSetupMode.self, forKey: .modelMode) ?? .local
        modelModeChosen = try values.decodeIfPresent(Bool.self, forKey: .modelModeChosen) ?? false
    }

    /// Starts the model step on what suits the Mac: a plan on one with less memory than a model on
    /// the Mac wants (ModelMemoryGuidance), on this Mac otherwise. Once the person has chosen, their
    /// choice stays. True when the choice changed.
    @discardableResult
    mutating func suggestModelMode(memoryBytes: UInt64?) -> Bool {
        guard !modelModeChosen, memoryBytes != nil else { return false }
        let suggested = ModelMemoryGuidance.suggestedMode(memoryBytes)
        guard suggested != modelMode else { return false }
        modelMode = suggested
        return true
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

extension OnboardingProgress.Step {
    /// The Mac's setup steps with a second pill under Continue that means something else: the model,
    /// where Continue waits for one that answers and Set up later goes on without it, and permissions'
    /// Not now. The computer step is optional, so its Continue already goes on with the switch off.
    var hasLaterPill: Bool { self == .model || self == .permissions }

    /// Continue on an optional step works whatever is chosen: off means go on without it.
    var continueAlwaysWorks: Bool { self == .computer || self == .permissions }

    /// Finish setup later, on the Mac steps without a pill of their own. The computer step has none:
    /// Continue is its one way on.
    var hasSkipPill: Bool { !hasLaterPill && self != .computer }
}

#if os(macOS)
extension OnboardingProgress {
    /// The steps the Mac header counts: those after the path is chosen, before Ready. Counted only once a
    /// path is chosen, so the total never changes under someone.
    var countedSteps: [Step] {
        guard route != nil, ![.welcome, .home, .ready].contains(step) else { return [] }
        return steps.filter { ![.welcome, .home, .ready].contains($0) }
    }

    /// "Step 2 of 6", or nil where the header shows no count.
    var stepCount: (index: Int, total: Int)? {
        guard let index = countedSteps.firstIndex(of: step) else { return nil }
        return (index + 1, countedSteps.count)
    }
}
#endif

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
