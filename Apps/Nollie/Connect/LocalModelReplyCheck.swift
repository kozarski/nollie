import Foundation
import NollieCore

enum LocalModelReplyEvidence {
    static func completedReply(_ result: LocalModelReplyResult, expectedModel: String) throws -> String {
        guard result.provider == "llamacpp", result.model == expectedModel,
              result.text.count <= 4096 else { throw LocalModelCheckFailure.changed }
        let clean = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { throw LocalModelCheckFailure.incomplete }
        return clean
    }
}

@MainActor
enum LocalModelReplyCheck {
    static func run(api: LocalModelAPI, model: String, isCurrent: @escaping @MainActor () -> Bool) async throws -> String {
        guard isCurrent(), !Task.isCancelled else { throw CancellationError() }
        let result = try await api.firstReply()
        guard isCurrent(), !Task.isCancelled else { throw CancellationError() }
        return try LocalModelReplyEvidence.completedReply(result, expectedModel: model)
    }
}
