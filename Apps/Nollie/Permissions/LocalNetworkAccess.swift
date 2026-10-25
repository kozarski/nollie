import Foundation
import Network
import NollieCore

/// Local Network is the one permission the system never lets an app read. The only way to learn
/// the answer is to use the network and watch what happens, and the first use shows the prompt.
/// So this asks only when a person presses Allow, writes the answer down, and looks again (with
/// no prompt, because the answer is already given) only once there is an answer to look at.
@MainActor
final class LocalNetworkAccess {
    static let shared = LocalNetworkAccess()

    enum Answer: Sendable, Equatable { case granted, denied, undecided }
    /// Uses the local network for a moment and says what the system did.
    typealias Probe = @MainActor (_ timeout: Duration) async -> Answer

    static let answerKey = "permissions.localNetwork.answer"

    private let defaults: UserDefaults
    private let probe: Probe

    init(defaults: UserDefaults = .standard, probe: @escaping Probe = LocalNetworkAccess.systemProbe) {
        self.defaults = defaults
        self.probe = probe
    }

    /// What was seen last time, with no use of the network.
    var remembered: PermissionState {
        switch defaults.string(forKey: Self.answerKey) {
        case "granted": .granted
        case "denied": .denied
        default: .notAsked
        }
    }

    /// Before the first Allow this is `notAsked` and the network is not touched. After it, a short
    /// quiet look catches a change made in Settings.
    func read() async -> PermissionState {
        guard remembered != .notAsked else { return .notAsked }
        return keep(await probe(.seconds(2))) ?? remembered
    }

    /// Shows the system prompt (the first use of the network does) and waits for the answer.
    func request() async -> PermissionState {
        keep(await probe(.seconds(120))) ?? remembered
    }

    /// Writes down a real answer. A probe that saw nothing decided leaves what was there.
    private func keep(_ answer: Answer) -> PermissionState? {
        switch answer {
        case .granted: defaults.set("granted", forKey: Self.answerKey); return .granted
        case .denied: defaults.set("denied", forKey: Self.answerKey); return .denied
        case .undecided: return nil
        }
    }

    // MARK: The system's side

    /// Browses for Nollie's own Bonjour type to catch a no (the browser waits with a policy error)
    /// and publishes a throwaway service to catch a yes (it publishes only once allowed).
    static let systemProbe: Probe = { timeout in await SystemProbe().run(timeout: timeout) }
}

@MainActor
private final class SystemProbe: NSObject, NetServiceDelegate {
    /// The system's "policy denied" for a browse: kDNSServiceErr_PolicyDenied.
    nonisolated private static let policyDenied: Int32 = -65570

    private var continuation: CheckedContinuation<LocalNetworkAccess.Answer, Never>?
    private var browser: NWBrowser?
    private var service: NetService?
    private var timer: Task<Void, Never>?

    func run(timeout: Duration) async -> LocalNetworkAccess.Answer {
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<LocalNetworkAccess.Answer, Never>) in
                self.continuation = continuation
                start(timeout: timeout)
            }
        } onCancel: {
            Task { @MainActor in self.finish(.undecided) }
        }
    }

    private func start(timeout: Duration) {
        let browser = NWBrowser(for: .bonjour(type: NollieLinkClient.serviceType, domain: nil), using: NWParameters())
        browser.stateUpdateHandler = { [weak self] state in
            guard case .waiting(let error) = state, case .dns(let code) = error, code == Self.policyDenied else { return }
            Task { @MainActor in self?.finish(.denied) }
        }
        browser.start(queue: .main)
        self.browser = browser

        let service = NetService(domain: "local.", type: "_nollie-check._tcp.", name: "Nollie check", port: 9)
        service.delegate = self
        service.publish(options: [.noAutoRename])
        self.service = service

        timer = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            self?.finish(.undecided)
        }
    }

    private func finish(_ answer: LocalNetworkAccess.Answer) {
        guard let continuation else { return }
        self.continuation = nil
        timer?.cancel()
        browser?.cancel()
        service?.stop()
        browser = nil
        service = nil
        continuation.resume(returning: answer)
    }

    nonisolated func netServiceDidPublish(_ sender: NetService) {
        MainActor.assumeIsolated { finish(.granted) }
    }
}
