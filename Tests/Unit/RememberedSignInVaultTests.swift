import Foundation
import LocalAuthentication
import Security
import Testing
@testable import Nollie
@testable import NollieCore

/// Where a remembered sign-in lives, and what the vault says about it without asking the person.
@MainActor @Suite struct RememberedSignInVaultTests {
    private let secret = RememberedFixtures.secret
    private typealias KeychainBackend = KeychainRememberedSignInBackend

    // MARK: protection

    @Test func theKeychainQueryKeepsTheItemOffICloudAndInItsOwnService() throws {
        let query = KeychainBackend.query(account: "signin.x")
        #expect(query[kSecAttrSynchronizable as String] as? Bool == false)
        #expect(query[kSecClass as String] as? String == kSecClassGenericPassword as String)
        let serviceName = query[kSecAttrService as String] as? String
        let service = try #require(serviceName)
        // A service of its own keeps the gateway-secret migration from ever touching it, so no
        // Face ID prompt appears at launch.
        #expect(service.hasSuffix(".remembered"))
        #expect(service.hasPrefix(Keychain.baseBundleID))
        #expect(service != Keychain.service)
        #if os(macOS)
        #expect(query[kSecUseDataProtectionKeychain as String] as? Bool == true)
        #endif
    }

    @Test func theNewItemNeedsThePasscodeAndTheOwnerAndStaysOnThisDevice() throws {
        #expect(KeychainBackend.protection as String == kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly as String)
        #expect(KeychainBackend.accessFlags == .userPresence)
        let payload = Data("x".utf8)
        let attributes = try KeychainBackend.addAttributes(payload, account: "signin.x")
        #expect(attributes[kSecAttrSynchronizable as String] as? Bool == false)
        #expect(attributes[kSecValueData as String] as? Data == payload)
        // The protection class travels inside the access control; beside it, the add would be refused.
        #expect(attributes[kSecAttrAccessible as String] == nil)
        let control = try #require(attributes[kSecAttrAccessControl as String])
        #expect(CFGetTypeID(control as AnyObject) == SecAccessControlGetTypeID())
        let words = String(describing: control)
        #expect(words.contains("akpu"), "\(words)")
        #expect(words.contains("DeviceOwnerAuthentication"), "\(words)")
    }

    @Test func noWayOfPrintingItShowsTheCredentials() {
        var dumped = String()
        dump(secret, to: &dumped)
        let renderings = [String(describing: secret), String(reflecting: secret), "\(secret)", dumped]
        for text in renderings {
            #expect(!text.contains(secret.password))
            #expect(!text.contains(secret.username))
        }
    }

    // MARK: what the vault knows

    @Test func theVaultAnswersFromAccountNamesAndOpensWithTheCheckedContext() throws {
        let shelf = Shelf()
        let mine = try shelf.save(in: shelf.open())
        let nextLaunch = shelf.open()
        #expect(nextLaunch.ids == [mine])
        #expect(nextLaunch.contains(mine) && !nextLaunch.contains(UUID()))
        // Handing over the context of an evaluated check is what spares the second prompt.
        let opened = try nextLaunch.signIn(for: mine, context: LAContext())
        #expect(opened == secret)
        #expect(shelf.backend.readsWithContext == 1)
        nextLaunch.forget(mine)
        #expect(!nextLaunch.contains(mine))
        #expect(shelf.backend.items.isEmpty)
    }

    @Test func anItemThatVanishedUnderTheVaultIsDroppedFromTheList() throws {
        let shelf = Shelf()
        let vault = shelf.open()
        let id = try shelf.save(in: vault)
        shelf.backend.delete(account: RememberedSignInVault.account(id))
        let found = try vault.signIn(for: id, context: nil)
        #expect(found == nil)
        #expect(vault.ids.isEmpty)
    }

    // MARK: deleting while the device is locked

    @Test func aDeleteDeniedByALockedKeychainIsFinishedLater() throws {
        let shelf = Shelf()
        defer { shelf.tidy() }
        let vault = shelf.open()
        let doomed = try shelf.save(in: vault)
        let spared = try shelf.save(in: vault)

        shelf.backend.undeletable = true
        #expect(vault.forget(doomed) == false)
        #expect(shelf.stillStored(doomed))
        #expect(vault.pendingForgets == [doomed])
        #expect(try vault.signIn(for: doomed, context: LAContext()) == nil)
        #expect(shelf.backend.readsWithContext == 0, "a forgotten item must not be opened")
        vault.reload()
        #expect(vault.ids == [spared])

        // After a relaunch that is still locked, the pending delete is remembered.
        let relaunched = shelf.open()
        #expect(relaunched.pendingForgets == [doomed])
        #expect(relaunched.contains(spared) && !relaunched.contains(doomed))

        shelf.backend.undeletable = false
        relaunched.reload()
        #expect(!shelf.stillStored(doomed))
        #expect(relaunched.pendingForgets.isEmpty)
        #expect(relaunched.ids == [spared])
        #expect(shelf.defaults.object(forKey: RememberedSignInVault.pendingForgetsKey) == nil)
    }

    @Test func rememberingAgainBeforeTheLateDeleteSurvivesIt() throws {
        let shelf = Shelf()
        defer { shelf.tidy() }
        let vault = shelf.open()
        let id = try shelf.save(in: vault)
        shelf.backend.undeletable = true
        vault.forget(id)
        try vault.remember(secret, for: id)
        shelf.backend.undeletable = false
        vault.reload()
        #expect(vault.contains(id) && shelf.stillStored(id))
        #expect(vault.pendingForgets.isEmpty)
        #expect(vault.forget(id))
        #expect(!vault.contains(id))
    }

    @Test(arguments: [
        (errSecSuccess, true), (errSecItemNotFound, true),
        (errSecInteractionNotAllowed, false), (errSecMissingEntitlement, false),
    ])
    func onlyGoneOrNeverThereCountsAsDeleted(status: OSStatus, gone: Bool) {
        #expect(KeychainBackend.deleted(status: status) == gone)
    }

    // MARK: lists that cannot be read

    @Test func anUnreadableListStaysUnknownUntilItCanBeRead() throws {
        let shelf = Shelf()
        let id = try shelf.save(in: shelf.open())

        shelf.backend.unreadable = true
        let vault = shelf.open()
        #expect(vault.isKnown == false)
        #expect(vault.ids.isEmpty)
        vault.reload()
        #expect(vault.isKnown == false)

        shelf.backend.unreadable = false
        vault.reload()
        #expect(vault.isKnown)
        #expect(vault.ids == [id])

        // Locked again: what was learned stays learned.
        shelf.backend.unreadable = true
        vault.reload()
        #expect(vault.isKnown && vault.contains(id))

        // Nothing there on a good read is an answer too.
        shelf.backend.unreadable = false
        shelf.backend.delete(account: RememberedSignInVault.account(id))
        vault.reload()
        #expect(vault.isKnown)
        #expect(vault.ids.isEmpty)
    }

    @Test func whatTheKeychainsListingStatusesMean() {
        #expect(KeychainBackend.accounts(status: errSecItemNotFound, found: nil) == [])
        for refusal in [errSecInteractionNotAllowed, errSecMissingEntitlement, errSecSuccess] {
            #expect(KeychainBackend.accounts(status: refusal, found: nil) == nil)
        }
        let rows = [[kSecAttrAccount as String: "signin.a"], [kSecAttrAccount as String: "signin.b"]] as AnyObject
        #expect(KeychainBackend.accounts(status: errSecSuccess, found: rows) == ["signin.a", "signin.b"])
        #if os(iOS)
        if RememberedFixtures.hostHasKeychain { #expect(KeychainBackend().accounts() != nil) }
        #endif
    }

    // MARK: staying put

    @Test func removingAGatewayForgetsItsSignIn() throws {
        let store = RememberedFixtures.memoryStore()
        let gone = UUID()
        try store.remembered.remember(secret, for: gone)
        store.delete(id: gone)
        #expect(store.remembered.ids.isEmpty)
    }

    /// The gateway's saved secrets have no field a remembered password could slip into; a new
    /// field fails here first.
    @Test func theSavedSecretsCarryNoPasswordField() throws {
        let cloudflare = CloudflareAccess(clientId: "i", clientSecret: "c")
        let everything = GatewaySecrets(sessionToken: "s", accessToken: "a", refreshToken: "r", expiresAt: 1,
                                        provider: "p", userId: "u", access: cloudflare)
        let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(everything)) as? [String: Any]
        let names = Set(try #require(object).keys)
        let expected: Set<String> = ["sessionToken", "accessToken", "refreshToken", "expiresAt", "provider", "userId", "access"]
        #expect(names == expected)
    }
}

/// An in-memory Keychain and the defaults that hold pending deletes, reopened as often as a test likes.
@MainActor private final class Shelf {
    let backend = MemoryRememberedSignInBackend()
    private let suite = "remembered-shelf-\(UUID().uuidString)"
    let defaults: UserDefaults

    init() { defaults = UserDefaults(suiteName: suite) ?? .standard }

    func open() -> RememberedSignInVault { RememberedSignInVault(backend: backend, defaults: defaults) }

    @discardableResult func save(in vault: RememberedSignInVault) throws -> UUID {
        let id = UUID()
        try vault.remember(RememberedFixtures.secret, for: id)
        return id
    }

    func stillStored(_ id: UUID) -> Bool { backend.items[RememberedSignInVault.account(id)] != nil }
    func tidy() { defaults.removePersistentDomain(forName: suite) }
}
