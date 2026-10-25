import Foundation
import LocalAuthentication
import Testing
@testable import Nollie
import NollieCore

@MainActor
@Suite(.serialized) struct WatchTakeoverTests {
    private let now = Date(timeIntervalSince1970: 10_000)

    private func frame(state: String = "live", at: Double? = 10_000) -> ComputerPreviewFrame {
        ComputerPreviewFrame(state: state, computerName: "Studio desktop", kind: "space", imageDataUrl: nil, capturedAt: at)
    }

    // MARK: The badge

    @Test func liveOnlyForAFreshFrameThatIsStillUpdating() {
        #expect(WatchPolicy.badge(frame: frame(), hasImage: true, interrupted: false, updating: true, receivedAt: now, now: now) == .live)
        #expect(WatchPolicy.badge(frame: frame(), hasImage: true, interrupted: false, updating: false, receivedAt: now, now: now) == .paused)
        #expect(WatchPolicy.badge(frame: frame(), hasImage: true, interrupted: true, updating: true, receivedAt: now, now: now) == .lastSeen(0))
        #expect(WatchPolicy.badge(frame: frame(), hasImage: false, interrupted: false, updating: true, receivedAt: now, now: now) == nil)
    }

    @Test func aSignInBeingTypedSaysSoWithNoPicture() {
        let paused = WatchPolicy.badge(frame: frame(state: "paused", at: nil), hasImage: false, interrupted: false,
                                       updating: true, receivedAt: nil, now: now, signInPaused: true)
        #expect(paused == .signIn)
        #expect(paused?.text == "Paused while a sign-in is typed")
        #expect(WatchPolicy.badge(frame: frame(), hasImage: true, interrupted: false, updating: false, receivedAt: now, now: now,
                                  signInPaused: true) == .signIn)
    }

    @Test func staleFramesSayHowOldTheyAre() {
        let stale = WatchPolicy.badge(frame: frame(at: 10_000 - 130), hasImage: true, interrupted: false,
                                      updating: true, receivedAt: now, now: now)
        #expect(stale == .lastSeen(130))
        #expect(stale?.text == "Last seen 2 min ago")
        // A last screen from the chat (no preview frame) is dated by when it arrived.
        let fallback = WatchPolicy.badge(frame: nil, hasImage: true, interrupted: false, updating: true,
                                         receivedAt: now.addingTimeInterval(-30), now: now)
        #expect(fallback?.text == "Last seen just now")
        #expect(WatchPolicy.badge(frame: nil, hasImage: true, interrupted: false, updating: true, receivedAt: nil, now: now)?.text == "Last screen")
        #expect(WatchPolicy.lastSeen(59) == "Last seen just now")
        #expect(WatchPolicy.lastSeen(60) == "Last seen 1 min ago")
        #expect(WatchPolicy.lastSeen(3 * 3600 + 5) == "Last seen 3 hr ago")
        #expect(WatchPolicy.lastSeen(2 * 86_400) == "Last seen over a day ago")
    }

    // MARK: The badge with a live picture

    private func live(open: Bool = true, shown: Bool = true, fresh: Bool = true, beat: TimeInterval? = 1,
                      current: TimeInterval? = 1, ended: LiveWire.EndReason? = nil,
                      endedAgo: TimeInterval? = nil) -> WatchPolicy.LiveBadge {
        WatchPolicy.LiveBadge(open: open, shown: shown, fresh: fresh, beatAt: beat.map { now.addingTimeInterval(-$0) },
                              currentAt: current.map { now.addingTimeInterval(-$0) }, ended: ended,
                              endedAt: endedAgo.map { now.addingTimeInterval(-$0) })
    }

    private func badge(_ live: WatchPolicy.LiveBadge, frame: ComputerPreviewFrame? = nil, hasImage: Bool = true,
                       updating: Bool = true) -> WatchPolicy.Badge? {
        WatchPolicy.badge(frame: frame, hasImage: hasImage, interrupted: false, updating: updating,
                          receivedAt: now.addingTimeInterval(-40), now: now, live: live)
    }

    @Test func liveWhileTheStreamShowsAPictureItsBeatsCallCurrent() {
        #expect(badge(live()) == .live)
        #expect(badge(live(), hasImage: false) == .live, "The video alone is enough")
        // A still screen sends no frames; fresh beats keep it live.
        #expect(badge(live(current: 50)) == .live)
        #expect(badge(live(beat: 3)) == .live)
        #expect(badge(live(), updating: false) == .paused)
    }

    @Test func aStreamThatFallsBehindSaysWhenItWasLastCurrent() {
        #expect(badge(live(beat: 4, current: 4)) == .lastSeen(4), "A beat over 3 seconds old vouches for nothing")
        #expect(badge(live(fresh: false, current: 75))?.text == "Last seen 1 min ago")
        // Opened, but no frame on screen yet: a fresh snapshot alone no longer says Live.
        #expect(badge(live(shown: false, current: nil), frame: frame()) == .lastSeen(0))
        #expect(badge(live(open: false, shown: false, current: nil), hasImage: false) == nil)
        // Closed: the picture on screen dates it, the stream's last frame or a newer still.
        #expect(badge(live(open: false, current: 20), frame: frame(at: 10_000 - 90)) == .lastSeen(20))
        #expect(badge(live(open: false, shown: false, current: 200), frame: frame(at: 10_000 - 90)) == .lastSeen(90))
    }

    @Test func stoppedOnlyWhenTheHelperStoppedOrTheComputerWentAway() {
        #expect(badge(live(open: false, ended: .stopped)) == .stopped)
        #expect(badge(live(open: false, ended: .gone)) == .stopped)
        #expect(badge(live(open: false, ended: .stopped))?.text == "Stopped")
        #expect(badge(live(open: false, ended: .stopped), updating: false) == .paused)
        // A refused or busy stream leaves the snapshots in charge.
        for reason in [LiveWire.EndReason.refused, .busy, .unavailable] {
            #expect(badge(live(open: false, shown: false, current: nil, ended: reason), frame: frame()) == .live)
        }
        // A new stream that said hello is no longer stopped.
        #expect(badge(live(open: true, ended: .stopped)) == .live)
    }

    @Test func aSnapshotOfTheComputerInUseAgainOutranksStopped() {
        // The snapshot arrived 40 seconds ago, after a stream that ended 60 seconds ago.
        let before = live(open: false, shown: false, current: nil, ended: .stopped, endedAgo: 60)
        #expect(badge(before, frame: frame()) == .live)
        #expect(badge(before, frame: frame(state: "idle")) == .stopped, "A computer not in use stays stopped")
        // A snapshot from before the end says nothing about since.
        #expect(badge(live(open: false, ended: .stopped, endedAgo: 20), frame: frame()) == .stopped)
    }

    @Test func aSignInPauseOutranksALivePicture() {
        #expect(badge(live()) == .live)
        #expect(WatchPolicy.badge(frame: frame(), hasImage: true, interrupted: false, updating: true, receivedAt: now, now: now,
                                  live: live(), signInPaused: true) == .signIn)
        #expect(WatchPolicy.badge(frame: nil, hasImage: false, interrupted: false, updating: true, receivedAt: nil, now: now,
                                  live: live(open: false, shown: false, ended: .stopped), signInPaused: true) == .signIn)
        #expect(WatchPolicy.pictureValue(showsVideo: true, badge: .signIn, capturedAt: nil) == "Last picture")
    }

    @Test func thePictureIsCalledLiveOnlyWhenTheBadgeIs() {
        func value(_ live: WatchPolicy.LiveBadge, updating: Bool = true) -> String {
            WatchPolicy.pictureValue(showsVideo: true, badge: badge(live, updating: updating), capturedAt: nil)
        }
        #expect(value(live()) == "Live picture")
        // Video still on screen, but the badge says otherwise: so does VoiceOver.
        #expect(value(live(fresh: false)) == "Last picture")
        #expect(value(live(beat: 4)) == "Last picture", "A beat over 3 seconds old")
        #expect(value(live(beat: nil)) == "Last picture", "No beat yet")
        #expect(value(live(), updating: false) == "Last picture")
        #expect(value(live(open: false, ended: .stopped)) == "Last picture")
        // A still is named by when it was taken.
        #expect(WatchPolicy.pictureValue(showsVideo: false, badge: .live, capturedAt: nil) == "Last screen")
        #expect(WatchPolicy.pictureValue(showsVideo: false, badge: .live, capturedAt: 10_000)
                == now.formatted(date: .omitted, time: .standard))
    }

    @Test func wordsFollowTheCopyRules() {
        #expect(WatchPolicy.linkLine(.fine) == nil)
        #expect(WatchPolicy.linkLine(.behind) == "The connection is slow, so the picture is lighter.")
        #expect(WatchPolicy.linkLine(.stalled) == "Waiting for the picture to catch up.")
        #expect(WatchPolicy.coolingLine("iPhone") == "Slowed down to keep your iPhone cool.")
        let lines = [WatchPolicy.heldLine("Scout"), WatchPolicy.someoneLine, WatchPolicy.takeOverFailed,
                     WatchPolicy.handBackFailed, WatchPolicy.authReason("Scout"), WatchPolicy.lastSeen(130),
                     WatchPolicy.Badge.stopped.text, WatchPolicy.Badge.live.text, WatchPolicy.Badge.paused.text,
                     WatchPolicy.Badge.signIn.text,
                     WatchPolicy.linkLine(.behind) ?? "", WatchPolicy.linkLine(.stalled) ?? "", WatchPolicy.coolingLine("iPad")]
        #expect(WatchPolicy.heldLine("Scout") == "You have the computer. Scout is waiting.")
        for line in lines {
            #expect(!line.contains("\u{2014}"))
            for word in ["lease", "Space", "VM", "sandbox"] { #expect(!line.contains(word)) }
        }
    }

    // MARK: The pointer

    @Test func pointerIsPlacedOnlyInsideTheFrame() {
        let size = CGSize(width: 640, height: 400)
        let spot = WatchPolicy.pointerSpot(ComputerPointer(x: 319, y: 199, at: nil), pixelSize: size)
        // The middle of the pixel the helper named.
        #expect(spot == CGPoint(x: 319.5 / 640, y: 199.5 / 400))
        #expect(WatchPolicy.pointerSpot(ComputerPointer(x: 0, y: 0, at: nil), pixelSize: size) != nil)
        #expect(WatchPolicy.pointerSpot(ComputerPointer(x: 640, y: 10, at: nil), pixelSize: size) == nil)
        #expect(WatchPolicy.pointerSpot(ComputerPointer(x: 10, y: 400, at: nil), pixelSize: size) == nil)
        #expect(WatchPolicy.pointerSpot(ComputerPointer(x: -1, y: 10, at: nil), pixelSize: size) == nil)
        #expect(WatchPolicy.pointerSpot(nil, pixelSize: size) == nil)
        #expect(WatchPolicy.pointerSpot(ComputerPointer(x: 1, y: 1, at: nil), pixelSize: nil) == nil, "No size, no guess")
    }

    @Test func previewDecodesPointerAndHolder() throws {
        let data = Data(#"{"state":"live","kind":"space","computer_name":"Studio desktop","captured_at":10000,"control":"you","pointer":{"x":12,"y":34,"at":9998.5}}"#.utf8)
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let decoded = try decoder.decode(ComputerPreviewFrame.self, from: data)
        #expect(decoded.pointer == ComputerPointer(x: 12, y: 34, at: 9998.5))
        #expect(decoded.control.flatMap(ComputerHolder.init(rawValue:)) == .you)
        let older = try decoder.decode(ComputerPreviewFrame.self, from: Data(#"{"state":"idle"}"#.utf8))
        #expect(older.pointer == nil && older.control == nil, "An older add-on offers no take over")
    }

    // MARK: The pill

    @Test func watchPillShowsWhileBusyOrHeld() {
        #expect(WatchPolicy.showsWatch(active: true, held: false, isPrivate: false))
        #expect(WatchPolicy.showsWatch(active: false, held: true, isPrivate: false))
        #expect(!WatchPolicy.showsWatch(active: false, held: false, isPrivate: false))
        #expect(!WatchPolicy.showsWatch(active: true, held: true, isPrivate: true), "A private bot is never shown")
    }

    // MARK: Take over and hand back

    private func runtime() throws -> GatewayRuntime {
        let connection = GatewayConnection(name: "unit", gateway: try GatewayURL.normalize("https://watch.invalid/hermes"), authMode: .sessionToken)
        return GatewayRuntime(connection: connection, store: ConnectionStore())
    }

    private func api() throws -> HermesAPI {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [WatchControlStub.self]
        return HermesAPI(gateway: try GatewayURL.normalize("https://watch.invalid/hermes"),
                         signer: RequestSigner(authMode: .sessionToken, sessionToken: "watch-test-token"),
                         urlSession: URLSession(configuration: configuration))
    }

    @Test func takeOverAsksFirstThenHandBackReturnsIt() async throws {
        let handoff = ComputerHandoff()
        let rt = try runtime(), api = try api()
        let profile = "watch-\(UUID().uuidString.prefix(8).lowercased())"
        let paths = Recorder()
        WatchControlStub.handler = { request in
            paths.add("\(request.httpMethod ?? "") \(request.url?.path ?? "")?\(request.url?.query ?? "")")
            let control = request.url?.path.hasSuffix("take-over") == true ? "you" : "helper"
            return (200, Data(#"{"control":"\#(control)"}"#.utf8))
        }
        defer { WatchControlStub.handler = nil }

        let no = Answering(false)
        #expect(await handoff.takeOver(profile: profile, runtime: rt, api: api, name: "Scout", authenticator: no) == .cancelled)
        #expect(paths.all.isEmpty, "No Face ID, no request")
        #expect(no.reasons == ["Take over Scout’s computer"])

        #expect(await handoff.takeOver(profile: profile, runtime: rt, api: api, name: "Scout", authenticator: Answering(true)) == .done(.you))
        #expect(handoff.isHeld(rt, profile))
        #expect(await handoff.handBack(profile: profile, runtime: rt, api: api) == .done(.helper))
        #expect(!handoff.isHeld(rt, profile))
        #expect(paths.all == ["POST /hermes/api/plugins/nollie-computer/take-over?profile=\(profile)",
                              "POST /hermes/api/plugins/nollie-computer/hand-back?profile=\(profile)"])
    }

    @Test func refusalsAndLostAnswersLeaveItUncertain() async throws {
        let handoff = ComputerHandoff()
        let rt = try runtime(), api = try api()
        let profile = "watch-\(UUID().uuidString.prefix(8).lowercased())"
        WatchControlStub.handler = { _ in (409, Data(#"{"detail":"This computer can't be taken over right now."}"#.utf8)) }
        defer { WatchControlStub.handler = nil }
        #expect(await handoff.takeOver(profile: profile, runtime: rt, api: api, name: "Scout", authenticator: Answering(true)) == .refused)
        #expect(!handoff.isHeld(rt, profile))
        WatchControlStub.handler = { _ in (200, Data(#"{"control":"someone"}"#.utf8)) }
        #expect(await handoff.takeOver(profile: profile, runtime: rt, api: api, name: "Scout", authenticator: Answering(true)) == .done(.someone))
        #expect(!handoff.isHeld(rt, profile), "Someone else's hold is never ours")
        WatchControlStub.handler = { _ in (500, Data("{}".utf8)) }
        #expect(await handoff.takeOver(profile: profile, runtime: rt, api: api, name: "Scout", authenticator: Answering(true)) == .failed)
        // The next preview settles it either way.
        handoff.note(.you, runtime: rt, profile: profile)
        #expect(handoff.isHeld(rt, profile))
        handoff.note(nil, runtime: rt, profile: profile)
        #expect(handoff.isHeld(rt, profile), "A preview that can't say leaves it as it was")
        handoff.note(.helper, runtime: rt, profile: profile)
        #expect(!handoff.isHeld(rt, profile))
    }

    @Test func holdsAreKeptPerConnectionAndBot() throws {
        let handoff = ComputerHandoff()
        let rt = try runtime(), other = try runtime()
        handoff.note(.you, runtime: rt, profile: "career")
        #expect(handoff.isHeld(rt, "career"))
        #expect(!handoff.isHeld(rt, "default"))
        #expect(!handoff.isHeld(other, "career"))
    }
}

@MainActor
private final class Answering: DeviceOwnerAuthenticating {
    let answer: Bool
    var reasons: [String] = []
    init(_ answer: Bool) { self.answer = answer }
    var canAuthenticate: Bool { true }
    var methodName: String { "Face ID" }
    func authenticate(reason: String) async -> LAContext? {
        reasons.append(reason)
        return answer ? LAContext() : nil
    }
}

private final class Recorder: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String] = []
    func add(_ item: String) { lock.lock(); items.append(item); lock.unlock() }
    var all: [String] { lock.lock(); defer { lock.unlock() }; return items }
}

private final class WatchControlStub: URLProtocol {
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) -> (Int, Data)?)?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let (status, data) = Self.handler?(request) else {
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
            return
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
