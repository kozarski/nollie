import Foundation
import Observation
import NollieCore

struct LocalModelInstallScope: Codable, Equatable, Sendable {
    var installationID: UUID
    var connectionID: UUID
    var profile: String

    static func managed(_ connection: GatewayConnection, profile: String, isDemo: Bool) -> Self? {
        guard !isDemo, profile == "default", let installation = connection.managedInstallationID,
              connection.authMode == .sessionToken, connection.connectionKind == "local",
              ["127.0.0.1", "localhost", "::1", "[::1]"].contains(connection.gateway.host) else { return nil }
        return Self(installationID: installation, connectionID: connection.id, profile: profile)
    }

    var storageKey: String { "nollie.localModel.job.v1.\(installationID.uuidString).\(profile)" }
}

struct LocalModelInstallReceipt: Codable, Equatable, Sendable {
    var scope: LocalModelInstallScope
    var catalogID: String
    var variantID: String
    var requestedAt: Date
    var jobID: String?
}

@MainActor
struct LocalModelInstallPersistence {
    var load: () throws -> LocalModelInstallReceipt?
    var save: (LocalModelInstallReceipt?) throws -> Void

    static func preferences(_ defaults: UserDefaults, scope: LocalModelInstallScope) -> Self {
        Self(load: {
            guard let data = defaults.data(forKey: scope.storageKey) else { return nil }
            let receipt = try JSONDecoder().decode(LocalModelInstallReceipt.self, from: data)
            guard receipt.scope == scope else { return nil }
            return receipt
        }, save: { receipt in
            if let receipt { defaults.set(try JSONEncoder().encode(receipt), forKey: scope.storageKey) }
            else { defaults.removeObject(forKey: scope.storageKey) }
        })
    }
}

/// Owns only an explicitly requested install on one app-managed home. Leaving the
/// screen stops observation; it does not claim to cancel work already accepted by Hermes.
@MainActor @Observable
final class LocalModelQuickstart {
    enum State: Equatable {
        case idle, starting, installing, paused, checkingSelection, selected, checkingReply, ready
        case interrupted, uncertain, failed
    }

    private(set) var state: State = .idle
    private(set) var job: LocalModelJob?
    private(set) var selectedModel: String?
    private(set) var reply: String?
    private(set) var message: String?
    private(set) var receipt: LocalModelInstallReceipt?
    private(set) var busy = false
    private let api: LocalModelAPI
    private let inspect: @Sendable () async throws -> LocalModelSetupSnapshot
    private let checkReply: @MainActor (String) async throws -> String
    private let isCurrent: @MainActor () -> Bool
    private let scope: LocalModelInstallScope
    private let persistence: LocalModelInstallPersistence
    private let wait: @Sendable () async throws -> Void
    private var generation = UUID()
    @ObservationIgnored private var operation: Task<Void, Never>?

    init(api: LocalModelAPI, scope: LocalModelInstallScope, persistence: LocalModelInstallPersistence,
         inspect: @escaping @Sendable () async throws -> LocalModelSetupSnapshot,
         isCurrent: @escaping @MainActor () -> Bool,
         checkReply: @escaping @MainActor (String) async throws -> String,
         wait: @escaping @Sendable () async throws -> Void = { try await Task.sleep(for: .seconds(1)) }) {
        self.api = api; self.scope = scope; self.persistence = persistence
        self.inspect = inspect; self.isCurrent = isCurrent; self.checkReply = checkReply; self.wait = wait
    }

    #if DEBUG
    /// Inert rendering data. Every action remains denied even if a preview receives input.
    static func picture(state: State, job: LocalModelJob, selectedModel: String? = nil, reply: String? = nil) -> LocalModelQuickstart {
        let result = LocalModelQuickstart(api: .init { _, _, _ in throw CancellationError() },
            scope: .init(installationID: UUID(), connectionID: UUID(), profile: "default"),
            persistence: .init(load: { nil }, save: { _ in }),
            inspect: { throw CancellationError() }, isCurrent: { false },
            checkReply: { _ in throw CancellationError() })
        result.state = state; result.job = job; result.selectedModel = selectedModel; result.reply = reply
        return result
    }
    #endif

    var canBegin: Bool { !busy && [.idle, .failed, .interrupted].contains(state) }

    func install(_ entry: LocalModelCatalogEntry) {
        guard canBegin, isCurrent(), entry.isInstallableCandidate, let variant = entry.modelId else { return }
        state = .starting; message = nil; reply = nil; selectedModel = nil; job = nil
        let saved = LocalModelInstallReceipt(scope: scope, catalogID: entry.id, variantID: variant, requestedAt: Date())
        do { try persistence.save(saved); receipt = saved }
        catch { fail(String(localized: "Couldn't save download progress. Nothing was started.")); return }
        run { id in
            do {
                try self.check(id)
                let started = try await self.api.quickstart(catalogID: entry.id)
                try self.check(id)
                guard started.modelId == entry.id, !started.jobId.isEmpty else { throw LocalModelCheckFailure.incomplete }
                self.receipt?.jobID = started.jobId
                try self.persistence.save(self.receipt)
                try await self.poll(id)
            } catch {
                guard self.current(id) else { return }
                // A transport failure can hide an accepted POST. Never automatically repeat it.
                self.state = .uncertain
                self.message = String(localized: "The connection changed. Check progress before starting another download.")
            }
        }
    }

    func restore() {
        guard !busy, isCurrent() else { return }
        do { receipt = try persistence.load() }
        catch { fail(String(localized: "Saved download progress could not be read. Nothing was started.")); return }
        guard receipt != nil else { return }
        checkProgress()
    }

    func checkProgress() {
        guard !busy, receipt != nil, isCurrent() else { return }
        message = nil
        run { id in
            do {
                if self.receipt?.jobID == nil {
                    let jobs = try await self.api.jobs()
                    try self.check(id)
                    guard let saved = self.receipt else { return }
                    let matches = jobs.filter {
                        $0.kind == "quickstart" && $0.modelId == saved.catalogID &&
                        (["running", "paused"].contains($0.status) ||
                         $0.startedAt >= saved.requestedAt.timeIntervalSince1970 - 5)
                    }
                    guard matches.count == 1 else {
                        self.state = matches.isEmpty ? .interrupted : .uncertain
                        self.message = matches.isEmpty
                            ? String(localized: "No active setup was found. Review the model before trying again. Existing downloads are kept.")
                            : String(localized: "More than one setup matches. Nothing else was started.")
                        return
                    }
                    self.receipt?.jobID = matches[0].jobId
                    try self.persistence.save(self.receipt)
                }
                try await self.poll(id)
            } catch {
                guard self.current(id) else { return }
                if case HermesAPIError.http(404, _) = error {
                    self.state = .interrupted
                    self.message = String(localized: "This setup is no longer running. Existing downloads are kept. Review the model before trying again.")
                } else {
                    self.state = .uncertain
                    self.message = String(localized: "Couldn't check progress. The download may still be running on your Mac.")
                }
            }
        }
    }

    func pause() {
        guard let job, job.canPause == true, isCurrent() else { return }
        stopObserving()
        run { id in
            do { try self.check(id); try await self.api.pause(id: job.jobId); try self.check(id); try await self.poll(id) }
            catch { if self.current(id) { self.fail(String(localized: "Couldn't pause the download. Check progress before trying again."), uncertain: true) } }
        }
    }

    func resume() {
        guard !busy, let job, job.canResume == true, isCurrent() else { return }
        run { id in
            do { try self.check(id); try await self.api.resume(id: job.jobId); try self.check(id); try await self.poll(id) }
            catch { if self.current(id) { self.fail(String(localized: "Couldn't resume the download. Check progress before trying again."), uncertain: true) } }
        }
    }

    func testReply() {
        guard !busy, let selectedModel, [.selected, .ready].contains(state), isCurrent() else { return }
        state = .checkingReply; message = nil; reply = nil
        run { id in
            do {
                let current = try await self.api.selectedModel()
                try self.check(id)
                guard current.provider == "llamacpp", current.model == selectedModel else { throw LocalModelCheckFailure.changed }
                let answer = try await self.checkReply(selectedModel)
                try self.check(id)
                guard !answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw LocalModelCheckFailure.incomplete }
                self.reply = answer; self.state = .ready
            } catch {
                guard self.current(id) else { return }
                self.state = .selected
                self.message = String(localized: "The model is selected, but its reply wasn't verified. You can try again.")
            }
        }
    }

    func stopObserving() {
        generation = UUID(); operation?.cancel(); operation = nil; busy = false
    }

    func waitForOperation() async { await operation?.value }

    private func run(_ work: @escaping @MainActor (UUID) async -> Void) {
        generation = UUID(); let id = generation
        busy = true
        operation = Task { [weak self] in
            await work(id)
            guard let self, self.generation == id else { return }
            self.busy = false; self.operation = nil
        }
    }

    private func poll(_ id: UUID) async throws {
        guard let jobID = receipt?.jobID else { throw LocalModelCheckFailure.incomplete }
        while true {
            try check(id)
            let value = try await api.job(id: jobID)
            try check(id)
            guard value.jobId == jobID, value.kind == "quickstart", value.modelId == receipt?.catalogID else {
                throw LocalModelCheckFailure.incomplete
            }
            job = value
            switch value.status {
            case "running": state = .installing
            case "paused": state = .paused; return
            case "error": fail(String(localized: "Setup couldn't finish. Downloaded files are kept. Check your connection and available disk space before trying again.")); return
            case "done": try await verifySelection(id); return
            default: throw LocalModelCheckFailure.incomplete
            }
            try await wait()
        }
    }

    private func verifySelection(_ id: UUID) async throws {
        state = .checkingSelection
        let current = try await api.selectedModel()
        let snapshot = try await inspect()
        try check(id)
        guard let entry = snapshot.models.first(where: { $0.id == receipt?.catalogID }),
              current.provider == "llamacpp", let selected = current.model, !selected.isEmpty,
              [entry.modelId, entry.downloadedModelId].compactMap({ $0 }).contains(selected),
              entry.downloaded == true else {
            fail(String(localized: "The download finished, but the selected model wasn't verified. Check progress to try again."), uncertain: true)
            return
        }
        selectedModel = selected; state = .selected; message = nil
    }

    private func current(_ id: UUID) -> Bool { !Task.isCancelled && generation == id && isCurrent() }
    private func check(_ id: UUID) throws { guard current(id) else { throw CancellationError() } }
    private func fail(_ text: String, uncertain: Bool = false) { state = uncertain ? .uncertain : .failed; message = text }
}

enum LocalModelCheckFailure: Error { case incomplete, changed, timedOut, requestedAction }

extension LocalModelCatalogEntry {
    var isInstallableCandidate: Bool {
        fits == true && spilled == false && needsEngine == false &&
        modelId?.isEmpty == false && sizeBytes.map { $0 > 0 } == true && startWindow.map { $0 > 0 } == true
    }
}
