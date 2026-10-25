import Foundation
import Testing
@testable import Nollie
import NollieCore

struct DevicePairingRecoveryTests {
    private func invitation(_ address: String = "https://studio.example.invalid") throws -> DevicePairingInvitation {
        try DevicePairingInvitation(gateway: GatewayURL.normalize(address), id: UUID().uuidString.lowercased(),
                                    grant: String(repeating: "a", count: 64), displayName: "Name from QR",
                                    expiresAt: Date().addingTimeInterval(120))
    }

    @Test func repairingKeepsTheSavedIdentityAndPersonalChoices() throws {
        let invite = try invitation()
        let saved = GatewayConnection(name: "My Mac", gateway: invite.gateway, authMode: .oauth,
                                      authProvider: DevicePairingClient.provider,
                                      createdAt: Date(timeIntervalSince1970: 100), lastProfile: "default",
                                      lastVersion: "1.0", connectionKind: "tailscale")
        let replacement = try DevicePairingRecovery.connection(for: invite, replacing: saved)
        #expect(replacement == saved)
        #expect(replacement.id == saved.id)
        #expect(replacement.name != invite.displayName)
    }

    @Test func anotherAssistantCannotReplaceTheSavedConnection() throws {
        let saved = GatewayConnection(name: "Home", gateway: try GatewayURL.normalize("https://home.example.invalid"),
                                      authMode: .oauth, authProvider: DevicePairingClient.provider)
        let original = saved
        #expect(throws: DevicePairingRecovery.Failure.differentAssistant) {
            try DevicePairingRecovery.connection(for: invitation(), replacing: saved)
        }
        #expect(saved == original)
    }

    @Test func anOrdinarySignInIsNeverOverwrittenAsPairing() throws {
        let invite = try invitation()
        let saved = GatewayConnection(name: "Home", gateway: invite.gateway, authMode: .oauth, authProvider: "ordinary")
        #expect(throws: DevicePairingRecovery.Failure.differentAssistant) {
            try DevicePairingRecovery.connection(for: invite, replacing: saved)
        }
    }

    @Test func firstPairingCreatesAnIndependentPhoneConnection() throws {
        let invite = try invitation()
        let first = try DevicePairingRecovery.connection(for: invite, replacing: nil)
        let second = try DevicePairingRecovery.connection(for: invite, replacing: nil)
        #expect(first.id != second.id)
        #expect(first.authMode == .oauth)
        #expect(first.authProvider == DevicePairingClient.provider)
        #expect(first.managedInstallationID == nil)
        #expect(!first.hasAccessHeaders)
    }
}
