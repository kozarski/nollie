import Foundation
import LocalAuthentication
import NollieCore

// MARK: - Asking the device owner

/// Asks the person to prove they are the owner before a stored sign-in is used (biometrics,
/// the device passcode, or the Mac account password). Kept as a protocol so tests and the
/// simulator build, which has no biometrics, can supply their own answer.
@MainActor
protocol DeviceOwnerAuthenticating: AnyObject {
    /// Label for the check in user-facing text (Optic ID, Passcode, or Password on a Mac).
    var methodName: String { get }
    /// Whether the device can ask at all. That takes a passcode; without one the Keychain has
    /// already thrown the remembered sign-in away.
    var canAuthenticate: Bool { get }
    /// Asks. Returns the context that passed, so the Keychain can open the item without a second
    /// prompt, or nil for a refusal, a cancel or a lockout.
    func authenticate(reason: String) async -> LAContext?
}

final class SystemDeviceOwnerAuthenticator: DeviceOwnerAuthenticating {
    private static let policy = LAPolicy.deviceOwnerAuthentication

    var canAuthenticate: Bool {
        LAContext().canEvaluatePolicy(Self.policy, error: nil)
    }

    var methodName: String {
        let probe = LAContext()
        _ = probe.canEvaluatePolicy(Self.policy, error: nil)
        // Also matched on (`RememberedSignInCopy`, the sign-in symbols), so it stays in English. Show
        // `RememberedSignInCopy.shownMethod(_:)`.
        let byBiometry: [LABiometryType: String] = [.faceID: "Face ID", .touchID: "Touch ID", .opticID: "Optic ID"]
        return byBiometry[probe.biometryType] ?? (DeviceWords.isMac ? "Password" : "Passcode")
    }

    func authenticate(reason: String) async -> LAContext? {
        let session = LAContext()
        session.localizedCancelTitle = String(localized: "Not Now", comment: "Safety: cancels a Face ID check")
        guard let passed = try? await session.evaluatePolicy(Self.policy, localizedReason: reason), passed else {
            return nil
        }
        return session
    }
}

#if DEBUG
/// Used by the simulator demo build, where neither biometrics nor a passcode exist. The launch
/// flag `-nollie-demo-biometry` takes yes or no and answers every check that way, so UI tests can
/// walk the saved-sign-in path. Never part of a release build.
final class DemoDeviceOwnerAuthenticator: DeviceOwnerAuthenticating {
    private let answer: Bool
    let canAuthenticate = true
    let methodName = "Face ID"

    init(answer: Bool) { self.answer = answer }

    func authenticate(reason: String) async -> LAContext? {
        guard answer else { return nil }
        return LAContext()
    }

    /// The answer the launch flag gives, when this is the demo copy and the flag is there.
    static func fromLaunchArguments() -> DemoDeviceOwnerAuthenticator? {
        let words = ProcessInfo.processInfo.arguments
        guard DemoMode.isOn, let at = words.firstIndex(of: "-nollie-demo-biometry"), at + 1 < words.count else {
            return nil
        }
        return DemoDeviceOwnerAuthenticator(answer: words[at + 1] == "yes")
    }
}
#endif

// MARK: - Copy

/// Phrases describing what guards a saved sign-in on this device.
enum RememberedSignInCopy {
    /// `methodName` as the person reads it: Face ID, Touch ID and Optic ID as they are, the rest in their language.
    static func shownMethod(_ method: String) -> String {
        switch method {
        case "Passcode": String(localized: "Passcode", comment: "The device passcode, as a way to sign in")
        case "Password": String(localized: "Password", comment: "The Mac's login password, as a way to sign in")
        default: method
        }
    }

    /// Phrasings produced: the passcode alone, Touch ID with your password, Face ID with the passcode.
    /// `method` is a `methodName`, matched in English.
    static func guardedBy(_ method: String) -> String {
        guard !DeviceWords.isMac else {
            return method == "Touch ID"
                ? String(localized: "Touch ID or your password", comment: "In the middle of a sentence: what can sign you back in")
                : String(localized: "your password", comment: "In the middle of a sentence: what can sign you back in")
        }
        return method == "Passcode"
            ? String(localized: "the passcode", comment: "In the middle of a sentence: what can sign you back in")
            : String(localized: "\(method) or the passcode", comment: "In the middle of a sentence; %@ is Face ID, Touch ID or Optic ID")
    }

    /// Shown under the switch when it is on. One whole sentence per case, so each language can build its own.
    static func kept(_ method: String) -> String {
        if DeviceWords.isMac {
            return method == "Touch ID"
                ? String(localized: "Kept in this Mac's Keychain behind Touch ID or your password, so Nollie signs in again by itself when the session ends. Never synced to iCloud.")
                : String(localized: "Kept in this Mac's Keychain behind your password, so Nollie signs in again by itself when the session ends. Never synced to iCloud.")
        }
        let device = DeviceWords.device
        return method == "Passcode"
            ? String(localized: "Kept in this \(device)'s Keychain behind the passcode, so Nollie signs in again by itself when the session ends. Never synced to iCloud.",
                     comment: "%@ is iPhone or iPad")
            : String(localized: "Kept in this \(device)'s Keychain behind \(method) or the passcode, so Nollie signs in again by itself when the session ends. Never synced to iCloud.",
                     comment: "The first %@ is iPhone or iPad, the second Face ID, Touch ID or Optic ID")
    }

    /// Appears beneath the switch on a device with no passcode.
    static var needsPasscode: String {
        DeviceWords.isMac ? String(localized: "Remembering a sign-in needs a login password on this Mac.")
                          : String(localized: "Remembering a sign-in needs a passcode on \(DeviceWords.this).",
                                   comment: "%@ is a phrase like this iPhone")
    }
}

// MARK: - Errors

/// Why a remembered sign-in failed, phrased for the Sign In sheet.
enum RememberedSignInError: LocalizedError, Equatable {
    case cancelled, gone, rejected
    /// Saved for an address that the gateway has since dropped.
    case moved

    var errorDescription: String? {
        switch self {
        case .gone: String(localized: "\(DeviceWords.This) no longer remembers a sign-in for this gateway. Enter it again.",
                           comment: "%@ is a phrase like This iPhone")
        case .cancelled: String(localized: "That check did not finish. Try once more, or type the sign-in.")
        case .moved: String(localized: "The gateway's address changed since you saved this sign-in, so it has been cleared. Please enter it again.")
        case .rejected: String(localized: "The gateway turned down the saved sign-in, so it has been cleared. Please enter the current one.")
        }
    }
}

// MARK: - The coordinator

/// Signs a gateway in once more with no visit to the sheet, after a Face ID check, when the
/// session has ended for good and the person had asked the device to keep the sign-in. Only a
/// username and password can be kept. A browser sign-in carries a refresh token that renews on
/// its own; if the gateway rejects it, nothing but the browser can fix that.
@MainActor
final class RememberedSignInCoordinator {
    /// The way forward once a session has run out.
    enum Decision: Equatable, Sendable {
        /// Run the Face ID or passcode check, and on success sign in with the stored details.
        case useRemembered
        /// Show the usual sign-in prompt, for this reason.
        case askPerson(Reason)
    }

    enum Reason: Equatable, Sendable {
        /// A browser sign-in or session token: there is no typed password to reuse.
        case notPasswordSignIn, nothingRemembered
        /// The device has no passcode, so a saved sign-in would have no protection.
        case noPasscode
        /// Another app is in front or the app's own lock is up. Retry when it is usable again.
        case notNow
        /// The check was declined or did not work after the previous sign-in. Nothing is attempted again
        /// until the person presses the button on the Sign In sheet.
        case declined
        /// Too many automatic sign-ins for this gateway lately (see `allowedByFloor`). If it kept
        /// dropping sessions, Face ID would pop up and the password go out again every minute. Until the
        /// floor lifts, only the sheet's button gets through.
        case tooSoon
    }

    /// Chooses from plain facts. `asked` means the person tapped the button, so the timing and
    /// earlier-refusal checks are skipped.
    nonisolated static func decide(
        authMode: AuthMode, remembered: Bool, canAuthenticate: Bool, canPromptNow: Bool,
        declined: Bool, usedRecently: Bool, asked: Bool
    ) -> Decision {
        var checks: [(blocked: Bool, reason: Reason)] = [
            (authMode != .password, .notPasswordSignIn),
            (!remembered, .nothingRemembered),
            (!canAuthenticate, .noPasscode),
        ]
        if !asked {
            checks += [(!canPromptNow, .notNow), (declined, .declined), (usedRecently, .tooSoon)]
        }
        guard let first = checks.first(where: \.blocked) else { return .useRemembered }
        return .askPerson(first.reason)
    }

    // Throttle on automatic sign-ins, shared by both entry points and tracked per gateway: at least
    // 60 seconds between them and no more than `budget` within `budgetWindow`. The button on the
    // sheet ignores this and is never counted.
    nonisolated static let budgetWindow: TimeInterval = 600
    nonisolated static let minimumInterval: TimeInterval = 60
    nonisolated static let budget: Int = 3

    /// Whether one more automatic sign-in may go ahead at `now`, given when the earlier ones were.
    nonisolated static func allowedByFloor(_ times: [Date], now: Date) -> Bool {
        // An entry dated in the future (the clock moved back) is skipped, since counting it would block
        // both paths until the app restarts.
        var ages: [TimeInterval] = []
        for time in times {
            let age = now.timeIntervalSince(time)
            if age >= 0 && age < budgetWindow { ages.append(age) }
        }
        if ages.count >= budget { return false }
        return (ages.min() ?? minimumInterval) >= minimumInterval
    }

    /// Facts passed in: the form's switch now (`switchOn`), its state at open (`wasOn`), whether
    /// a username and password were typed (`typed`), and whether the address being saved differs from
    /// the one the form started with (`moved`).
    nonisolated static func formChange(authMode: AuthMode, switchOn: Bool, wasOn: Bool, typed: Bool, moved: Bool) -> FormChange {
        // Other sign-in methods have no typed password to reuse.
        if authMode != .password { return .forget }
        if switchOn && typed { return .remember }
        // A password typed for the old address is worthless at the new one.
        if moved { return .forget }
        // Forget only if the person flipped the switch off in this form. A switch that merely opened
        // off proves nothing: it also opens off when the stored list was unreadable (phone locked at
        // launch), and saving in that state used to wipe a sign-in the person meant to keep.
        return wasOn && !switchOn ? .forget : .keep
    }

    /// What saving a gateway's form means for its remembered sign-in.
    enum FormChange: Equatable, Sendable {
        /// Keep the typed username and password for the address being saved.
        case remember, forget
        /// Leave whatever is stored alone.
        case keep
    }

    // MARK: State

    private(set) var declined = Set<UUID>()
    /// For each gateway, when it was last signed in automatically (within `budgetWindow`).
    private(set) var signedInByItself = [UUID: [Date]]()
    private var inFlight = [UUID: Task<GatewaySecrets, Error>]()

    /// Face ID may be shown right now: the app is frontmost and unlocked.
    var canPromptNow: @MainActor () -> Bool = { true }
    /// The clock. Tests replace it.
    var now: @MainActor () -> Date = { Date() }
    /// The password sign-in call. Tests replace it.
    var signIn: @MainActor (GatewayConnection, RememberedSignIn, CloudflareAccess) async throws -> GatewaySecrets = { connection, saved, access in
        try await NativeAuthClient.signInWithPassword(
            gateway: connection.gateway, provider: saved.provider,
            username: saved.username, password: saved.password, access: access)
    }

    var authenticator: any DeviceOwnerAuthenticating
    let vault: RememberedSignInVault

    init(vault: RememberedSignInVault, authenticator: (any DeviceOwnerAuthenticating)? = nil) {
        self.vault = vault
        self.authenticator = authenticator ?? Self.defaultAuthenticator()
    }

    static func defaultAuthenticator() -> any DeviceOwnerAuthenticating {
        let real = SystemDeviceOwnerAuthenticator()
        #if DEBUG
        return DemoDeviceOwnerAuthenticator.fromLaunchArguments() ?? real
        #else
        return real
        #endif
    }

    func decision(for connection: GatewayConnection, asked: Bool) -> Decision {
        let history = signedInByItself[connection.id, default: []]
        return Self.decide(
            authMode: connection.authMode,
            remembered: vault.contains(connection.id),
            canAuthenticate: authenticator.canAuthenticate,
            canPromptNow: asked || canPromptNow(),
            declined: declined.contains(connection.id),
            usedRecently: !Self.allowedByFloor(history, now: now()),
            asked: asked)
    }

    // MARK: Entry points

    /// The runtime calls this as soon as the gateway rejects the refresh token. Returns new secrets
    /// if the saved sign-in can be used, or nil so the sign-in prompt appears. A rejection here means
    /// the session is truly gone (the gateway came back with a new signing key, for instance), so only
    /// the throttle can hold it back.
    func signInAgain(_ connection: GatewayConnection, access: CloudflareAccess) async -> GatewaySecrets? {
        await autoSignIn(connection, access: access)
    }

    /// The app came to the front or unlocked while the gateway in use is rejecting its session. Try
    /// the saved sign-in that could not run during the absence, but only when the refresh token
    /// itself was rejected. A socket that failed after a successful renewal gains nothing from
    /// another sign-in, and trying used to show Face ID on every return for no reason.
    func signInAgainOnReturn(_ runtime: GatewayRuntime) async -> GatewaySecrets? {
        guard runtime.refreshRefused, case .authRejected = runtime.socketState else { return nil }
        return await autoSignIn(runtime.connection, access: runtime.secrets.access)
    }

    /// Same sign-in, but started from the button on the Sign In sheet. It does not wait for a better
    /// moment, and problems are reported in words.
    func signInWithRemembered(_ connection: GatewayConnection, access: CloudflareAccess) async throws -> GatewaySecrets {
        if decision(for: connection, asked: true) != .useRemembered { throw RememberedSignInError.gone }
        return try await perform(connection, access: access, automatic: false)
    }

    /// Call after the person signs in by hand, so automatic sign-in is allowed again.
    func didSignIn(_ id: UUID) {
        signedInByItself[id] = nil
        declined.remove(id)
    }

    // MARK: Doing it

    private func autoSignIn(_ connection: GatewayConnection, access: CloudflareAccess) async -> GatewaySecrets? {
        // At launch the device may have been locked and unable to read the saved list. Read again now
        // instead of acting as if nothing were saved.
        if !vault.isKnown { vault.reload() }
        if decision(for: connection, asked: false) != .useRemembered { return nil }
        guard let secrets = try? await perform(connection, access: access, automatic: true) else {
            declined.insert(connection.id)
            return nil
        }
        return secrets
    }

    /// Only one prompt runs per gateway. Calls that fail in a rush all join it and count once.
    private func perform(_ connection: GatewayConnection, access: CloudflareAccess, automatic: Bool) async throws -> GatewaySecrets {
        if let running = inFlight[connection.id] { return try await running.value }
        let task = Task { try await attempt(connection, access: access) }
        inFlight[connection.id] = task
        defer { inFlight[connection.id] = nil }

        let secrets = try await task.value
        if automatic {
            let moment = now()
            let recent = signedInByItself[connection.id, default: []].filter { moment.timeIntervalSince($0) < Self.budgetWindow }
            signedInByItself[connection.id] = recent + [moment]
        }
        return secrets
    }

    private func attempt(_ connection: GatewayConnection, access: CloudflareAccess) async throws -> GatewaySecrets {
        let reason = String(localized: "Sign in to \(connection.name)", comment: "Safety: why Face ID is asked; %@ is a gateway's name")
        guard let context = await authenticator.authenticate(reason: reason) else {
            throw RememberedSignInError.cancelled
        }
        guard let saved = try vault.signIn(for: connection.id, context: context) else {
            throw RememberedSignInError.gone
        }
        // A password is only good for the address it was typed against. If the gateway moved since,
        // delete it and never send it to the new place.
        if !saved.belongs(to: connection.gateway) {
            vault.forget(connection.id)
            throw RememberedSignInError.moved
        }
        do {
            var secrets = try await signIn(connection, saved, access)
            secrets.access = access
            declined.remove(connection.id)
            return secrets
        } catch let failure as HermesAPIError where failure.isUnauthorized {
            // The password was changed on the gateway. Keeping it would ask for Face ID for nothing.
            vault.forget(connection.id)
            throw RememberedSignInError.rejected
        }
    }
}
