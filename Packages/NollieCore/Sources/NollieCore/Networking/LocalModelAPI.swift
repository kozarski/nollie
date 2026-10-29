import Foundation

public struct LocalModelJob: Codable, Equatable, Sendable, Identifiable {
    public var jobId: String
    public var kind: String
    public var target: String
    public var modelId: String?
    public var status: String
    public var phase: String
    public var totalBytes: UInt64?
    public var doneBytes: UInt64
    public var startedAt: Double
    public var canPause: Bool?
    public var canResume: Bool?
    public var pauseRequested: Bool?
    public var id: String { jobId }

    public var fractionCompleted: Double? {
        guard let totalBytes, totalBytes > 0 else { return nil }
        return min(1, Double(doneBytes) / Double(totalBytes))
    }
}

public struct LocalModelQuickstartResult: Decodable, Sendable {
    public var jobId: String
    public var modelId: String
    public var displayName: String
    public var needsRuntime: Bool
    public var needsDownload: Bool
    public var downloadBytes: UInt64
}

public struct LocalModelReplyResult: Decodable, Sendable {
    public var provider: String
    public var model: String
    public var text: String
}

/// The existing local-model job routes. No retry of a start request: a lost reply can
/// still mean the server accepted it. Callers recover that job before offering a new start.
public struct LocalModelAPI: Sendable {
    public typealias Request = @Sendable (String, String, Data?) async throws -> Data
    private let request: Request

    public init(api: HermesAPI, profile: String) {
        request = { method, path, body in
            let (data, _) = try await api.raw(method, path, profile: profile,
                body: body.map { ($0, "application/json") }, authenticated: true,
                timeout: path == "/api/nollie/local-model/reply-check" ? 190 : nil)
            return data
        }
    }

    public init(request: @escaping Request) { self.request = request }

    public func quickstart(catalogID: String) async throws -> LocalModelQuickstartResult {
        try Self.validate(catalogID)
        return try await call("POST", "/api/local-models/quickstart", body: ["model_id": catalogID])
    }

    public func job(id: String) async throws -> LocalModelJob {
        try Self.validate(id)
        return try await call("GET", "/api/local-models/jobs/" + id)
    }

    public func jobs() async throws -> [LocalModelJob] {
        struct Response: Decodable { var jobs: [LocalModelJob] }
        let result: Response = try await call("GET", "/api/local-models/jobs")
        return result.jobs
    }

    public func pause(id: String) async throws {
        try Self.validate(id)
        let _: ActionResult = try await call("POST", "/api/local-models/download/pause", body: ["job_id": id])
    }

    public func resume(id: String) async throws {
        try Self.validate(id)
        let _: ActionResult = try await call("POST", "/api/local-models/download/resume", body: ["job_id": id])
    }

    public func selectedModel() async throws -> ModelOptionsResult {
        try await call("GET", "/api/model/options")
    }

    /// Available only on the app-managed runtime. The server chooses its configured
    /// local model and sends a fixed greeting directly to its owned engine.
    public func firstReply() async throws -> LocalModelReplyResult {
        try await call("POST", "/api/nollie/local-model/reply-check", body: [:])
    }

    private struct ActionResult: Decodable { var ok: Bool }

    private func call<T: Decodable>(_ method: String, _ path: String, body: [String: String]? = nil) async throws -> T {
        try Task.checkCancellation()
        let encoded = try body.map { try JSONEncoder().encode($0) }
        let data = try await request(method, path, encoded)
        try Task.checkCancellation()
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(T.self, from: data)
    }

    private static func validate(_ id: String) throws {
        guard !id.isEmpty, id.utf8.count <= 200,
              id.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || [45, 46, 95].contains($0) }) else {
            throw HermesAPIError.decoding(String(localized: "Invalid local model identifier", table: "Core"))
        }
    }
}
