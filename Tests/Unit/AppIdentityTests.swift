import Foundation
import CryptoKit
import Security
import Testing
@testable import NollieCore

@Suite struct AppIdentityTests {
    @Test func onlyTheCurrentAppLinkSchemeIsAccepted() {
        #expect(AppIdentity.bundleID == "com.coreykozarski.nollie")
        #expect(AppIdentity.urlScheme == "nollie")
        #expect(AppIdentity.acceptsURLScheme("nollie"))
        #expect(!AppIdentity.acceptsURLScheme("other"))
        #expect(!AppIdentity.acceptsURLScheme(""))
        #expect(!AppIdentity.acceptsURLScheme(nil))
    }

    @Test func savedSignInsKeepTheirCurrentNamespaceAndProtection() {
        let query = KeychainRememberedSignInBackend.query(account: "signin.fixture")
        #expect(query[kSecAttrService as String] as? String == Keychain.baseBundleID + ".remembered")
        #expect(query[kSecAttrAccount as String] as? String == "signin.fixture")
        #expect(query[kSecAttrSynchronizable as String] as? Bool == false)
        #expect(Keychain.service == Keychain.baseBundleID + ".gateways")
        #expect(KeychainRememberedSignInBackend.protection as String == kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly as String)
        #expect(KeychainRememberedSignInBackend.accessFlags == .userPresence)
        #if os(macOS)
        #expect(query[kSecUseDataProtectionKeychain as String] as? Bool == true)
        #endif
    }

    @Test func theRequiredLicenseTravelsUnchangedInTheAppBundle() throws {
        let resource = try #require(Bundle.main.url(forResource: "LICENSE", withExtension: nil))
        let data = try Data(contentsOf: resource)
        let checksum = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        // The whole LICENSE travels with the app: Nollie's own notice, then the third-party notices, word for word.
        #expect(checksum == "7cce67a3255046e040d93f529b3d3bfb3db29b9aeb21dcf777c3067c8b11a5b8")
    }
}
