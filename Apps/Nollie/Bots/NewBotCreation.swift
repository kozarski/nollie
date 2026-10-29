import Foundation
import Observation

/// A create request can leave a real profile behind even when its model could not be saved.
/// Keep that identity until verification finishes; an uncertain POST is never repeated.
@MainActor @Observable
final class NewBotCreation {
    struct Selection: Equatable, Sendable {
        var provider: String
        var model: String
        var isComplete: Bool { !provider.isEmpty && !model.isEmpty }
    }

    struct Request: Encodable, Equatable, Sendable {
        var name: String
        var description: String?
        var cloneFrom: String?
        var provider: String?
        var model: String?

        var selection: Selection? {
            guard let provider, let model else { return nil }
            return Selection(provider: provider, model: model)
        }
        var isConfigured: Bool { selection?.isComplete == true || (provider == nil && model == nil && cloneFrom?.isEmpty == false) }
    }

    struct Acknowledgement: Decodable, Sendable {
        var ok: Bool
        var name: String
        var modelSet: Bool?
    }

    enum Phase: Equatable { case new, unconfirmed, created, verified }
    private(set) var phase: Phase = .new
    private(set) var request: Request?
    private(set) var issue: String?
    private(set) var isBusy = false

    func submit(
        _ proposed: Request,
        allowed: () -> Bool,
        create: (Request) async throws -> Acknowledgement,
        setModel: (String, Selection) async throws -> Void,
        readModel: (String) async throws -> Selection
    ) async -> Bool {
        guard !isBusy, allowed(), !Task.isCancelled else { return false }
        guard proposed.isConfigured else {
            issue = String(localized: "Choose a model, or choose a bot to copy.")
            return false
        }
        isBusy = true
        issue = nil
        defer { isBusy = false }
        let draft = request ?? proposed
        do {
            if phase == .new {
                request = draft
                phase = .unconfirmed
                let acknowledgement = try await create(draft)
                // Retain an acknowledged identity even if the view was locked during the request.
                guard acknowledgement.ok, acknowledgement.name == draft.name else { throw CreationError.unconfirmed }
                phase = .created
                guard allowed(), !Task.isCancelled else { throw CancellationError() }
                if draft.selection != nil, acknowledgement.modelSet != true { throw CreationError.modelNotSaved }
            } else if phase == .created, let selection = draft.selection {
                // Only a positively acknowledged profile may be repaired after a partial create.
                try await setModel(draft.name, selection)
                guard allowed(), !Task.isCancelled else { throw CancellationError() }
            }

            let actual = try await readModel(draft.name)
            guard allowed(), !Task.isCancelled else { throw CancellationError() }
            guard phase != .unconfirmed else { throw CreationError.unconfirmed }
            guard actual.isComplete, draft.selection.map({ $0 == actual }) ?? true else { throw CreationError.modelMismatch }
            phase = .verified
            return true
        } catch {
            if phase == .unconfirmed {
                issue = String(localized: "The creation response was lost. Check Bots for \(draft.name) before trying a different name. Checking again will not create another bot.")
            } else if error is CancellationError {
                issue = String(localized: "\(draft.name) was created. Its model still needs checking.")
            } else {
                issue = String(localized: "\(draft.name) was created, but its model was not confirmed. Retry setup to save and check the chosen model.")
            }
            return false
        }
    }

    private enum CreationError: Error { case unconfirmed, modelNotSaved, modelMismatch }
}
