import Foundation
import NollieCore

struct LocalModelHardware: Decodable, Equatable, Sendable {
    var uma: Bool?
    var vramTotalBytes: UInt64?
    var vramUsableBytes: UInt64?
    var ramTotalBytes: UInt64?
    var ramAvailableBytes: UInt64?
    var gpuName: String?

    var summary: String {
        guard let total = ramTotalBytes, total > 0 else { return String(localized: "Hermes computer memory is not available.") }
        let memory = ByteCountFormatter.string(fromByteCount: Int64(clamping: total), countStyle: .memory)
        return uma == true ? String(localized: "\(memory) shared memory on your Hermes computer", comment: "%@ is an amount of memory, such as 16 GB")
            : String(localized: "\(memory) memory on your Hermes computer", comment: "%@ is an amount of memory, such as 16 GB")
    }
}

struct LocalModelCatalogEntry: Decodable, Equatable, Identifiable, Sendable {
    let id: String
    var displayName: String
    var description: String?
    var recommended: Bool?
    var recommendedReason: String?
    var fits: Bool?
    var spilled: Bool?
    var needsEngine: Bool?
    var modelId: String?
    var downloaded: Bool?
    var downloadedModelId: String?
    var sizeBytes: UInt64?
    var startWindow: Int?
    var nativeContext: Int?
    var fitSummary: String?
    var quantValidated: Bool?

    var downloadLabel: String {
        guard let bytes = sizeBytes, bytes > 0 else { return String(localized: "Download size not available") }
        return ByteCountFormatter.string(fromByteCount: Int64(clamping: bytes), countStyle: .file)
    }

    /// File size alone omits context, buffers and vision assets. Hermes prices the launch plan.
    var isRecommendedCandidate: Bool {
        recommended == true && fits == true && spilled == false && needsEngine == false
            && modelId?.isEmpty == false && sizeBytes.map { $0 > 0 } == true
            && startWindow.map { $0 > 0 } == true
    }
}

/// Decode status only when an authorized flow already supplied it. The installed Hermes
/// GET /status can adopt legacy model files, so the inspection client intentionally skips it.
struct LocalModelRuntimeStatus: Decodable, Equatable, Sendable {
    var enabled: Bool?
    var runtimeInstalled: Bool?
    var serverRunning: Bool?
    var activeModelId: String?
}

enum LocalModelSetupIssue: Equatable, Sendable {
    case unsupported, signInRequired, unavailable, invalidResponse

    var message: String {
        switch self {
        case .unsupported: String(localized: "This Hermes version does not offer local model setup here.")
        case .signInRequired: String(localized: "Sign in to your Hermes connection to check local models.")
        case .unavailable: String(localized: "Could not check local models. Try again when the connection is ready.")
        case .invalidResponse: String(localized: "Hermes returned incomplete model information. No model was selected.")
        }
    }
}

struct LocalModelSetupSnapshot: Equatable, Sendable {
    var hardware: LocalModelHardware?
    var models: [LocalModelCatalogEntry]
    var hardwareIssue: LocalModelSetupIssue?
    var catalogIssue: LocalModelSetupIssue?

    var recommended: LocalModelCatalogEntry? {
        guard hardware?.ramTotalBytes.map({ $0 > 0 }) == true, hardwareIssue == nil, catalogIssue == nil else { return nil }
        return models.first(where: \.isRecommendedCandidate)
    }

    var summary: String {
        if let catalogIssue { return catalogIssue.message }
        if let hardwareIssue { return hardwareIssue.message }
        if let model = recommended {
            return String(localized: "\(model.displayName) is Hermes' suggested fit for this computer. Review its \(model.downloadLabel) model download before continuing.",
                          comment: "The first %@ is a model name, the second its download size")
        }
        return String(localized: "Hermes has no automatic recommendation for this computer. You can review models that fit or keep your current setup.")
    }
}

/// Uses only the authenticated hardware and catalog reads. Inspection never changes a provider,
/// installs an engine, downloads weights, starts a server or selects a cloud fallback.
struct LocalModelSetupClient: Sendable {
    private let read: @Sendable (String) async throws -> Data

    init(api: HermesAPI) {
        read = { path in
            let (data, _) = try await api.raw("GET", path, body: nil, authenticated: true)
            return data
        }
    }

    init(read: @escaping @Sendable (String) async throws -> Data) { self.read = read }

    func inspect() async throws -> LocalModelSetupSnapshot {
        try Task.checkCancellation()
        async let hardware: ReadResult<LocalModelHardware> = fetch("/api/local-models/hardware")
        async let catalog: ReadResult<Catalog> = fetch("/api/local-models/catalog")
        let (facts, choices) = try await (hardware, catalog)
        try Task.checkCancellation()
        return LocalModelSetupSnapshot(hardware: facts.value, models: choices.value?.models ?? [],
                                       hardwareIssue: facts.issue, catalogIssue: choices.issue)
    }

    private struct Catalog: Decodable, Sendable { var models: [LocalModelCatalogEntry] }
    private struct ReadResult<Value: Sendable>: Sendable { var value: Value?; var issue: LocalModelSetupIssue? }

    private func fetch<Value: Decodable & Sendable>(_ path: String) async throws -> ReadResult<Value> {
        do {
            let data = try await read(path)
            try Task.checkCancellation()
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            return ReadResult(value: try decoder.decode(Value.self, from: data), issue: nil)
        } catch is CancellationError { throw CancellationError() }
        catch {
            try Task.checkCancellation()
            let issue: LocalModelSetupIssue
            switch error {
            case HermesAPIError.http(404, _): issue = .unsupported
            case HermesAPIError.unauthorized, HermesAPIError.sessionExpired: issue = .signInRequired
            case HermesAPIError.http(401, _), HermesAPIError.http(403, _): issue = .signInRequired
            case is DecodingError: issue = .invalidResponse
            default: issue = .unavailable
            }
            return ReadResult(value: nil, issue: issue)
        }
    }
}
