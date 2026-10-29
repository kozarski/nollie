import Foundation
import Network

public enum DevicePairingError: LocalizedError, Equatable, Sendable {
    case invalidInvitation, expired, secureConnectionRequired, setupRequired, invalidResponse

    public var errorDescription: String? {
        switch self {
        case .invalidInvitation: String(localized: "This is not an Nollie pairing code.", table: "Core")
        case .expired: String(localized: "This code has expired. Create a new one on your Mac.", table: "Core")
        case .secureConnectionRequired: String(localized: "Pairing needs a secure address your iPhone can reach.", table: "Core")
        case .setupRequired: String(localized: "iPhone pairing is not set up on this connection yet.", table: "Core")
        case .invalidResponse: String(localized: "Pairing could not finish. Create a new code and try again.", table: "Core")
        }
    }
}

/// A short-lived invitation. Its secret is never a saved gateway credential.
public struct DevicePairingInvitation: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public let gateway: GatewayURL
    public let id: String
    public let displayName: String
    public let expiresAt: Date
    let grant: String

    public var description: String { "Nollie pairing invitation" }
    public var debugDescription: String { description }

    public init(gateway: GatewayURL, id: String, grant: String, displayName: String,
                expiresAt: Date, now: Date = Date()) throws {
        try Self.validateGateway(gateway.base.absoluteString)
        guard UUID(uuidString: id)?.uuidString.lowercased() == id,
              grant.count == 64, grant.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
              Self.validName(displayName) else { throw DevicePairingError.invalidInvitation }
        guard expiresAt > now else { throw DevicePairingError.expired }
        guard expiresAt.timeIntervalSince(now) <= 135 else { throw DevicePairingError.invalidInvitation }
        self.gateway = gateway
        self.id = id
        self.grant = grant
        self.displayName = displayName
        self.expiresAt = expiresAt
    }

    public var qrString: String {
        let payload = Payload(version: 1, gateway: gateway.base.absoluteString, id: id,
                              grant: grant, displayName: displayName, expiresAt: Int(expiresAt.timeIntervalSince1970))
        let data = try! JSONEncoder().encode(payload)
        let encoded = data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        return "nollie://pair#" + encoded
    }

    public static func parse(_ raw: String, now: Date = Date()) throws -> Self {
        guard raw.utf8.count <= 4096, raw.hasPrefix("nollie://pair#"),
              let components = URLComponents(string: raw), components.scheme == "nollie",
              components.host == "pair", components.path.isEmpty, components.query == nil,
              components.user == nil, components.password == nil, components.port == nil,
              let encoded = components.fragment, !encoded.isEmpty,
              encoded.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 95 }),
              raw == "nollie://pair#" + encoded else { throw DevicePairingError.invalidInvitation }
        var base64 = encoded.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        guard let data = Data(base64Encoded: base64),
              let fields = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(fields.keys) == Set(["version", "gateway", "id", "grant", "displayName", "expiresAt"]),
              let payload = try? JSONDecoder().decode(Payload.self, from: data), payload.version == 1 else {
            throw DevicePairingError.invalidInvitation
        }
        try validateGateway(payload.gateway)
        return try Self(gateway: GatewayURL.normalize(payload.gateway), id: payload.id, grant: payload.grant,
                        displayName: payload.displayName, expiresAt: Date(timeIntervalSince1970: TimeInterval(payload.expiresAt)), now: now)
    }

    /// Address shape only. The phone must still verify reachability before saving it.
    public static func validateGateway(_ raw: String) throws {
        guard raw.utf8.count <= 2048, let c = URLComponents(string: raw), c.scheme == "https",
              let host = c.host?.lowercased(), !host.isEmpty, c.user == nil, c.password == nil,
              c.query == nil, c.fragment == nil, c.port.map({ (1...65535).contains($0) }) ?? true,
              c.path.split(separator: "/").allSatisfy({ $0 != "." && $0 != ".." }),
              !c.percentEncodedPath.contains("%"), !host.contains("%"),
              host != "localhost", !host.hasSuffix(".localhost"), host != "0.0.0.0",
              host != "[::]", host != "::", host != "[::1]", host != "::1",
              !host.hasPrefix("127."), !host.contains(":ffff:"),
              host.contains(".") || host.contains(":"),
              !host.allSatisfy({ $0.isNumber }),
              let normalized = try? GatewayURL.normalize(raw), normalized.base.absoluteString == raw else {
            throw DevicePairingError.secureConnectionRequired
        }
        let unbracketed = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if let ipv6 = IPv6Address(unbracketed) {
            let bytes = Array(ipv6.rawValue)
            let zeroPrefix = bytes.prefix(15).allSatisfy { $0 == 0 }
            let mappedV4 = bytes.prefix(10).allSatisfy { $0 == 0 } && bytes[10] == 255 && bytes[11] == 255
            guard !(zeroPrefix && bytes[15] <= 1), !mappedV4 else { throw DevicePairingError.secureConnectionRequired }
        } else {
            let labels = host.split(separator: ".", omittingEmptySubsequences: false)
            let numeric = labels.allSatisfy { $0.allSatisfy(\.isNumber) || $0.lowercased().hasPrefix("0x") }
            if numeric {
                guard labels.count == 4, labels.allSatisfy({ label in
                    guard let value = Int(label), (0...255).contains(value) else { return false }
                    return String(value) == label
                }), labels.first != "127", labels.first != "0" else { throw DevicePairingError.secureConnectionRequired }
            }
        }
    }

    private static func validName(_ name: String) -> Bool {
        !name.isEmpty && name.count <= 64 && name == name.trimmingCharacters(in: .whitespacesAndNewlines)
            && !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) || CharacterSet(charactersIn: "\u{202A}\u{202B}\u{202D}\u{202E}\u{202C}\u{2066}\u{2067}\u{2068}\u{2069}").contains($0) })
    }

    private struct Payload: Codable {
        let version: Int
        let gateway: String
        let id: String
        let grant: String
        let displayName: String
        let expiresAt: Int
    }
}
