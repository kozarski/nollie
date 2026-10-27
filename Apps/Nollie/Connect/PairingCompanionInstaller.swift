#if os(macOS)
import CryptoKit
import Foundation
import Observation
import NollieCore

/// Runs only after the person accepts the pairing setup review.
@MainActor @Observable
final class PairingCompanionInstaller {
    enum Phase: Equatable {
        case idle, checking, backingUp, copying, enabling, verifying, ready, needsActivation, failed
    }
    private(set) var phase: Phase = .idle
    private(set) var message: String?
    private(set) var backupDirectory: URL?
    var isBusy: Bool { [.checking, .backingUp, .copying, .enabling, .verifying].contains(phase) }

    func clearStatus() {
        guard !isBusy else { return }
        phase = .idle
        message = nil
    }

    struct Operations {
        var check: @MainActor () async throws -> String
        var validateDirectories: @MainActor (String) async throws -> Void
        var read: @MainActor (String) async throws -> Data?
        var upload: @MainActor (String, PairingCompanionPackage.File) async throws -> Void
        var enable: @MainActor (String) async throws -> Void
        var capability: @MainActor () async throws -> DevicePairingCapability
        var stillAllowed: @MainActor () -> Bool
    }

    enum Failure: Error, LocalizedError {
        case unsupportedConnection, wrongHome, busy, unknownActivity, changed, upload, enable, cancelled
        var errorDescription: String? {
            switch self {
            case .unsupportedConnection: String(localized: "Pairing needs your original sign-in and an existing secure address your iPhone can reach.")
            case .wrongHome: String(localized: "Couldn't verify the pairing installation folder. No more files were changed.")
            case .busy: String(localized: "Nollie is working. Wait for the current tasks to finish, then set up pairing.")
            case .unknownActivity: String(localized: "Couldn't check whether tasks are running. Try again when the connection is ready.")
            case .changed: String(localized: "The companion files changed during setup. Your backup is saved. Check the connection before trying again.")
            case .upload: String(localized: "Couldn't verify the copied pairing files. Setup stopped and your backup is saved.")
            case .enable: String(localized: "The pairing files are saved, but Hermes couldn't enable them. Your backup is saved.")
            case .cancelled: String(localized: "Pairing setup stopped. Any verified backup is kept.")
            }
        }
    }

    func install(plan: PairingCompanionPackage.Plan, backupParent: URL, operations: Operations) async {
        guard !isBusy else { return }
        phase = .checking; message = nil; backupDirectory = nil
        do {
            try checkAllowed(operations)
            let home = try Self.validHome(await operations.check())
            try checkAllowed(operations)
            try await operations.validateDirectories(home)
            let directory = home + "/" + plan.pluginRelativeDirectory
            let paths = plan.files.map { directory + "/" + $0.relativePath }
            phase = .backingUp
            var priorFiles: [String: Data] = [:]
            for path in paths {
                try checkAllowed(operations)
                do { priorFiles[path] = try await operations.read(path) }
                catch is CancellationError { throw CancellationError() }
                catch { throw CompanionFileBackup.Failure.unreadable }
            }
            let snapshot = priorFiles
            let receipt = try await CompanionFileBackup.create(paths: paths, parent: backupParent,
                read: { @Sendable path in snapshot[path] })
            backupDirectory = receipt.directory
            try checkAllowed(operations)
            // Publish the manifest last, so a fresh partial copy cannot be discovered as a plugin.
            let files = plan.files.filter { $0.relativePath != "plugin.yaml" } + plan.files.filter { $0.relativePath == "plugin.yaml" }
            phase = .copying
            for file in files {
                try checkAllowed(operations)
                let path = directory + "/" + file.relativePath
                let current = try await operations.read(path)
                let previous = receipt.entries.first { $0.path == path }
                guard current.map(Self.digest) == previous?.sha256,
                      previous != nil || receipt.absent.contains(path) else { throw Failure.changed }
                try checkAllowed(operations)
                if current != file.data {
                    try await operations.validateDirectories(home)
                    try checkAllowed(operations)
                    try await operations.upload(path, file)
                }
                try checkAllowed(operations)
                guard let copied = try await operations.read(path), Self.digest(copied) == file.sha256 else { throw Failure.upload }
            }
            try checkAllowed(operations)
            // Recheck activity immediately before activation, which can reload plugin handlers.
            guard try Self.validHome(await operations.check()) == home else { throw Failure.wrongHome }
            try checkAllowed(operations)
            phase = .enabling
            try await operations.enable(home)
            try checkAllowed(operations)
            phase = .verifying
            let capability = try await operations.capability()
            try checkAllowed(operations)
            if capability.supported {
                phase = .ready
                message = String(localized: "Pairing is ready. Your existing connection is unchanged.")
            } else {
                phase = .needsActivation
                message = Self.activationMessage(reason: capability.reason)
            }
        } catch {
            let wasCopying = phase == .copying
            let wasEnabling = phase == .enabling
            phase = .failed
            if error is CancellationError { message = Failure.cancelled.localizedDescription }
            else if let failure = error as? Failure { message = failure.localizedDescription }
            else if error is CompanionFileBackup.Failure { message = String(localized: "Couldn't verify the companion backup. No installation files were changed.") }
            else if error is PairingCompanionPackage.Failure { message = PairingCompanionPackage.Failure.unavailable.localizedDescription }
            else if wasCopying { message = Failure.upload.localizedDescription }
            else if wasEnabling { message = Failure.enable.localizedDescription }
            else { message = String(localized: "Couldn't finish pairing setup. Check the connection and try again. Any verified backup is kept.") }
        }
    }

    func install(runtime: GatewayRuntime, allowed: @escaping () -> Bool) async {
        guard !isBusy else { return }
        do {
            guard !DemoMode.isOn, !runtime.connection.hasAccessHeaders,
                  runtime.connection.authMode.usesBearer,
                  runtime.connection.authProvider != DevicePairingClient.provider else { throw Failure.unsupportedConnection }
            try DevicePairingInvitation.validateGateway(runtime.connection.gateway.base.absoluteString)
            let plan = try PairingCompanionPackage.load()
            let parent = NolliePaths.current.companionBackups.appendingPathComponent("Pairing", isDirectory: true)
            let api = runtime.api
            let expectedGateway = runtime.connection.gateway
            let client = DevicePairingClient(api: api)
            let operations = Operations(check: {
                guard await api.gateway == expectedGateway else { throw Failure.unsupportedConnection }
                let status: ActivityStatus = try await api.get("/api/status")
                try Self.requireIdle(status)
                // No selected-bot fallback: enable belongs to the dashboard's launch home.
                let profile = try await runtime.rpc("config.get", ["key": .string("profile")], owner: nil, timeout: 15)
                guard let home = profile["home"]?.stringValue else { throw Failure.wrongHome }
                return home
            }, validateDirectories: { home in
                try await Self.validateDirectoryTree(home: home) { path in
                    try await api.get("/api/files", query: [.init(name: "path", value: path)])
                }
            }, read: { path in
                try await Self.read(api: api, path: path)
            }, upload: { path, file in
                // This endpoint writes a sibling temporary file and atomically replaces the target.
                let result: ManagedUploadResult = try await api.sendMultipart("/api/files/upload-stream",
                    fields: ["path": path, "overwrite": "true"], fileField: "file",
                    filename: URL(fileURLWithPath: path).lastPathComponent, fileData: file.data, mimeType: file.mimeType)
                guard result.ok != false, result.path == path else { throw Failure.upload }
            }, enable: { home in
                try await Self.enableThenActivate(validate: {
                    let gateway = await api.gateway
                    try Task.checkCancellation()
                    guard allowed(), !DemoMode.isOn, gateway == expectedGateway,
                          runtime.connection.gateway == expectedGateway else { throw Failure.cancelled }
                }, enable: {
                    let result: EnableResult = try await api.send("POST", plan.enableAPIPath, body: EmptyBody())
                    guard result.ok else { throw Failure.enable }
                    return result.unchanged == true
                }, activate: {
                    // An existing enabled copy may not yet be loaded in this dashboard process.
                    let activated: EnableResult = try await api.send("POST", "/api/dashboard/agent-plugins/activate",
                        body: ActivationBody(name: PairingCompanionPackage.pluginID, home: home))
                    guard activated.ok else { throw Failure.enable }
                })
            }, capability: { try await client.capability() }, stillAllowed: {
                allowed() && !DemoMode.isOn && runtime.connection.gateway == expectedGateway
            })
            await install(plan: plan, backupParent: parent, operations: operations)
        } catch {
            phase = .failed
            message = (error as? Failure)?.localizedDescription
                ?? (error as? PairingCompanionPackage.Failure)?.localizedDescription
                ?? Failure.unsupportedConnection.localizedDescription
        }
    }

    struct ActivityStatus: Decodable {
        var gatewayBusy: Bool?
        var activeAgents: Int?
    }

    struct DirectoryListing: Decodable {
        struct Entry: Decodable {
            let name: String
            let path: String
            let isDirectory: Bool
            var brokenLink: Bool?
        }
        let path: String
        let entries: [Entry]
    }

    static func validateDirectoryTree(home: String,
        list: @MainActor (String) async throws -> DirectoryListing) async throws {
        var parent = try validHome(home)
        for component in ["plugins", PairingCompanionPackage.pluginID, "dashboard"] {
            try Task.checkCancellation()
            let listing = try await list(parent)
            guard listing.path == parent else { throw Failure.wrongHome }
            let matches = listing.entries.filter { $0.name == component }
            // Only absence from a verified parent proves the child is safe to create.
            // A GET of a dangling link itself returns the same 404 as a missing folder.
            if matches.isEmpty { return }
            let expected = parent + "/" + component
            guard matches.count == 1, let child = matches.first,
                  child.brokenLink != true, child.isDirectory, child.path == expected else { throw Failure.wrongHome }
            parent = expected
        }
        let last = try await list(parent)
        guard last.path == parent else { throw Failure.wrongHome }
    }

    static func enableThenActivate(validate: @MainActor () async throws -> Void,
        enable: @MainActor () async throws -> Bool,
        activate: @MainActor () async throws -> Void) async throws {
        try Task.checkCancellation()
        try await validate()
        try Task.checkCancellation()
        let unchanged = try await enable()
        if unchanged {
            try Task.checkCancellation()
            try await validate()
            try Task.checkCancellation()
            try await activate()
        }
    }
    static func requireIdle(_ status: ActivityStatus) throws {
        guard let busy = status.gatewayBusy, let count = status.activeAgents, count >= 0 else { throw Failure.unknownActivity }
        guard !busy, count == 0 else { throw Failure.busy }
    }

    static func validHome(_ home: String) throws -> String {
        guard home.hasPrefix("/"), home != "/", !home.contains("\\"), !home.contains("\0"),
              !home.split(separator: "/").contains(where: { [".", "..", "private"].contains(String($0)) }),
              URL(fileURLWithPath: home).standardizedFileURL.path == home else { throw Failure.wrongHome }
        return home
    }

    private func checkAllowed(_ operations: Operations) throws {
        try Task.checkCancellation()
        guard operations.stillAllowed() else { throw Failure.cancelled }
    }
    private static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    private struct EnableResult: Decodable { let ok: Bool; var unchanged: Bool? }
    private struct ActivationBody: Encodable, Sendable { let name: String; let home: String }
    private struct ManagedRead: Decodable { let path: String; let size: Int; let dataUrl: String }

    private static func read(api: HermesAPI, path: String) async throws -> Data? {
        do {
            let result: ManagedRead = try await api.get("/api/files/read", query: [.init(name: "path", value: path)])
            guard result.path == path, (0...524_288).contains(result.size), result.dataUrl.utf8.count <= 710_000,
                  let separator = result.dataUrl.firstIndex(of: ","), result.dataUrl[..<separator].hasSuffix(";base64"),
                  let data = Data(base64Encoded: String(result.dataUrl[result.dataUrl.index(after: separator)...])),
                  data.count == result.size else { throw Failure.changed }
            return data
        } catch let error as HermesAPIError {
            if case .http(let code, _) = error, code == 404 { return nil }
            throw error
        }
    }

    static func activationMessage(reason: String?) -> String {
        switch reason {
        case "https_required", "authenticated_https_required", "secure_address_required":
            String(localized: "The pairing companion is saved. This address still needs a secure sign-in before it can pair an iPhone. No network settings were changed.")
        case "original_sign_in_required":
            String(localized: "The pairing companion is saved. Sign in with your original Mac account before making a code.")
        default:
            String(localized: "The pairing companion is saved, but this Hermes version hasn't activated it yet. A dashboard restart may be needed. Your running tasks were not restarted.")
        }
    }
}
#endif
