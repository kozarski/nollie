import Foundation

/// Tracks whether the companion's own sign-in works. A saved sign-in proves nothing until it is
/// installed and a later heartbeat either accepts or rejects it, so this remembers which heartbeats
/// count as evidence for the current credential.
struct CompanionSignInState: Codable {
    private(set) var needsInstall = false
    private(set) var rejected = false
    private var previousHeartbeat: Double?
    private var verificationNotBefore: Double?
    private var latestObservedHeartbeat: Double?

    /// How long the running companion needs to notice a changed config before a failure counts.
    private static let reloadGrace: Double = 10
    private static let freshRange: ClosedRange<Double> = -5...60

    // MARK: Saving

    private static func storageKey(_ id: UUID) -> String { "companionSignInState." + id.uuidString }

    static func restore(connectionID: UUID, defaults: UserDefaults = .standard) -> Self {
        defaults.data(forKey: storageKey(connectionID)).flatMap { try? JSONDecoder().decode(Self.self, from: $0) } ?? Self()
    }

    func save(connectionID: UUID, defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(self) { defaults.set(data, forKey: Self.storageKey(connectionID)) }
    }

    // MARK: Events

    /// A new sign-in was saved. It does nothing until it is installed.
    mutating func signedIn(after heartbeat: Double?) {
        needsInstall = true
        rejected = false
        previousHeartbeat = heartbeat
        verificationNotBefore = nil
        latestObservedHeartbeat = nil
    }

    /// The config carrying the new sign-in is on the gateway.
    mutating func installed(after heartbeat: Double?, at now: Date) {
        guard needsInstall else { return }
        needsInstall = false
        previousHeartbeat = heartbeat
        verificationNotBefore = now.timeIntervalSince1970 + Self.reloadGrace
    }

    mutating func observe(_ heartbeat: PushSetupModel.CompanionHeartbeat, at now: Date) {
        guard accepts(heartbeat, at: now) else { return }
        latestObservedHeartbeat = heartbeat.updatedAt
        if heartbeat.connected == true {
            rejected = false
            verificationNotBefore = nil
        } else if Self.isSignInRejection(heartbeat) {
            rejected = true
            verificationNotBefore = nil
        }
    }

    // MARK: Questions

    /// Whether this heartbeat is evidence about the current sign-in.
    func accepts(_ heartbeat: PushSetupModel.CompanionHeartbeat, at now: Date) -> Bool {
        guard !needsInstall, Self.isFresh(heartbeat, at: now) else { return false }
        let stamp = heartbeat.updatedAt
        if let previousHeartbeat, stamp <= previousHeartbeat { return false }
        if let verificationNotBefore, stamp < verificationNotBefore { return false }
        if let latestObservedHeartbeat, stamp < latestObservedHeartbeat { return false }
        return true
    }

    func waitingForHeartbeat(_ heartbeat: PushSetupModel.CompanionHeartbeat?, at now: Date) -> Bool {
        guard verificationNotBefore != nil else { return false }
        guard let heartbeat else { return true }
        return !accepts(heartbeat, at: now)
    }

    static func isFresh(_ heartbeat: PushSetupModel.CompanionHeartbeat, at now: Date) -> Bool {
        let age = now.timeIntervalSince1970 - heartbeat.updatedAt
        return age.isFinite && freshRange.contains(age)
    }

    /// Only a refusal from Hermes itself calls for another sign-in. Access-gate failures need their own setup.
    static func isSignInRejection(_ heartbeat: PushSetupModel.CompanionHeartbeat) -> Bool {
        guard heartbeat.connected == false, let message = heartbeat.error?.lowercased() else { return false }
        if message.contains("cloudflare") || message.contains("cf-access") { return false }
        return ["sign-in rejected", "http 401", "http 403", "4401"].contains { message.contains($0) }
    }
}
