import Foundation
import Observation
import UserNotifications
import NollieCore
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

/// The three system calls the registrar needs, so tests can stand in for them.
@MainActor
struct NotificationAuthorizationClient {
    var status: () async -> UNAuthorizationStatus
    var request: () async throws -> Bool
    var register: () -> Void

    static let system = Self(
        status: { await UNUserNotificationCenter.current().notificationSettings().authorizationStatus },
        request: {
            let wanted: UNAuthorizationOptions = .timeSensitive
            let center = UNUserNotificationCenter.current()
            return try await center.requestAuthorization(options: wanted.union([.alert, .sound, .badge]))
        },
        register: {
            #if os(iOS)
            UIApplication.shared.registerForRemoteNotifications()
            #else
            NSApplication.shared.registerForRemoteNotifications()
            #endif
        }
    )
}

extension Notification.Name {
    /// Posted when the device token arrives, so the app can publish the registration again.
    static let hermesPushRegistrationNeedsSync = Notification.Name("nollie.push.registrationNeedsSync")
}

/// Gets this device a push token, tells the Nollie relay about it, and publishes a device file to
/// the gateway so the push companion (Companions/hermes-push) knows where to send notifications.
@MainActor
@Observable
final class PushRegistrar: PushRegistrationSyncing {
    // MARK: Keys and names

    static let installIDKey = "pushInstallID"
    /// Settings, Notifications: the master switch. Off removes this device from gateway and relay.
    static let enabledKey = "notificationsEnabled"
    /// Settings > Notifications: stay quiet while a Mac is handling the chat. The companion reads this too.
    static let muteDesktopOriginKey = "push.muteDesktopOrigin"

    /// The platform name used in the device file and by the relay.
    static let platform: String = {
        #if os(macOS)
        return "macos"
        #else
        return "ios"
        #endif
    }()

    /// The name the person gave this device, shown beside it in the companion's diagnostics.
    static var deviceName: String {
        #if os(iOS)
        return UIDevice.current.name
        #else
        return Host.current().localizedName ?? "Mac"
        #endif
    }

    var notificationsEnabled: Bool { UserDefaults.standard.object(forKey: Self.enabledKey) as? Bool ?? true }

    var apnsEnvironment: String {
        #if DEBUG
        "development"
        #else
        "production"
        #endif
    }

    // MARK: State

    var deviceToken: String?
    var authorization: UNAuthorizationStatus = .notDetermined
    var lastRegistrationPath: String?
    var lastError: String?
    var registeredAt: Date?
    var registrationFailure: String?
    var relayRegisteredAt: Date?
    var relayError: String?
    var relayNeedsInvitation = false

    let installID: String

    @ObservationIgnored private let system: NotificationAuthorizationClient
    @ObservationIgnored private var refreshing: Task<Void, Never>?
    @ObservationIgnored private var asking: Task<Bool, Never>?
    @ObservationIgnored private var askedSystemToRegister = false
    @ObservationIgnored private var originNotedAt: [String: Date] = [:]

    private var canReceive: Bool { authorization == .authorized || authorization == .provisional }

    init(installID: String? = nil, authorizationClient: NotificationAuthorizationClient = .system) {
        system = authorizationClient
        self.installID = installID ?? Self.persistentInstallID()
    }

    /// The id also names this device's file on the gateway, so a reinstall must keep it. That is why it
    /// lives in the Keychain; an id that older builds kept in UserDefaults gets copied across once.
    /// (A fresh id after each reinstall once stranded the old file and doubled every push.)
    private static func persistentInstallID() -> String {
        let defaults = UserDefaults.standard
        let kept = Keychain.get(account: installIDKey).flatMap { String(data: $0, encoding: .utf8) } ?? ""
        let id = kept.isEmpty ? (defaults.string(forKey: installIDKey) ?? UUID().uuidString.lowercased()) : kept
        if kept.isEmpty { try? Keychain.set(Data(id.utf8), account: installIDKey) }
        defaults.set(id, forKey: installIDKey)
        return id
    }

    // MARK: System permission

    /// Reads the permission and, once it allows notifications, asks the system for a push token.
    /// Callers arriving together wait on one read.
    func refreshAuthorization() async {
        if let refreshing { return await refreshing.value }
        refreshing = Task { @MainActor in
            defer { refreshing = nil }
            authorization = await system.status()
            guard canReceive else {
                // Allowing notifications later in Settings needs a new registration.
                askedSystemToRegister = false
                return
            }
            if !askedSystemToRegister {
                askedSystemToRegister = true
                system.register()
            }
        }
        await refreshing?.value
    }

    /// Shows the system prompt if it has not been answered yet. True when notifications end up allowed.
    func requestAuthorization() async -> Bool {
        if let asking { return await asking.value }
        asking = Task { @MainActor in
            defer { asking = nil }
            await refreshAuthorization()
            if authorization != .notDetermined { return canReceive }
            do {
                _ = try await system.request()
                // A read begun while the prompt was up may be out of date.
                await refreshing?.value
                await refreshAuthorization()
                lastError = nil
            } catch {
                lastError = error.localizedDescription
                return false
            }
            return canReceive
        }
        return await asking?.value ?? false
    }

    func registerForRemoteNotificationsIfAuthorized() async {
        await refreshAuthorization()
    }

    func didRegister(token: Data) {
        deviceToken = token.reduce(into: "") { $0 += String(format: "%02x", $1) }
        registrationFailure = nil
        Task { await registerWithRelay() }
        NotificationCenter.default.post(name: .hermesPushRegistrationNeedsSync, object: nil)
    }

    func didFailToRegister(_ error: Error) {
        registrationFailure = error.localizedDescription
        askedSystemToRegister = false
    }

    // MARK: The relay

    /// If this build has a relay, the device signs up there on its own. The gateway then needs only the
    /// install id and secret from the device file, and no APNs key at all.
    func registerWithRelay() async {
        guard notificationsEnabled, PushRelay.isConfigured, let token = deviceToken else { return }
        let bundle = Bundle.main.bundleIdentifier ?? ""
        do {
            try await PushRelay.register(deviceToken: token, platform: Self.platform, bundleID: bundle, environment: apnsEnvironment)
        } catch {
            (relayRegisteredAt, relayError) = (nil, error.localizedDescription)
            if case PushRelay.RelayError.invitationRequired = error { relayNeedsInvitation = true }
            return
        }
        (relayRegisteredAt, relayError, relayNeedsInvitation) = (Date(), nil, false)
    }

    /// A daily nudge tells the relay this device still exists.
    func refreshRelayIfStale() async {
        if let last = relayRegisteredAt, Date().timeIntervalSince(last) < 24 * 3600 { return }
        await registerWithRelay()
    }

    // MARK: Files on the gateway

    /// Where this device's file lives, or nil until the gateway has told us its home folder.
    private func deviceFilePath(_ runtime: GatewayRuntime) -> String? {
        runtime.profileHome.map { $0 + "/push/devices/" + installID + ".json" }
    }

    private func deviceRecord(token: String, runtime: GatewayRuntime) -> [String: JSONValue] {
        let connection = runtime.connection
        var fields: [String: JSONValue] = [
            "schema": 1,
            "profiles": .array(runtime.profiles.map { .string($0.name) }),
        ]
        let words: KeyValuePairs<String, String> = [
            "app": "Nollie", "device_id": installID, "device_name": Self.deviceName, "platform": Self.platform,
            "bundle_id": Bundle.main.bundleIdentifier ?? "", "apns_token": token, "apns_environment": apnsEnvironment,
            "connection_id": connection.id.uuidString, "connection_name": connection.name,
            "gateway": connection.gateway.description, "registered_at": ISO8601DateFormatter().string(from: Date()),
        ]
        for (key, value) in words { fields[key] = .string(value) }
        #if os(iOS)
        fields["mute_desktop_origin"] = .bool(UserDefaults.standard.bool(forKey: Self.muteDesktopOriginKey))
        #endif
        return fields.merging(PushRelay.deviceFileFields()) { _, relay in relay }
    }

    /// Publishes this device's file for the companion to read.
    func syncRegistration(runtime: GatewayRuntime) async {
        guard notificationsEnabled, let token = deviceToken, let path = deviceFilePath(runtime) else { return }
        let record = JSONValue.object(deviceRecord(token: token, runtime: runtime).compactingNulls)
        do {
            try await GatewayFiles.put(record, at: path, via: runtime)
        } catch {
            lastError = "Push registration did not reach the gateway: \(error.localizedDescription)"
            return
        }
        lastRegistrationPath = path
        registeredAt = Date()
        lastError = nil
        // Now that this device is registered, we can finally tell if the gateway runs the companion.
        // The check at launch ran too soon, so the app would show its own banner next to the
        // companion's until the next time it came to the front.
        guard AppModel.shared.companionInstalledVersion == nil else { return }
        Task { @MainActor in await AppModel.shared.refreshCompanionUpdateFlag() }
    }

    /// Takes this device off the relay and the gateway.
    func removeRegistration(runtime: GatewayRuntime) async {
        await PushRelay.unregister()
        guard let path = deviceFilePath(runtime) else { return }
        await GatewayFiles.remove(path, via: runtime)
        if lastRegistrationPath == path { (lastRegistrationPath, registeredAt) = (nil, nil) }
    }

    // MARK: Markers the companion reads

    private enum Marker {
        case origin, answer

        var folder: String { self == .origin ? "origins" : "answers" }
        var failure: String { self == .origin ? "origin marker failed" : "answer marker failed" }
    }

    private func leave(_ marker: Marker, key: String, details: [String: JSONValue], runtime: GatewayRuntime) {
        guard let home = runtime.profileHome else { return }
        let path = "\(home)/push/\(marker.folder)/\(Self.fileSafe(key)).json"
        var body = details
        body["device_id"] = .string(installID)
        body["at"] = .number(Date().timeIntervalSince1970)
        let note = JSONValue.object(body)
        Task {
            do { try await GatewayFiles.put(note, at: path, via: runtime) }
            catch { PushLog.note("\(marker.failure): \(error.localizedDescription)") }
        }
    }

    /// Stamps this device as the latest to prompt a chat. While the stamp says Mac, any phone set to
    /// quiet stays silent. Throttled to one write a minute per chat.
    func noteSend(session: String, runtime: GatewayRuntime) {
        guard !session.isEmpty else { return }
        if let last = originNotedAt[session], -last.timeIntervalSinceNow < 60 { return }
        originNotedAt[session] = Date()
        leave(.origin, key: session, details: ["platform": .string(Self.platform)], runtime: runtime)
    }

    /// Tells the companion an approval was handled on this device, so other devices lose their banner
    /// and this one keeps none to remove.
    func noteAnswer(requestID: String, session: String, runtime: GatewayRuntime) {
        guard notificationsEnabled, !requestID.isEmpty else { return }
        leave(.answer, key: requestID, details: ["session_id": .string(session)], runtime: runtime)
    }

    /// Letters, digits and `._-` stay; anything else becomes an underscore (the companion does the same).
    private static func fileSafe(_ name: String) -> String {
        let keep = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
        return String(String.UnicodeScalarView(name.unicodeScalars.map { keep.contains($0) ? $0 : "_" }))
    }
}

/// Small files on the gateway, written and deleted through its managed files API.
private enum GatewayFiles {
    private static let uploadPath = "/api/files/upload"

    static func put(_ json: JSONValue, at path: String, via runtime: GatewayRuntime) async throws {
        let payload = try JSONEncoder().encode(json)
        let upload: JSONValue = [
            "path": .string(path),
            "overwrite": true,
            "data_url": .string("data:application/json;base64," + payload.base64EncodedString()),
        ]
        let _: ManagedUploadResult = try await runtime.api.send("POST", uploadPath, json: upload)
    }

    static func remove(_ path: String, via runtime: GatewayRuntime) async {
        let removal: JSONValue = ["recursive": false, "path": .string(path)]
        _ = try? await runtime.api.send("DELETE", "/api/files", json: removal) as JSONValue
    }
}
