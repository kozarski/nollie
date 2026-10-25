#if os(macOS)
import CoreGraphics
import CoreVideo
import Foundation
import ImageIO
import ScreenCaptureKit
import Synchronization
import Testing
import VideoToolbox
@testable import Nollie
import NollieCore

/// Where the Mac's live pictures come from: the window Nollie Computer works in, and a helper's
/// own computer through the add-on's preview (against a pretend gateway that answers PNGs).
/// The last two tests measure this Mac and print the numbers.
@Suite(.serialized, .timeLimit(.minutes(2)))
struct LiveSourceTests {
    // MARK: Which window

    private static let notes = ComputerTask.App(info: ComputerAppInfo(bundleID: "com.apple.Notes", name: "Notes"), viewOnly: false)
    private static let safari = ComputerTask.App(info: ComputerAppInfo(bundleID: "com.apple.Safari", name: "Safari"), viewOnly: true)

    /// Keyed as Nollie Computer keys a chat: the bot, "/", the chat's first session.
    private func task(profile: String = "work", session: String = "chat-1") -> ComputerTask {
        ComputerTask(botName: "Scout", profile: profile, sessionID: profile + "/" + session, chatIDs: [session], purpose: "",
                     apps: [Self.notes, Self.safari], startedAt: Date())
    }

    private func window(_ id: Int, pid: Int, layer: Int = 0, onScreen: Bool = true, width: CGFloat = 800) -> LiveWindowChoice.Window {
        LiveWindowChoice.Window(id: id, pid: pid, layer: layer, onScreen: onScreen, bounds: CGRect(x: 0, y: 0, width: width, height: 600))
    }

    private func pids(_ app: ComputerTask.App) -> Int? { app == Self.notes ? 100 : app == Self.safari ? 200 : nil }

    @Test func theWindowTheHelperLastActedInWins() {
        // Front to back: a stranger's window, then two of Notes'.
        let windows = [window(1, pid: 999), window(2, pid: 100), window(3, pid: 100)]
        let choice = LiveWindowChoice.choose(task: task(), profile: "work", sessionID: "chat-1", pid: pids,
                                             lastWindow: { $0 == 100 ? 3 : nil }, windows: windows)
        #expect(choice == .window(windows[2]))
    }

    @Test func elseTheCurrentAppsFrontmostWindowOnScreen() {
        let windows = [window(1, pid: 999), window(5, pid: 100, layer: 25), window(2, pid: 100, onScreen: false),
                       window(3, pid: 100, width: 1), window(4, pid: 100), window(6, pid: 100)]
        // The last window is gone: the frontmost normal one on screen.
        let choice = LiveWindowChoice.choose(task: task(), profile: "work", sessionID: "chat-1", pid: pids,
                                             lastWindow: { _ in 77 }, windows: windows)
        #expect(choice == .window(windows[4]))
        // After the bot moves to Safari, Safari's window, never Notes'.
        var moved = task()
        moved.noteActivity(in: Self.safari, at: Date())
        let safariWindows = windows + [window(9, pid: 200)]
        #expect(LiveWindowChoice.choose(task: moved, profile: "work", sessionID: "chat-1", pid: pids, lastWindow: { _ in 4 },
                                        windows: safariWindows) == .window(window(9, pid: 200)))
    }

    @Test func neverAWindowOfAnAppThatWasntApproved() {
        // The remembered window belongs to another process now: it doesn't count.
        let windows = [window(1, pid: 999), window(2, pid: 555)]
        #expect(LiveWindowChoice.choose(task: task(), profile: "work", sessionID: "chat-1", pid: pids,
                                        lastWindow: { _ in 1 }, windows: windows) == .noWindow)
        // An approved app that isn't running shows nothing.
        #expect(LiveWindowChoice.choose(task: task(), profile: "work", sessionID: "chat-1", pid: { _ in nil },
                                        lastWindow: { _ in 1 }, windows: windows) == .noWindow)
    }

    @Test func anotherChatOrNoTaskIsStopped() {
        let windows = [window(2, pid: 100)]
        #expect(LiveWindowChoice.choose(task: nil, profile: "work", sessionID: "chat-1", pid: pids, lastWindow: { _ in nil },
                                        windows: windows) == .stopped)
        #expect(LiveWindowChoice.choose(task: task(session: "chat-2"), profile: "work", sessionID: "chat-1", pid: pids,
                                        lastWindow: { _ in nil }, windows: windows) == .stopped)
        #expect(LiveWindowChoice.choose(task: task(profile: "career"), profile: "work", sessionID: "chat-1", pid: pids,
                                        lastWindow: { _ in nil }, windows: windows) == .stopped)
    }

    @Test func theChatIsMatchedTheWayNollieComputerStoresIt() {
        // As requestStart makes it: the bot, "/", the chat's first session; and the ids that led there.
        let stored = ComputerTask(botName: "Scout", profile: "career", sessionID: "career/20261021_101500_abc123",
                                  chatIDs: ["20261021_131500_def456", "20261021_101500_abc123"], purpose: "",
                                  apps: [Self.notes, Self.safari], startedAt: Date())
        let windows = [window(2, pid: 100)]
        func choose(_ profile: String, _ session: String) -> LiveWindowChoice.Result {
            LiveWindowChoice.choose(task: stored, profile: profile, sessionID: session, pid: pids, lastWindow: { _ in nil },
                                    windows: windows, isPrivate: { _ in false })
        }
        #expect(choose("career", "20261021_101500_abc123") == .window(windows[0]), "The chat's first session")
        #expect(choose("career", "20261021_131500_def456") == .window(windows[0]), "The session that asked")
        #expect(choose("career", "20261021_090000_zzz999") == .stopped, "Another chat of the same bot")
        #expect(choose("work", "20261021_101500_abc123") == .stopped, "Another bot")
        #expect(choose("career", "career/20261021_101500_abc123") == .stopped)
    }

    @Test func aWindowStreamOffersNoTakeOver() async {
        let running = task()
        let source = LiveWindowSource(profile: "work", sessionID: "chat-1", allowed: { true }) { profile, session in
            LiveWindowChoice.choose(task: running, profile: profile, sessionID: session, pid: { _ in nil }, lastWindow: { _ in nil },
                                    windows: [], isPrivate: { _ in false })
        }
        let events = Events()
        source.start(level: 3) { events.add($0) }
        #expect(await events.wait(seconds: 3) { $0.contains { if case .control = $0 { true } else { false } } })
        source.stop()
        let holders = events.all.compactMap { if case .control(let holder) = $0 { Optional(holder) } else { nil } }
        #expect(holders == [nil], "Nollie Computer isn't paused by Take over, so nobody is named as holding it")
    }

    @Test func aBotThatTurnsPrivateIsRefusedMidStream() async {
        let windows = [window(2, pid: 100)]
        #expect(LiveWindowChoice.choose(task: task(), profile: "work", sessionID: "chat-1", pid: pids, lastWindow: { _ in nil },
                                        windows: windows, isPrivate: { $0 == "work" }) == .refused)

        // The source looks again every second: a bot marked private meanwhile ends the stream.
        let turnedPrivate = Mutex(false)
        let running = task()
        let source = LiveWindowSource(profile: "work", sessionID: "chat-1", allowed: { true }) { profile, session in
            LiveWindowChoice.choose(task: running, profile: profile, sessionID: session, pid: { $0 == Self.notes ? 100 : nil },
                                    lastWindow: { _ in nil }, windows: [], isPrivate: { _ in turnedPrivate.withLock { $0 } })
        }
        let events = Events()
        source.start(level: 3) { events.add($0) }
        #expect(await events.wait(seconds: 3) { $0.contains { if case .fresh(false) = $0 { true } else { false } } })
        #expect(events.ended == nil)
        turnedPrivate.withLock { $0 = true }
        #expect(await events.wait(seconds: 3) { _ in events.ended != nil })
        #expect(events.ended == .refused)
        source.stop()
    }

    @Test func aCaptureThePersonStopsEndsAndAnyOtherStopIsMadeAgain() {
        let events = Events()
        let output = LiveWindowOutput()
        output.events = { events.add($0) }
        output.stopped(by: SCStreamError(.internalError))
        #expect(output.takeStopped() && !output.takeStopped(), "The next look makes a new stream")
        #expect(events.ended == nil && !output.isClosed)
        output.stopped(by: nil)
        #expect(output.takeStopped())
        output.stopped(by: SCStreamError(.userStopped))
        #expect(events.ended == .unavailable && output.isClosed)
        #expect(!output.takeStopped())
    }

    /// Only where the test host may record the screen; elsewhere this one check is skipped.
    @MainActor @Test(.enabled(if: CGPreflightScreenCaptureAccess(), "Screen Recording isn't allowed for the test host"))
    func aWindowIsCapturedAtTheLevelsSize() async throws {
        let target = try #require(LiveWindowChoice.onScreenWindows().first { $0.layer == 0 && $0.bounds.width >= 200 && $0.bounds.height >= 200 })
        let events = Events()
        let output = LiveWindowOutput()
        output.events = { events.add($0) }
        let capture = LiveWindowCapture(output: output)
        await capture.show(.window(target), level: 3)
        let pictured = await events.wait { $0.contains { if case .picture = $0 { true } else { false } } }
        await capture.stop()
        #expect(pictured)
        let picture = events.all.compactMap { if case .picture(let picture) = $0 { picture } else { nil } }.first
        if let picture {
            #expect(max(CVPixelBufferGetWidth(picture.buffer), CVPixelBufferGetHeight(picture.buffer)) <= 640)
            #expect(CVPixelBufferGetPixelFormatType(picture.buffer) == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange)
        }
    }

    // MARK: A helper's own computer

    final class Events: @unchecked Sendable {
        private let lock = NSLock()
        private var events: [LiveSourceEvent] = []
        func add(_ event: LiveSourceEvent) { lock.withLock { events.append(event) } }
        var all: [LiveSourceEvent] { lock.withLock { events } }
        func wait(seconds: Double = 5, _ done: @escaping ([LiveSourceEvent]) -> Bool) async -> Bool {
            let deadline = Date().addingTimeInterval(seconds)
            while Date() < deadline {
                if done(all) { return true }
                try? await Task.sleep(for: .milliseconds(10))
            }
            return done(all)
        }
        var ended: LiveWire.EndReason? { all.lazy.compactMap { if case .ended(let reason) = $0 { reason } else { nil } }.first }
    }

    static func png(width: Int, height: Int, bar: Int = 0) -> Data {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 0.42, green: 0.62, blue: 0.86, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(CGColor(red: 0.98, green: 0.98, blue: 0.97, alpha: 1))
        context.fill(CGRect(x: width / 8, y: height / 8, width: width * 3 / 4, height: height * 3 / 4))
        context.setFillColor(CGColor(red: 0.2, green: 0.2, blue: 0.25, alpha: 1))
        for line in 0..<12 { context.fill(CGRect(x: width / 6, y: height / 5 + line * height / 24, width: width / 2 + (line * 37) % 200, height: 6)) }
        context.setFillColor(CGColor(red: 0.9, green: 0.4, blue: 0.2, alpha: 1))
        context.fill(CGRect(x: width / 6, y: height / 8 + 20, width: 20 + bar * 9 % (width / 2), height: 14))
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data as CFMutableData, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        CGImageDestinationFinalize(destination)
        return data as Data
    }

    private func api(_ host: String) throws -> HermesAPI {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [LivePreviewStub.self]
        return HermesAPI(gateway: try GatewayURL.normalize("https://\(host)/hermes"),
                         signer: RequestSigner(authMode: .sessionToken, sessionToken: "live-test-token"),
                         urlSession: URLSession(configuration: configuration))
    }

    private static func answer(state: String = "live", kind: String = "space", image: Data? = nil, capturedAt: Double = Date().timeIntervalSince1970,
                               extra: [String: Any] = [:]) -> Data {
        var object: [String: Any] = ["state": state, "kind": kind, "computer_name": "Studio desktop", "captured_at": capturedAt]
        if let image { object["image_data_url"] = "data:image/png;base64," + image.base64EncodedString() }
        object.merge(extra) { $1 }
        return try! JSONSerialization.data(withJSONObject: object)
    }

    @Test func previewAnswersBecomePicturesAtTheLevelsSize() async throws {
        let host = "live-\(UUID().uuidString.lowercased()).invalid"
        let image = Self.png(width: 1600, height: 1000)
        let asked = Mutex<[URLRequest]>([])
        LivePreviewStub.route(host) { request in
            asked.withLock { $0.append(request) }
            return (200, Self.answer(image: image, extra: ["control": "you", "pointer": ["x": 30, "y": 40, "at": 1.5]]), 0.02)
        }
        defer { LivePreviewStub.route(host, nil) }
        let source = LivePreviewSource(api: try api(host), profile: "work", sessionID: "chat-1")
        let events = Events()
        source.start(level: 3) { events.add($0) }
        let pictured = await events.wait { $0.contains { if case .picture = $0 { true } else { false } } }
        source.stop()
        #expect(pictured)
        let all = events.all
        let picture = try #require(all.compactMap { if case .picture(let picture) = $0 { picture } else { nil } }.first)
        #expect(CVPixelBufferGetWidth(picture.buffer) == 640 && CVPixelBufferGetHeight(picture.buffer) == 400)
        #expect(all.contains { if case .size(let size) = $0 { size == .init(width: 1600, height: 1000) } else { false } })
        #expect(all.contains { if case .computer("Studio desktop") = $0 { true } else { false } })
        #expect(all.contains { if case .control(.you) = $0 { true } else { false } })
        #expect(all.contains { if case .pointer(let pointer) = $0 { pointer == .init(x: 30, y: 40, at: 1.5) } else { false } })
        #expect(all.contains { if case .fresh(true) = $0 { true } else { false } })
        // The size comes before the first picture, so a hello can go first.
        let sizeAt = all.firstIndex { if case .size = $0 { true } else { false } }
        let pictureAt = all.firstIndex { if case .picture = $0 { true } else { false } }
        #expect(sizeAt! < pictureAt!)
        let first = try #require(asked.withLock { $0.first }?.url)
        let items = URLComponents(url: first, resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(first.path == "/hermes/api/plugins/nollie-computer/preview")
        #expect(Set(items.map { "\($0.name)=\($0.value ?? "")" }) == ["session_id=chat-1", "fresh=1", "profile=work"])
        #expect(asked.withLock { $0.first }?.value(forHTTPHeaderField: "X-Hermes-Session-Token") == "live-test-token")
    }

    @Test func idleStopsAMacComputerIsUnavailableAndSoIsAMissingAddOn() async throws {
        for (status, body, reason) in [(200, Self.answer(state: "idle"), LiveWire.EndReason.stopped),
                                       (200, Self.answer(state: "unavailable", kind: "mac"), .unavailable),
                                       (404, Data(#"{"detail":"Not Found"}"#.utf8), .unavailable)] {
            let host = "live-\(UUID().uuidString.lowercased()).invalid"
            LivePreviewStub.route(host) { _ in (status, body, 0) }
            defer { LivePreviewStub.route(host, nil) }
            let source = LivePreviewSource(api: try api(host), profile: "work", sessionID: "chat-1")
            let events = Events()
            source.start(level: 0) { events.add($0) }
            #expect(await events.wait { _ in events.ended != nil })
            #expect(events.ended == reason)
            source.stop()
        }
    }

    @Test func aSlowAnswerMeansThePictureIsntCurrent() async throws {
        let host = "live-\(UUID().uuidString.lowercased()).invalid"
        let asks = Mutex(0)
        let image = Self.png(width: 320, height: 200)
        // The first answer comes at once, every later one takes a second.
        LivePreviewStub.route(host) { _ in
            let ask = asks.withLock { $0 += 1; return $0 }
            return (200, Self.answer(image: image), ask == 1 ? 0.01 : 1)
        }
        defer { LivePreviewStub.route(host, nil) }
        let source = LivePreviewSource(api: try api(host), profile: "work", sessionID: "chat-1", staleAfter: .milliseconds(200))
        let events = Events()
        source.start(level: 0) { events.add($0) }
        func freshness(_ events: [LiveSourceEvent]) -> [Bool] { events.compactMap { if case .fresh(let fresh) = $0 { fresh } else { nil } } }
        #expect(await events.wait(seconds: 3) { freshness($0).starts(with: [true, false, true]) })
        source.stop()
        #expect(events.ended == nil)
    }

    @Test func aComputerThatIsntLiveStaysButIsntFreshThenEnds() async throws {
        let host = "live-\(UUID().uuidString.lowercased()).invalid"
        let live = Mutex(true)
        let image = Self.png(width: 320, height: 200)
        LivePreviewStub.route(host) { _ in
            live.withLock { $0 } ? (200, Self.answer(image: image), 0.01) : (200, Self.answer(state: "unavailable"), 0.01)
        }
        defer { LivePreviewStub.route(host, nil) }
        let source = LivePreviewSource(api: try api(host), profile: "work", sessionID: "chat-1",
                                       unavailableAfter: .milliseconds(400), rest: .milliseconds(20))
        let events = Events()
        source.start(level: 0) { events.add($0) }
        #expect(await events.wait { $0.contains { if case .picture = $0 { true } else { false } } })
        live.withLock { $0 = false }
        #expect(await events.wait { $0.contains { if case .fresh(false) = $0 { true } else { false } } })
        #expect(events.ended == nil)
        #expect(await events.wait { _ in events.ended != nil })
        #expect(events.ended == .unavailable)
        source.stop()
    }

    // MARK: A saved sign-in

    @Test func aPausedAnswerHoldsPicturesBackAndKeepsTheStreamUntilALiveOne() async throws {
        let host = "live-\(UUID().uuidString.lowercased()).invalid"
        let paused = Mutex(true)
        let image = Self.png(width: 320, height: 200)
        let pausedAnswer = try JSONSerialization.data(withJSONObject: ["state": "paused", "kind": "space", "computer_name": "Studio desktop",
                                                                       "message": "Paused while Nollie types a saved sign-in."])
        LivePreviewStub.route(host) { _ in paused.withLock { $0 } ? (200, pausedAnswer, 0.01) : (200, Self.answer(image: image), 0.01) }
        defer { LivePreviewStub.route(host, nil) }
        // Far longer paused than a computer may go without a picture: a pause isn't "unavailable".
        let source = LivePreviewSource(api: try api(host), profile: "work", sessionID: "chat-1",
                                       unavailableAfter: .milliseconds(300), rest: .milliseconds(20))
        let events = Events()
        source.start(level: 3) { events.add($0) }
        #expect(await events.wait { $0.contains { if case .hold(.signIn) = $0 { true } else { false } } })
        try await Task.sleep(for: .milliseconds(600))
        #expect(events.ended == nil)
        #expect(!events.all.contains { if case .picture = $0 { true } else { false } })
        #expect(!events.all.contains { if case .fresh(true) = $0 { true } else { false } })
        #expect(events.all.filter { if case .hold = $0 { true } else { false } }.count == 1, "Said once, not with every answer")
        paused.withLock { $0 = false }
        #expect(await events.wait { $0.contains { if case .picture = $0 { true } else { false } } })
        source.stop()
        let all = events.all
        let lifted = try #require(all.firstIndex { if case .hold(nil) = $0 { true } else { false } })
        let pictured = try #require(all.firstIndex { if case .picture = $0 { true } else { false } })
        #expect(lifted < pictured, "The hold is lifted before the first picture after it")
    }

    @Test func aPausedAnswerForThisMacIsNoStreamHere() async throws {
        let host = "live-\(UUID().uuidString.lowercased()).invalid"
        let body = try JSONSerialization.data(withJSONObject: ["state": "paused", "kind": "mac", "computer_name": "This Mac",
                                                               "message": "Paused while Nollie types a saved sign-in."])
        LivePreviewStub.route(host) { _ in (200, body, 0) }
        defer { LivePreviewStub.route(host, nil) }
        let source = LivePreviewSource(api: try api(host), profile: "work", sessionID: "chat-1")
        let events = Events()
        source.start(level: 0) { events.add($0) }
        #expect(await events.wait { _ in events.ended != nil })
        #expect(events.ended == .unavailable)
        source.stop()
    }

    @Test func aWindowIsntCapturedWhileASignInIsTypedOrBeforeTheAddOnSays() async {
        let running = task()
        let answer = Mutex(LiveSignInPause.paused)
        let asked = Mutex(0)
        let source = LiveWindowSource(profile: "work", sessionID: "chat-1", allowed: { true }, look: { profile, session in
            LiveWindowChoice.choose(task: running, profile: profile, sessionID: session, pid: { _ in nil }, lastWindow: { _ in nil },
                                    windows: [], isPrivate: { _ in false })
        }, pause: {
            asked.withLock { $0 += 1 }
            return answer.withLock { $0 }
        })
        let events = Events()
        source.start(level: 3) { events.add($0) }
        #expect(await events.wait(seconds: 3) { $0.contains { if case .hold(.signIn) = $0 { true } else { false } } })
        // Asked twice a second, and the stream waits: no "nothing to show", no end.
        #expect(await events.wait(seconds: 3) { _ in asked.withLock { $0 } >= 3 })
        #expect(events.ended == nil)
        answer.withLock { $0 = .clear }
        #expect(await events.wait(seconds: 3) { $0.contains { if case .hold(nil) = $0 { true } else { false } } })
        // Clear, it carries on looking for the window (this task has none on screen yet).
        try? await Task.sleep(for: .milliseconds(400))
        #expect(events.ended == nil)
        answer.withLock { $0 = .unknown }
        #expect(await events.wait(seconds: 3) { _ in events.ended != nil })
        #expect(events.ended == .unavailable, "An add-on that can't say means no live picture of this Mac")
        source.stop()
    }

    private func windowSource(pause: @escaping LiveWindowSource.Pause, answerWithin: Duration = .seconds(5),
                              giveUpAfter: Duration) -> LiveWindowSource {
        let running = task()
        return LiveWindowSource(profile: "work", sessionID: "chat-1", allowed: { true }, look: { profile, session in
            LiveWindowChoice.choose(task: running, profile: profile, sessionID: session, pid: { _ in nil }, lastWindow: { _ in nil },
                                    windows: [], isPrivate: { _ in false })
        }, pause: pause, answerWithin: answerWithin, giveUpAfter: giveUpAfter)
    }

    private static func said(_ hold: LiveWire.Hold?) -> ([LiveSourceEvent]) -> Bool {
        { $0.contains { if case .hold(let said) = $0 { said == hold } else { false } } }
    }

    @Test func anAnswerThatNeverComesHoldsPicturesBackThenEndsTheStream() async {
        let source = windowSource(pause: {
            // Hermes never answers.
            try? await Task.sleep(for: .seconds(3600))
            return .clear
        }, answerWithin: .milliseconds(100), giveUpAfter: .milliseconds(800))
        let events = Events()
        source.start(level: 3) { events.add($0) }
        #expect(await events.wait(seconds: 3, Self.said(.signIn)), "Silence counts as paused")
        #expect(source.isHeld, "So nothing captured goes out")
        #expect(events.ended == nil)
        #expect(await events.wait(seconds: 3) { _ in events.ended != nil })
        #expect(events.ended == .unavailable, "An add-on that stays silent means no live picture of this Mac")
        #expect(!events.all.contains { if case .picture = $0 { true } else { false } })
        source.stop()
    }

    @Test func failedAsksEndTheStreamButARealPauseKeepsItOpen() async {
        let answer = Mutex(LiveSignInPause.failed)
        let source = windowSource(pause: { answer.withLock { $0 } }, giveUpAfter: .milliseconds(1200))
        let events = Events()
        source.start(level: 3) { events.add($0) }
        #expect(await events.wait(seconds: 3, Self.said(.signIn)), "A failed ask holds pictures back")
        #expect(source.isHeld)
        // A real answer resets the clock: a long genuine pause keeps the stream open.
        answer.withLock { $0 = .paused }
        try? await Task.sleep(for: .milliseconds(2000))
        #expect(events.ended == nil)
        #expect(source.isHeld)
        // Only failures again, for longer than a picture may take: no stream.
        answer.withLock { $0 = .failed }
        #expect(await events.wait(seconds: 4) { _ in events.ended != nil })
        #expect(events.ended == .unavailable)
        source.stop()
    }

    @Test func aFillStartingOnThisMacHoldsEveryWindowStreamAtOnce() async {
        let asked = Mutex(0)
        let source = windowSource(pause: {
            asked.withLock { $0 += 1 }
            return .clear
        }, giveUpAfter: .seconds(10))
        let events = Events()
        source.start(level: 3) { events.add($0) }
        #expect(await events.wait(seconds: 3) { _ in asked.withLock { $0 } >= 1 && !source.isHeld })
        LiveWindowSource.holdForSignIn()
        #expect(source.isHeld, "Held before any answer from the add-on")
        #expect(Self.said(.signIn)(events.all), "And the host is told at once")
        source.stop()
        let stopped = events.all.count
        LiveWindowSource.holdForSignIn()
        #expect(events.all.count == stopped, "A stopped stream is no longer held by the next fill")
    }

    @Test func aHeldOutputPassesNoPictureAndNothingSaysTheLastIsCurrent() {
        let events = Events()
        let output = LiveWindowOutput()
        output.events = { events.add($0) }
        let picture = LivePicture(buffer: LiveHostTests.buffer(), captureMicros: 1)
        // Before the add-on has said anything: held, without telling anyone.
        output.waitForPauseAnswer()
        output.send(.fresh(true))
        output.send(.picture(picture))
        #expect(events.all.isEmpty && !output.hasPictured)
        #expect(!output.hold(false), "Nothing was going out")
        #expect(events.all.isEmpty, "No hold was said, so none is lifted")
        output.send(.fresh(true))
        output.send(.picture(picture))
        #expect(output.hasPictured)
        #expect(output.hold(true), "Pictures were going out: the capture stops")
        output.send(.picture(picture))
        output.send(.fresh(true))
        #expect(!output.hold(true))
        output.hold(false)
        let said = events.all.map { event -> String in
            switch event {
            case .fresh(let fresh): "fresh \(fresh)"
            case .picture: "picture"
            case .hold(let hold): "hold \(hold?.rawValue ?? "none")"
            default: "other"
            }
        }
        #expect(said == ["fresh true", "picture", "fresh false", "hold sign_in", "hold none"])
    }

    // MARK: Measured on this Mac

    final class Timing: LiveHostViewer, @unchecked Sendable {
        private let lock = NSLock()
        private var latencies: [Double] = []
        private var bytes = 0
        func send(_ message: LiveWire.ServerMessage) {}
        func send(_ video: LiveWire.Video, encoded: Data) {
            let ms = Double(LiveWire.micros() &- video.captureMicros) / 1000
            lock.withLock { latencies.append(ms); bytes += encoded.count }
        }
        func end(_ reason: LiveWire.EndReason) {}
        var count: Int { lock.withLock { latencies.count } }
        func summary(skipping warmUp: Int) -> (median: Double, p95: Double, frames: Int, bytes: Int)? {
            let measured = lock.withLock { Array(latencies.dropFirst(warmUp)).sorted() }
            guard !measured.isEmpty else { return nil }
            return (measured[measured.count / 2], measured[min(measured.count - 1, Int(Double(measured.count) * 0.95))], measured.count,
                    lock.withLock { bytes })
        }
    }

    /// Desktop pictures in 4:2:0, the format ScreenCaptureKit hands over.
    private static func desktop420(_ count: Int, width: Int, height: Int) -> [CVPixelBuffer] {
        var transfer: VTPixelTransferSession?
        VTPixelTransferSessionCreate(allocator: kCFAllocatorDefault, pixelTransferSessionOut: &transfer)
        return (0..<count).map { index in
            let source = LiveEncoderTests.picture(index, width: width, height: height)
            var out: CVPixelBuffer?
            CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
                                [kCVPixelBufferIOSurfacePropertiesKey: [CFString: Any]() as CFDictionary] as CFDictionary, &out)
            VTPixelTransferSessionTransferImage(transfer!, from: source, to: out!)
            return out!
        }
    }

    @Test func measureASyntheticPictureToItsWireMessage() async throws {
        let source = LiveHostTests.FakeSource(kind: .mac)
        let made = Mutex<LiveHostEncoder?>(nil)
        var environment = LiveHost.Environment()
        environment.beats = false
        environment.macLimit = { .none }
        environment.makeEncoder = { level, output in
            let encoder = LiveHostEncoder(level: level, output: output)
            made.withLock { $0 = encoder }
            return encoder
        }
        let host = LiveHost(key: .init(profile: "work", sessionID: "measure"), source: source, environment: environment)
        let timing = Timing()
        guard case .viewer = host.attach(timing, judged: false) else { Issue.record("No viewer"); return }
        source.emit(.size(.init(width: 1280, height: 800)))
        let pictures = Self.desktop420(8, width: 1280, height: 800)
        for frame in 0..<120 {
            source.emit(.picture(LivePicture(buffer: pictures[frame % pictures.count], captureMicros: LiveWire.micros())))
            try await Task.sleep(for: .milliseconds(33))
        }
        try await Task.sleep(for: .milliseconds(300))
        let engine = made.withLock { $0?.engine?.rawValue } ?? "none"
        host.stop(.stopped)
        let summary = try #require(timing.summary(skipping: 20))
        print(String(format: "LIVE-MEASURE synthetic 1280x800 420f -> LiveWire message: median %.1f ms, p95 %.1f ms over %d frames (%d of 120 sent, %@ encoder)",
                     summary.median, summary.p95, summary.frames, timing.count, engine))
        #expect(summary.frames >= 30)
    }

    @Test func measureAPreviewAnswerToItsEncodedFrame() async throws {
        let host = "live-\(UUID().uuidString.lowercased()).invalid"
        let images = (0..<4).map { Self.png(width: 1280, height: 800, bar: $0 * 20) }
        let served = Mutex(0)
        LivePreviewStub.routeStamped(host) { _ in
            let index = served.withLock { count in defer { count += 1 }; return count }
            // About what one capture takes; the answer is stamped as it leaves.
            return (200, Data(), 0.08, { Self.answer(image: images[index % images.count]) })
        }
        defer { LivePreviewStub.route(host, nil) }
        let source = LivePreviewSource(api: try api(host), profile: "work", sessionID: "measure")
        var environment = LiveHost.Environment()
        environment.beats = false
        environment.macLimit = { .none }
        let live = LiveHost(key: .init(profile: "work", sessionID: "measure"), source: source, environment: environment)
        let timing = Timing()
        guard case .viewer = live.attach(timing, judged: false) else { Issue.record("No viewer"); return }
        try await Task.sleep(for: .seconds(6))
        live.stop(.stopped)
        let summary = try #require(timing.summary(skipping: 5))
        print(String(format: "LIVE-MEASURE preview answer (1280x800 PNG) -> encoded frame: median %.1f ms, p95 %.1f ms over %d frames (%d answers)",
                     summary.median, summary.p95, summary.frames, served.withLock { $0 }))
        #expect(summary.frames >= 10)
    }
}

/// A pretend gateway: answers by host name, so tests running side by side never share answers.
final class LivePreviewStub: URLProtocol {
    struct Answer: Sendable {
        var status: Int
        var body: Data
        var delay: Double
        var late: (@Sendable () -> Data)?
    }
    typealias Route = @Sendable (URLRequest) -> Answer
    private static let routes = Mutex<[String: Route]>([:])
    private let stopped = Mutex(false)

    static func route(_ host: String, _ answer: (@Sendable (URLRequest) -> (Int, Data, Double))?) {
        guard let answer else {
            routes.withLock { $0[host] = nil }
            return
        }
        let route: Route = { request in
            let made = answer(request)
            return Answer(status: made.0, body: made.1, delay: made.2, late: nil)
        }
        routes.withLock { $0[host] = route }
    }

    /// The body is made after the delay, as a real answer is.
    static func routeStamped(_ host: String, _ answer: @escaping @Sendable (URLRequest) -> (Int, Data, Double, @Sendable () -> Data)) {
        let route: Route = { request in
            let made = answer(request)
            return Answer(status: made.0, body: made.1, delay: made.2, late: made.3)
        }
        routes.withLock { $0[host] = route }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let host = request.url?.host, let route = Self.routes.withLock({ $0[host] }) else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
            return
        }
        let answer = route(request)
        let loading = Loading(stub: self)
        let respond: @Sendable () -> Void = {
            let stub = loading.stub
            guard !stub.stopped.withLock({ $0 }) else { return }
            let response = HTTPURLResponse(url: stub.request.url!, statusCode: answer.status, httpVersion: "HTTP/1.1",
                                           headerFields: ["Content-Type": "application/json"])!
            stub.client?.urlProtocol(stub, didReceive: response, cacheStoragePolicy: .notAllowed)
            stub.client?.urlProtocol(stub, didLoad: answer.late?() ?? answer.body)
            stub.client?.urlProtocolDidFinishLoading(stub)
        }
        if answer.delay > 0 {
            DispatchQueue.global().asyncAfter(deadline: .now() + answer.delay, execute: respond)
        } else {
            respond()
        }
    }

    override func stopLoading() { stopped.withLock { $0 = true } }

    /// URL loading answers a protocol from any thread.
    private struct Loading: @unchecked Sendable { let stub: LivePreviewStub }
}
#endif
