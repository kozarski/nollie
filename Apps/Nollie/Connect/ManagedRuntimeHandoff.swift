#if os(macOS)
import Foundation
import NollieCore

/// Converts a previously verified service into a saved connection after one fresh,
/// authenticated status read. This never registers or starts a service.
@MainActor
enum ManagedRuntimeHandoff {
    enum Failure: Error { case changed }

    struct Prepared: Sendable {
        let connection: GatewayConnection
        let secrets: GatewaySecrets
        /// Saved connections to Nollie's own assistant whose setup is no longer on this Mac. The new
        /// one takes their place, so they are removed once it is in use.
        var replaces: [UUID] = []
    }

    static func prepare(installationID: UUID, endpoint: URL, token: String, name: String,
                        readStatus: () async throws -> NollieRuntimeIPCResponse,
                        connections: () -> [GatewayConnection],
                        setupExists: (UUID) -> Bool = { !ManagedSetupPresence.isMissing($0) },
                        isCurrent: () -> Bool) async throws -> Prepared {
        try Task.checkCancellation()
        guard isCurrent(), GatewayConnection.isManagedLoopbackEndpoint(endpoint),
              token.count == 64, token.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            throw Failure.changed
        }
        let response = try await readStatus()
        try Task.checkCancellation()
        guard isCurrent(), response.version == 1, response.error == nil,
              response.snapshot.phase == .ready,
              response.snapshot.installationID == installationID,
              response.snapshot.enabledInstallationID == installationID,
              response.snapshot.endpoint == endpoint else { throw Failure.changed }

        let gateway = try GatewayURL.normalize(endpoint.absoluteString)
        let saved = connections()
        var connection = saved.first { $0.managedInstallationID == installationID }
            ?? GatewayConnection(name: name, gateway: gateway, authMode: .sessionToken,
                                 lastProfile: "default", managedInstallationID: installationID)
        connection.gateway = gateway
        connection.authMode = .sessionToken
        connection.authProvider = nil
        connection.hasAccessHeaders = false
        connection.connectionKind = "local"
        let gone = saved.filter { old in
            guard let other = old.managedInstallationID, other != installationID, old.id != connection.id else { return false }
            return !setupExists(other)
        }
        return Prepared(connection: connection, secrets: GatewaySecrets(sessionToken: token), replaces: gone.map(\.id))
    }
}

/// Whether the setup a connection to Nollie's own assistant belongs to is still on this Mac. Its folder
/// can go while the saved connection, kept in the Keychain, stays: a cleaner app, a move to another Mac,
/// a removal that stopped part way.
enum ManagedSetupPresence {
    /// True only when the setup is known to be gone: no folder with its ownership record where Nollie
    /// keeps setups. Never in the demo or an edition that can't run one.
    static func isMissing(_ installation: UUID?, setups: URL = NolliePaths.current.setups) -> Bool {
        guard let installation else { return false }
        #if NOLLIE_DIRECT
        guard !DemoMode.isOn else { return false }
        let record = setups.appendingPathComponent(installation.uuidString, isDirectory: true)
            .appendingPathComponent("ownership.json")
        return !FileManager.default.fileExists(atPath: record.path)
        #else
        return false
        #endif
    }
}
#endif
