import Foundation
import LocalAuthentication
import Testing
@testable import Nollie
@testable import NollieCore

/// An owner check (Face ID, in life) that answers as told and keeps what it was asked.
@MainActor final class ScriptedOwnerCheck: DeviceOwnerAuthenticating {
    var willPass = true
    var canAuthenticate = true
    var methodName = "Face ID"
    var hold: Duration = .zero
    private(set) var asked: [String] = []

    func authenticate(reason: String) async -> LAContext? {
        asked.append(reason)
        if hold > .zero { try? await Task.sleep(for: hold) }
        return willPass ? LAContext() : nil
    }
}

/// A list a closure can add to while it runs on the main actor.
@MainActor final class Tally<Entry> {
    private(set) var entries: [Entry] = []
    func add(_ entry: Entry) { entries.append(entry) }
    var count: Int { entries.count }
}

/// A clock the test winds by hand.
@MainActor final class HandClock {
    var now = Date(timeIntervalSince1970: 1_800_000_000)
    func advance(_ seconds: TimeInterval) { now = now.addingTimeInterval(seconds) }
}

enum RememberedFixtures {
    static let address = try! GatewayURL.normalize("https://gateway.example.com")
    static let secret = RememberedSignIn(provider: "basic", username: "river-at-home", password: "plum-tree-lantern", gateway: address)

    static func connection(_ mode: AuthMode = .password, name: String = "Home", at url: GatewayURL = address) -> GatewayConnection {
        GatewayConnection(name: name, gateway: url, authMode: mode, authProvider: "basic")
    }

    @MainActor static func memoryStore() -> ConnectionStore {
        let store = ConnectionStore()
        store.remembered = RememberedSignInVault(backend: MemoryRememberedSignInBackend())
        return store
    }

    /// A runtime for a password gateway where nothing listens, over a store with no saved secrets.
    @MainActor static func deadEndRuntime(called name: String) throws -> (store: ConnectionStore, id: UUID, runtime: GatewayRuntime) {
        let store = memoryStore()
        let target = GatewayConnection(name: name, gateway: try GatewayURL.normalize("http://127.0.0.1:1"), authMode: .password)
        return (store, target.id, GatewayRuntime(connection: target, store: store))
    }

    /// Whether this host offers a Keychain at all (unsigned test builds don't: errSecMissingEntitlement).
    static let hostHasKeychain: Bool = {
        var query = KeychainRememberedSignInBackend.query(account: nil)
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitAll
        var found: AnyObject?
        return SecItemCopyMatching(query as CFDictionary, &found) != errSecMissingEntitlement
    }()
}

/// A coordinator wired to in-memory parts, plus the dials the tests turn.
@MainActor final class SignInRig {
    let backend = MemoryRememberedSignInBackend()
    let check = ScriptedOwnerCheck()
    let clock = HandClock()
    let coordinator: RememberedSignInCoordinator
    let home = RememberedFixtures.connection()

    /// `startLocked`: the sign-in is on the device but the list cannot be read when the coordinator
    /// starts, as when the app is launched in the background on a locked phone.
    init(remembering: Bool = true, startLocked: Bool = false) throws {
        let id = home.id
        if startLocked {
            try RememberedSignInVault(backend: backend).remember(RememberedFixtures.secret, for: id)
            backend.unreadable = true
        }
        let made = RememberedSignInCoordinator(vault: RememberedSignInVault(backend: backend), authenticator: check)
        made.now = { [clock] in clock.now }
        if remembering && !startLocked { try made.vault.remember(RememberedFixtures.secret, for: id) }
        coordinator = made
    }

    /// The sign-in the gateway would give back.
    func gatewayAccepts(_ token: String = "a") {
        coordinator.signIn = { _, _, _ in GatewaySecrets(accessToken: token) }
    }

    func gatewayMustNotBeCalled(_ why: String) {
        coordinator.signIn = { _, _, _ in
            Issue.record("\(why)")
            return GatewaySecrets()
        }
    }

    func again(_ connection: GatewayConnection? = nil) async -> GatewaySecrets? {
        await coordinator.signInAgain(connection ?? home, access: CloudflareAccess())
    }

    /// A runtime for `home` the way the app finds it on return, with its socket turned away. With
    /// `refreshTurnedDown` the refresh is refused as well (nothing is stored, so renewal fails with no request).
    func returningRuntime(refreshTurnedDown: Bool) async -> GatewayRuntime {
        let runtime = GatewayRuntime(connection: home, store: RememberedFixtures.memoryStore())
        runtime.socketEnabled = false
        if refreshTurnedDown { _ = try? await runtime.refreshSession() }
        runtime.socketState = .authRejected("The gateway turned down the WebSocket credential (4401).")
        return runtime
    }
}
