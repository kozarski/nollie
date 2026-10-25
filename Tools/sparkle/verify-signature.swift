// Checks a sign_update signature against the public key an app carries, the way Sparkle does before it
// installs an update.
//
//   swift Tools/sparkle/verify-signature.swift <public key> <signature> <file>
//
// The key and the signature are base64, as in Info.plist and the appcast. Exits 0 when the signature is
// good, 1 when it is not. Reads nothing secret.
import CryptoKit
import Foundation

func stop(_ message: String, _ code: Int32) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(code)
}

let arguments = CommandLine.arguments
guard arguments.count == 4 else {
    stop("Usage: swift verify-signature.swift <public key> <signature> <file>", 2)
}
guard let keyData = Data(base64Encoded: arguments[1]),
      let key = try? Curve25519.Signing.PublicKey(rawRepresentation: keyData) else {
    stop("The public key is not a base64 EdDSA key.", 2)
}
guard let signature = Data(base64Encoded: arguments[2]) else {
    stop("The signature is not base64.", 2)
}
guard let file = try? Data(contentsOf: URL(fileURLWithPath: arguments[3]), options: .alwaysMapped) else {
    stop("Cannot read \(arguments[3]).", 2)
}
if key.isValidSignature(signature, for: file) {
    print("Good signature: \((arguments[3] as NSString).lastPathComponent)")
} else {
    stop("The signature does not match \((arguments[3] as NSString).lastPathComponent) and this key.", 1)
}
