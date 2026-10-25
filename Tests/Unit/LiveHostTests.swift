#if os(macOS)
import CoreGraphics
import CoreVideo
import Foundation
import Synchronization
import Testing
@testable import Nollie
import NollieCore

/// The Mac's live host with a pretend source, encoder and viewers: what each viewer hears and
/// when, how the judge and the floors move the level, and how a stream ends.
@Suite(.timeLimit(.minutes(1)))
struct LiveHostTests {
    // MARK: Pretend pieces

    final class FakeSource: LiveSource, @unchecked Sendable {
        let kind: LiveWire.ComputerKind
        private let lock = NSLock()
        private var events: (@Sendable (LiveSourceEvent) -> Void)?
        private(set) var starts = 0
        private(set) var stops = 0
        private(set) var levels: [Int] = []

        init(kind: LiveWire.ComputerKind = .space) { self.kind = kind }

        func start(level: Int, events: @escaping @Sendable (LiveSourceEvent) -> Void) {
            lock.withLock { starts += 1; levels.append(level); self.events = events }
        }
        func setLevel(_ level: Int) { lock.withLock { levels.append(level) } }
        func stop() { lock.withLock { stops += 1 } }
        func emit(_ event: LiveSourceEvent) { lock.withLock { events }?(event) }
        var started: Int { lock.withLock { starts } }
        var stopped: Int { lock.withLock { stops } }
        var levelsSeen: [Int] { lock.withLock { levels } }
    }

    /// Answers each picture at once with a frame: a keyframe when asked for one or first.
    final class FakeEncoder: LiveHostEncoding, @unchecked Sendable {
        private let lock = NSLock()
        private let output: @Sendable (LiveWire.Video) -> Void
        private var sequence: UInt32 = 0
        private var wantKeyframe = true
        private(set) var keyframeRequests = 0
        private(set) var levels: [Int] = []
        private(set) var stopped = false

        init(level: Int, output: @escaping @Sendable (LiveWire.Video) -> Void) {
            self.output = output
            levels = [level]
        }

        func encode(_ picture: LivePicture) {
            let video = lock.withLock { () -> LiveWire.Video in
                defer { sequence += 1; wantKeyframe = false }
                let key = wantKeyframe
                return LiveWire.Video(keyframe: key, sequence: sequence, captureMicros: picture.captureMicros, width: 64, height: 40,
                                      parameterSets: key ? [Data([0x40, 1]), Data([0x42, 1]), Data([0x44, 1])] : nil,
                                      sample: Data([0, 0, 0, 2, 0x26, 1]))
            }
            output(video)
        }
        func requestKeyframe() { lock.withLock { keyframeRequests += 1; wantKeyframe = true } }
        func nextIsKeyframe(_ keyframe: Bool) { lock.withLock { wantKeyframe = keyframe } }
        func setLevel(_ level: Int) { lock.withLock { levels.append(level) } }
        func stop() { lock.withLock { stopped = true } }
        var keyframes: Int { lock.withLock { keyframeRequests } }
        var levelsSeen: [Int] { lock.withLock { levels } }
        var isStopped: Bool { lock.withLock { stopped } }
    }

    enum Heard: Equatable {
        case message(LiveWire.ServerMessage)
        case video(keyframe: Bool, sequence: UInt32)
        case end(LiveWire.EndReason)
    }

    final class FakeViewer: LiveHostViewer, @unchecked Sendable {
        private let lock = NSLock()
        private var heard: [Heard] = []
        func send(_ message: LiveWire.ServerMessage) { lock.withLock { heard.append(.message(message)) } }
        func send(_ video: LiveWire.Video, encoded: Data) {
            #expect((try? LiveWire.decodeVideo(encoded)) == video)
            lock.withLock { heard.append(.video(keyframe: video.keyframe, sequence: video.sequence)) }
        }
        func end(_ reason: LiveWire.EndReason) { lock.withLock { heard.append(.end(reason)) } }
        var all: [Heard] { lock.withLock { heard } }
        func take() -> [Heard] { lock.withLock { defer { heard = [] }; return heard } }
        var beats: [LiveWire.Beat] { all.compactMap { if case .message(.beat(let beat)) = $0 { beat } else { nil } } }
    }

    final class Rig: @unchecked Sendable {
        let source: FakeSource
        let limit = Mutex(LiveWire.Limit.none)
        private let lock = NSLock()
        private var encoders: [FakeEncoder] = []
        private(set) var finished = 0
        var host: LiveHost!

        init(kind: LiveWire.ComputerKind = .space) {
            source = FakeSource(kind: kind)
            var environment = LiveHost.Environment()
            environment.beats = false
            environment.now = { 1_000_000 }
            environment.macLimit = { [unowned self] in limit.withLock { $0 } }
            environment.makeEncoder = { [unowned self] level, output in
                let encoder = FakeEncoder(level: level, output: output)
                lock.withLock { encoders.append(encoder) }
                return encoder
            }
            host = LiveHost(key: .init(profile: "work", sessionID: "chat-1"), source: source, environment: environment) { [unowned self] _ in
                lock.withLock { finished += 1 }
            }
        }

        var encoder: FakeEncoder? { lock.withLock { encoders.first } }
        var latestEncoder: FakeEncoder? { lock.withLock { encoders.last } }
        var encoderCount: Int { lock.withLock { encoders.count } }
        var finishes: Int { lock.withLock { finished } }

        func attach(_ viewer: FakeViewer, judged: Bool = false) throws -> LiveHost.ViewerID {
            guard case .viewer(let id) = host.attach(viewer, judged: judged) else { throw Refused() }
            return id
        }

        /// Everything handed over so far, including frames the encoder answered.
        func settle() { host.settle(); host.settle() }

        func emit(_ event: LiveSourceEvent) { source.emit(event); settle() }

        func picture(at micros: UInt64 = 5) { emit(.picture(LivePicture(buffer: LiveHostTests.buffer(), captureMicros: micros))) }

        /// A source that knows its size and pointer, with one picture through.
        func live() {
            emit(.computer("Studio desktop"))
            emit(.control(.helper))
            emit(.fresh(true))
            emit(.pointer(LiveWire.Pointer(x: 10, y: 20, at: nil)))
            emit(.size(.init(width: 1280, height: 800)))
            picture()
        }
    }

    struct Refused: Error {}

    static func buffer(width: Int = 8, height: Int = 8) -> CVPixelBuffer {
        var made: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, nil, &made)
        return made!
    }

    private func second(sent: Int = 10, withheld: Int = 0, taken: Int = 1000, waiting: Int = 0, heard: Bool = true) -> LiveHost.Input {
        .stats(LiveJudge.Second(sent: sent, withheld: withheld, bytesTaken: taken, bytesWaiting: waiting, heard: heard))
    }

    // MARK: What a viewer hears

    @Test func helloComesFirstThenThePointerAndABeat() throws {
        let rig = Rig()
        let viewer = FakeViewer()
        _ = try rig.attach(viewer)
        #expect(rig.source.started == 1)
        rig.emit(.computer("Studio desktop"))
        rig.emit(.control(.helper))
        rig.emit(.pointer(LiveWire.Pointer(x: 10, y: 20, at: 3)))
        // Nothing before the size is known: hello needs it.
        rig.picture()
        #expect(viewer.all.isEmpty)
        rig.emit(.size(.init(width: 1280, height: 800)))
        let greeting = viewer.take()
        #expect(greeting.count == 3)
        #expect(greeting.first == .message(.hello(.init(kind: .space, computer: "Studio desktop", source: .init(width: 1280, height: 800)))))
        #expect(greeting.dropFirst().first == .message(.pointer(.init(x: 10, y: 20, at: 3))))
        guard case .message(.beat(let beat)) = greeting.last else { Issue.record("No beat after hello"); return }
        #expect(beat.control == .helper && beat.link == .fine && beat.level == 0)
        #expect(!beat.fresh, "Fresh only once a picture went out")

        rig.picture()
        #expect(viewer.take() == [.video(keyframe: true, sequence: 0)])
        // The pointer and the size go out when they change, and only then.
        rig.emit(.pointer(LiveWire.Pointer(x: 10, y: 20, at: 3)))
        rig.emit(.pointer(LiveWire.Pointer(x: 11, y: 20, at: 4)))
        rig.emit(.pointer(nil))
        rig.emit(.size(.init(width: 1280, height: 800)))
        rig.emit(.size(.init(width: 1440, height: 900)))
        #expect(viewer.take() == [.message(.pointer(.init(x: 11, y: 20, at: 4))), .message(.pointer(nil)),
                                  .message(.source(.init(width: 1440, height: 900)))])
    }

    @Test func beatsSayWhetherThePictureIsCurrentAndWhoHasIt() throws {
        let rig = Rig()
        let viewer = FakeViewer()
        _ = try rig.attach(viewer, judged: true)
        rig.live()
        _ = viewer.take()
        rig.host.beat()
        rig.settle()
        #expect(viewer.beats == [LiveWire.Beat(micros: 1_000_000, fresh: true, link: .fine, level: 0, control: .helper)])
        _ = viewer.take()
        rig.emit(.fresh(false))
        rig.emit(.control(.you))
        rig.host.beat()
        rig.settle()
        #expect(viewer.beats == [LiveWire.Beat(micros: 1_000_000, fresh: false, link: .fine, level: 0, control: .you)])
    }

    // MARK: The judge and the floors

    @Test func judgeVerdictsChangeTheLevelAndAskForAKeyframe() throws {
        let rig = Rig()
        let viewer = FakeViewer()
        let id = try rig.attach(viewer, judged: true)
        rig.live()
        let encoder = try #require(rig.encoder)
        let keyframesBefore = encoder.keyframes
        // Two short seconds in four: behind, one step lighter.
        rig.host.receive(second(sent: 5, withheld: 5), from: id)
        rig.host.receive(second(sent: 5, withheld: 5), from: id)
        rig.settle()
        #expect(rig.host.currentLevel == 1)
        #expect(encoder.levelsSeen.last == 1)
        #expect(rig.source.levelsSeen.last == 1)
        #expect(encoder.keyframes > keyframesBefore)
        rig.host.beat()
        rig.settle()
        #expect(viewer.beats.last?.link == .behind && viewer.beats.last?.level == 1)

        // Two dead seconds: stalled and lighter again; the first live second asks for a keyframe.
        rig.host.receive(second(sent: 0, taken: 0, waiting: 500, heard: false), from: id)
        rig.host.receive(second(sent: 0, taken: 0, waiting: 500, heard: false), from: id)
        rig.settle()
        #expect(rig.host.currentLevel == 2)
        let stalledKeyframes = encoder.keyframes
        rig.host.receive(second(), from: id)
        rig.settle()
        #expect(encoder.keyframes == stalledKeyframes + 1)

        // A viewer's own keyframe request reaches the encoder too.
        rig.host.receive(.viewer(.keyframe), from: id)
        rig.settle()
        #expect(encoder.keyframes == stalledKeyframes + 2)
    }

    @Test func theViewersLimitAndThisMacSetTheFloor() throws {
        let rig = Rig()
        let viewer = FakeViewer()
        let id = try rig.attach(viewer)
        rig.live()
        #expect(rig.host.currentLevel == 0)
        rig.host.receive(.viewer(.report(.init(beat: 0, got: 30, shown: 30, late: 0, limit: .low))), from: id)
        rig.settle()
        #expect(rig.host.currentLevel == 2)
        rig.host.receive(.viewer(.report(.init(beat: 0, got: 30, shown: 30, late: 0, limit: .lowest))), from: id)
        rig.settle()
        #expect(rig.host.currentLevel == 3)
        rig.host.receive(.viewer(.report(.init(beat: 0, got: 30, shown: 30, late: 0, limit: .none))), from: id)
        rig.settle()
        #expect(rig.host.currentLevel == 0)

        // This Mac in Low Power Mode or warm: level 2; hot: level 3. Read at each beat.
        rig.limit.withLock { $0 = .low }
        rig.host.beat()
        rig.settle()
        #expect(rig.host.currentLevel == 2)
        rig.limit.withLock { $0 = .lowest }
        rig.host.beat()
        rig.settle()
        #expect(rig.host.currentLevel == 3)
        #expect(viewer.beats.last?.level == 3)
        rig.limit.withLock { $0 = .none }
        rig.host.beat()
        rig.settle()
        #expect(rig.host.currentLevel == 0)
        #expect(rig.source.levelsSeen == [0, 2, 3, 0, 2, 3, 0])
    }

    @Test func aHotMacStartsLight() throws {
        let rig = Rig()
        rig.limit.withLock { $0 = .lowest }
        _ = try rig.attach(FakeViewer())
        #expect(rig.host.currentLevel == 3)
        #expect(rig.source.levelsSeen == [3])
        #expect(rig.encoder?.levelsSeen == [3])
    }

    @Test func thisMacsLimitFollowsLowPowerModeAndWarmth() {
        let limit = LiveHost.macLimit()
        switch ProcessInfo.processInfo.thermalState {
        case .critical: #expect(limit == .lowest)
        case .serious: #expect(limit == .low)
        default: #expect(limit == (ProcessInfo.processInfo.isLowPowerModeEnabled ? .low : .none))
        }
    }

    // MARK: A saved sign-in

    private func held(_ fresh: Bool = false, _ hold: LiveWire.Hold? = .signIn) -> Heard {
        .message(.beat(LiveWire.Beat(micros: 1_000_000, fresh: fresh, link: .fine, level: 0, control: .helper, hold: hold)))
    }

    @Test func whileASignInIsTypedNoPictureGoesOutAndBeatsSaySo() throws {
        let rig = Rig()
        let viewer = FakeViewer()
        let id = try rig.attach(viewer)
        rig.live()
        #expect(viewer.take().contains(.video(keyframe: true, sequence: 0)))
        let first = try #require(rig.encoder)
        rig.emit(.hold(.signIn))
        // Said at once, and the encoder goes with the picture it keeps for keyframes.
        #expect(viewer.take() == [held()])
        #expect(first.isStopped && rig.encoderCount == 1)
        rig.emit(.hold(.signIn))
        #expect(viewer.take().isEmpty, "Only a change is said")

        // Nothing goes out while held: not a new picture, not a frame the old encoder still had, not a keyframe.
        rig.emit(.fresh(true))
        rig.picture(at: 2_000_000)
        first.encode(LivePicture(buffer: Self.buffer(), captureMicros: 2_000_000))
        rig.host.receive(.viewer(.keyframe), from: id)
        rig.settle()
        rig.host.beat()
        rig.settle()
        #expect(viewer.take() == [held()], "Never fresh while held")
        #expect(rig.encoderCount == 1)

        // Someone who starts watching now is greeted, told, and shown nothing.
        let late = FakeViewer()
        _ = try rig.attach(late)
        #expect(late.take() == [.message(.hello(.init(kind: .space, computer: "Studio desktop", source: .init(width: 1280, height: 800)))),
                                .message(.pointer(.init(x: 10, y: 20, at: nil))), held()])

        // Over: a new encoder, and the first picture after it is a keyframe for everyone.
        rig.emit(.hold(nil))
        #expect(rig.encoderCount == 2)
        #expect(viewer.take() == [held(false, nil)], "Not current until a picture goes out again")
        _ = late.take()
        // A picture taken before the hold began never goes out afterwards.
        rig.picture(at: 5)
        #expect(viewer.take().isEmpty && late.take().isEmpty)
        rig.picture(at: 2_000_000)
        #expect(viewer.take() == [.video(keyframe: true, sequence: 0)])
        #expect(late.take() == [.video(keyframe: true, sequence: 0)])
        rig.host.beat()
        rig.settle()
        #expect(viewer.take() == [held(true, nil)])
        #expect(rig.latestEncoder?.isStopped == false)
    }

    @Test func aHoldThatEndsTheStreamStopsEverything() throws {
        let rig = Rig()
        let viewer = FakeViewer()
        _ = try rig.attach(viewer)
        rig.live()
        rig.emit(.hold(.signIn))
        rig.emit(.ended(.stopped))
        #expect(viewer.all.last == .end(.stopped))
        #expect(rig.source.stopped == 1 && rig.finishes == 1)
        // A hold lifted after the end makes no encoder.
        rig.emit(.hold(nil))
        #expect(rig.encoderCount == 1)
    }

    // MARK: Sharing and ending

    @Test func viewersShareOneSourceAndOneEncoder() throws {
        let rig = Rig()
        let first = FakeViewer(), second = FakeViewer()
        let firstID = try rig.attach(first)
        rig.live()
        rig.picture()
        #expect(first.all.filter { if case .video = $0 { true } else { false } }.count == 2)
        let encoder = try #require(rig.encoder)
        let keyframesBefore = encoder.keyframes
        let secondID = try rig.attach(second)
        // The newcomer is greeted at once and a keyframe is asked for, so it can start.
        #expect(second.all.first == .message(.hello(.init(kind: .space, computer: "Studio desktop", source: .init(width: 1280, height: 800)))))
        #expect(encoder.keyframes == keyframesBefore + 1)
        _ = second.take()
        rig.picture()
        rig.picture()
        #expect(second.take() == [.video(keyframe: true, sequence: 2), .video(keyframe: false, sequence: 3)])
        #expect(rig.source.started == 1 && rig.encoderCount == 1)

        // One leaving keeps the source for the other; the last one leaving stops it.
        rig.host.detach(firstID)
        rig.settle()
        #expect(rig.source.stopped == 0)
        rig.host.detach(secondID)
        rig.settle()
        #expect(rig.source.stopped == 1 && encoder.isStopped && rig.finishes == 1)
        #expect(rig.host.attach(FakeViewer(), judged: false) == .ended)
    }

    @Test func theAppStaysOutOfAppNapOnlyWhileSomeoneWatches() throws {
        let rig = Rig()
        #expect(!rig.host.keepsAppAwake)
        let first = try rig.attach(FakeViewer())
        let second = try rig.attach(FakeViewer())
        #expect(rig.host.keepsAppAwake)
        rig.host.detach(first)
        rig.settle()
        #expect(rig.host.keepsAppAwake, "Someone is still watching")
        rig.host.detach(second)
        rig.settle()
        #expect(!rig.host.keepsAppAwake, "The last viewer leaving lets the app rest")

        let ended = Rig()
        _ = try ended.attach(FakeViewer())
        ended.host.stop(.stopped)
        ended.settle()
        #expect(!ended.host.keepsAppAwake)
    }

    @Test func aNewViewerNeverGetsFramesBeforeItsKeyframe() throws {
        let rig = Rig()
        let first = FakeViewer(), late = FakeViewer()
        _ = try rig.attach(first)
        rig.live()
        _ = try rig.attach(late)
        _ = first.take()
        _ = late.take()
        // A frame the encoder had already started is no keyframe: only the first viewer gets it.
        let encoder = try #require(rig.encoder)
        encoder.nextIsKeyframe(false)
        rig.picture()
        #expect(first.take() == [.video(keyframe: false, sequence: 1)])
        #expect(late.take().isEmpty)
        encoder.nextIsKeyframe(true)
        rig.picture()
        rig.picture()
        #expect(late.take() == [.video(keyframe: true, sequence: 2), .video(keyframe: false, sequence: 3)])
        #expect(first.take() == [.video(keyframe: true, sequence: 2), .video(keyframe: false, sequence: 3)])
    }

    @Test func endsSayWhyToEveryViewer() throws {
        for reason in [LiveWire.EndReason.stopped, .gone, .unavailable] {
            let rig = Rig()
            let first = FakeViewer(), second = FakeViewer()
            _ = try rig.attach(first)
            _ = try rig.attach(second)
            rig.live()
            rig.emit(.ended(reason))
            #expect(first.all.last == .end(reason) && second.all.last == .end(reason))
            #expect(rig.source.stopped == 1 && rig.finishes == 1)
            // Nothing after the end.
            rig.picture()
            rig.host.beat()
            rig.settle()
            #expect(first.all.last == .end(reason))
        }
        let rig = Rig()
        let viewer = FakeViewer()
        _ = try rig.attach(viewer)
        rig.host.stop(.gone)
        rig.settle()
        #expect(viewer.all == [.end(.gone)])
    }

    @Test func tooManyViewersAreBusy() throws {
        let rig = Rig()
        for _ in 0..<LiveHost.maximumViewers { _ = try rig.attach(FakeViewer()) }
        #expect(rig.host.attach(FakeViewer(), judged: false) == .full)
    }

    // MARK: The center

    @MainActor @Test func theCenterSharesHostsAndRefusesWhatItMustNot() async throws {
        let center = LiveHostCenter()
        let sources = Mutex<[FakeSource]>([])
        center.isPrivate = { $0 == "private" }
        center.environment.beats = false
        center.chooseSource = { profile, _ in
            if profile == "nothing" { return .failure(LiveHostRefusal(reason: .stopped)) }
            let source = FakeSource()
            sources.withLock { $0.append(source) }
            return .success(source)
        }
        func open(_ profile: String, _ session: String = "chat-1") async -> LiveHostCenter.Opened {
            await center.open(profile: profile, sessionID: session, viewer: FakeViewer(), judged: false)
        }
        guard case .ended(.refused) = await open("private") else { Issue.record("A private bot was asked about"); return }
        guard case .ended(.refused) = await open("work", "../x") else { Issue.record("A bad chat id got through"); return }
        guard case .ended(.stopped) = await open("nothing") else { Issue.record("No source should end stopped"); return }
        guard case .attached(let first, _) = await open("work"), case .attached(let again, _) = await open("work") else {
            Issue.record("No host"); return
        }
        #expect(first === again && sources.withLock { $0.count } == 1)
        guard case .attached = await open("work", "chat-2") else { Issue.record("A second chat should get a host"); return }
        guard case .ended(.busy) = await open("work", "chat-3") else { Issue.record("Too many hosts should be busy"); return }
        #expect(center.count == LiveHostCenter.maximumHosts)
        center.stopAll()
        #expect(center.count == 0)
    }

    @MainActor @Test func viewersWhoAskTogetherShareOneHost() async throws {
        let center = LiveHostCenter()
        center.environment.beats = false
        let made = LiveTestBox(0)
        // Finding the source takes a moment (Hermes may be asked about the chat).
        center.chooseSource = { _, _ in
            made.withLock { $0 += 1 }
            try? await Task.sleep(for: .milliseconds(50))
            return .success(FakeSource())
        }
        let first = Task { await center.open(profile: "work", sessionID: "chat-1", viewer: FakeViewer(), judged: false) }
        let second = Task { await center.open(profile: "work", sessionID: "chat-1", viewer: FakeViewer(), judged: false) }
        guard case .attached(let one, _) = await first.value, case .attached(let two, _) = await second.value else {
            Issue.record("No host"); return
        }
        #expect(one === two && center.count == 1)
        #expect(one.viewerCount == 2)
        center.stopAll()
    }

    @MainActor @Test func onlyThisMacsOwnRuntimePlaysInProcess() throws {
        let local = try GatewayURL.normalize("http://127.0.0.1:48123")
        var own = GatewayConnection(name: "This Mac", gateway: local, authMode: .sessionToken, managedInstallationID: UUID())
        #expect(LiveHostCenter.isOwnRuntime(own) == !DemoMode.isOn)
        own.managedInstallationID = nil
        #expect(!LiveHostCenter.isOwnRuntime(own), "A loopback gateway Nollie doesn't own, like the mock, uses the network")
        let remote = GatewayConnection(name: "Studio", gateway: try GatewayURL.normalize("https://studio.example.net:8443"),
                                       authMode: .sessionToken, managedInstallationID: UUID())
        #expect(!LiveHostCenter.isOwnRuntime(remote))
        #expect(LiveHostCenter.shared.localFeed(connection: remote, profile: "work", sessionID: "chat-1") == nil)
    }

    // MARK: The Mac's own Watch screen

    @MainActor @Test func theLocalFeedHearsWhatAPhoneWouldAndClosesOnce() async throws {
        let center = LiveHostCenter()
        let source = FakeSource()
        center.environment.beats = false
        center.chooseSource = { _, _ in .success(source) }
        let feed = LiveLocalFeed()
        guard case .attached(let host, let id) = await center.open(profile: "work", sessionID: "chat-1", viewer: feed, judged: false) else {
            Issue.record("No host"); return
        }
        feed.connect(host, id: id)
        source.emit(.size(.init(width: 1280, height: 800)))
        source.emit(.picture(LivePicture(buffer: Self.buffer(), captureMicros: 7)))
        host.settle()
        feed.send(.keyframe)
        feed.cancel()
        feed.cancel()
        var events: [String] = []
        for await event in feed.events {
            switch event {
            case .message(.hello): events.append("hello")
            case .message(.pointer): events.append("pointer")
            case .message(.beat): events.append("beat")
            case .message: events.append("message")
            case .video(let video, _): events.append(video.keyframe ? "keyframe" : "frame")
            case .closed(let how): events.append("closed \(how)")
            }
        }
        #expect(events.first == "hello" && events.last == "closed cancelled")
        #expect(events.filter { $0.hasPrefix("closed") }.count == 1)
        host.settle()
        host.settle()
        #expect(source.stopped == 1, "The last viewer leaving stops the source")
    }

    @Test func theLocalFeedDropsVideoTheScreenHasntTakenAndAsksForAKeyframe() async throws {
        let rig = Rig()
        let feed = LiveLocalFeed()
        guard case .viewer(let id) = rig.host.attach(feed, judged: false) else { throw Refused() }
        feed.connect(rig.host, id: id)
        rig.live()
        // The screen takes nothing while twelve more pictures go through.
        for micros in 6..<18 { rig.picture(at: UInt64(micros)) }
        rig.settle()
        #expect(feed.dropped > 0)
        #expect((rig.encoder?.keyframes ?? 0) >= 1, "A drop asks the host for a keyframe")
        feed.cancel()
        var videos: [LiveWire.Video] = []
        var hellos = 0
        var closes = 0
        for await event in feed.events {
            switch event {
            case .video(let video, _): videos.append(video)
            case .message(.hello): hellos += 1
            case .closed: closes += 1
            case .message: break
            }
        }
        #expect(hellos == 1 && closes == 1, "Text and the end are never dropped")
        #expect(videos.count <= LiveLocalFeed.videoWaiting)
        #expect(videos.first?.keyframe == true)
        // Every frame after the first follows the one before it: nothing the screen can't show.
        for (before, after) in zip(videos, videos.dropFirst()) where !after.keyframe {
            #expect(after.sequence == before.sequence + 1)
        }
    }

    @Test func aFeedThatEndsTellsWhyThenCloses() async {
        let feed = LiveLocalFeed()
        feed.end(.stopped)
        feed.end(.gone)
        var events: [LiveFeedEvent] = []
        for await event in feed.events { events.append(event) }
        #expect(events.count == 2)
        if case .message(.end(.stopped)) = events.first {} else { Issue.record("No end message") }
        if case .closed(.ended(.stopped)) = events.last {} else { Issue.record("Not closed with the reason") }
    }
}
#endif
