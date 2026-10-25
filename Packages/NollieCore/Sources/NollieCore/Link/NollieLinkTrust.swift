import CryptoKit
import Foundation
import Security

/// Pins are SHA-256 hashes of a server key's SubjectPublicKeyInfo. A linked Mac is trusted
/// because its key matches the pin from its QR code; certificate chains, names and dates
/// play no part, and the system trust store is never consulted for it.
public enum NollieLinkPin {
    /// SEQUENCE { SEQUENCE { id-ecPublicKey, prime256v1 }, BIT STRING } before the 65-byte point.
    static let p256Prefix = Data([0x30, 0x59, 0x30, 0x13, 0x06, 0x07, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x02, 0x01,
                                  0x06, 0x08, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x03, 0x01, 0x07, 0x03, 0x42, 0x00])

    /// The pin of a P-256 public key; nil for any other kind of key.
    public static func pin(of key: SecKey) -> Data? {
        guard let attributes = SecKeyCopyAttributes(key) as? [String: Any],
              attributes[kSecAttrKeyType as String] as? String == kSecAttrKeyTypeECSECPrimeRandom as String,
              attributes[kSecAttrKeySizeInBits as String] as? Int == 256,
              let raw = SecKeyCopyExternalRepresentation(key, nil) as Data?, raw.count == 65, raw.first == 4 else { return nil }
        return Data(SHA256.hash(data: p256Prefix + raw))
    }

    public static func pin(of certificate: SecCertificate) -> Data? {
        SecCertificateCopyKey(certificate).flatMap(pin(of:))
    }

    /// True only when the server's own certificate carries the pinned key.
    public static func matches(_ trust: SecTrust, pin expected: Data) -> Bool {
        guard expected.count == 32,
              let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate], let leaf = chain.first,
              let actual = pin(of: leaf) else { return false }
        var difference: UInt8 = 0
        for (a, b) in zip(actual, expected) { difference |= a ^ b }
        return difference == 0
    }

    /// The decision for one server-trust challenge, separate from URLSession for tests.
    public static func disposition(for trust: SecTrust?, pin: Data?) -> URLSession.AuthChallengeDisposition {
        guard let pin else { return .performDefaultHandling }
        guard let trust, matches(trust, pin: pin) else { return .cancelAuthenticationChallenge }
        return .useCredential
    }
}

/// The URLSession delegate every gateway session uses. An address registered for a saved
/// linked Mac is accepted only with that Mac's pinned key; every other host gets the system's
/// usual checks. Each address holds one pin, owned by one saved connection: a later
/// registration replaces it, and forgetting the connection removes it.
public final class GatewayTrust: NSObject, URLSessionDelegate, @unchecked Sendable {
    public static let shared = GatewayTrust()
    private let lock = NSLock()
    private var pins: [String: (pin: Data, owner: UUID)] = [:]

    private static func key(_ host: String, _ port: Int) -> String {
        host.trimmingCharacters(in: CharacterSet(charactersIn: "[]")).lowercased() + ":" + String(port)
    }

    public func register(pin: Data, host: String, port: Int, owner: UUID) {
        guard pin.count == 32 else { return }
        lock.lock(); defer { lock.unlock() }
        pins[Self.key(host, port)] = (pin, owner)
    }

    /// Every address a saved linked Mac may answer on.
    public func register(_ link: LinkedMac, hosts extra: [String] = [], owner: UUID) {
        for host in link.hosts + extra { register(pin: link.pin, host: host, port: link.port, owner: owner) }
    }

    /// Called when a linked connection is removed or replaced.
    public func forget(owner: UUID) {
        lock.lock(); defer { lock.unlock() }
        pins = pins.filter { $0.value.owner != owner }
    }

    /// The pin a host must show, if it is a saved linked Mac.
    public func pin(host: String, port: Int) -> Data? {
        lock.lock(); defer { lock.unlock() }
        return pins[Self.key(host, port)]?.pin
    }

    public func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                           completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        let space = challenge.protectionSpace
        guard space.authenticationMethod == NSURLAuthenticationMethodServerTrust else {
            completionHandler(.performDefaultHandling, nil); return
        }
        switch NollieLinkPin.disposition(for: space.serverTrust, pin: pin(host: space.host, port: space.port)) {
        case .performDefaultHandling: completionHandler(.performDefaultHandling, nil)
        case .useCredential: completionHandler(.useCredential, space.serverTrust.map(URLCredential.init(trust:)))
        default: completionHandler(.cancelAuthenticationChallenge, nil)
        }
    }
}

/// A session delegate with one expected key, for exchanges before a link is saved: pairing and
/// the first connection check. Nothing is registered process-wide for them.
public final class NollieLinkPinnedDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let pin: Data
    public init(pin: Data) { self.pin = pin }

    public func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        let space = challenge.protectionSpace
        guard space.authenticationMethod == NSURLAuthenticationMethodServerTrust else {
            completionHandler(.cancelAuthenticationChallenge, nil); return
        }
        switch NollieLinkPin.disposition(for: space.serverTrust, pin: pin) {
        case .useCredential: completionHandler(.useCredential, space.serverTrust.map(URLCredential.init(trust:)))
        default: completionHandler(.cancelAuthenticationChallenge, nil)
        }
    }

    /// The door never redirects; a redirect is refused rather than followed elsewhere.
    public func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
