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
    }

    static func prepare(installationID: UUID, endpoint: URL, token: String, name: String,
                        readStatus: () async throws -> NollieRuntimeIPCResponse,
                        connections: () -> [GatewayConnection],
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
        var connection = connections().first { $0.managedInstallationID == installationID }
            ?? GatewayConnection(name: name, gateway: gateway, authMode: .sessionToken,
                                 lastProfile: "default", managedInstallationID: installationID)
        connection.gateway = gateway
        connection.authMode = .sessionToken
        connection.authProvider = nil
        connection.hasAccessHeaders = false
        connection.connectionKind = "local"
        return Prepared(connection: connection, secrets: GatewaySecrets(sessionToken: token))
    }
}
#endif
