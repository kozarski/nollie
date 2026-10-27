import Foundation
import Network

public enum NollieLinkError: LocalizedError, Equatable, Sendable {
    case invalidOffer, expired, unreachable, identityMismatch, refused(String), invalidResponse

    public var errorDescription: String? {
        switch self {
        case .invalidOffer: String(localized: "This isn't a Nollie code. Show the code again on your Mac and scan it.", table: "Core")
        case .expired: String(localized: "This code has expired. Show a new one on your Mac.", table: "Core")
        case .unreachable: String(localized: "Your iPhone couldn't reach your Mac. At home, try again on the same network. Away, both need Tailscale.", table: "Core")
        case .identityMismatch: String(localized: "This Mac didn't prove it's the one that showed the code. Nothing was linked.", table: "Core")
        case .refused(let message): message
        case .invalidResponse: String(localized: "Linking didn't finish. Show a new code on your Mac and try again.", table: "Core")
        }
    }
}

/// A pairing offer from a Mac's QR code: `https://nollie.app/pair#<payload>`. The payload
/// sits after the `#`, so even opened as a link it never reaches a web server. Its secret
/// works once, for two minutes, and is only ever sent over a connection whose key matches
/// the pin beside it.
public struct NollieLinkOffer: Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible {
    public static let prefix = "https://nollie.app/pair#"

    public let macName: String
    /// SHA-256 of the Mac's TLS public key (SubjectPublicKeyInfo).
    public let pin: Data
    public let port: Int
    /// Home addresses, the Bonjour host name and, when away from home is on, Tailscale's name and address.
    public let hosts: [String]
    /// Finds this Mac over Bonjour without trusting what Bonjour says: the pin still decides.
    public let installTag: String
    public let expiresAt: Date
    let secret: Data
    /// A code for someone at home (version 2): who shares, and the helpers. Whoever claims it gets
    /// only those helpers; the Mac decides that, not this field.
    public let invite: NollieLinkInvite?

    public var description: String { "Nollie Link offer" }
    public var debugDescription: String { description }

    public init(macName: String, pin: Data, port: Int, hosts: [String], installTag: String, secret: Data,
                expiresAt: Date, invite: NollieLinkInvite? = nil, now: Date = Date()) throws(NollieLinkError) {
        guard let name = Self.cleanName(macName), name == macName, pin.count == 32, secret.count == 32,
              (1024...65535).contains(port), Self.validTag(installTag),
              !hosts.isEmpty, hosts.count <= 8, Set(hosts).count == hosts.count, hosts.allSatisfy(Self.validHost) else {
            throw .invalidOffer
        }
        // A minute's grace either way for a phone and Mac whose clocks disagree; the Mac decides.
        guard expiresAt > now.addingTimeInterval(-60) else { throw .expired }
        guard expiresAt <= now.addingTimeInterval(600) else { throw .invalidOffer }
        self.macName = name
        self.pin = pin
        self.port = port
        self.hosts = hosts
        self.installTag = installTag
        self.secret = secret
        self.expiresAt = expiresAt
        self.invite = invite
    }

    public var url: URL { URL(string: urlString)! }

    public var urlString: String {
        let payload = Payload(v: invite == nil ? 1 : 2, n: macName, k: Self.base64URL(pin), p: port, h: hosts, t: installTag,
                              s: Self.base64URL(secret), e: Int(expiresAt.timeIntervalSince1970.rounded(.down)),
                              f: invite.map { .init(o: $0.owner, b: $0.helpers) })
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return Self.prefix + Self.base64URL(try! encoder.encode(payload))
    }

    /// Whether a scanned value or opened link looks like a Nollie Link code at all.
    public static func isOffer(_ raw: String) -> Bool { raw.hasPrefix(prefix) }

    public static func parse(_ raw: String, now: Date = Date()) throws(NollieLinkError) -> Self {
        guard raw.utf8.count <= 2048, raw.hasPrefix(prefix),
              let components = URLComponents(string: raw), components.scheme == "https", components.host == "nollie.app",
              components.path == "/pair", components.query == nil, components.port == nil,
              components.user == nil, components.password == nil,
              let encoded = components.fragment, raw == prefix + encoded,
              let data = decodeBase64URL(encoded),
              let fields = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let payload = try? JSONDecoder().decode(Payload.self, from: data),
              (payload.v == 1 && Set(fields.keys) == Self.keys) || (payload.v == 2 && Set(fields.keys) == Self.keys.union(["f"])),
              let pin = decodeBase64URL(payload.k), let secret = decodeBase64URL(payload.s) else { throw .invalidOffer }
        var invite: NollieLinkInvite?
        if payload.v == 2 {
            guard let shared = payload.f, let made = NollieLinkInvite(owner: shared.o, helpers: shared.b) else { throw .invalidOffer }
            invite = made
        }
        return try Self(macName: payload.n, pin: pin, port: payload.p, hosts: payload.h, installTag: payload.t,
                        secret: secret, expiresAt: Date(timeIntervalSince1970: TimeInterval(payload.e)), invite: invite, now: now)
    }

    private static let keys: Set<String> = ["v", "n", "k", "p", "h", "t", "s", "e"]

    // MARK: Pieces

    static func cleanName(_ raw: String) -> String? {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let hidden = CharacterSet.controlCharacters.union(CharacterSet(charactersIn: "\u{202A}\u{202B}\u{202C}\u{202D}\u{202E}\u{2066}\u{2067}\u{2068}\u{2069}\u{200E}\u{200F}"))
        guard !name.isEmpty, name.count <= 64, !name.unicodeScalars.contains(where: hidden.contains) else { return nil }
        return name
    }

    static func validTag(_ tag: String) -> Bool {
        tag.utf8.count == 16 && tag.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    /// A private IPv4 address, a Tailscale IPv6 address, or a `.local` or `.ts.net` name. Never a
    /// public address: the Mac only answers private networks, so a public one in a code is a forgery.
    public static func validHost(_ host: String) -> Bool { NollieTailnet.validLinkHost(host) }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    public static func decodeBase64URL(_ text: String) -> Data? {
        guard !text.isEmpty, text.utf8.count <= 2048,
              text.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 95 }) else { return nil }
        var base64 = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        return Data(base64Encoded: base64)
    }

    private struct Payload: Codable {
        let v: Int
        let n: String
        let k: String
        let p: Int
        let h: [String]
        let t: String
        let s: String
        let e: Int
        /// Version 2 only; left out of a version 1 code.
        let f: Shared?

        struct Shared: Codable {
            let o: String
            let b: [String]
        }
    }
}

/// Who shares and what, in a code for someone at home. Names only: the Mac decides what the code gives.
public struct NollieLinkInvite: Sendable, Equatable, Hashable, Codable {
    /// The first name of the person whose Mac it is ("Corey"). May be empty.
    public let owner: String
    /// The shared helpers' shown names ("Scout"), one to eight.
    public let helpers: [String]

    public init?(owner: String, helpers: [String]) {
        let cleaned = helpers.compactMap(NollieLinkOffer.cleanName)
        guard owner.isEmpty || NollieLinkOffer.cleanName(owner) == owner, owner.count <= 40,
              (1...8).contains(helpers.count), cleaned == helpers else { return nil }
        self.owner = owner
        self.helpers = helpers
    }

    /// "Scout", "Scout and Juniper", "Scout, Juniper and Fern".
    public var helperList: String {
        guard helpers.count > 1 else { return helpers.first ?? "" }
        return Papertrail.list(helpers)
    }
}
