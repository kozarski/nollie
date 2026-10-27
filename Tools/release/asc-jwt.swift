// Writes a signed App Store Connect API token to stdout.
//
// The environment must provide ASC_KEY_ID and ASC_KEY_PATH, the last being the .p8 file, and either
// ASC_ISSUER_ID for a team key or ASC_KEY_KIND=individual for Corey's own key. Work done with the
// individual key shows his name in App Store Connect; a team key shows "API user". The token stays valid for 18 minutes, though Apple permits up to 20. Run it with
// `swift asc-jwt.swift`.
import CryptoKit
import Foundation

extension Data {
    /// Base64 with the URL-safe alphabet and no padding, as a JWT segment wants.
    var jwtSegment: String {
        String(base64EncodedString().compactMap { symbol -> Character? in
            switch symbol {
            case "+": return "-"
            case "/": return "_"
            case "=": return nil
            default: return symbol
            }
        })
    }
}

func setting(_ name: String) -> String? {
    guard let value = ProcessInfo.processInfo.environment[name], !value.isEmpty else { return nil }
    return value
}

func stop(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

let individual = setting("ASC_KEY_KIND") == "individual"
guard let keyID = setting("ASC_KEY_ID"), let keyPath = setting("ASC_KEY_PATH"),
      individual || setting("ASC_ISSUER_ID") != nil else {
    stop("ASC_KEY_ID and ASC_KEY_PATH must be set, with ASC_ISSUER_ID or ASC_KEY_KIND=individual")
}

do {
    let pem = try String(contentsOfFile: keyPath, encoding: .utf8)
    let signer = try P256.Signing.PrivateKey(pemRepresentation: pem)

    let issuedAt = Int(Date().timeIntervalSince1970)
    let head: [String: Any] = ["alg": "ES256", "kid": keyID, "typ": "JWT"]
    var claims: [String: Any] = ["iat": issuedAt, "exp": issuedAt + 18 * 60, "aud": "appstoreconnect-v1"]
    // An individual key names no issuer; Apple reads the person from the key itself.
    if individual { claims["sub"] = "user" } else { claims["iss"] = setting("ASC_ISSUER_ID") }

    let signingInput = try [head, claims]
        .map { try JSONSerialization.data(withJSONObject: $0).jwtSegment }
        .joined(separator: ".")
    let signature = try signer.signature(for: Data(signingInput.utf8))
    print(signingInput + "." + signature.rawRepresentation.jwtSegment)
} catch {
    stop("could not mint token: \(error)")
}
