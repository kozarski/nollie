#if os(macOS)
import Foundation
import NollieCore
import Testing
@testable import Nollie

@MainActor
struct ManagedRuntimeHandoffTests {
    private let endpoint = URL(string: "http://127.0.0.1:19241")!
    private let token = String(repeating: "a", count: 64)

    private func ready(_ id: UUID) -> NollieRuntimeIPCResponse {
        .init(snapshot: .init(phase: .ready, installationID: id, endpoint: endpoint,
                              enabledInstallationID: id))
    }

    @Test func verifiedSetupBecomesALocalConnectionAfterOneStatusRead() async throws {
        let id = UUID()
        var reads = 0
        let prepared = try await ManagedRuntimeHandoff.prepare(installationID: id, endpoint: endpoint,
            token: token, name: "Pip", readStatus: { reads += 1; return ready(id) },
            connections: { [] }, isCurrent: { true })
        #expect(reads == 1)
        #expect(prepared.connection.name == "Pip")
        #expect(prepared.connection.managedInstallationID == id)
        #expect(prepared.connection.gateway.base == endpoint)
        #expect(prepared.connection.authMode == .sessionToken && prepared.connection.authProvider == nil)
        #expect(prepared.connection.connectionKind == "local" && prepared.connection.lastProfile == "default")
        #expect(prepared.secrets == GatewaySecrets(sessionToken: token))
    }

    @Test func retryReusesOnlyTheExactManagedInstallation() async throws {
        let id = UUID(), gateway = try GatewayURL.normalize(endpoint.absoluteString)
        let manual = GatewayConnection(name: "Manual", gateway: gateway, authMode: .sessionToken)
        let other = GatewayConnection(name: "Other", gateway: gateway, authMode: .sessionToken,
                                      managedInstallationID: UUID())
        let existing = GatewayConnection(name: "My assistant", gateway: try GatewayURL.normalize("http://127.0.0.1:19240"),
            authMode: .sessionToken, lastProfile: "default", managedInstallationID: id)
        let prepared = try await ManagedRuntimeHandoff.prepare(installationID: id, endpoint: endpoint,
            token: token, name: "New name", readStatus: { ready(id) },
            connections: { [manual, other, existing] }, isCurrent: { true })
        #expect(prepared.connection.id == existing.id && prepared.connection.createdAt == existing.createdAt)
        #expect(prepared.connection.name == existing.name)
        #expect(prepared.connection.gateway.base == endpoint)
    }

    @Test(arguments: ["installation", "consent", "endpoint", "phase", "error", "version"])
    func staleOrUntrustedStatusCannotProduceASavedConnection(_ field: String) async {
        let id = UUID()
        var response = ready(id)
        switch field {
        case "installation": response.snapshot.installationID = UUID()
        case "consent": response.snapshot.enabledInstallationID = nil
        case "endpoint": response.snapshot.endpoint = URL(string: "http://127.0.0.1:19242")
        case "phase": response.snapshot.phase = .restarting
        case "error": response.error = .unavailable
        default: response.version = 2
        }
        await #expect(throws: ManagedRuntimeHandoff.Failure.self) {
            _ = try await ManagedRuntimeHandoff.prepare(installationID: id, endpoint: endpoint,
                token: token, name: "Pip", readStatus: { response },
                connections: { Issue.record("Invalid status must not prepare a saved connection"); return [] },
                isCurrent: { true })
        }
    }

    @Test func lockOrRouteChangeDuringStatusReadCancelsTheHandoff() async {
        let id = UUID()
        var current = true
        await #expect(throws: ManagedRuntimeHandoff.Failure.self) {
            _ = try await ManagedRuntimeHandoff.prepare(installationID: id, endpoint: endpoint,
                token: token, name: "Pip", readStatus: {
                    await Task.yield()
                    current = false
                    return ready(id)
                }, connections: { Issue.record("A stale handoff cannot prepare a save"); return [] },
                isCurrent: { current })
        }
    }

    @Test func alreadyStaleHandoffDoesNotContactTheHelper() async {
        await #expect(throws: ManagedRuntimeHandoff.Failure.self) {
            _ = try await ManagedRuntimeHandoff.prepare(installationID: UUID(), endpoint: endpoint,
                token: token, name: "Pip", readStatus: {
                    Issue.record("A locked or stale request must not use IPC")
                    return ready(UUID())
                }, connections: { [] }, isCurrent: { false })
        }
    }

    @Test func cancelledStatusReadCannotContinueWithItsResult() async {
        let id = UUID()
        let operation = Task { @MainActor in
            try await ManagedRuntimeHandoff.prepare(installationID: id, endpoint: endpoint,
                token: token, name: "Pip", readStatus: {
                    withUnsafeCurrentTask { $0?.cancel() }
                    return ready(id)
                }, connections: { Issue.record("Cancelled work cannot prepare a save"); return [] },
                isCurrent: { true })
        }
        await #expect(throws: CancellationError.self) { _ = try await operation.value }
    }

    @Test func remoteEndpointIsRejectedBeforeAnyCredentialUse() async {
        await #expect(throws: ManagedRuntimeHandoff.Failure.self) {
            _ = try await ManagedRuntimeHandoff.prepare(installationID: UUID(),
                endpoint: URL(string: "https://example.com")!, token: token, name: "Pip",
                readStatus: { Issue.record("Invalid endpoint must not use IPC"); return ready(UUID()) },
                connections: { [] }, isCurrent: { true })
        }
    }

    /// The folder of the first setup was lost while its saved connection stayed in the Keychain. A new
    /// setup became ready, and Connect has to use it and take the old connection's place.
    @Test func aNewReadySetupReplacesTheConnectionToASetupNoLongerOnThisMac() async throws {
        let gone = UUID(), fresh = UUID(), kept = UUID()
        let old = GatewayConnection(name: "Nollie", gateway: try GatewayURL.normalize("http://127.0.0.1:19240"),
            authMode: .sessionToken, lastProfile: "default", managedInstallationID: gone)
        let other = GatewayConnection(name: "Other setup", gateway: try GatewayURL.normalize("http://127.0.0.1:19243"),
            authMode: .sessionToken, managedInstallationID: kept)
        let manual = GatewayConnection(name: "Studio", gateway: try GatewayURL.normalize("https://studio.example"),
            authMode: .sessionToken)
        let prepared = try await ManagedRuntimeHandoff.prepare(installationID: fresh, endpoint: endpoint,
            token: token, name: "Nollie", readStatus: { ready(fresh) },
            connections: { [manual, old, other] }, setupExists: { $0 == kept || $0 == fresh }, isCurrent: { true })
        #expect(prepared.connection.managedInstallationID == fresh)
        #expect(prepared.connection.id != old.id)
        #expect(prepared.connection.gateway.base == endpoint)
        #expect(prepared.replaces == [old.id], "Only the connection whose setup is gone gives way")
    }

    @Test func connectingAgainToTheSameSetupReplacesNothing() async throws {
        let id = UUID()
        let existing = GatewayConnection(name: "Nollie", gateway: try GatewayURL.normalize(endpoint.absoluteString),
            authMode: .sessionToken, managedInstallationID: id)
        let prepared = try await ManagedRuntimeHandoff.prepare(installationID: id, endpoint: endpoint,
            token: token, name: "Nollie", readStatus: { ready(id) },
            connections: { [existing] }, setupExists: { _ in false }, isCurrent: { true })
        #expect(prepared.connection.id == existing.id)
        #expect(prepared.replaces.isEmpty)
    }

    #if NOLLIE_DIRECT
    @Test func aSetupIsMissingOnlyWithoutItsOwnershipRecord() throws {
        let setups = FileManager.default.temporaryDirectory.appendingPathComponent("setups-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: setups) }
        let here = UUID(), gone = UUID(), empty = UUID()
        try FileManager.default.createDirectory(at: setups.appendingPathComponent(here.uuidString), withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: setups.appendingPathComponent(here.uuidString + "/ownership.json"))
        try FileManager.default.createDirectory(at: setups.appendingPathComponent(empty.uuidString), withIntermediateDirectories: true)
        #expect(!ManagedSetupPresence.isMissing(here, setups: setups))
        #expect(ManagedSetupPresence.isMissing(gone, setups: setups))
        #expect(ManagedSetupPresence.isMissing(empty, setups: setups))
        #expect(!ManagedSetupPresence.isMissing(nil, setups: setups), "Not a connection to Nollie's own assistant")
    }
    #endif
}
#endif
