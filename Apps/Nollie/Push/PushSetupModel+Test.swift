import Foundation
import UserNotifications
import NollieCore

/// Sending one real notification through the whole chain and watching for it to arrive.
extension PushSetupModel {
    var testPassed: Bool {
        if case .done(let ok, _) = testPhase { ok } else { false }
    }

    /// The notification extension's last note ("decrypted OK", "no relay credentials readable").
    var extensionBreadcrumb: String? {
        Keychain.get(account: "push.nse.last").flatMap { String(data: $0, encoding: .utf8) }
    }

    /// What one attempt has learned so far.
    private struct Attempt {
        let nonce: String
        let began = Date()
        var companionSentTo: Int?
        var relayDetail = ""
        var sawUnreadable = false

        var elapsed: Int { Int(-began.timeIntervalSinceNow) }
    }

    /// Drops a request file beside the companion's config. The companion pushes once to every
    /// registered device and writes the nonce into its heartbeat; when that arrives, the whole chain works.
    func sendTest(runtime rt: GatewayRuntime) async {
        testPhase = .waiting
        testStartedAt = Date()
        testStage = "Sending the request to the gateway…"
        var attempt = Attempt(nonce: UUID().uuidString.lowercased())
        Self.testNonces = Self.testNonces.filter { -$0.value.timeIntervalSinceNow < 1800 }
        Self.testNonces[attempt.nonce] = Date()
        do {
            let request = JSONValue.object(["nonce": .string(attempt.nonce), "requested_at": .number(Date().timeIntervalSince1970)])
            try await writeFile(rt, path: pushDir(for: rt) + "/test-request.json", data: JSONEncoder().encode(request), mime: "application/json")
        } catch {
            testPhase = .done(ok: false, text: "Could not send the request to the gateway: \(error.localizedDescription)")
            return
        }
        testStage = "Waiting for the companion to pick it up (it looks every 3 seconds)…"
        Self.presentedNonces.remove(attempt.nonce)
        Self.lastPresentedAt = nil

        while attempt.elapsed < Int(Self.testWait) {
            try? await Task.sleep(for: .seconds(1))
            if let verdict = await judge(&attempt, runtime: rt) {
                testPhase = verdict
                return
            }
        }
        testPhase = .done(ok: false, text: Self.timeoutText(attempt))
    }

    /// One look at where the attempt stands. A result means it is over.
    private func judge(_ attempt: inout Attempt, runtime rt: GatewayRuntime) async -> TestPhase? {
        let seconds = attempt.elapsed
        let asked = Set(Self.testNonces.keys)
        var arrived = Self.presentedNonces.first(where: asked.contains)
        var stray = Self.lastPresentedAt.map { $0 >= attempt.began } ?? false
        if arrived == nil {
            let found = await Self.scanDelivered(asked: asked, since: attempt.began)
            arrived = found.nonce
            stray = stray || found.unreadable
        }
        if let arrived {
            let askedAt = Self.testNonces.removeValue(forKey: arrived) ?? attempt.began
            Self.presentedNonces.remove(arrived)
            if arrived == attempt.nonce {
                return .done(ok: true, text: "It reached \(DeviceWords.this) \(seconds)s after you asked, and the content opened. The whole chain works.")
            }
            return .done(ok: true, text: "An earlier test has just reached \(DeviceWords.this), \(Int(-askedAt.timeIntervalSinceNow))s after it was sent, and the content opened. The chain works, though pushes are slow here.")
        }
        // Something came that is not a known test. The extension's note decides: a decrypt failure is
        // a failure, but "decrypted OK" may be an ordinary reply, so it is not a pass.
        if stray, let note = Self.recentExtensionNote(since: attempt.began),
           ["decrypt failed", "no relay credentials"].contains(where: note.contains) {
            return .done(ok: false, text: "A push reached \(DeviceWords.this) \(seconds)s after you asked, but its content could not be opened (\(note)). Register \(DeviceWords.this) again (step 1) so the keys match, then test once more.")
        }
        attempt.sawUnreadable = attempt.sawUnreadable || stray
        if attempt.companionSentTo == nil, seconds.isMultiple(of: 2) {
            await noteCompanionProgress(&attempt, runtime: rt)
        }
        if seconds == 45 {
            testStage = attempt.companionSentTo == nil ? "Still waiting for the companion to notice it…"
                : "Still on its way. Apple can take a minute or more, so there is no need to ask again."
        }
        return nil
    }

    private func noteCompanionProgress(_ attempt: inout Attempt, runtime rt: GatewayRuntime) async {
        await checkCompanion(runtime: rt)
        guard let beat = heartbeat, beat.lastTestNonce == attempt.nonce else { return }
        let count = beat.lastTestDevices ?? 0
        attempt.companionSentTo = count
        attempt.relayDetail = beat.lastTestDetail ?? ""
        testStage = count == 0 ? "The companion has no device to send to" : "The companion has sent it. Waiting for it to arrive…"
    }

    private static func timeoutText(_ attempt: Attempt) -> String {
        let detail = attempt.relayDetail
        let blockedByCloudflare = detail.contains("1010")
        let relayNote = detail.isEmpty ? ""
            : blockedByCloudflare ? " A Cloudflare browser check stopped the companion's request to the relay (error 1010). Update the companion; newer ones identify themselves."
            : " The relay said: \(detail)."
        let strayNote = attempt.sawUnreadable
            ? " A push did arrive meanwhile that Nollie could not read. If that happens again, register \(DeviceWords.this) again (step 1)." : ""
        switch attempt.companionSentTo {
        case nil:
            return "The companion did not pick the request up within three minutes. Is it connected (step 5)?\(strayNote)"
        case 0?:
            let hint = blockedByCloudflare ? "" : " If it says \"unknown device\", register \(DeviceWords.this) again (step 1)."
            return "The companion tried, but the relay turned the push down for \(DeviceWords.this).\(relayNote)\(hint)"
        case let count?:
            return "The companion sent it to \(count) device\(count == 1 ? "" : "s"), but nothing reached here in three minutes.\(relayNote) Check that notifications are allowed for Nollie, and the registration in step 1. If it turns up later, the next test will say so.\(strayNote)"
        }
    }

    /// Looks at Notification Center for anything delivered since the request: either a known test
    /// (the extension opened it, so its nonce is visible) or a push that is still sealed (no nonce).
    private static func scanDelivered(asked: Set<String>, since: Date) async -> Delivered {
        var found = Delivered(nonce: nil, unreadable: false)
        let held = await UNUserNotificationCenter.current().deliveredNotifications()
        for note in held {
            let info = note.request.content.userInfo
            let hermes = info["hermes"] as? [String: Any]
            if let opened = hermes?["nonce"] as? String, asked.contains(opened) {
                found.nonce = opened
                found.unreadable = false
                break
            }
            let recent = note.date >= since.addingTimeInterval(-2)
            if recent && hermes == nil && info["enc"] != nil { found.unreadable = true }
        }
        return found
    }

    /// What a look at Notification Center turned up.
    private struct Delivered {
        var nonce: String?
        var unreadable: Bool
    }

    /// The extension's note ("<ISO date> <what>") if it was written since `since`.
    private static func recentExtensionNote(since: Date) -> String? {
        guard let data = Keychain.get(account: "push.nse.last"), let line = String(data: data, encoding: .utf8) else { return nil }
        let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
        guard parts.count == 2, let written = ISO8601DateFormatter().date(from: parts[0]), written >= since.addingTimeInterval(-2) else { return nil }
        return parts[1]
    }
}
