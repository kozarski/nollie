import Foundation
import NollieCore

/// Re-pairing replaces credentials only for the same saved assistant.
enum DevicePairingRecovery {
    enum Failure: LocalizedError, Equatable {
        case freshCodeRequired, differentAssistant

        var errorDescription: String? {
            switch self {
            case .freshCodeRequired: String(localized: "This connection needs a fresh pairing code from your Mac.")
            case .differentAssistant: String(localized: "This code is for a different assistant. Make a new code on the Mac for this saved connection.")
            }
        }
    }

    static func needsPairing(_ connection: GatewayConnection) -> Bool {
        connection.authProvider == DevicePairingClient.provider
    }

    static func connection(for invitation: DevicePairingInvitation, replacing saved: GatewayConnection?) throws -> GatewayConnection {
        if var saved {
            guard needsPairing(saved), saved.gateway == invitation.gateway, !saved.hasAccessHeaders else {
                throw Failure.differentAssistant
            }
            saved.authMode = .oauth
            saved.authProvider = DevicePairingClient.provider
            saved.managedInstallationID = nil
            return saved
        }
        return GatewayConnection(name: invitation.displayName, gateway: invitation.gateway,
                                 authMode: .oauth, authProvider: DevicePairingClient.provider,
                                 connectionKind: invitation.gateway.isTailscaleHost ? "tailscale" : "other")
    }
}
