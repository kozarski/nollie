import CryptoKit
import Foundation

/// An address can change while the authenticated Hermes installation remains the same.
public enum GatewayIdentity {
    public static func fingerprint(installID: String) -> String? {
        guard installID.utf8.count == 32, installID.utf8.allSatisfy({
            (48...57).contains($0) || (97...102).contains($0)
        }) else { return nil }
        return SHA256.hash(data: Data(("nollie.hermes.install.v1\u{0}" + installID).utf8))
            .map { String(format: "%02x", $0) }.joined()
    }

    public static func isValid(_ fingerprint: String) -> Bool {
        fingerprint.utf8.count == 64 && fingerprint.utf8.allSatisfy {
            (48...57).contains($0) || (97...102).contains($0)
        }
    }
}
