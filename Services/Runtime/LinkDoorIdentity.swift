#if os(macOS)
import CryptoKit
import Foundation
import Security

/// The door's TLS identity: one P-256 key made once and kept in this helper's Data Protection
/// Keychain, with a self-signed certificate around it. Phones trust the key, not the
/// certificate: the pin is the SHA-256 of its SubjectPublicKeyInfo.
struct LinkDoorIdentity: @unchecked Sendable {
    let identity: SecIdentity
    let pin: Data

    enum Failure: Error, Equatable { case keychain(OSStatus), key, certificate }

    /// `name` keeps tests apart from the real identity; the helper uses the default.
    static func loadOrCreate(name: String = "com.coreykozarski.nollie.link.identity") throws -> LinkDoorIdentity {
        if let found = try find(name: name) { return found }
        let key = try existingKey(name: name) ?? createKey(name: name)
        guard let publicKey = SecKeyCopyPublicKey(key) else { throw Failure.key }
        let der = try certificate(privateKey: key, publicKey: publicKey)
        guard let certificate = SecCertificateCreateWithData(nil, der as CFData) else { throw Failure.certificate }
        var add = base(kSecClassCertificate, name: name)
        add[kSecValueRef as String] = certificate
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess || status == errSecDuplicateItem else { throw Failure.keychain(status) }
        guard let made = try find(name: name) else { throw Failure.certificate }
        return made
    }

    /// Removes the key and certificate. Used by tests, and if the identity must be replaced.
    static func remove(name: String) {
        SecItemDelete(base(kSecClassCertificate, name: name) as CFDictionary)
        var key = base(kSecClassKey, name: name)
        key[kSecAttrApplicationTag as String] = Data(name.utf8)
        key.removeValue(forKey: kSecAttrLabel as String)
        SecItemDelete(key as CFDictionary)
    }

    /// SHA-256 over the DER SubjectPublicKeyInfo of an uncompressed P-256 public key.
    static func pin(of publicKey: SecKey) -> Data? {
        guard let attributes = SecKeyCopyAttributes(publicKey) as? [String: Any],
              attributes[kSecAttrKeyType as String] as? String == kSecAttrKeyTypeECSECPrimeRandom as String,
              attributes[kSecAttrKeySizeInBits as String] as? Int == 256,
              let raw = SecKeyCopyExternalRepresentation(publicKey, nil) as Data?, raw.count == 65, raw.first == 4 else { return nil }
        return Data(SHA256.hash(data: spkiPrefix + raw))
    }

    /// SEQUENCE { SEQUENCE { id-ecPublicKey, prime256v1 }, BIT STRING ( 0x04 || X || Y ) }
    static let spkiPrefix = Data([0x30, 0x59, 0x30, 0x13, 0x06, 0x07, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x02, 0x01,
                                  0x06, 0x08, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x03, 0x01, 0x07, 0x03, 0x42, 0x00])

    // MARK: Keychain

    private static func base(_ itemClass: CFString, name: String) -> [String: Any] {
        [kSecClass as String: itemClass,
         kSecAttrLabel as String: name,
         kSecUseDataProtectionKeychain as String: true,
         kSecAttrSynchronizable as String: false]
    }

    private static func find(name: String) throws -> LinkDoorIdentity? {
        var query = base(kSecClassIdentity, name: name)
        query[kSecReturnRef as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let item, CFGetTypeID(item) == SecIdentityGetTypeID() else { throw Failure.keychain(status) }
        let identity = item as! SecIdentity
        var certificate: SecCertificate?
        guard SecIdentityCopyCertificate(identity, &certificate) == errSecSuccess, let certificate,
              let key = SecCertificateCopyKey(certificate), let pin = pin(of: key) else { throw Failure.certificate }
        return LinkDoorIdentity(identity: identity, pin: pin)
    }

    private static func existingKey(name: String) throws -> SecKey? {
        var query = base(kSecClassKey, name: name)
        query.removeValue(forKey: kSecAttrLabel as String)
        query[kSecAttrApplicationTag as String] = Data(name.utf8)
        query[kSecAttrKeyClass as String] = kSecAttrKeyClassPrivate
        query[kSecReturnRef as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let item, CFGetTypeID(item) == SecKeyGetTypeID() else { throw Failure.keychain(status) }
        return (item as! SecKey)
    }

    private static func createKey(name: String) throws -> SecKey {
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeySizeInBits as String: 256,
            kSecUseDataProtectionKeychain as String: true,
            kSecPrivateKeyAttrs as String: [
                kSecAttrIsPermanent as String: true,
                kSecAttrApplicationTag as String: Data(name.utf8),
                kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
                kSecAttrSynchronizable as String: false,
            ] as [String: Any],
        ]
        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateRandomKey(attributes as CFDictionary, &error) else {
            throw Failure.keychain(OSStatus(CFErrorGetCode(error!.takeRetainedValue())))
        }
        return key
    }

    // MARK: Certificate

    /// A minimal X.509 v3 certificate, signed with the key itself.
    static func certificate(privateKey: SecKey, publicKey: SecKey, now: Date = Date()) throws -> Data {
        guard let raw = SecKeyCopyExternalRepresentation(publicKey, nil) as Data?, raw.count == 65 else { throw Failure.key }
        let ecdsaWithSHA256 = DER.sequence([DER.oid([0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x04, 0x03, 0x02])])
        let name = DER.sequence([DER.set([DER.sequence([DER.oid([0x55, 0x04, 0x03]), DER.utf8("Nollie Link")])])])
        var serial = [UInt8](LinkDoorDevices.randomBytes(16))
        serial[0] &= 0x7F
        serial[0] |= 0x01
        let tbs = DER.sequence([
            DER.tagged(0, DER.integer([2])),
            DER.integer(serial),
            ecdsaWithSHA256,
            name,
            DER.sequence([DER.utcTime(now.addingTimeInterval(-86_400)), DER.utcTime(now.addingTimeInterval(20 * 365 * 86_400))]),
            name,
            spkiPrefix + raw,
        ])
        var error: Unmanaged<CFError>?
        guard let signature = SecKeyCreateSignature(privateKey, .ecdsaSignatureMessageX962SHA256, tbs as CFData, &error) as Data? else {
            throw Failure.key
        }
        return DER.sequence([tbs, ecdsaWithSHA256, DER.bitString(signature)])
    }

    private enum DER {
        static func element(_ tag: UInt8, _ content: Data) -> Data {
            var out = Data([tag])
            let count = content.count
            if count < 0x80 { out.append(UInt8(count)) }
            else if count <= 0xFF { out.append(contentsOf: [0x81, UInt8(count)]) }
            else { out.append(contentsOf: [0x82, UInt8(count >> 8), UInt8(count & 0xFF)]) }
            out.append(content)
            return out
        }
        static func sequence(_ items: [Data]) -> Data { element(0x30, items.reduce(Data(), +)) }
        static func set(_ items: [Data]) -> Data { element(0x31, items.reduce(Data(), +)) }
        static func oid(_ bytes: [UInt8]) -> Data { element(0x06, Data(bytes)) }
        static func utf8(_ text: String) -> Data { element(0x0C, Data(text.utf8)) }
        static func integer(_ bytes: [UInt8]) -> Data { element(0x02, Data(bytes)) }
        static func bitString(_ bytes: Data) -> Data { element(0x03, Data([0]) + bytes) }
        static func tagged(_ number: UInt8, _ content: Data) -> Data { element(0xA0 | number, content) }
        static func utcTime(_ date: Date) -> Data {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(identifier: "UTC")
            formatter.dateFormat = "yyMMddHHmmss'Z'"
            return element(0x17, Data(formatter.string(from: date).utf8))
        }
    }
}
#endif
