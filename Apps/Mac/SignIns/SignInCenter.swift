import Foundation
import LocalAuthentication
import NollieCore
import Observation

/// Saved sign-ins on this Mac: the Keychain store, telling the add-on which sites are saved, and
/// filling a sign-in once the person said yes. Every fill reads the password with Touch ID or the
/// Mac's password first, whichever device answered the card.
@MainActor
@Observable
final class SignInCenter {
    static let shared = SignInCenter()

    let store: SavedSignInStore
    @ObservationIgnored var filler: any SignInFilling = SignInFillRouter()
    @ObservationIgnored var runtime: () -> (any SignInGateway)? = { AppModel.shared.runtime }
    @ObservationIgnored var isPrivate: (String) -> Bool = {
        PrivateBots.isPrivate($0, connection: AppModel.shared.runtime?.connection.id) || $0.lowercased() == "private"
    }
    /// How long to wait for Hermes to pass a yes on before giving up on a fill.
    @ObservationIgnored var approvalWait: Duration = .seconds(20)
    @ObservationIgnored var pollEvery: Duration = .seconds(2)
    /// How long to wait after the fill starts before typing.
    @ObservationIgnored var settleBeforeTyping: Duration = .milliseconds(1500)
    /// Requests this Mac is working on, so the watcher never takes one twice.
    private(set) var handling: Set<String> = []
    @ObservationIgnored private var loop: Task<Void, Never>?
    /// The gateway the saved sites were last sent to, and what was sent.
    @ObservationIgnored private var sentSites: (connection: UUID, sites: [String])?

    init(store: SavedSignInStore? = nil) {
        self.store = store ?? Self.defaultStore()
        self.store.onChange = { [weak self] _ in self?.sentSites = nil }
    }

    static func defaultStore() -> SavedSignInStore {
        let authenticator = RememberedSignInCoordinator.defaultAuthenticator()
        let authenticate: @MainActor (String) async -> LAContext? = { reason in await authenticator.authenticate(reason: reason) }
        #if DEBUG
        if DemoMode.isOn || Keychain.memoryOnly {
            // The demo copy may not use the Keychain, so it gets an in-memory dictionary with a few sites to show in pictures.
            let backend = MemorySavedSignInBackend()
            if ProcessInfo.processInfo.arguments.contains("-nollie-demo-signins") {
                let start = Date(timeIntervalSince1970: 1_790_000_000)
                for (i, (site, user)) in [("example.com", "corey@example.com"), ("library.org", "corey.k"),
                                          ("shop.example.net", "corey")].enumerated() {
                    try? backend.add(SavedSignIn(site: site, username: user, createdAt: start.addingTimeInterval(Double(i))),
                                     secret: (try? JSONEncoder().encode(SignInSecret(password: "demo-password-\(i)",
                                                                                    note: i == 0 ? "Codes come by text" : nil))) ?? Data())
                }
            }
            return SavedSignInStore(backend: backend, authenticate: authenticate)
        }
        #endif
        return SavedSignInStore(backend: KeychainSavedSignInBackend(), authenticate: authenticate)
    }

    func start() {
        guard loop == nil else { return }
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-nollie-demo-signin-fill") { filler = DemoSignInFill() }
        #endif
        loop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.tick()
                try? await Task.sleep(for: self?.pollEvery ?? .seconds(2))
            }
        }
    }

    /// The runtime this Mac fills for: a gateway on this very Mac, connected.
    private func localRuntime() -> (any SignInGateway)? {
        guard let rt = runtime(), rt.gatewayIsOnThisMac else { return nil }
        return rt
    }

    func tick() async {
        guard let rt = localRuntime() else { return }
        await sendSites(to: rt)
        guard let requests = try? await rt.signInRequests() else { return }
        // A yes that came from somewhere else (the iPhone, another app or Hermes itself): the Mac
        // asks for Touch ID now, then types.
        for request in requests where request.state == "approved" && request.approver != "mac" && !handling.contains(request.id) {
            handling.insert(request.id)
            Task { await self.fillAfterOwnerCheck(request, runtime: rt) }
        }
    }

    func sendSites(to rt: any SignInGateway) async {
        store.reload()
        guard store.isKnown else { return }
        let sites = store.sites
        if let sent = sentSites, sent.connection == rt.connectionID, sent.sites == sites { return }
        do {
            try await rt.saveSignInSites(sites)
            sentSites = (rt.connectionID, sites)
        } catch {
            // An add-on without saved sign-ins, or Hermes restarting: try again on the next look.
        }
    }

    // MARK: Answering on this Mac

    /// Allow once on this Mac's card: Touch ID or the Mac's password, then the yes, then the typing.
    /// Returns a sentence when it didn't go through; nil when it did or the person cancelled.
    func allowHere(_ ask: SignInAsk, card: PendingCard, chat: ChatSession) async -> String? {
        let rt = chat.runtime
        guard rt.gatewayIsOnThisMac else { return String(localized: "This Mac doesn't run this bot's Hermes, so it can't fill in the sign-in.") }
        guard !isPrivate(chat.profileName) else {
            await chat.respond(card: card, result: ["choice": "deny"])
            return String(localized: "Saved sign-ins aren't used for private bots.")
        }
        store.reload()
        guard let item = store.signIn(for: ask.site) else {
            await chat.respond(card: card, result: ["choice": "deny"])
            return String(localized: "There's no saved sign-in for \(ask.site) on this Mac. Add one in Settings, Sign-ins.")
        }
        let bot = SignInAnswer.botName(chat)
        let reason = String(localized: "let \(bot) sign in to \(ask.site)", comment: "Safety: Touch ID reason; finishes 'Nollie is trying to …'")
        guard let context = await store.confirmOwner(reason: reason) else { return nil }
        let secret: SignInSecret
        do { secret = try store.secret(item, context: context) } catch { return error.localizedDescription }
        guard (try? await rt.claimSignIn(ask.requestID, approver: "mac")) != false else {
            return String(localized: "This one was already answered.", comment: "A sign-in request someone already answered")
        }
        handling.insert(ask.requestID)
        await chat.respond(card: card, result: ["choice": "once"])
        Task { await self.fillWhenApproved(ask.requestID, item: item, secret: secret, runtime: rt) }
        return nil
    }

    /// After this Mac's yes: wait for Hermes to pass it on, then type.
    func fillWhenApproved(_ id: String, item: SavedSignIn, secret: SignInSecret, runtime rt: any SignInGateway) async {
        defer { handling.remove(id) }
        let deadline = ContinuousClock.now + approvalWait
        while ContinuousClock.now < deadline {
            guard let request = try? await rt.signInRequest(id) else { return }
            if request.state == "approved" {
                await fill(request, item: item, secret: secret, runtime: rt)
                return
            }
            if request.state != "asking" { return }
            try? await Task.sleep(for: .milliseconds(400))
        }
    }

    /// A yes from elsewhere: Touch ID or the Mac's password now, then type.
    func fillAfterOwnerCheck(_ request: SignInRequest, runtime rt: any SignInGateway) async {
        defer { handling.remove(request.id) }
        guard !isPrivate(request.bot) else {
            try? await rt.reportSignIn(request.id, outcome: "failed", reason: .privateBot)
            return
        }
        store.reload()
        guard let item = store.signIn(for: request.site) else {
            try? await rt.reportSignIn(request.id, outcome: "failed", reason: .notSavedHere)
            return
        }
        let bot = rt.botName(request.bot)
        let secret: SignInSecret
        do {
            let reason = String(localized: "let \(bot) sign in to \(request.site)", comment: "Safety: Touch ID reason; finishes 'Nollie is trying to …'")
            secret = try await store.reveal(item, reason: reason)
        } catch SavedSignInError.cancelled {
            try? await rt.reportSignIn(request.id, outcome: "cancelled")
            return
        } catch {
            try? await rt.reportSignIn(request.id, outcome: "failed", reason: .touchID)
            return
        }
        await fill(request, item: item, secret: secret, runtime: rt)
    }

    private func fill(_ request: SignInRequest, item: SavedSignIn, secret: SignInSecret, runtime rt: any SignInGateway) async {
        // A live picture of this Mac stops showing anything first, without waiting for the add-on.
        LiveWindowSource.holdForSignIn()
        // Only once, and only while the helper still waits: a request it gave up on is never typed.
        guard (try? await rt.startSignInFill(request.id)) == true else { return }
        // Pictures pause from here on; one already being taken finishes first, so it can't show the typing.
        try? await Task.sleep(for: settleBeforeTyping)
        // The helper may have stopped while we waited: type only into a fill that is still on.
        guard (try? await rt.signInRequest(request.id))?.state == "filling" else { return }
        let job = SignInFillJob(computer: request.computer, focus: request.focus, username: item.username, password: secret.password)
        switch await filler.fill(job) {
        case .success:
            try? await rt.reportSignIn(request.id, outcome: "signed_in", reason: nil, codeNote: secret.hasNote)
        case .failure(let reason):
            try? await rt.reportSignIn(request.id, outcome: "failed", reason: reason)
        }
    }
}

/// What the center needs from a gateway: a protocol so the tests can stand in for Hermes.
@MainActor
protocol SignInGateway: AnyObject {
    var gatewayIsOnThisMac: Bool { get }
    var connectionID: UUID { get }
    func botName(_ profile: String) -> String
    func saveSignInSites(_ sites: [String]) async throws
    func signInRequests() async throws -> [SignInRequest]
    func signInRequest(_ id: String) async throws -> SignInRequest
    func claimSignIn(_ id: String, approver: String) async throws -> Bool
    func startSignInFill(_ id: String) async throws -> Bool
    func reportSignIn(_ id: String, outcome: String, reason: SignInFailure?, codeNote: Bool) async throws
}

extension SignInGateway {
    func reportSignIn(_ id: String, outcome: String, reason: SignInFailure? = nil) async throws {
        try await reportSignIn(id, outcome: outcome, reason: reason, codeNote: false)
    }
}

extension GatewayRuntime: SignInGateway {
    var connectionID: UUID { connection.id }
    func botName(_ profile: String) -> String { profiles.first { $0.name == profile }?.shownName ?? profile.capitalized }
}

#if DEBUG
/// The demo copy's computer: a fill that always works, after a moment. Never in a release build.
struct DemoSignInFill: SignInFilling {
    func fill(_ job: SignInFillJob) async -> Result<Void, SignInFailure> {
        try? await Task.sleep(for: .milliseconds(800))
        return .success(())
    }
}
#endif
