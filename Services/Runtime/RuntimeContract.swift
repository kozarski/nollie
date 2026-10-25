#if os(macOS)
import Foundation
#if canImport(NollieCore)
import NollieCore
#endif

/// This contract is internal to the direct Mac app and its signed helper. It is not
/// a network API. The helper's IPC boundary must authenticate the calling app first.
enum NollieRuntimeContract {
    static let serviceLabel = "com.coreykozarski.nollie.runtime"
    static let owner = "com.coreykozarski.nollie"
    static let protocolVersion = 1

    enum Phase: String, Codable, Sendable { case stopped, validating, starting, ready, restarting, failed }
    struct Snapshot: Codable, Equatable, Sendable {
        var phase: Phase = .stopped
        var installationID: UUID?
        var endpoint: URL?
        var restartCount = 0
        var failure: Failure?
    }
    enum Failure: String, Error, Codable, Sendable {
        case unavailable, consentRequired, invalidInstallation, preparationChanged, alreadyRunning
        case launchFailed, startupTimedOut, identityMismatch, childExited, restartLimit, cancelled
    }
    enum Role: String, Codable, Sendable { case api, gateway }
    struct Child: Hashable, Sendable {
        let id: UUID
        let pid: Int32
        let role: Role
    }
    enum Health: Equatable, Sendable { case starting, ready(port: Int?), exited(Int32) }

    /// A fresh user-approved start is required after a deliberate stop or a failure.
    /// Persisting this choice belongs to the authenticated service registration flow.
    struct StartConsent: Sendable { let installationID: UUID }

    struct Plan: Sendable {
        let installationID: UUID
        let installation: URL
        let executable: URL
        let entrypoint: URL
        var source: URL { installation.appendingPathComponent("hermes") }
        var home: URL { installation.appendingPathComponent("home") }

        func arguments(for role: Role) -> [String] {
            ["-I", "-B", entrypoint.path, "--source", source.path, "--role", role.rawValue]
        }
        func environment(for role: Role, token: String) -> [String: String] {
            var result = NativeSetupPlan.environment(installation: installation)
            result["HERMES_RUNTIME_DIR"] = installation.appendingPathComponent("runtime/store").path
            result["HERMES_INSTALL_ROOT"] = source.path
            result["HERMES_DISABLE_LAZY_INSTALLS"] = "1"
            result["PYTHONPATH"] = source.path
            result["PATH"] = installation.appendingPathComponent("environment/bin").path + ":/usr/bin:/bin:/usr/sbin:/sbin"
            result["PYTHONUNBUFFERED"] = "1"
            result["NOLLIE_OWNER_FD"] = "3"
            // The computer add-on calls Cua's tool by full path, inside whichever copy is in use.
            if let cua = NollieCuaPlaces.cli(home: FileManager.default.homeDirectoryForCurrentUser, own: NolliePaths.current.cua) {
                result["NOLLIE_CUA_CLI"] = cua.path
            }
            // Where the computer add-on reads whether the exit relay carries the computers' traffic.
            result["NOLLIE_EXIT_RELAY"] = NolliePaths.current.runtimeService.appendingPathComponent(NollieExitRelayRecord.fileName).path
            if role == .api { result["HERMES_DASHBOARD_SESSION_TOKEN"] = token }
            return result
        }
    }

    static func validToken(_ token: String) -> Bool {
        token.utf8.count == 64 && token.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
    static func readyPort(_ line: String) -> Int? {
        let prefix = "HERMES_BACKEND_READY port="
        guard line.hasPrefix(prefix), let port = Int(line.dropFirst(prefix.count)), (1...65535).contains(port) else { return nil }
        return port
    }
    static func verifyIdentity(_ data: Data, expectedPID: Int32) throws {
        struct Identity: Decodable { let ok: Bool; let protocolVersion: Int; let pid: Int32; let role: String; let servesSpa: Bool }
        guard data.count <= 4096,
              let identity = try? JSONDecoder().decode(Identity.self, from: data), identity.ok,
              identity.protocolVersion == protocolVersion, identity.pid == expectedPID,
              identity.role == "serve", !identity.servesSpa else { throw Failure.identityMismatch }
    }
}

protocol NollieRuntimeBackend: Sendable {
    func prepare(installationID: UUID) async throws -> NollieRuntimeContract.Plan
    func launch(_ role: NollieRuntimeContract.Role, plan: NollieRuntimeContract.Plan, token: String) async throws -> NollieRuntimeContract.Child
    func health(_ child: NollieRuntimeContract.Child, plan: NollieRuntimeContract.Plan, token: String) async throws -> NollieRuntimeContract.Health
    func stop(_ child: NollieRuntimeContract.Child) async
    func release() async
}
#endif
