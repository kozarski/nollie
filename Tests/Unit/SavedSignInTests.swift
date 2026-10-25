import Foundation
import LocalAuthentication
import Security
import Testing
@testable import Nollie
@testable import NollieCore

/// Saved sign-ins: how they are stored, read and removed, how a card is recognised, and (on the
/// Mac) how a fill reaches a helper's computer. No real password is used; Keychain tests add and
/// delete their own items only.
@MainActor
struct SavedSignInTests {
    typealias K = KeychainSavedSignInBackend

    /// True when the test host provides a Keychain (an unsigned build does not).
    nonisolated static let hasKeychain: Bool = {
        var q = K.query(id: nil)
        q[kSecReturnAttributes as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitAll
        var out: AnyObject?
        return SecItemCopyMatching(q as CFDictionary, &out) != errSecMissingEntitlement
    }()

    final class Prompts {
        var answer = true
        var reasons: [String] = []
    }

    private func store(_ backend: MemorySavedSignInBackend = MemorySavedSignInBackend(), prompts: Prompts = Prompts()) -> SavedSignInStore {
        SavedSignInStore(backend: backend) { reason in
            prompts.reasons.append(reason)
            return prompts.answer ? LAContext() : nil
        }
    }

    // MARK: Storage policy

    @Test func itemsAreThisMacOnlyNeverSyncedAndBehindTouchIDForEveryRead() throws {
        let q = K.query(id: "x")
        #expect(q[kSecAttrSynchronizable as String] as? Bool == false, "iCloud Keychain must never carry a password")
        #expect(q[kSecUseDataProtectionKeychain as String] as? Bool == true, "access control is ignored by the legacy Mac keychain")
        #expect(q[kSecClass as String] as? String == kSecClassGenericPassword as String)
        #expect(K.service == Keychain.baseBundleID + ".signins")
        #expect(![Keychain.service, KeychainRememberedSignInBackend.service].contains(K.service))
        #expect(K.accessFlags == .userPresence, "Touch ID or the Mac's password on every read")
        #expect(K.protection == kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly, "this device only, never in a backup")

        let item = SavedSignIn(id: "x", site: "example.com", username: "sam@example.com")
        let secret = try JSONEncoder().encode(SignInSecret(password: "hunter2-correct-horse", note: "Text code"))
        let protected = try K.secretAttributes(item, secret: secret)
        #expect(protected[kSecAttrAccessControl as String] != nil)
        #expect(protected[kSecAttrAccessible as String] == nil, "the access control carries the protection class")
        #expect(protected[kSecValueData as String] as? Data == secret)
        #expect(protected[kSecAttrService as String] as? String == K.service)
        // What is readable without Touch ID: the listing only, in an item of its own.
        let listing = try K.listingAttributes(item)
        #expect(listing[kSecAttrService as String] as? String == K.listService)
        #expect(listing[kSecAttrSynchronizable as String] as? Bool == false)
        #expect(listing[kSecUseDataProtectionKeychain as String] as? Bool == true)
        #expect(listing[kSecAttrAccessible as String] as? String == kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String)
        let text = String(decoding: try #require(listing[kSecValueData as String] as? Data), as: UTF8.self)
        #expect(text.contains("example.com") && text.contains("sam@example.com"))
        #expect(!text.contains("hunter2") && !text.contains("Text code"))
        for attributes in [protected, listing] {
            #expect((attributes[kSecAttrLabel as String] as? String)?.contains("hunter2") == false)
        }
    }

    @Test func secretsNeverPrint() {
        let secret = SignInSecret(password: "hunter2-correct-horse", note: "Text code to my phone")
        for text in [String(describing: secret), String(reflecting: secret), "\(secret)"] {
            #expect(!text.contains("hunter2") && !text.contains("Text code"))
        }
        var dumped = ""
        dump(secret, to: &dumped)
        #expect(!dumped.contains("hunter2"))
        #expect(SignInSecret(password: "p", note: "  ").note == nil)
    }

    /// Goes through the real Keychain when the test build has one: add, list without prompting,
    /// then delete for good. The secret itself is never read here (that would ask for Touch ID).
    @Test func deleteReallyDeletes() throws {
        guard Self.hasKeychain else { return }
        let backend = K()
        // Anything an interrupted run of this test left behind goes first, by its listing.
        for leftover in backend.list() ?? [] where leftover.site == "nollie-test.example" { backend.delete(id: leftover.id) }
        let item = SavedSignIn(id: "test-\(UUID().uuidString)", site: "nollie-test.example", username: "test-user")
        do {
            try backend.add(item, secret: try JSONEncoder().encode(SignInSecret(password: "test-only-\(UUID().uuidString)")))
        } catch let error as KeychainError where error.status == errSecAuthFailed || error.status == errSecNotAvailable {
            return  // A simulator without a passcode can't hold a passcode-only item at all.
        }
        defer { backend.delete(id: item.id) }
        #expect(backend.list()?.contains { $0.id == item.id && $0.site == item.site && $0.username == item.username } == true)
        #expect(backend.delete(id: item.id))
        #expect(backend.list()?.contains { $0.id == item.id } == false)
        // Gone from both services. Asked without a prompt: a missing item never needs one.
        for service in [K.service, K.listService] {
            var q = K.query(id: item.id, service: service)
            let quiet = LAContext()
            quiet.interactionNotAllowed = true
            q[kSecUseAuthenticationContext as String] = quiet
            #expect(SecItemCopyMatching(q as CFDictionary, nil) == errSecItemNotFound, "\(service)")
        }
        let quiet = LAContext()
        quiet.interactionNotAllowed = true
        #expect(try backend.read(id: item.id, context: quiet) == nil)
        #expect(backend.delete(id: item.id), "deleting what is gone counts as deleted")
    }

    // MARK: Sites

    @Test func sitesAreNormalisedLikeTheAddOn() {
        let cases: [(String, String?)] = [
            ("example.com", "example.com"), ("  Example.COM.  ", "example.com"),
            ("https://www.example.com/login?next=/", "www.example.com"), ("http://login.example.com:8443/", "login.example.com"),
            ("bücher.de", "xn--bcher-kva.de"),
            ("", nil), ("localhost", nil), ("192.168.1.1", nil), ("https://user@example.com/", nil), ("exa mple.com", nil),
            ("-bad.com", nil), ("a..b", nil),
        ]
        for (raw, host) in cases { #expect(SignInSite.normalize(raw) == host, "\(raw)") }
    }

    @Test func aSavedSiteCoversItsSubdomainsOnly() {
        #expect(SignInSite.matches(saved: "example.com", requested: "login.example.com"))
        for other in ["example.com.evil.net", "myexample.com", "examp1e.com"] {
            #expect(!SignInSite.matches(saved: "example.com", requested: other), "\(other)")
        }
        let items = [SavedSignIn(id: "a", site: "example.com", username: "a"), SavedSignIn(id: "b", site: "login.example.com", username: "b")]
        #expect(SignInSite.best(for: "login.example.com", in: items)?.id == "b")
        #expect(SignInSite.best(for: "www.example.com", in: items)?.id == "a")
        #expect(SignInSite.best(for: "other.com", in: items) == nil)
    }

    // MARK: The store

    @Test func savingChecksTheDetailsAndKeepsOnePerSite() throws {
        let s = store()
        var told: [[String]] = []
        s.onChange = { told.append($0) }
        #expect(throws: SavedSignInError.badSite) { try s.save(site: "not a site", username: "a", secret: SignInSecret(password: "p")) }
        #expect(throws: SavedSignInError.noUsername) { try s.save(site: "example.com", username: " ", secret: SignInSecret(password: "p")) }
        #expect(throws: SavedSignInError.noPassword) { try s.save(site: "example.com", username: "a", secret: SignInSecret(password: "")) }
        let first = try s.save(site: "https://Example.com/", username: " sam ", secret: SignInSecret(password: "p"))
        #expect((first.site, first.username) == ("example.com", "sam"))
        #expect(throws: SavedSignInError.duplicate("example.com")) { try s.save(site: "example.com", username: "b", secret: SignInSecret(password: "p")) }
        let edited = try s.save(site: "example.com", username: "sam2", secret: SignInSecret(password: "q"), replacing: first)
        #expect(edited.id == first.id && s.items.count == 1 && s.items[0].username == "sam2")
        try s.remove(edited)
        #expect(s.items.isEmpty)
        #expect(told == [["example.com"], ["example.com"], []], "the add-on hears every change, sites only")
    }

    @Test func readingAPasswordAlwaysAsksFirst() async throws {
        let backend = MemorySavedSignInBackend()
        let prompts = Prompts()
        let s = store(backend, prompts: prompts)
        let item = try s.save(site: "example.com", username: "sam", secret: SignInSecret(password: "pw", note: "code by text"))
        prompts.answer = false
        await #expect(throws: SavedSignInError.cancelled) { try await s.reveal(item, reason: "show it") }
        #expect(backend.reads == 0, "nothing is read when the person says no")
        prompts.answer = true
        let secret = try await s.reveal(item, reason: "let Scout sign in to example.com")
        #expect(secret.password == "pw" && secret.hasNote)
        #expect(backend.readsWithContext == 1, "the Keychain is opened with the check's own context")
        #expect(prompts.reasons == ["show it", "let Scout sign in to example.com"])
    }

    @Test func listingNeverAsks() throws {
        let prompts = Prompts()
        let s = store(prompts: prompts)
        try s.save(site: "example.com", username: "sam", secret: SignInSecret(password: "pw"))
        s.reload()
        _ = s.signIn(for: "login.example.com")
        #expect(prompts.reasons.isEmpty)
        #expect(s.sites == ["example.com"])
    }

    // MARK: The card

    @Test func aSignInCardIsRecognisedOnlyFromTheAddOnsRule() {
        let id = "0123456789abcdef0123456789abcdef"
        func approval(_ key: String?, _ words: String?) -> ApprovalRequest {
            ApprovalRequest(requestId: "r", sessionId: "s", command: "<request_sign_in> (plugin approval rule)",
                            description: words, patternKey: key)
        }
        #expect(SignInAsk(approval("plugin_rule:nollie-sign-in:" + id, "Sign in to example.com")) == SignInAsk(requestID: id, site: "example.com"))
        for (key, words) in [("plugin_rule:other:" + id, "Sign in to example.com"),
                             ("plugin_rule:nollie-sign-in:../x", "Sign in to example.com"),
                             ("plugin_rule:nollie-sign-in:" + id.uppercased(), "Sign in to example.com"),
                             ("plugin_rule:nollie-sign-in:" + id, "Sign in to Example.com/login"),
                             ("plugin_rule:nollie-sign-in:" + id, "Delete everything"),
                             (nil, "Sign in to example.com")] {
            #expect(SignInAsk(approval(key, words)) == nil, "\(String(describing: key)) \(words)")
        }
        #expect(SignInAsk(nil) == nil)
    }

    #if os(macOS)
    // MARK: Filling (the Mac)

    private func said(_ result: Result<Void, SignInFailure>) -> String {
        switch result {
        case .success: return "ok"
        case .failure(let reason): return reason.rawValue
        }
    }

    /// Cua's MCP server, played back: answers each call and keeps what was sent.
    final class FakeCua: CuaLineTransport {
        var sent: [[String: Any]] = []
        var sandbox: [String: Any] = ["id": "local:dev", "location": "local", "status": "ready"]
        var failTool: String?
        private var queue: [[String: Any]] = []

        func send(_ message: [String: Any]) throws {
            sent.append(message)
            guard let id = message["id"] as? Int else { return }
            let params = message["params"] as? [String: Any] ?? [:]
            var result: [String: Any] = ["content": [[String: Any]]()]
            if params["name"] as? String == "sandbox_get" {
                let text = String(decoding: try JSONSerialization.data(withJSONObject: sandbox), as: UTF8.self)
                result = ["content": [["type": "text", "text": text]]]
            }
            if let failTool, params["name"] as? String == failTool { result["isError"] = true }
            queue.append(["jsonrpc": "2.0", "method": "notifications/progress"])
            queue.append(["jsonrpc": "2.0", "id": id, "result": result])
        }

        func receive() throws -> [String: Any]? { queue.isEmpty ? nil : queue.removeFirst() }

        var tools: [(String, [String: Any])] {
            sent.compactMap { m in
                guard m["method"] as? String == "tools/call", let p = m["params"] as? [String: Any] else { return nil }
                return (p["name"] as? String ?? "", p["arguments"] as? [String: Any] ?? [:])
            }
        }
    }

    private let job = SignInFillJob(computer: "dev", focus: "username", username: "sam@example.com", password: "hunter2-correct-horse")

    @Test func aFillChecksTheComputerThenTypesUsernameTabPasswordReturn() {
        let cua = FakeCua()
        #expect(said(CuaSignInExchange.run(cua, job: job)) == "ok")
        let tools = cua.tools
        #expect(tools.map(\.0) == ["sandbox_get", "computer_type", "computer_key", "computer_type", "computer_key"])
        #expect(tools[0].1["name"] as? String == "dev")
        #expect(tools[1].1["text"] as? String == "sam@example.com")
        #expect(tools[2].1["key"] as? String == CuaSignInExchange.tabKey)
        #expect(tools[3].1["text"] as? String == "hunter2-correct-horse")
        #expect(tools[4].1["key"] as? String == CuaSignInExchange.returnKey)
        #expect(tools.dropFirst().allSatisfy { $0.1["sandbox"] as? String == "local:dev" }, "typed into the computer it checked")
        // The password goes in exactly one place: the one typing call.
        let mentions = cua.sent.filter { String(decoding: (try? JSONSerialization.data(withJSONObject: $0)) ?? Data(), as: UTF8.self).contains("hunter2") }
        #expect(mentions.count == 1)
    }

    @Test func passwordFocusTypesThePasswordOnly() {
        let cua = FakeCua()
        var only = job
        only.focus = "password"
        #expect(said(CuaSignInExchange.run(cua, job: only)) == "ok")
        #expect(cua.tools.map(\.0) == ["sandbox_get", "computer_type", "computer_key"])
        #expect(!cua.sent.contains { ($0["params"] as? [String: Any]).flatMap { ($0["arguments"] as? [String: Any])?["text"] as? String } == "sam@example.com" })
    }

    @Test func nothingIsTypedIntoAComputerThatIsNotTheOneNamedAndReady() {
        for sandbox: [String: Any] in [["id": "local:dev", "location": "local", "status": "stopped"],
                                       ["id": "local:other", "location": "local", "status": "ready"],
                                       ["id": "cloud:dev", "location": "local", "status": "ready"],
                                       ["status": "ready"]] {
            let cua = FakeCua()
            cua.sandbox = sandbox
            #expect(said(CuaSignInExchange.run(cua, job: job)) == "computer_unavailable")
            #expect(cua.tools.map(\.0) == ["sandbox_get"], "\(sandbox)")
        }
        let cua = FakeCua()
        var qualified = job
        qualified.computer = "cloud:dev"
        #expect(said(CuaSignInExchange.run(cua, job: qualified)) == "computer_unavailable", "a qualified name must match exactly")
    }

    @Test func aFailureWhileTypingIsCouldNotFinish() {
        let cua = FakeCua()
        cua.failTool = "computer_key"
        #expect(said(CuaSignInExchange.run(cua, job: job)) == "fill_failed")
        #expect(cua.tools.map(\.0) == ["sandbox_get", "computer_type", "computer_key"], "stops at the first failure")
    }

    @Test func thisMacIsHonestlyNotWiredYetAndJobsNeverPrint() async {
        var mac = job
        mac.computer = "mac"
        #expect(await said(SignInFillRouter().fill(mac)) == "fill_unavailable")
        for text in [String(describing: job), String(reflecting: job)] {
            #expect(!text.contains("hunter2") && !text.contains("sam@example.com"))
        }
    }

    // MARK: The Mac's side of a request

    final class FakeGateway: SignInGateway {
        var gatewayIsOnThisMac = true
        let connectionID = UUID()
        var requests: [SignInRequest] = []
        var sites: [[String]] = []
        var claimed: [String] = []
        var started: [String] = []
        var reports: [(String, String, SignInFailure?, Bool)] = []
        var canStart = true
        /// The helper stops while the Mac waits to type.
        var stopsDuringTheWait = false
        func botName(_ profile: String) -> String { profile == "career" ? "Scout" : profile }
        func saveSignInSites(_ sites: [String]) async throws { self.sites.append(sites) }
        func signInRequests() async throws -> [SignInRequest] { requests }
        func signInRequest(_ id: String) async throws -> SignInRequest {
            guard let r = requests.first(where: { $0.id == id }) else { throw HermesAPIError.http(status: 404, detail: "") }
            return r
        }
        func claimSignIn(_ id: String, approver: String) async throws -> Bool { claimed.append(approver); return true }
        func startSignInFill(_ id: String) async throws -> Bool {
            started.append(id)
            guard canStart else { return false }
            if let i = requests.firstIndex(where: { $0.id == id }) { requests[i].state = stopsDuringTheWait ? "done" : "filling" }
            return true
        }
        func reportSignIn(_ id: String, outcome: String, reason: SignInFailure?, codeNote: Bool) async throws {
            reports.append((id, outcome, reason, codeNote))
        }
    }

    final class FakeFill: SignInFilling, @unchecked Sendable {
        var jobs: [SignInFillJob] = []
        var answer: Result<Void, SignInFailure> = .success(())
        func fill(_ job: SignInFillJob) async -> Result<Void, SignInFailure> { jobs.append(job); return answer }
    }

    private func center(_ prompts: Prompts, fill: FakeFill, gateway: FakeGateway) throws -> SignInCenter {
        let s = store(prompts: prompts)
        try s.save(site: "example.com", username: "sam@example.com", secret: SignInSecret(password: "pw", note: "code by text"))
        let c = SignInCenter(store: s)
        c.filler = fill
        c.runtime = { gateway }
        c.isPrivate = { $0 == "moss" }
        c.settleBeforeTyping = .zero
        return c
    }

    private func approved(_ bot: String = "career", site: String = "login.example.com", approver: String? = "iphone") -> SignInRequest {
        SignInRequest(id: "0123456789abcdef0123456789abcdef", bot: bot, site: site, computer: "local:dev", state: "approved", approver: approver)
    }

    @Test func aYesFromThePhoneStillNeedsTouchIDOnTheMacBeforeTyping() async throws {
        let prompts = Prompts(), fill = FakeFill(), gateway = FakeGateway()
        gateway.requests = [approved()]
        let c = try center(prompts, fill: fill, gateway: gateway)
        await c.fillAfterOwnerCheck(approved(), runtime: gateway)
        #expect(prompts.reasons == ["let Scout sign in to login.example.com"])
        #expect(fill.jobs.count == 1 && fill.jobs[0].username == "sam@example.com" && fill.jobs[0].password == "pw")
        #expect(gateway.started == ["0123456789abcdef0123456789abcdef"])
        #expect(gateway.reports.map { "\($0.1) \($0.3)" } == ["signed_in true"], "says a code may follow, not what the note is")
    }

    @Test func noTouchIDMeansNothingIsTyped() async throws {
        let prompts = Prompts(), fill = FakeFill(), gateway = FakeGateway()
        prompts.answer = false
        let c = try center(prompts, fill: fill, gateway: gateway)
        await c.fillAfterOwnerCheck(approved(), runtime: gateway)
        #expect(fill.jobs.isEmpty && gateway.started.isEmpty)
        #expect(gateway.reports.map(\.1) == ["cancelled"])
    }

    @Test func aRequestTheHelperGaveUpOnIsNeverTyped() async throws {
        let prompts = Prompts(), fill = FakeFill(), gateway = FakeGateway()
        gateway.canStart = false
        let c = try center(prompts, fill: fill, gateway: gateway)
        await c.fillAfterOwnerCheck(approved(), runtime: gateway)
        #expect(fill.jobs.isEmpty)
        #expect(gateway.reports.isEmpty)
    }

    @Test func aHelperThatStopsDuringTheWaitIsNeverTyped() async throws {
        let prompts = Prompts(), fill = FakeFill(), gateway = FakeGateway()
        gateway.requests = [approved()]
        gateway.stopsDuringTheWait = true
        let c = try center(prompts, fill: fill, gateway: gateway)
        await c.fillAfterOwnerCheck(approved(), runtime: gateway)
        #expect(gateway.started == ["0123456789abcdef0123456789abcdef"])
        #expect(fill.jobs.isEmpty, "a fill the helper stopped is never typed")
        #expect(gateway.reports.isEmpty)
        // Gone altogether: nothing typed either.
        let gone = FakeGateway(), quiet = FakeFill()
        let c2 = try center(Prompts(), fill: quiet, gateway: gone)
        await c2.fillAfterOwnerCheck(approved(), runtime: gone)
        #expect(quiet.jobs.isEmpty)
    }

    @Test func privateBotsAndUnsavedSitesAreRefusedWithoutAsking() async throws {
        let prompts = Prompts(), fill = FakeFill(), gateway = FakeGateway()
        let c = try center(prompts, fill: fill, gateway: gateway)
        await c.fillAfterOwnerCheck(approved("moss"), runtime: gateway)
        await c.fillAfterOwnerCheck(approved(site: "other.org"), runtime: gateway)
        #expect(prompts.reasons.isEmpty && fill.jobs.isEmpty)
        #expect(gateway.reports.map { $0.2 } == [.privateBot, .notSavedHere])
    }

    @Test func aFailedFillIsReportedInFixedWords() async throws {
        let prompts = Prompts(), fill = FakeFill(), gateway = FakeGateway()
        fill.answer = .failure(.computerUnavailable)
        gateway.requests = [approved()]
        let c = try center(prompts, fill: fill, gateway: gateway)
        await c.fillAfterOwnerCheck(approved(), runtime: gateway)
        #expect(gateway.reports.map { "\($0.1) \($0.2?.rawValue ?? "")" } == ["failed computer_unavailable"])
    }

    @Test func theWatcherTakesApprovedRequestsFromElsewhereAndSendsSitesOnce() async throws {
        let prompts = Prompts(), fill = FakeFill(), gateway = FakeGateway()
        let c = try center(prompts, fill: fill, gateway: gateway)
        gateway.requests = [approved(approver: "mac"),
                            SignInRequest(id: "ffffffffffffffffffffffffffffffff", bot: "career", site: "example.com", computer: "local:dev", state: "asking")]
        await c.tick()
        await c.tick()
        #expect(gateway.sites == [["example.com"]], "sites go once per change")
        #expect(prompts.reasons.isEmpty, "this Mac's own yes and an unanswered card are not the watcher's")
        gateway.gatewayIsOnThisMac = false
        gateway.requests = [approved()]
        await c.tick()
        #expect(prompts.reasons.isEmpty, "a gateway on another computer is never filled for")
    }
    #endif
}
