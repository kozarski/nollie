import Foundation
import NollieCore
import Observation

/// Nollie on the Mac answering helpers' Calendar, Reminders and Contacts requests (the workflow
/// add-on's `apple_data.py`). It looks for open requests on the gateway on this Mac, then:
///
/// - a read is answered from the person's own apps, for a helper whose switch is on;
/// - a change is worded for the card and remembered, and nothing is changed;
/// - once that change comes back approved (the person said yes on the card, on any device), exactly
///   the remembered change is made, if what it changes still looks as it did.
///
/// It never asks macOS for anything: the prompt only comes from the switch in Bot settings.
@MainActor
@Observable
final class AppleDataCenter {
    static let shared = AppleDataCenter()

    @ObservationIgnored var runtime: () -> (any AppleDataGateway)? = { AppModel.shared.runtime }
    @ObservationIgnored var library: any AppleDataLibrary = AppleLibrary()
    @ObservationIgnored var isPrivate: (String) -> Bool = {
        PrivateBots.isPrivate($0, connection: AppModel.shared.runtime?.connection.id) || AskFirstModel.isPrivateBot($0)
    }
    @ObservationIgnored var time: () -> AppleDataTime = { AppleDataTime() }
    /// How often to look while some helper has a switch on, and while none has.
    @ObservationIgnored var busyEvery: Duration = .seconds(1)
    @ObservationIgnored var idleEvery: Duration = .seconds(10)

    /// Changes worded for a card and waiting for the yes, by request. Only this copy of Nollie holds
    /// them: a change that comes back approved without one is refused, never guessed.
    private(set) var plans: [String: AppleDataPlan] = [:]
    @ObservationIgnored private var handling: Set<String> = []
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var anyOn = false
    /// The gateway the permissions were last told to, and what it was told.
    @ObservationIgnored private var sentAccess: (connection: UUID, access: [AppleDataArea: AppleDataAccess])?

    func start() {
        guard loop == nil else { return }
        #if DEBUG
        if DemoMode.isOn { return }
        #endif
        loop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.tick()
                try? await Task.sleep(for: (self?.anyOn ?? false) ? (self?.busyEvery ?? .seconds(1)) : (self?.idleEvery ?? .seconds(10)))
            }
        }
    }

    func access() -> [AppleDataArea: AppleDataAccess] {
        Dictionary(uniqueKeysWithValues: AppleDataArea.allCases.map { ($0, library.access($0)) })
    }

    func tick() async {
        guard let rt = runtime(), rt.gatewayIsOnThisMac else { return }
        await sendAccess(to: rt)
        guard let snapshot = try? await rt.appleDataRequests() else { return }
        anyOn = !snapshot.bots.values.allSatisfy(\.isEmpty)
        // A change that is no longer waiting (answered, declined, given up) is forgotten.
        let open = Set(snapshot.requests.map(\.id))
        plans = plans.filter { open.contains($0.key) || handling.contains($0.key) }
        for request in snapshot.requests where !handling.contains(request.id) {
            handling.insert(request.id)
            await handle(request, snapshot: snapshot, runtime: rt)
            handling.remove(request.id)
        }
    }

    func sendAccess(to rt: any AppleDataGateway) async {
        let now = access()
        if let sent = sentAccess, sent.connection == rt.connectionID, sent.access == now { return }
        do {
            try await rt.reportAppleDataAccess(now)
            sentAccess = (rt.connectionID, now)
        } catch {
            // An add-on without these routes, or Hermes restarting: try again on the next look.
        }
    }

    func handle(_ request: AppleDataRequest, snapshot: AppleDataSnapshot, runtime rt: any AppleDataGateway) async {
        let area = request.known?.area
        let step = AppleDataGate.step(request, switchedOn: area.map { snapshot.isOn($0, for: request.bot) } ?? false,
                                      isPrivate: isPrivate(request.bot), access: area.map(library.access) ?? .unavailable,
                                      plan: plans[request.id])
        let work = AppleDataWork(library: library, time: time())
        switch step {
        case .wait:
            return
        case let .refuse(message):
            plans[request.id] = nil
            try? await rt.answerAppleData(request.id, result: nil, error: message)
        case .read:
            switch await work.read(request) {
            case let .success(result): try? await rt.answerAppleData(request.id, result: result, error: nil)
            case let .failure(refusal): try? await rt.answerAppleData(request.id, result: nil, error: refusal.message)
            }
        case .prepare:
            switch await work.prepare(request) {
            case let .success(prepared):
                plans[request.id] = prepared.plan
                if (try? await rt.prepareAppleData(request.id, card: prepared.card)) != true { plans[request.id] = nil }
            case let .failure(refusal):
                try? await rt.answerAppleData(request.id, result: nil, error: refusal.message)
            }
        case let .apply(plan):
            // Once only: a second look at the same approved request finds no plan and is refused.
            plans[request.id] = nil
            switch await work.apply(plan) {
            case let .success(result): try? await rt.answerAppleData(request.id, result: result, error: nil)
            case let .failure(refusal): try? await rt.answerAppleData(request.id, result: nil, error: refusal.message)
            }
        }
    }
}

/// What the center needs from a gateway: a protocol so the tests can stand in for Hermes.
@MainActor
protocol AppleDataGateway: AnyObject {
    var gatewayIsOnThisMac: Bool { get }
    var connectionID: UUID { get }
    func appleDataRequests() async throws -> AppleDataSnapshot
    func reportAppleDataAccess(_ access: [AppleDataArea: AppleDataAccess]) async throws
    func prepareAppleData(_ id: String, card: String) async throws -> Bool
    func answerAppleData(_ id: String, result: [String: JSONValue]?, error: String?) async throws
}

extension GatewayRuntime: AppleDataGateway {}
