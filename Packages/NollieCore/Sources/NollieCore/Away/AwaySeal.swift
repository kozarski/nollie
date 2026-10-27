import CryptoKit
import Foundation

// Away from home through iCloud: the two paired devices' own keys. A record in the person's iCloud
// opens only on the device it was sealed for, and only with the header it was sealed with.
// See Docs/specs/away-icloud.md.

/// Which end of a channel a device is.
public enum AwaySide: String, Codable, Sendable {
    case mac, phone

    public var other: AwaySide { self == .mac ? .phone : .mac }
}

/// One device's away key pair. The private half never leaves the device's Keychain.
public struct AwayKey: Sendable {
    public let privateKey: Curve25519.KeyAgreement.PrivateKey

    public init() { privateKey = .init() }

    public init?(raw: Data) {
        guard raw.count == 32, let key = try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: raw) else { return nil }
        privateKey = key
    }

    public var raw: Data { privateKey.rawRepresentation }
    public var publicKey: Data { privateKey.publicKey.rawRepresentation }

    /// Reads this device's key from the Keychain, or makes and keeps a new one.
    public static func loadOrCreate(account: String) throws -> AwayKey {
        if let saved = Keychain.get(account: account), let key = AwayKey(raw: saved) { return key }
        let made = AwayKey()
        try Keychain.set(made.raw, account: account)
        return made
    }

    /// A public key as it travels: 32 bytes. Anything else is refused.
    public static func validPublic(_ data: Data) -> Bool {
        data.count == 32 && (try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: data)) != nil
    }
}

/// The address a device is known by in the mailbox: a hash of its away public key, so it says
/// nothing about the person, and differs by role so a Mac's and a phone's never collide.
public enum AwayTag {
    public static func of(_ publicKey: Data, side: AwaySide) -> String {
        var input = Data("nollie-away-\(side.rawValue)".utf8)
        input.append(publicKey)
        return String(hex(Data(SHA256.hash(data: input))).prefix(32))
    }

    public static func isValid(_ tag: String) -> Bool {
        tag.utf8.count == 32 && tag.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    static func hex(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }
}

/// What a sealed record says outside its box, all of it bound into the seal.
public struct AwayHeader: Equatable, Sendable {
    public var id: String
    public var from: String
    public var to: String
    public var expiresAt: Date
    public var alert: Bool

    public init(id: String, from: String, to: String, expiresAt: Date, alert: Bool) {
        self.id = id
        self.from = from
        self.to = to
        self.expiresAt = expiresAt
        self.alert = alert
    }

    /// `aw1_` and 64 lowercase hex: random, never derived from what is inside.
    public static func newID() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return "aw1_" + AwayTag.hex(Data(bytes))
    }

    public static func isValidID(_ id: String) -> Bool {
        id.utf8.count == 68 && id.hasPrefix("aw1_")
            && id.utf8.dropFirst(4).allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    public var isWellFormed: Bool { Self.isValidID(id) && AwayTag.isValid(from) && AwayTag.isValid(to) && from != to }

    /// The bytes the seal authenticates. Whole seconds, so a store that keeps milliseconds or not
    /// gives the same answer.
    var authenticated: Data {
        let seconds = Int64(expiresAt.timeIntervalSince1970.rounded(.down))
        return Data("nollie-away-v1\n\(id)\n\(from)\n\(to)\n\(seconds)\n\(alert ? 1 : 0)".utf8)
    }
}

/// The channel between one Mac and one phone: a key for each direction, from both devices' keys.
public struct AwayChannel: Sendable {
    public let macTag: String
    public let phoneTag: String
    private let toMac: SymmetricKey
    private let toPhone: SymmetricKey
    /// The side this copy belongs to: it seals towards the other side and opens what comes to it.
    public let side: AwaySide

    public enum Failure: Error, Equatable, Sendable { case badKey, notForUs, malformed, unopened, tooBig }

    /// The largest box the mailbox carries.
    public static let maximumBox = 72 * 1024

    public init(own: AwayKey, side: AwaySide, otherPublic: Data) throws {
        guard let other = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: otherPublic) else { throw Failure.badKey }
        let shared = try own.privateKey.sharedSecretFromKeyAgreement(with: other)
        let macPublic = side == .mac ? own.publicKey : otherPublic
        let phonePublic = side == .phone ? own.publicKey : otherPublic
        // An all-zero secret means a small-order point: refuse it rather than seal with it.
        guard shared.withUnsafeBytes({ $0.contains { $0 != 0 } }) else { throw Failure.badKey }
        let root = shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: Data("nollie-away-v1".utf8),
                                                  sharedInfo: macPublic + phonePublic, outputByteCount: 32)
        toMac = HKDF<SHA256>.deriveKey(inputKeyMaterial: root, info: Data("to-mac".utf8), outputByteCount: 32)
        toPhone = HKDF<SHA256>.deriveKey(inputKeyMaterial: root, info: Data("to-phone".utf8), outputByteCount: 32)
        macTag = AwayTag.of(macPublic, side: .mac)
        phoneTag = AwayTag.of(phonePublic, side: .phone)
        self.side = side
    }

    public var ownTag: String { side == .mac ? macTag : phoneTag }
    public var otherTag: String { side == .mac ? phoneTag : macTag }

    /// A header from this device to the other one.
    public func header(expiresAt: Date, alert: Bool = false, id: String = AwayHeader.newID()) -> AwayHeader {
        AwayHeader(id: id, from: ownTag, to: otherTag, expiresAt: expiresAt, alert: alert)
    }

    /// Seals a note for the other side.
    public func seal(_ plain: Data, header: AwayHeader) throws -> Data {
        guard header.from == ownTag, header.to == otherTag, header.isWellFormed else { throw Failure.notForUs }
        let key = side == .mac ? toPhone : toMac
        let box = try ChaChaPoly.seal(plain, using: key, authenticating: header.authenticated).combined
        guard box.count <= Self.maximumBox else { throw Failure.tooBig }
        return box
    }

    /// Opens a note the other side sealed for this one. Anything else fails.
    public func open(_ box: Data, header: AwayHeader) throws -> Data {
        guard header.to == ownTag, header.from == otherTag, header.isWellFormed else { throw Failure.notForUs }
        guard box.count >= 28, box.count <= Self.maximumBox, let sealed = try? ChaChaPoly.SealedBox(combined: box) else {
            throw Failure.malformed
        }
        let key = side == .mac ? toMac : toPhone
        do { return try ChaChaPoly.open(sealed, using: key, authenticating: header.authenticated) }
        catch { throw Failure.unopened }
    }
}

/// Base64url without padding, the way keys travel in Link requests.
public enum AwayBase64URL {
    public static func encode(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    public static func decode(_ text: String) -> Data? {
        guard text.utf8.count <= 4096, text.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 95 }) else { return nil }
        var base64 = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        return Data(base64Encoded: base64)
    }
}
