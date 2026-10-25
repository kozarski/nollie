import Foundation

/// A helper's request to sign in, as the workflow add-on keeps it while it is open
/// (`GET /api/plugins/nollie-workflow/sign-ins/requests`). It holds no secret.
public struct SignInRequest: Decodable, Equatable, Sendable, Identifiable {
    public var id: String
    public var bot: String
    public var site: String
    /// The helper's computer: "mac" for this Mac, otherwise its Cua computer (`local:dev`).
    public var computer: String
    /// Which box had focus when it asked: "username" or "password".
    public var focus: String
    /// "asking", "approved", "filling" or "done".
    public var state: String
    /// "mac" or "iphone": which device answered, when one said so.
    public var approver: String?
    public var createdAt: Int

    public init(id: String, bot: String, site: String, computer: String, focus: String = "username",
                state: String, approver: String? = nil, createdAt: Int = 0) {
        self.id = id; self.bot = bot; self.site = site; self.computer = computer; self.focus = focus
        self.state = state; self.approver = approver; self.createdAt = createdAt
    }
}

/// One use, for the history in Settings > Sign-ins: when, which bot, which site, who said yes
/// and how it went. Never the username, the password or the note.
public struct SignInHistoryEntry: Decodable, Equatable, Sendable, Identifiable {
    public var at: Int
    public var bot: String
    public var site: String
    /// "signed_in", "declined", "no_answer", "not_saved", "cancelled", "expired", "interrupted" or "failed".
    public var outcome: String
    public var approver: String?
    /// "mac", "space" or nil.
    public var computer: String?
    public var id: String { "\(at)-\(bot)-\(site)-\(outcome)" }

    public init(at: Int, bot: String, site: String, outcome: String, approver: String? = nil, computer: String? = nil) {
        self.at = at; self.bot = bot; self.site = site; self.outcome = outcome; self.approver = approver; self.computer = computer
    }
}

/// Why the Mac did not sign a helper in, in the add-on's fixed words (never free text).
public enum SignInFailure: String, Error, Sendable, Equatable {
    case notSavedHere = "not_saved_here"
    case fillUnavailable = "fill_unavailable"
    case computerUnavailable = "computer_unavailable"
    case fillFailed = "fill_failed"
    case privateBot = "private"
    case touchID = "touch_id"
}

/// The approval card's question when it is a sign-in: the add-on asks through Hermes's own gate
/// with the rule `plugin_rule:nollie-sign-in:<request id>` and the words "Sign in to <site>".
public struct SignInAsk: Equatable, Sendable {
    public static let rulePrefix = "plugin_rule:nollie-sign-in:"
    public var requestID: String
    public var site: String

    public init?(_ approval: ApprovalRequest?) {
        guard let approval, let key = approval.patternKey, key.hasPrefix(Self.rulePrefix) else { return nil }
        let id = String(key.dropFirst(Self.rulePrefix.count))
        guard id.count == 32, id.allSatisfy({ $0.isHexDigit && !$0.isUppercase }) else { return nil }
        let words = approval.description ?? ""
        guard words.hasPrefix("Sign in to "), let site = SignInSite.normalize(String(words.dropFirst("Sign in to ".count))),
              site == String(words.dropFirst("Sign in to ".count)) else { return nil }
        requestID = id
        self.site = site
    }

    public init(requestID: String, site: String) {
        self.requestID = requestID
        self.site = site
    }
}

private struct SignInSitesBody: Codable, Sendable { var sites: [String] }
private struct SignInRequestsReply: Decodable, Sendable { var requests: [SignInRequest] }
private struct SignInHistoryReply: Decodable, Sendable { var entries: [SignInHistoryEntry] }

@MainActor
extension GatewayRuntime {
    public static let signInsPath = "/api/plugins/nollie-workflow/sign-ins"

    /// Whether this connection is a gateway on this very Mac: the only one whose helpers Nollie
    /// signs in, and the only one told which sites are saved.
    public var gatewayIsOnThisMac: Bool {
        ["127.0.0.1", "localhost", "::1", "[::1]"].contains(connection.gateway.host.lowercased())
    }

    /// Tells the add-on which sites have a saved sign-in. Sites only.
    public func saveSignInSites(_ sites: [String]) async throws {
        let _: SignInSitesBody = try await api.send("PUT", Self.signInsPath + "/sites", body: SignInSitesBody(sites: sites))
    }

    public func signInRequests() async throws -> [SignInRequest] {
        let reply: SignInRequestsReply = try await api.get(Self.signInsPath + "/requests")
        return reply.requests
    }

    public func signInRequest(_ id: String) async throws -> SignInRequest {
        try await api.get(Self.signInsPath + "/requests/" + id)
    }

    /// Says which device is answering, before it answers the card. False when another device
    /// already did or the request is over (409).
    public func claimSignIn(_ id: String, approver: String) async throws -> Bool {
        do {
            let _: SignInRequest = try await api.send("POST", Self.signInsPath + "/requests/\(id)/claim",
                                                      json: ["approver": .string(approver)])
            return true
        } catch HermesAPIError.http(status: 409, _) { return false }
    }

    /// The Mac is about to type. False when the helper stopped waiting or another Mac started (409).
    public func startSignInFill(_ id: String) async throws -> Bool {
        do {
            let _: SignInRequest = try await api.send("POST", Self.signInsPath + "/requests/\(id)/start", json: .object([:]))
            return true
        } catch HermesAPIError.http(status: 409, _) { return false }
    }

    /// How it went: signed in (and whether the site may ask for a code), cancelled, or failed with a reason.
    public func reportSignIn(_ id: String, outcome: String, reason: SignInFailure? = nil, codeNote: Bool = false) async throws {
        var body: [String: JSONValue] = ["outcome": .string(outcome), "code_note": .bool(codeNote)]
        if let reason { body["reason"] = .string(reason.rawValue) }
        let _: SignInRequest = try await api.send("POST", Self.signInsPath + "/requests/\(id)/result", json: .object(body))
    }

    public func signInHistory(days: Int = 30) async throws -> [SignInHistoryEntry] {
        let reply: SignInHistoryReply = try await api.get(Self.signInsPath + "/history",
                                                          query: [URLQueryItem(name: "days", value: String(days))])
        return reply.entries
    }
}
