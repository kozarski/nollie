#if os(macOS) && NOLLIE_DIRECT
import Foundation
import Security
import Testing

/// Nollie Runtime's key store against the real Data Protection Keychain, in this signed test
/// host's own group. Fake values only; each test removes what it saved.
struct RuntimeKeychainKeysTests {
    private let store = RuntimeKeychainKeys()

    private func cleanUp(_ id: UUID) {
        for key in (try? store.keys(for: id)) ?? [] { try? store.delete(profile: key.profile, name: key.name, for: id) }
    }

    @Test func keysAreSavedReplacedListedAndDeleted() throws {
        let id = UUID()
        defer { cleanUp(id) }
        try store.save(RuntimeKey(profile: "default", name: "OPENROUTER_API_KEY", value: "fake-1"), for: id)
        try store.save(RuntimeKey(profile: "scout", name: "GROQ_API_KEY", value: "fake-2"), for: id)
        try store.save(RuntimeKey(profile: "default", name: "OPENROUTER_API_KEY", value: "fake-3"), for: id)

        let kept = try store.keys(for: id).sorted { $0.description < $1.description }
        #expect(kept == [RuntimeKey(profile: "default", name: "OPENROUTER_API_KEY", value: "fake-3"),
                         RuntimeKey(profile: "scout", name: "GROQ_API_KEY", value: "fake-2")])
        #expect(try store.installations().contains(id))
        #expect(try store.keys(for: UUID()).isEmpty)

        try store.delete(profile: "scout", name: "GROQ_API_KEY", for: id)
        try store.delete(profile: "scout", name: "GROQ_API_KEY", for: id)
        #expect(try store.keys(for: id).map(\.name) == ["OPENROUTER_API_KEY"])
    }

    @Test func badNamesAndEmptyValuesAreRefused() {
        let id = UUID()
        defer { cleanUp(id) }
        #expect(throws: RuntimeKeyError.invalid) { try store.save(RuntimeKey(profile: "../x", name: "A_KEY", value: "fake"), for: id) }
        #expect(throws: RuntimeKeyError.invalid) { try store.save(RuntimeKey(profile: "default", name: "A-KEY", value: "fake"), for: id) }
        #expect(throws: RuntimeKeyError.invalid) { try store.save(RuntimeKey(profile: "default", name: "A_KEY", value: ""), for: id) }
    }

    @Test func itemsStayOnThisMacAndOpenAfterTheFirstUnlock() throws {
        let id = UUID()
        defer { cleanUp(id) }
        try store.save(RuntimeKey(profile: "default", name: "OPENROUTER_API_KEY", value: "fake-1"), for: id)
        var item: CFTypeRef?
        let status = SecItemCopyMatching([kSecClass as String: kSecClassGenericPassword,
                                          kSecAttrService as String: RuntimeKeychainKeys.service,
                                          kSecAttrAccount as String: "\(id.uuidString)/default/OPENROUTER_API_KEY",
                                          kSecUseDataProtectionKeychain as String: true,
                                          kSecReturnAttributes as String: true,
                                          kSecMatchLimit as String: kSecMatchLimitOne] as CFDictionary, &item)
        #expect(status == errSecSuccess)
        let attributes = try #require(item as? [String: Any])
        #expect(attributes[kSecAttrAccessible as String] as? String == kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String)
        #expect((attributes[kSecAttrSynchronizable as String] as? NSNumber)?.boolValue != true)
    }
}
#endif
