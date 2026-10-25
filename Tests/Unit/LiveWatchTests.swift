import CoreGraphics
import CoreMedia
import Foundation
import ImageIO
import Synchronization
import Testing
@testable import Nollie
import NollieCore
#if os(macOS)
import CoreVideo
#endif

/// The Watch screen's live picture with a pretend feed: what the host says reaches the screen,
/// the host hears back once a second, keyframes are asked for when the picture needs one, a warm
/// device steps down, and a stream that isn't there falls back to snapshots and is tried again.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(1)))
struct LiveWatchTests {
    private static let hello = LiveWire.ServerMessage.hello(.init(kind: .space, computer: "Studio desktop",
                                                                  source: .init(width: 1280, height: 800)))
    private static func beat(_ micros: UInt64 = 42, fresh: Bool = true, link: LiveWire.LinkState = .fine,
                             level: Int = 0, control: LiveWire.Control? = .helper) -> LiveWire.ServerMessage {
        .beat(.init(micros: micros, fresh: fresh, link: link, level: level, control: control))
    }
    /// A frame that can't start a picture: no keyframe has come yet.
    private static let delta = LiveWire.Video(keyframe: false, sequence: 3, captureMicros: 1, width: 64, height: 48,
                                              parameterSets: nil, sample: Data([0, 0, 0, 2, 0x02, 0x01]))
    private static let calm = LiveWatch.Power(lowPower: false, thermal: .nominal)

    private func until(_ condition: () -> Bool) async {
        for _ in 0..<1000 where !condition() { try? await Task.sleep(for: .milliseconds(5)) }
    }

    // MARK: The host's words

    @Test func whatTheHostSaysReachesTheScreen() async {
        let watch = LiveWatch(reportEvery: .seconds(3600), power: { Self.calm })
        let feed = FakeLiveFeed()
        let run = Task { await watch.run(feed) }
        feed.emit(.message(Self.hello))
        feed.emit(.message(Self.beat(9, link: .behind, level: 2, control: .you)))
        feed.emit(.message(.pointer(.init(x: 211, y: 284, at: 3.5))))
        await until { watch.pointer != nil }
        #expect(watch.running && watch.greeted)
        #expect(watch.computerName == "Studio desktop")
        #expect(watch.kind == "space")
        #expect(watch.sourceSize == CGSize(width: 1280, height: 800))
        #expect(watch.holder == .you)
        #expect(watch.link == .behind)
        #expect(watch.level == 2)
        #expect(watch.fresh)
        #expect(watch.pointer == ComputerPointer(x: 211, y: 284, at: 3.5))
        #expect(WatchPolicy.pointerSpot(watch.pointer, pixelSize: watch.sourceSize) == CGPoint(x: 211.5 / 1280, y: 284.5 / 800))

        feed.emit(.message(.source(.init(width: 640, height: 400))))
        feed.emit(.message(.pointer(nil)))
        feed.emit(.message(Self.beat(10, fresh: false, control: nil)))
        await until { watch.holder == nil }
        #expect(watch.sourceSize == CGSize(width: 640, height: 400))
        #expect(watch.pointer == nil)
        #expect(!watch.fresh)

        feed.emit(.message(.end(.stopped)))
        feed.close(.ended(.stopped))
        #expect(await run.value == .closed(.ended(.stopped)))
        #expect(watch.ended == .stopped)
        #expect(!watch.running)
        #expect(feed.cancelled, "The feed is always let go")
    }

    @Test func aHeldBeatClearsThePictureAndNothingShowsUntilItIsLifted() async {
        let clock = TestClock()
        let watch = LiveWatch(reportEvery: .seconds(3600), power: { Self.calm }, now: { clock.now })
        let display = FakeDisplay()
        watch.attach(display)
        let feed = FakeLiveFeed()
        let run = Task { await watch.run(feed) }
        feed.emit(.message(Self.hello))
        feed.emit(.message(Self.beat(1)))
        await until { watch.beatAt != nil }
        let clears = display.clears
        clock.advance(1)
        feed.emit(.message(.beat(.init(micros: 2, fresh: true, link: .fine, level: 0, control: .helper, hold: .signIn))))
        await until { watch.hold != nil }
        #expect(watch.hold == .signIn && !watch.fresh, "Held is never current")
        #expect(display.clears == clears + 1, "The picture on the display goes at once")
        #expect(watch.heldAt == clock.now)
        #expect(!watch.hasShownFrame && !watch.shownThisRun && watch.currentAt == nil)

        // A frame sent anyway is never shown, and no keyframe is asked for while held, even on the clock.
        clock.advance(1)
        feed.emit(.video(Self.delta, receivedAt: Date()))
        feed.emit(.message(.beat(.init(micros: 3, fresh: false, link: .fine, level: 0, control: .helper, hold: .signIn))))
        await until { watch.beatAt == clock.now }
        clock.advance(5)
        watch.tick()
        #expect(feed.keyframes == 0)
        #expect(display.shown.isEmpty)

        // Lifted: a keyframe taken after the pause is asked for at once.
        feed.emit(.message(Self.beat(4, fresh: false)))
        await until { watch.hold == nil }
        #expect(feed.keyframes == 1)
        run.cancel()
        _ = await run.value
        #expect(watch.heldAt != nil, "When it last held stays, so nothing from before comes back")
        watch.reset()
        #expect(watch.heldAt == nil && watch.hold == nil)
    }

    // MARK: What the host hears

    @Test func theHostHearsEachSecondWhatArrived() async {
        let watch = LiveWatch(reportEvery: .milliseconds(40), power: { .init(lowPower: true, thermal: .nominal) })
        let feed = FakeLiveFeed()
        let run = Task { await watch.run(feed) }
        feed.emit(.message(Self.hello))
        feed.emit(.message(Self.beat(1234)))
        feed.emit(.video(Self.delta, receivedAt: Date()))
        await until { feed.reports.contains { $0.got == 1 } && feed.reports.count >= 3 }
        let reports = feed.reports
        #expect(reports.reduce(0) { $0 + $1.got } == 1)
        #expect(reports.reduce(0) { $0 + $1.late } == 1)
        #expect(reports.allSatisfy { $0.shown == 0 && $0.limit == .low })
        #expect(reports.last?.beat == 1234, "The latest beat is echoed")
        #expect(feed.sent.first(where: { $0 == .keyframe }) != nil, "A frame that can't be shown asks for a keyframe")
        run.cancel()
        #expect(await run.value == .closed(.cancelled))
    }

    @Test func aKeyframeThatNeverComesIsAskedForAgain() async {
        let clock = TestClock()
        let watch = LiveWatch(reportEvery: .seconds(3600), power: { Self.calm }, now: { clock.now })
        let feed = FakeLiveFeed()
        let run = Task { await watch.run(feed) }
        feed.emit(.message(Self.hello))
        await until { watch.greeted }
        clock.advance(1)
        watch.tick()
        #expect(feed.keyframes == 0)
        clock.advance(1.5)
        watch.tick()
        #expect(feed.keyframes == 1, "A still screen sends nothing, so the wait is noticed on the clock")
        clock.advance(1)
        watch.tick()
        #expect(feed.keyframes == 1)
        clock.advance(1.5)
        watch.tick()
        #expect(feed.keyframes == 2)
        #expect(feed.reports.count == 4)

        watch.displayLost()
        #expect(feed.keyframes == 3, "A display that started over needs one too")
        run.cancel()
        _ = await run.value
    }

    // MARK: Power and heat

    @Test func aWarmDeviceAsksForLessAndAHotOneStops() async {
        #expect(LiveWatch.limit(.init(lowPower: false, thermal: .nominal)) == LiveWire.Limit.none)
        #expect(LiveWatch.limit(.init(lowPower: false, thermal: .fair)) == LiveWire.Limit.none)
        #expect(LiveWatch.limit(.init(lowPower: true, thermal: .nominal)) == .low)
        #expect(LiveWatch.limit(.init(lowPower: false, thermal: .serious)) == .low)
        #expect(LiveWatch.limit(.init(lowPower: true, thermal: .serious)) == .lowest)
        #expect(LiveWatch.limit(.init(lowPower: false, thermal: .critical)) == nil)

        let hot = FakeLiveFeed()
        #expect(await LiveWatch(power: { .init(lowPower: false, thermal: .critical) }).run(hot) == .cooling)
        #expect(hot.cancelled, "Too hot to start at all")

        let reading = LiveTestBox(LiveWatch.Power(lowPower: false, thermal: .serious))
        let watch = LiveWatch(reportEvery: .seconds(3600), power: { reading.withLock { $0 } })
        let feed = FakeLiveFeed()
        let run = Task { await watch.run(feed) }
        feed.emit(.message(Self.hello))
        await until { watch.greeted }
        watch.tick()
        #expect(feed.reports.last?.limit == .low)
        reading.withLock { $0.thermal = .critical }
        watch.tick()
        #expect(await run.value == .cooling)
        #expect(feed.cancelled)
    }

    #if os(macOS)
    // MARK: Real frames

    private static func realKeyframe() async throws -> LiveWire.Video {
        let frames = LiveTestBox<[LiveWire.Video]>([])
        let encoder = LiveEncoder(level: 3, preferHardware: false) { output in frames.withLock { $0.append(output.video) } }
        defer { encoder.stop() }
        encoder.encode(LiveEncoderTests.picture(0), captureMicros: LiveWire.micros())
        for _ in 0..<2000 where frames.withLock({ $0.isEmpty }) { try await Task.sleep(for: .milliseconds(5)) }
        let keyframe = try #require(frames.withLock { $0.first })
        #expect(keyframe.keyframe)
        return keyframe
    }

    @Test func aRealKeyframeIsShownAndTimed() async throws {
        let keyframe = try await Self.realKeyframe()

        let watch = LiveWatch(reportEvery: .seconds(3600), power: { Self.calm })
        let display = FakeDisplay()
        watch.attach(display)
        let feed = FakeLiveFeed()
        let run = Task { await watch.run(feed) }
        feed.emit(.message(Self.hello))
        feed.emit(.video(keyframe, receivedAt: Date()))
        await until { watch.hasShownFrame }
        #expect(display.shown == [true])
        #expect(watch.shownTotal == 1)
        #expect(watch.lastFrameAt != nil)
        let timing = try #require(watch.timing)
        #expect(timing.network >= 0 && timing.enqueue >= 0)
        #expect(watch.stats.hasPrefix("latency=") && watch.stats.hasSuffix(" frames=1 level=0"))

        // The display had to start over: that frame is dropped and a keyframe asked for.
        display.accept = false
        var next = keyframe
        next.sequence &+= 1
        feed.emit(.video(next, receivedAt: Date()))
        await until { feed.keyframes == 1 }
        #expect(watch.shownTotal == 1)
        run.cancel()
        _ = await run.value
        #expect(watch.hasShownFrame, "The last picture stays")
    }

    @Test func aKeyframeThatCameBeforeTheDisplayIsAskedForOnceItIsThere() async throws {
        let keyframe = try await Self.realKeyframe()
        let watch = LiveWatch(reportEvery: .seconds(3600), power: { Self.calm })
        let feed = FakeLiveFeed()
        let run = Task { await watch.run(feed) }
        feed.emit(.message(Self.hello))
        feed.emit(.video(keyframe, receivedAt: Date()))
        feed.emit(.message(Self.beat()))
        await until { watch.beatAt != nil }
        #expect(feed.keyframes == 0)
        let display = FakeDisplay()
        watch.attach(display)
        #expect(feed.keyframes == 1, "A still screen sends nothing more, so it is asked for at once")
        var again = keyframe
        again.sequence &+= 1
        feed.emit(.video(again, receivedAt: Date()))
        await until { watch.hasShownFrame }
        #expect(display.shown == [true])
        run.cancel()
        _ = await run.value
    }

    @Test func aNewRunNeverPassesOffTheLastRunsPicture() async throws {
        let keyframe = try await Self.realKeyframe()
        LiveWatchPreviewStub.reset(control: "helper", profile: "rerun")
        let clock = TestClock()
        let feeds = [FakeLiveFeed(), FakeLiveFeed()]
        let opens = LiveTestBox(0)
        let model = ComputerPreviewModel(api: try api(), live: LiveWatch(reportEvery: .seconds(3600), power: { Self.calm }),
                                         openFeed: { _ in
                                             let index = opens.withLock { opens in
                                                 defer { opens += 1 }
                                                 return opens
                                             }
                                             return index < feeds.count ? feeds[index] : FakeLiveFeed(closing: .unavailable)
                                         },
                                         now: { clock.now },
                                         pause: { duration in
                                             clock.advance(Double(duration.components.seconds))
                                             try await Task.sleep(for: .milliseconds(5))
                                         })
        let display = FakeDisplay()
        model.live.attach(display)
        let currentChat = try chat("rerun")
        let watching = Task { await model.watch(currentChat, live: true) }
        await until { model.live.running }
        feeds[0].emit(.message(Self.hello))
        feeds[0].emit(.message(Self.beat()))
        feeds[0].emit(.video(keyframe, receivedAt: Date()))
        await until { model.showsVideo }
        #expect(model.showsVideo)
        feeds[0].close(.dropped)

        // Snapshots again, then the next try: it says hello and its beats say fresh, but has
        // shown nothing of its own yet.
        await until { opens.withLock { $0 } >= 2 && model.live.running }
        feeds[1].emit(.message(Self.hello))
        feeds[1].emit(.message(Self.beat()))
        await until { model.live.beatAt != nil }
        #expect(display.clears >= 2, "Each run starts from a clear display")
        #expect(!model.showsVideo, "The newer snapshot stays on screen")
        #expect(model.liveBadge?.open == true)
        #expect(model.liveBadge?.shown == false)
        let badge = WatchPolicy.badge(frame: model.frame, hasImage: model.image != nil, interrupted: model.interrupted,
                                      updating: true, receivedAt: model.receivedAt, now: Date(), live: model.liveBadge)
        #expect(badge != .live, "Fresh beats alone never call an old picture live")
        watching.cancel()
        await watching.value
    }

    /// Plays one feed that shows a real frame, then ends it with `close`.
    private func showFrame(on feed: FakeLiveFeed, kind: LiveWire.ComputerKind, computer: String, model: ComputerPreviewModel,
                           keyframe: LiveWire.Video) async {
        feed.emit(.message(.hello(.init(kind: kind, computer: computer, source: .init(width: 1280, height: 800)))))
        feed.emit(.message(Self.beat(control: kind == .mac ? nil : .helper)))
        feed.emit(.video(keyframe, receivedAt: Date()))
        await until { model.showsVideo }
    }

    @Test func aRetryThatShowsNothingLeavesNoOldPictureBehind() async throws {
        let keyframe = try await Self.realKeyframe()
        // Nollie Computer on this Mac: its snapshots never carry a picture.
        LiveWatchPreviewStub.reset(profile: "retry", answer: .mac)
        let clock = TestClock()
        let first = FakeLiveFeed()
        let opens = LiveTestBox(0)
        let model = ComputerPreviewModel(api: try api(), live: LiveWatch(reportEvery: .seconds(3600), power: { Self.calm }),
                                         openFeed: { _ in
                                             let index = opens.withLock { opens in
                                                 defer { opens += 1 }
                                                 return opens
                                             }
                                             return index == 0 ? first : FakeLiveFeed(closing: .unavailable)
                                         },
                                         now: { clock.now },
                                         pause: { duration in
                                             clock.advance(Double(duration.components.seconds))
                                             try await Task.sleep(for: .milliseconds(5))
                                         })
        let display = FakeDisplay()
        model.live.attach(display)
        let currentChat = try chat("retry")
        let watching = Task { await model.watch(currentChat, live: true) }
        await until { model.live.running }
        await showFrame(on: first, kind: .mac, computer: "This Mac", model: model, keyframe: keyframe)
        #expect(model.showsVideo)
        #expect(model.holder == nil, "Nollie Computer's picture offers no Take over")
        // The task ends: the host says so, and the last frame stays, marked Stopped.
        first.emit(.message(.end(.stopped)))
        first.close(.ended(.stopped))
        await until { !model.live.running }
        #expect(model.showsVideo)
        #expect(model.liveBadge?.ended == .stopped)
        let clearsBefore = display.clears

        // Thirty seconds later a new try clears the display, then closes before saying hello.
        await until { opens.withLock { $0 } >= 3 }
        watching.cancel()
        await watching.value
        #expect(display.clears > clearsBefore)
        #expect(!model.live.hasShownFrame && model.live.lastFrameAt == nil && model.live.currentAt == nil)
        #expect(!model.showsVideo, "An empty display is never shown as the last picture")
        #expect(model.liveBadge?.ended == .stopped, "Why the last stream ended still stands")
        #expect(model.holder == nil)
    }

    @Test func anotherComputerDropsTheLastLivePicture() async throws {
        let keyframe = try await Self.realKeyframe()
        LiveWatchPreviewStub.reset(control: "helper", profile: "moved")
        let clock = TestClock()
        let first = FakeLiveFeed()
        let opens = LiveTestBox(0)
        let model = ComputerPreviewModel(api: try api(), live: LiveWatch(reportEvery: .seconds(3600), power: { Self.calm }),
                                         openFeed: { _ in
                                             let index = opens.withLock { opens in
                                                 defer { opens += 1 }
                                                 return opens
                                             }
                                             return index == 0 ? first : FakeLiveFeed(closing: .unavailable)
                                         },
                                         now: { clock.now },
                                         pause: { duration in
                                             clock.advance(Double(duration.components.seconds))
                                             try await Task.sleep(for: .milliseconds(5))
                                         })
        let display = FakeDisplay()
        model.live.attach(display)
        let currentChat = try chat("moved")
        let watching = Task { await model.watch(currentChat, live: true) }
        await until { model.live.running }
        await showFrame(on: first, kind: .space, computer: "Studio desktop", model: model, keyframe: keyframe)
        #expect(model.showsVideo)
        let clearsBefore = display.clears

        // The helper moves to this Mac while the stream is down.
        LiveWatchPreviewStub.answer(.mac)
        first.close(.dropped)
        await until { model.kind == "mac" }
        #expect(model.computerName == "This Mac")
        #expect(!model.showsVideo, "The other computer's last frame isn't shown under this one's name")
        #expect(!model.live.hasShownFrame && model.live.sourceSize == nil)
        #expect(model.liveBadge == nil)
        #expect(display.clears > clearsBefore)
        watching.cancel()
        await watching.value
    }

    @Test func aFrameCapturedBeforeAHoldIsNeverShownAfterIt() async throws {
        let keyframe = try await Self.realKeyframe()
        let watch = LiveWatch(reportEvery: .seconds(3600), power: { Self.calm })
        let display = FakeDisplay()
        watch.attach(display)
        let feed = FakeLiveFeed()
        let run = Task { await watch.run(feed) }
        feed.emit(.message(Self.hello))
        let heldAt = keyframe.captureMicros + 1_000
        feed.emit(.message(.beat(.init(micros: heldAt, fresh: false, link: .fine, level: 0, control: .helper, hold: .signIn))))
        feed.emit(.message(Self.beat(heldAt + 2_000_000, fresh: false)))
        await until { feed.keyframes >= 1 }
        #expect(watch.hold == nil, "Lifted, and a keyframe taken after it is asked for")

        // A keyframe captured before the hold, overtaken on the way by both beats, arrives now.
        feed.emit(.video(keyframe, receivedAt: Date()))
        try await Task.sleep(for: .milliseconds(100))
        #expect(display.shown.isEmpty, "Nothing captured before the pause is shown after it")
        #expect(!watch.hasShownFrame)

        var after = keyframe
        after.sequence &+= 1
        after.captureMicros = heldAt + 3_000_000
        feed.emit(.video(after, receivedAt: Date()))
        await until { watch.hasShownFrame }
        #expect(display.shown == [true])
        run.cancel()
        _ = await run.value
    }

    @Test func aSignInPausesTheLivePictureAndNothingOlderStandsIn() async throws {
        let keyframe = try await Self.realKeyframe()
        LiveWatchPreviewStub.reset(control: "helper", profile: "signin")
        let clock = TestClock()
        let feed = FakeLiveFeed()
        let opens = LiveTestBox(0)
        let model = ComputerPreviewModel(api: try api(), live: LiveWatch(reportEvery: .seconds(3600), power: { Self.calm }),
                                         openFeed: { _ in
                                             let index = opens.withLock { opens in
                                                 defer { opens += 1 }
                                                 return opens
                                             }
                                             return index == 0 ? feed : FakeLiveFeed(closing: .unavailable)
                                         },
                                         now: { clock.now },
                                         pause: { duration in
                                             clock.advance(Double(duration.components.seconds))
                                             try await Task.sleep(for: .milliseconds(5))
                                         })
        let display = FakeDisplay()
        model.live.attach(display)
        let currentChat = try chat("signin")
        let watching = Task { await model.watch(currentChat, live: true) }
        await until { model.live.running }
        await showFrame(on: feed, kind: .space, computer: "Studio desktop", model: model, keyframe: keyframe)
        #expect(model.showsVideo && !model.signInPaused)
        func badge() -> WatchPolicy.Badge? {
            WatchPolicy.badge(frame: model.frame, hasImage: model.image != nil, interrupted: model.interrupted, updating: true,
                              receivedAt: model.receivedAt, now: Date(), live: model.liveBadge, signInPaused: model.signInPaused)
        }
        #expect(badge() == .live)
        let shown = display.shown.count

        feed.emit(.message(.beat(.init(micros: 50, fresh: false, link: .fine, level: 0, control: .helper, hold: .signIn))))
        await until { model.signInPaused }
        #expect(!model.showsVideo && !model.placesVideo, "No video, not even the last frame")
        #expect(model.image == nil, "Nor the snapshot from before the pause")
        #expect(badge() == .signIn)
        var during = keyframe
        during.sequence &+= 1
        feed.emit(.video(during, receivedAt: Date()))
        feed.emit(.message(.beat(.init(micros: 51, fresh: false, link: .fine, level: 0, control: .helper, hold: .signIn))))
        try await Task.sleep(for: .milliseconds(100))
        #expect(display.shown.count == shown, "Nothing is shown while held")

        // Lifted: a keyframe is asked for, the next picture plays, and the old snapshot never returns.
        feed.emit(.message(Self.beat(52)))
        await until { !model.signInPaused }
        #expect(feed.keyframes >= 1)
        var after = keyframe
        after.sequence &+= 2
        feed.emit(.video(after, receivedAt: Date()))
        await until { model.showsVideo }
        #expect(model.showsVideo)
        #expect(model.image == nil)
        #expect(badge() == .live)
        #expect(LiveWatchPreviewStub.requests == 1, "Told by the stream, not by polling")
        watching.cancel()
        await watching.value
    }
    #endif

    // MARK: Falling back to snapshots

    private func chat(_ profile: String = "work") throws -> ChatSession {
        let connection = GatewayConnection(name: "unit", gateway: try GatewayURL.normalize("https://live-watch.invalid/hermes"),
                                           authMode: .sessionToken)
        return ChatSession(runtime: GatewayRuntime(connection: connection, store: ConnectionStore()), storedID: "live-session",
                           title: nil, profile: profile)
    }

    private func api() throws -> HermesAPI {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [LiveWatchPreviewStub.self]
        return HermesAPI(gateway: try GatewayURL.normalize("https://live-watch.invalid/hermes"),
                         signer: RequestSigner(authMode: .sessionToken, sessionToken: "live-watch-token"),
                         urlSession: URLSession(configuration: configuration))
    }

    @Test func aSignInBeforeTheStreamSaysHelloStillPausesWatch() async throws {
        LiveWatchPreviewStub.reset(control: "helper", profile: "early")
        let feed = FakeLiveFeed()
        let model = ComputerPreviewModel(api: try api(), live: LiveWatch(reportEvery: .seconds(3600), power: { Self.calm }),
                                         openFeed: { _ in feed }, beforeHelloEvery: .milliseconds(20))
        let currentChat = try chat("early")
        let watching = Task { await model.watch(currentChat, live: true) }
        await until { model.live.running }
        #expect(model.image != nil && !model.signInPaused)

        // The stream hasn't said hello (no picture size yet) when a sign-in begins.
        LiveWatchPreviewStub.answer(.init(state: "paused", image: false))
        await until { model.signInPaused }
        #expect(model.signInPaused, "Snapshots carry on until hello, so the pause still shows")
        #expect(model.image == nil, "The snapshot from before the pause goes")
        #expect(!model.placesVideo)
        #expect(WatchPolicy.badge(frame: model.frame, hasImage: model.image != nil, interrupted: model.interrupted, updating: true,
                                  receivedAt: model.receivedAt, now: Date(), live: model.liveBadge,
                                  signInPaused: model.signInPaused) == .signIn)

        // Once the stream speaks it leads, and no more snapshots are taken.
        feed.emit(.message(Self.hello))
        feed.emit(.message(.beat(.init(micros: 5, fresh: false, link: .fine, level: 0, control: .helper, hold: .signIn))))
        await until { model.live.hold == .signIn }
        let asked = LiveWatchPreviewStub.requests
        try await Task.sleep(for: .milliseconds(150))
        #expect(LiveWatchPreviewStub.requests == asked)
        #expect(model.signInPaused && model.image == nil)
        watching.cancel()
        await watching.value
    }

    @Test func noStreamMeansSnapshotsAndAnotherTryThirtySecondsLater() async throws {
        LiveWatchPreviewStub.reset(control: "helper", profile: "work")
        let clock = TestClock()
        let opened = LiveTestBox<[Date]>([])
        let model = ComputerPreviewModel(api: try api(), live: LiveWatch(power: { Self.calm }),
                                         openFeed: { _ in
                                             opened.withLock { $0.append(clock.now) }
                                             return FakeLiveFeed(closing: .unavailable)
                                         },
                                         now: { clock.now },
                                         pause: { duration in
                                             clock.advance(Double(duration.components.seconds))
                                             await Task.yield()
                                         })
        let currentChat = try chat()
        let watching = Task { await model.watch(currentChat, live: true) }
        await until { opened.withLock { $0.count } >= 2 }
        watching.cancel()
        await watching.value
        let times = opened.withLock { $0 }
        #expect(times.count >= 2)
        #expect(times[1].timeIntervalSince(times[0]) >= ComputerPreviewModel.liveRetry)
        #expect(times[1].timeIntervalSince(times[0]) <= ComputerPreviewModel.liveRetry + 2)
        // One snapshot before each try, then one every 2 seconds in between.
        #expect(LiveWatchPreviewStub.requests >= 15)
        #expect(model.image != nil)
        #expect(model.holder == .helper)
        #expect(!model.showsVideo)
        #expect(model.liveBadge?.open != true)
    }

    @Test func whileTheStreamPlaysNothingIsPolledAndItsHolderLeads() async throws {
        LiveWatchPreviewStub.reset(control: "helper", profile: "playing")
        let clock = TestClock()
        let feed = FakeLiveFeed()
        let opens = LiveTestBox(0)
        let model = ComputerPreviewModel(api: try api(), live: LiveWatch(reportEvery: .seconds(3600), power: { Self.calm }),
                                         openFeed: { _ in
                                             opens.withLock { $0 += 1 }
                                             return opens.withLock { $0 } == 1 ? feed : FakeLiveFeed(closing: .unavailable)
                                         },
                                         now: { clock.now },
                                         pause: { duration in
                                             clock.advance(Double(duration.components.seconds))
                                             try await Task.sleep(for: .milliseconds(5))
                                         })
        let currentChat = try chat("playing")
        let watching = Task { await model.watch(currentChat, live: true) }
        await until { model.live.running }
        #expect(LiveWatchPreviewStub.requests == 1, "One snapshot first")
        #expect(model.holder == .helper)
        feed.emit(.message(Self.hello))
        await until { model.live.greeted }
        #expect(model.holder == .helper, "The snapshot's word stands until the stream's first beat")
        #expect(model.pixelSize == CGSize(width: 1280, height: 800))
        feed.emit(.message(Self.beat(control: .you)))
        await until { model.holder == .you }
        #expect(model.holder == .you, "Beats say who holds the computer")
        #expect(model.pixelSize == CGSize(width: 1280, height: 800))
        try await Task.sleep(for: .milliseconds(200))
        #expect(LiveWatchPreviewStub.requests == 1, "No snapshots while the stream plays")
        #expect(model.liveBadge?.open == true)

        feed.close(.dropped)
        await until { LiveWatchPreviewStub.requests >= 3 }
        #expect(!model.live.running)
        #expect(LiveWatchPreviewStub.requests >= 3, "Snapshots again once it drops")
        #expect(opens.withLock { $0 } == 1, "And no new stream for 30 seconds")
        watching.cancel()
        await watching.value
    }
}

// MARK: Pretend pieces

final class FakeLiveFeed: LiveFeed {
    let events: AsyncStream<LiveFeedEvent>
    private let continuation: AsyncStream<LiveFeedEvent>.Continuation
    private let state = Mutex<(sent: [LiveWire.ViewerMessage], cancelled: Bool, closed: Bool)>(([], false, false))

    init(closing close: LiveFeedClose? = nil) {
        (events, continuation) = AsyncStream.makeStream(of: LiveFeedEvent.self)
        if let close { self.close(close) }
    }

    var sent: [LiveWire.ViewerMessage] { state.withLock { $0.sent } }
    var cancelled: Bool { state.withLock { $0.cancelled } }
    var keyframes: Int { sent.filter { $0 == .keyframe }.count }
    var reports: [LiveWire.Report] {
        sent.compactMap { if case .report(let report) = $0 { report } else { nil } }
    }

    func emit(_ event: LiveFeedEvent) { continuation.yield(event) }

    func close(_ close: LiveFeedClose) {
        guard state.withLock({ state in defer { state.closed = true }; return !state.closed }) else { return }
        continuation.yield(.closed(close))
        continuation.finish()
    }

    func send(_ message: LiveWire.ViewerMessage) {
        state.withLock { if !$0.closed { $0.sent.append(message) } }
    }

    func cancel() {
        state.withLock { $0.cancelled = true }
        close(.cancelled)
    }
}

@MainActor
final class FakeDisplay: LiveDisplay {
    var accept = true
    private(set) var shown: [Bool] = []
    private(set) var clears = 0

    func show(_ sample: CMSampleBuffer, keyframe: Bool) -> Bool {
        guard accept else { return false }
        shown.append(keyframe)
        return true
    }

    func clear() { clears += 1 }
}

final class TestClock: Sendable {
    private let value = Mutex(Date(timeIntervalSince1970: 1_800_000_000))
    var now: Date { value.withLock { $0 } }
    func advance(_ seconds: TimeInterval) { value.withLock { $0 = $0.addingTimeInterval(seconds) } }
}

/// The add-on's preview: a live snapshot with a tiny picture, counted for one bot only, so a
/// request a finished test left in flight never counts for the next.
private final class LiveWatchPreviewStub: URLProtocol {
    /// What the preview answers: by default a live snapshot of a helper's own computer.
    struct Answer: Sendable {
        var state = "live"
        var kind = "space"
        var computer = "Studio desktop"
        var control: String? = "helper"
        var image = true
        /// This Mac under Nollie Computer: snapshots never carry a picture.
        static let mac = Answer(state: "unavailable", kind: "mac", computer: "This Mac", control: nil, image: false)
    }

    private static let state = Mutex((requests: 0, profile: "work", answer: Answer()))
    static var requests: Int { state.withLock { $0.requests } }
    static func reset(control: String, profile: String) { reset(profile: profile, answer: Answer(control: control)) }
    static func reset(profile: String, answer: Answer) { state.withLock { $0 = (0, profile, answer) } }
    static func answer(_ answer: Answer) { state.withLock { $0.answer = answer } }

    private static let body: Data = {
        let context = CGContext(data: nil, width: 4, height: 2, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 4, height: 2))
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data as CFMutableData, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        CGImageDestinationFinalize(destination)
        return Data("data:image/png;base64,".utf8) + (data as Data).base64EncodedData()
    }()

    private static let takesEveryRequest = true
    override class func canInit(with request: URLRequest) -> Bool { takesEveryRequest }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let profile = request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }?
            .queryItems?.first { $0.name == "profile" }?.value
        let answer = Self.state.withLock { state in
            if profile == state.profile { state.requests += 1 }
            return state.answer
        }
        var object: [String: Any] = ["state": answer.state, "kind": answer.kind, "computer_name": answer.computer,
                                     "captured_at": Date().timeIntervalSince1970]
        if let control = answer.control { object["control"] = control }
        if answer.image { object["image_data_url"] = String(decoding: Self.body, as: UTF8.self) }
        let data = (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
        let jsonHeaders = ["Content-Type": "application/json"]
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: jsonHeaders)!
        guard let client else { return }
        client.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client.urlProtocol(self, didLoad: data)
        client.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
