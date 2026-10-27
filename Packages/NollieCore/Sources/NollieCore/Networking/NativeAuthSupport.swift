import CryptoKit
import Foundation

/// Why a native sign-in stopped.
public enum NativeAuthError: LocalizedError {
    case invalidResponse(String)
    case providerRequired([AuthProvider])
    case stateMismatch
    case noCallback
    case cancelled

    /// The browser sheet refused to start.
    static let browserWouldNotOpen = NativeAuthError.invalidResponse(String(localized: "The sign-in browser would not open.", table: "Core"))

    public var errorDescription: String? {
        switch self {
        case .cancelled:
            String(localized: "You stopped the sign-in.", table: "Core")
        case .stateMismatch:
            String(localized: "The sign-in did not match the one we started. Please try again.", table: "Core")
        case .invalidResponse(let text):
            text
        case .providerRequired(let providers):
            String(localized: "Pick how to sign in: \(providers.map(\.name).joined(separator: ", ")).", table: "Core", comment: "The value is a list of sign-in providers")
        case .noCallback:
            String(localized: "No sign-in code came back from the browser. Try again, or paste a session token from the dashboard.", table: "Core")
        }
    }
}

/// A random secret plus its SHA-256 fingerprint. The fingerprint goes out first; the secret
/// follows later and proves the same app is finishing the sign-in that started it.
public struct PKCE: Sendable {
    public let verifier, challenge: String

    public init() {
        let secret = SymmetricKey(size: SymmetricKeySize(bitCount: 384))
        verifier = secret.withUnsafeBytes { Data($0).base64URLEncodedString() }
        let digest = SHA256.hash(data: Array(verifier.utf8))
        challenge = Data(digest).base64URLEncodedString()
    }
}

public extension Data {
    /// Base64 in the URL-safe alphabet (`-` and `_`), with the padding left off.
    func base64URLEncodedString() -> String {
        var out = ""
        for letter in base64EncodedString() {
            switch letter {
            case "+": out.append("-")
            case "/": out.append("_")
            case "=": continue
            default: out.append(letter)
            }
        }
        return out
    }
}

/// A flag that one caller, on any thread, can take.
public final class LockedFlag: @unchecked Sendable {
    private let state = Guarded(false)

    public init() {}

    /// True for the first call, false for every later one.
    public func claim() -> Bool {
        state.withLock { used in
            if used { return false }
            used = true
            return true
        }
    }
}
