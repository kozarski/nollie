import Foundation
import CloudKit
import NollieCore

struct CloudAlertObservedSession: Codable, Sendable {
    let id: String
    let profile: String?
    let lastActive: Double?
    let messageCount: Int?
    var signature: String { "\(lastActive ?? 0):\(messageCount ?? 0)" }
}

struct CloudAlertObservedMessages: Codable, Sendable {
    let profile: String
    let messages: [TranscriptMessage]
    var sessionID: String? = nil

    enum CodingKeys: String, CodingKey { case profile, messages; case sessionID = "sessionId" }
}

@MainActor
protocol CloudAlertOutcomeSource {
    func gatewayIdentity() async throws -> String?
    func sessions(profile: String) async throws -> [CloudAlertObservedSession]
    func messages(sessionID: String, profile: String) async throws -> CloudAlertObservedMessages
}

/// Read-only HTTP polling avoids attaching a socket to a chat or becoming its approval handler.
@MainActor
final class HermesCloudAlertOutcomeSource: CloudAlertOutcomeSource {
    private let api: HermesAPI
    init(api: HermesAPI) { self.api = api }
    init(connection: GatewayConnection, store: ConnectionStore) async {
        let secrets = store.secrets(for: connection.id)
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 30
        api = HermesAPI(gateway: connection.gateway, signer: RequestSigner(authMode: connection.authMode, secrets: secrets),
                        urlSession: URLSession(configuration: config))
        if connection.authMode.usesBearer {
            await api.setRefresher {
                let current = await store.secrets(for: connection.id)
                if current != secrets { return RequestSigner(authMode: connection.authMode, secrets: current) }
                let renewed = try await NativeAuthClient.refresh(gateway: connection.gateway, secrets: current)
                await store.saveSecrets(renewed, for: connection.id)
                return RequestSigner(authMode: connection.authMode, secrets: renewed)
            }
        }
    }

    func gatewayIdentity() async throws -> String? {
        let status: GatewayStatusResponse = try await api.get("/api/status", profile: "default")
        return status.installId.flatMap { GatewayIdentity.fingerprint(installID: $0) }
    }

    func sessions(profile: String) async throws -> [CloudAlertObservedSession] {
        guard CloudAlertHelperConfiguration.permitsProfile(profile) else { throw CloudAlertHelperFailure.invalidConsent }
        struct Response: Decodable {
            let sessions: [CloudAlertObservedSession]
            let errors: [JSONValue]?
        }
        let response: Response = try await api.get("/api/profiles/sessions", query: [
            URLQueryItem(name: "limit", value: "50"), URLQueryItem(name: "order", value: "recent"),
            URLQueryItem(name: "archived", value: "exclude")], profile: profile)
        guard response.errors?.isEmpty != false else { throw CloudAlertHelperFailure.unavailable }
        return response.sessions.filter { $0.profile == profile }
    }

    func messages(sessionID: String, profile: String) async throws -> CloudAlertObservedMessages {
        guard CloudAlertHelperConfiguration.permitsProfile(profile),
              CloudAlertHelperConfiguration.permitsSessionID(sessionID) else { throw CloudAlertHelperFailure.invalidConsent }
        // GatewayURL encodes the path once. The validated ID contains only letters, digits,
        // underscores and hyphens; pre-encoding here would turn an underscore into %255F.
        return try await api.get("/api/sessions/\(sessionID)/messages", query: [
            URLQueryItem(name: "order", value: "latest"), URLQueryItem(name: "limit", value: "12"),
            URLQueryItem(name: "inline_images", value: "false")], profile: profile)
    }
}

enum CloudAlertHelperFailure: Error, Equatable {
    case invalidConsent, configurationChanged, mainChatUnknown, unavailable, journalDamaged, expired, accountChanged
}

/// Fixed local classifications only. Error descriptions can contain URLs, response bodies or credentials.
enum CloudAlertHelperIssue: String, CaseIterable, Sendable {
    case signInRequired, sessionNotFound, responseInvalid, serverRejected, gatewayUnavailable
    case journalDamaged, localStorageUnavailable, iCloudUnavailable, retrying

    static func classify(_ error: Error) -> Self {
        if let api = error as? HermesAPIError {
            switch api {
            case .unauthorized, .sessionExpired: return .signInRequired
            case .http(let status, _): return status == 404 ? .sessionNotFound : .serverRejected
            case .decoding, .htmlResponse: return .responseInvalid
            case .transport: return .gatewayUnavailable
            }
        }
        if error as? CloudAlertHelperFailure == .journalDamaged { return .journalDamaged }
        let domain = (error as NSError).domain
        if domain == CKErrorDomain { return .iCloudUnavailable }
        if domain == NSCocoaErrorDomain { return .localStorageUnavailable }
        if domain == NSURLErrorDomain { return .gatewayUnavailable }
        return .retrying
    }
}

enum CloudAlertOutcomePolicy {
    /// Only persisted terminal rows qualify. A pause in streaming is not completion.
    static func latest(in messages: [TranscriptMessage], since: Date, now: Date) -> (rowID: Int, kind: CloudAlertKind, at: Date, preview: CloudAlertPreview)? {
        // Hermes can persist a promoted answer as empty content plus api_content. Match the
        // transcript's displayed answer before applying quiet-turn filtering; never promote raw reasoning.
        let presented = messages.map { message in
            guard message.role == "assistant",
                  (message.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  let answer = message.apiContent,
                  !answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return message }
            var copy = message
            copy.text = answer
            return copy
        }
        let visible = AutomatedReply.previewMessages(presented)
        guard let last = visible.last, last.role == "assistant" || last.role == "error", !last.hasToolCalls,
              let id = last.rowId, id > 0, let timestamp = last.timestamp else { return nil }
        let at = Date(timeIntervalSince1970: timestamp)
        guard at >= since, at > now.addingTimeInterval(-24 * 3600), at <= now.addingTimeInterval(60) else { return nil }
        if last.role == "error" || last.displayKind == "failed_turn" || ["error", "failed"].contains(last.finishReason ?? "") {
            return (id, .needsAttention, at, CloudAlertPreview(title: "Nollie needs attention", body: "Open the conversation to see what needs your help."))
        }
        // A length-limited fragment may still be followed by Hermes' automatic continuation.
        guard last.finishReason == "stop", !(last.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return (id, .replyReady, at, CloudAlertPreview(body: last.text ?? ""))
    }

    static func retryDelay(attempt: Int) -> TimeInterval {
        min(15 * 60, 20 * pow(2, Double(max(0, min(attempt - 1, 6)))))
    }
}

@MainActor
protocol CloudAlertHelperPersistence {
    func load(consentID: UUID) throws -> CloudAlertHelperJournal
    func save(_ journal: CloudAlertHelperJournal) throws
}

/// The helper's private sandbox holds its bounded outbox. The app never assumes its defaults are shared.
@MainActor
final class FileCloudAlertHelperPersistence: CloudAlertHelperPersistence {
    private let directory: URL
    init(directory: URL) { self.directory = directory }
    private var file: URL { directory.appendingPathComponent("alert-outbox-v1.json") }

    func load(consentID: UUID) throws -> CloudAlertHelperJournal {
        guard FileManager.default.fileExists(atPath: file.path) else { return .init(consentID: consentID) }
        let values = try file.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey, .fileSizeKey])
        guard values.isSymbolicLink != true, values.isRegularFile == true, (values.fileSize ?? Int.max) < 4_000_000,
              let journal = try? JSONDecoder().decode(CloudAlertHelperJournal.self, from: Data(contentsOf: file)),
              journal.version == 1 else { throw CloudAlertHelperFailure.journalDamaged }
        return journal.consentID == consentID ? journal : .init(consentID: consentID)
    }

    func save(_ journal: CloudAlertHelperJournal) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let values = try directory.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
        guard values.isSymbolicLink != true, values.isDirectory == true else { throw CloudAlertHelperFailure.journalDamaged }
        let data = try JSONEncoder().encode(journal)
        guard data.count < 4_000_000 else { throw CloudAlertHelperFailure.journalDamaged }
        try data.write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        try handle.synchronize()
    }
}

@MainActor
final class CloudAlertHelperObserver {
    private let source: any CloudAlertOutcomeSource
    private let cloud: any CloudAlertStore
    private let persistence: any CloudAlertHelperPersistence
    private let consent: () -> CloudAlertHelperConfiguration?
    private let now: () -> Date
    private let gatewayFingerprint: String?

    init(source: any CloudAlertOutcomeSource, cloud: any CloudAlertStore,
         persistence: any CloudAlertHelperPersistence,
         consent: @escaping () -> CloudAlertHelperConfiguration?, now: @escaping () -> Date = Date.init,
         gatewayFingerprint: String? = nil) {
        self.source = source; self.cloud = cloud; self.persistence = persistence; self.consent = consent; self.now = now
        self.gatewayFingerprint = gatewayFingerprint
    }

    func tick(_ config: CloudAlertHelperConfiguration) async throws -> Int {
        try validate(config)
        var journal = try persistence.load(consentID: config.consentID)
        journal.prune(now: now())
        guard try await cloud.accountFingerprint() == config.accountFingerprint else { throw CloudAlertHelperFailure.accountChanged }
        try validate(config)
        guard try await cloud.enabled() else { throw CloudAlertHelperFailure.expired }
        try validate(config)
        // Already verified outcomes can still be delivered if Hermes is temporarily offline.
        try await deliverPending(config, journal: &journal)
        // The ordinary session list deliberately excludes hidden Bot Chats. An app-supplied
        // canonical ID lets this read-only helper include the main conversation without a socket.
        guard config.profiles == ["default"], let canonicalID = config.canonicalSessions?["default"] else {
            throw CloudAlertHelperFailure.mainChatUnknown
        }
        for profile in config.profiles {
            try validate(config)
            var sessions = try await source.sessions(profile: profile)
            // A protected read succeeded on this saved endpoint before its public identity is used.
            let gatewayIdentity = try? await source.gatewayIdentity()
            try validate(config)
            sessions.removeAll { $0.id == canonicalID }
            sessions.insert(.init(id: canonicalID, profile: profile, lastActive: nil, messageCount: nil), at: 0)
            for session in sessions where session.profile == profile {
                try validate(config)
                let scope = CloudAlertEvent.digest(config.connectionID.uuidString + "/" + profile + "/" + session.id)
                let canonical = session.id == canonicalID
                if !canonical {
                    guard let active = session.lastActive, active >= config.enabledAt.timeIntervalSince1970,
                          active > now().timeIntervalSince1970 - 24 * 3600 else { continue }
                    if journal.checkpoints[scope] == session.signature { continue }
                }
                let page = try await source.messages(sessionID: session.id, profile: profile)
                try validate(config)
                guard page.profile == profile else { throw CloudAlertHelperFailure.invalidConsent }
                guard let outcome = CloudAlertOutcomePolicy.latest(in: page.messages, since: config.enabledAt, now: now()) else { continue }
                let key = "outcome/\(config.connectionID)/\(profile)/\(outcome.rowID)"
                let target = gatewayFingerprint.map {
                    CloudAlertTarget(connectionID: config.connectionID, gatewayFingerprint: $0, profile: profile,
                                     sessionID: page.sessionID ?? session.id, messageRowID: outcome.rowID, gatewayIdentity: gatewayIdentity)
                }
                guard target?.isValid != false else { throw CloudAlertHelperFailure.invalidConsent }
                let event = CloudAlertEvent(source: config.source, key: key, kind: outcome.kind, now: outcome.at,
                                            target: target, preview: outcome.preview)
                // Canonical reads follow compression on the server. Their durable row timestamps
                // enforce the opt-in baseline even when the list has no activity metadata.
                if !canonical { journal.checkpoints[scope] = session.signature }
                if journal.seen[event.id] == nil, journal.pending[event.id] == nil {
                    journal.pending[event.id] = CloudAlertHelperPending(event)
                }
                // The durable outbox is committed before any CloudKit call.
                try persistence.save(journal)
            }
        }
        try persistence.save(journal)
        try await deliverPending(config, journal: &journal)
        if journal.lastCleanup.map({ now().timeIntervalSince($0) > 3600 }) ?? true {
            try validate(config)
            guard try await cloud.accountFingerprint() == config.accountFingerprint else { throw CloudAlertHelperFailure.accountChanged }
            try validate(config)
            try? await cloud.cleanExpired(source: CloudAlertEvent.digest(config.source), before: now())
            journal.lastCleanup = now()
            try persistence.save(journal)
        }
        return journal.pending.count
    }

    private func deliverPending(_ config: CloudAlertHelperConfiguration, journal: inout CloudAlertHelperJournal) async throws {
        for pending in journal.pending.values.sorted(by: { $0.createdAt < $1.createdAt }).prefix(20) where pending.nextAttempt <= now() {
            try validate(config)
            guard try await cloud.accountFingerprint() == config.accountFingerprint else { throw CloudAlertHelperFailure.accountChanged }
            try validate(config)
            guard try await cloud.enabled() else { throw CloudAlertHelperFailure.expired }
            try validate(config)
            do {
                try await cloud.create(pending.event)
                journal.pending.removeValue(forKey: pending.id)
                journal.seen[pending.id] = now()
                try persistence.save(journal)
            } catch {
                var retry = pending
                retry.attempts += 1
                retry.nextAttempt = now().addingTimeInterval(CloudAlertOutcomePolicy.retryDelay(attempt: retry.attempts))
                journal.pending[retry.id] = retry
                try persistence.save(journal)
                throw error
            }
        }
    }

    private func validate(_ expected: CloudAlertHelperConfiguration) throws {
        guard !Task.isCancelled, expected.enabled, expected.isValid,
              let current = consent(), current.enabled, current.isValid,
              current.hasSameConsent(as: expected) else { throw CloudAlertHelperFailure.invalidConsent }
        guard current == expected else { throw CloudAlertHelperFailure.configurationChanged }
    }
}
