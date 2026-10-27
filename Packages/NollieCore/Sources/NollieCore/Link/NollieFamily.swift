import Foundation

// Sharing a helper with someone at home (Docs/specs/family-sharing.md). The Mac's door decides
// everything; these are the phone's and the Mac app's view of its answers.

/// Who this device is to the Mac: `GET /nollie/family/me`.
public struct NollieFamilyMe: Decodable, Sendable, Equatable {
    public var role: String
    /// For someone at home: the owner's first name, their own name as the owner typed it, the
    /// helpers shared with them, and whether they may say yes to their own small asks.
    public var owner: String?
    public var person: String?
    public var helpers: [String]?
    public var small: Bool?

    public init(role: String, owner: String? = nil, person: String? = nil, helpers: [String]? = nil, small: Bool? = nil) {
        self.role = role
        self.owner = owner
        self.person = person
        self.helpers = helpers
        self.small = small
    }

    public var isMember: Bool { role == "member" }
}

/// Someone at home and the helpers shared with them.
public struct NollieFamilyMember: Decodable, Sendable, Equatable, Identifiable {
    public var id: String
    public var person: String
    /// Their iPhone's name.
    public var device: String
    public var helpers: [String]
    public var small: Bool
    public var linkedAt: Double
    public var lastActive: Double?

    public init(id: String, person: String, device: String, helpers: [String], small: Bool = false,
                linkedAt: Double = 0, lastActive: Double? = nil) {
        self.id = id
        self.person = person
        self.device = device
        self.helpers = helpers
        self.small = small
        self.linkedAt = linkedAt
        self.lastActive = lastActive
    }
}

/// An approval from a shared helper's chat, waiting on the owner.
public struct NollieFamilyAsk: Decodable, Sendable, Equatable, Identifiable {
    public var id: String
    public var person: String
    /// The helper's profile (the household copy).
    public var helper: String
    public var chat: String
    public var small: Bool
    public var at: Double
    /// What Hermes said about it: description, the command as Hermes redacted it, rule keys, choices.
    public var request: JSONValue

    public init(id: String, person: String, helper: String, chat: String, small: Bool = false, at: Double, request: JSONValue) {
        self.id = id
        self.person = person
        self.helper = helper
        self.chat = chat
        self.small = small
        self.at = at
        self.request = request
    }

    /// The ask as the app's approval cards read one. Only Allow once and Deny are offered to the owner.
    public var approval: ApprovalRequest {
        let keys = field("pattern_keys")?.arrayValue?.compactMap(\.stringValue) ?? []
        return ApprovalRequest(requestId: field("request_id")?.stringValue ?? id, sessionId: chat,
                               command: field("command")?.stringValue, description: field("description")?.stringValue,
                               choices: ["once", "deny"], toolName: field("tool_name")?.stringValue,
                               smartDenied: field("smart_denied")?.boolValue,
                               patternKey: field("pattern_key")?.stringValue ?? keys.first)
    }

    /// A field of the request by Hermes's name, or as the app's decoder renamed it (`request_id`, `requestId`).
    private func field(_ name: String) -> JSONValue? {
        if let found = request[name] { return found }
        let parts = name.split(separator: "_")
        let camel = (parts.first.map(String.init) ?? "") + parts.dropFirst().map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined()
        return request[camel]
    }
}

public struct NollieFamilyOverview: Decodable, Sendable, Equatable {
    public var members: [NollieFamilyMember]
    public var asks: [NollieFamilyAsk]

    public init(members: [NollieFamilyMember] = [], asks: [NollieFamilyAsk] = []) {
        self.members = members
        self.asks = asks
    }
}

/// A code's fields as the door gives them to an owner's phone.
struct NollieFamilyCode: Decodable {
    var macName: String
    var pin: String
    var port: Int
    var hosts: [String]
    var tag: String
    var secret: String
    var expiresAt: Double
    var owner: String
    var helpers: [String]
}

public enum NollieFamilyClient {
    public static let mePath = "/nollie/family/me"
    public static let overviewPath = "/nollie/family"

    public static func me(_ api: HermesAPI) async throws -> NollieFamilyMe {
        try await api.get(mePath)
    }

    public static func overview(_ api: HermesAPI) async throws -> NollieFamilyOverview {
        try await api.get(overviewPath)
    }

    /// A version 2 code for someone at home, made by the Mac's door.
    public static func invite(_ api: HermesAPI, person: String, helpers: [String]) async throws -> NollieLinkOffer {
        let code: NollieFamilyCode = try await api.send("POST", "/nollie/family/invite",
                                                         json: .object(["person": .string(person), "helpers": .array(helpers.map(JSONValue.string))]))
        return try offer(from: code)
    }

    static func offer(from code: NollieFamilyCode) throws -> NollieLinkOffer {
        guard let pin = NollieLinkOffer.decodeBase64URL(code.pin), let secret = NollieLinkOffer.decodeBase64URL(code.secret),
              let invite = NollieLinkInvite(owner: code.owner, helpers: code.helpers) else { throw NollieLinkError.invalidResponse }
        return try NollieLinkOffer(macName: code.macName, pin: pin, port: code.port, hosts: code.hosts, installTag: code.tag,
                                   secret: secret, expiresAt: Date(timeIntervalSince1970: code.expiresAt), invite: invite)
    }

    public static func update(_ api: HermesAPI, member: String, helpers: [String]? = nil, small: Bool? = nil) async throws -> NollieFamilyOverview {
        var fields: [String: JSONValue] = [:]
        if let helpers { fields["helpers"] = .array(helpers.map(JSONValue.string)) }
        if let small { fields["small"] = .bool(small) }
        return try await api.send("PUT", "/nollie/family/members/\(member)", json: .object(fields))
    }

    public static func remove(_ api: HermesAPI, member: String) async throws -> NollieFamilyOverview {
        let (data, _) = try await api.raw("DELETE", "/nollie/family/members/\(member)", body: nil, authenticated: true)
        return try JSONCoding.decoder.decode(NollieFamilyOverview.self, from: data)
    }

    /// The owner's Allow once ("once") or Deny ("deny").
    public static func answer(_ api: HermesAPI, ask: String, choice: String) async throws -> NollieFamilyOverview {
        try await api.send("POST", "/nollie/family/asks/\(ask)", json: .object(["choice": .string(choice)]))
    }

    /// The household copy's profile name for a person: the helper's with theirs (`career-sam`),
    /// inside Hermes's grammar.
    public static func copyName(helper: String, person: String) -> String {
        let folded = person.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil).lowercased()
        let slug = String(folded.unicodeScalars.filter { ("a"..."z").contains(Character($0)) || ("0"..."9").contains(Character($0)) }
            .map(Character.init).prefix(16))
        let base = String(helper.prefix(64 - 1 - max(slug.count, 4)))
        return base + "-" + (slug.isEmpty ? "home" : slug)
    }
}
