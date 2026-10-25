#if NOLLIE_DIRECT
import Foundation

/// Whether this build knows where to look for updates and which key to trust. A build made before the
/// release key exists carries a placeholder; it must not start the updater, which would only complain.
struct SparkleConfiguration: Equatable {
    var feedURL: URL
    var publicKey: String

    /// The feed and key from an app's Info.plist, or nil when either is missing or wrong.
    init?(info: [String: Any]?) {
        guard let info,
              let feed = info["SUFeedURL"] as? String, let url = Self.secureURL(feed),
              let key = info["SUPublicEDKey"] as? String, Self.isValid(publicKey: key) else { return nil }
        feedURL = url
        publicKey = key
    }

    /// An EdDSA public key is 32 bytes, written in base64.
    static func isValid(publicKey: String) -> Bool {
        guard let data = Data(base64Encoded: publicKey.trimmingCharacters(in: .whitespacesAndNewlines)) else { return false }
        return data.count == 32
    }

    static func secureURL(_ text: String) -> URL? {
        guard let url = URL(string: text), url.scheme == "https", let host = url.host, !host.isEmpty else { return nil }
        return url
    }
}
#endif
