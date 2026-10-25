import CoreGraphics
import CoreMedia
import Foundation
import Observation
import NollieCore

/// One live picture on the Watch screen: runs a feed, turns its frames into pictures for the
/// display, and keeps what the host says about the computer (its size, the helper's pointer, who
/// holds it, how the connection is doing). Once a second it tells the host what arrived and what
/// this device can manage; it asks for a keyframe whenever the picture can't carry on without one.
@MainActor @Observable
final class LiveWatch {
    enum Outcome: Equatable {
        case closed(LiveFeedClose)
        /// The device got too warm for video: stills for now.
        case cooling
    }

    /// Low Power Mode and how warm the device is.
    struct Power: Equatable, Sendable {
        var lowPower: Bool
        var thermal: ProcessInfo.ThermalState

        static func now() -> Power {
            Power(lowPower: ProcessInfo.processInfo.isLowPowerModeEnabled, thermal: ProcessInfo.processInfo.thermalState)
        }
    }

    /// Timings of the newest frame shown, in milliseconds, for the debug stats line.
    struct Timing: Equatable {
        /// From capture on the host to arriving here (the two clocks may differ a little).
        var network: Int
        /// From arriving here to being handed to the display.
        var enqueue: Int
        var total: Int { network + enqueue }
    }

    /// A feed is running.
    private(set) var running = false
    /// The running feed has said hello, so its numbers lead.
    private(set) var greeted = false
    private(set) var computerName: String?
    private(set) var kind: String?
    /// The picture's own pixel size: what pointer spots are measured in.
    private(set) var sourceSize: CGSize?
    private(set) var pointer: ComputerPointer?
    private(set) var holder: ComputerHolder?
    private(set) var link: LiveWire.LinkState = .fine
    private(set) var level = 0
    /// The latest beat said the picture is current.
    private(set) var fresh = false
    /// The latest beat said pictures are held back, and why: while Nollie types a saved sign-in,
    /// nothing is shown, not even the last picture.
    private(set) var hold: LiveWire.Hold?
    /// When pictures were last held back. Nothing captured before then is shown again.
    private(set) var heldAt: Date?
    private(set) var beatAt: Date?
    /// When the picture on screen was last known to be current: a new frame, or a fresh beat
    /// after one (a still screen sends no frames).
    private(set) var currentAt: Date?
    private(set) var lastFrameAt: Date?
    /// A frame from a feed is on the display (it stays there after the feed ends).
    private(set) var hasShownFrame = false
    /// The running feed has shown a frame of its own. Until then whatever the display holds is
    /// older than this run.
    private(set) var shownThisRun = false
    private(set) var ended: LiveWire.EndReason?
    /// When the host's end arrived.
    private(set) var endedAt: Date?
    private(set) var limit: LiveWire.Limit = .none
    private(set) var timing: Timing?
    private(set) var shownTotal = 0

    @ObservationIgnored private weak var display: (any LiveDisplay)?
    @ObservationIgnored private var feed: (any LiveFeed)?
    @ObservationIgnored private var builder = LiveSampleBuilder()
    @ObservationIgnored private var got = 0
    @ObservationIgnored private var shown = 0
    @ObservationIgnored private var lateReported = 0
    @ObservationIgnored private var beatMicros: UInt64 = 0
    /// The host's time when this run's pictures were last held back. A frame captured before then
    /// may still be on its way behind the beats, and is never shown.
    @ObservationIgnored private var heldMicros: UInt64 = 0
    @ObservationIgnored private var askedAt: Date?
    @ObservationIgnored private var greetedAt: Date?
    @ObservationIgnored private var keyframeOnAttach = false
    @ObservationIgnored private var cooling = false
    @ObservationIgnored private let reportEvery: Duration
    @ObservationIgnored let power: () -> Power
    @ObservationIgnored private let now: () -> Date

    init(reportEvery: Duration = .seconds(1), power: @escaping () -> Power = Power.now, now: @escaping () -> Date = Date.init) {
        self.reportEvery = reportEvery
        self.power = power
        self.now = now
    }

    /// What this device asks of the host. Nil: too warm for video at all.
    nonisolated static func limit(_ power: Power) -> LiveWire.Limit? {
        switch power.thermal {
        case .critical: nil
        case .serious: power.lowPower ? .lowest : .low
        default: power.lowPower ? .low : LiveWire.Limit.none
        }
    }

    var stats: String { "latency=\(timing?.total ?? -1) frames=\(shownTotal) level=\(level)" }

    // MARK: Running a feed

    /// Plays one feed until it closes or this task is cancelled. The picture stays on the display.
    func run(_ feed: any LiveFeed) async -> Outcome {
        guard let limit = Self.limit(power()) else {
            feed.cancel()
            return .cooling
        }
        self.limit = limit
        start(feed)
        let ticker = Task { [weak self, reportEvery] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: reportEvery) } catch { return }
                self?.tick()
            }
        }
        defer {
            ticker.cancel()
            feed.cancel()
            finish()
        }
        var outcome = Outcome.closed(.cancelled)
        for await event in feed.events {
            switch event {
            case .message(let message): take(message)
            case .video(let video, let receivedAt): take(video, receivedAt: receivedAt)
            case .closed(let close):
                if case .ended(let reason) = close, ended != reason { ended = reason; endedAt = now() }
                outcome = cooling ? .cooling : .closed(close)
            }
        }
        return outcome
    }

    private func start(_ feed: any LiveFeed) {
        self.feed = feed
        running = true
        greeted = false
        // Why the last stream ended stands until this one says hello.
        cooling = false
        // Who holds the computer and where the pointer is come fresh from this run: the
        // pointer right after hello, the holder with the first beat.
        holder = nil; pointer = nil; sourceSize = nil
        builder = LiveSampleBuilder()
        got = 0; shown = 0; lateReported = 0; beatMicros = 0; heldMicros = 0
        askedAt = nil; greetedAt = nil; shownThisRun = false; keyframeOnAttach = false
        link = .fine; fresh = false; beatAt = nil; hold = nil
        // An old picture never stands in for this run's: the display starts clear, and nothing
        // that described the picture it held stays.
        display?.clear()
        hasShownFrame = false; lastFrameAt = nil; currentAt = nil
    }

    private func finish() {
        feed = nil
        running = false
        greeted = false
        fresh = false
        link = .fine
    }

    /// A new chat: nothing from the last one stays.
    func reset() {
        feed?.cancel()
        computerName = nil; kind = nil; sourceSize = nil; pointer = nil; holder = nil
        currentAt = nil; lastFrameAt = nil; hasShownFrame = false; shownThisRun = false; ended = nil; endedAt = nil
        timing = nil; shownTotal = 0; level = 0; hold = nil; heldAt = nil; heldMicros = 0
        display?.clear()
    }

    /// The computer changed while no stream ran: the last picture was of another one, so none of
    /// it stays on the display or speaks for this one.
    func forgetPicture() {
        guard !running else { return }
        hasShownFrame = false; shownThisRun = false; lastFrameAt = nil; currentAt = nil; sourceSize = nil
        ended = nil; endedAt = nil
        display?.clear()
    }

    /// Once a second: the report, the device's limit, and a keyframe asked for again when none came.
    func tick() {
        guard let feed else { return }
        guard let limit = Self.limit(power()) else {
            cooling = true
            feed.cancel()
            return
        }
        self.limit = limit
        let late = builder.late - lateReported
        lateReported = builder.late
        feed.send(.report(LiveWire.Report(beat: beatMicros, got: got, shown: shown, late: late, limit: limit)))
        got = 0
        shown = 0
        // A still screen sends nothing to refuse, so a keyframe that never came is asked for again.
        if greeted, hold == nil, builder.waiting, let since = askedAt ?? greetedAt, now().timeIntervalSince(since) >= 2 { askForKeyframe() }
    }

    private func askForKeyframe() {
        feed?.send(.keyframe)
        askedAt = now()
    }

    private func take(_ message: LiveWire.ServerMessage) {
        switch message {
        case .hello(let hello):
            greeted = true
            greetedAt = now()
            ended = nil; endedAt = nil
            computerName = hello.computer
            kind = hello.kind.rawValue
            sourceSize = CGSize(width: hello.source.width, height: hello.source.height)
        case .beat(let beat):
            beatMicros = beat.micros
            beatAt = now()
            fresh = beat.fresh
            link = beat.link
            level = beat.level
            holder = beat.control.flatMap { ComputerHolder(rawValue: $0.rawValue) }
            let wasHeld = hold != nil
            hold = beat.hold
            if hold != nil, !wasHeld {
                heldMicros = max(heldMicros, beat.micros)
                holdPicture()
            } else if hold == nil, wasHeld, greeted {
                // Pictures again: from a keyframe taken after the pause.
                askForKeyframe()
            }
            if beat.fresh, shownThisRun { currentAt = beatAt }
        case .pointer(let spot):
            pointer = spot.map { ComputerPointer(x: $0.x, y: $0.y, at: $0.at) }
        case .source(let size):
            sourceSize = CGSize(width: size.width, height: size.height)
        case .end(let reason):
            ended = reason
            endedAt = now()
        }
    }

    /// Pictures are held back: the one on the display goes, and nothing from before is kept.
    private func holdPicture() {
        heldAt = now()
        display?.clear()
        builder.lost()
        hasShownFrame = false; shownThisRun = false; lastFrameAt = nil; currentAt = nil
    }

    private func take(_ video: LiveWire.Video, receivedAt: Date) {
        got += 1
        // A frame sent while pictures are held back, or captured before they were, is never shown;
        // the next one starts from a keyframe.
        guard hold == nil, video.captureMicros > heldMicros else {
            builder.lost()
            return
        }
        switch builder.take(video) {
        case .waitingForKeyframe(let justLost):
            if justLost { askForKeyframe() }
        case .sample(let sample):
            guard let display else {
                // Nowhere to show it yet: start from a keyframe once there is.
                keyframeOnAttach = true
                return
            }
            guard display.show(sample, keyframe: video.keyframe) else {
                builder.lost()
                askForKeyframe()
                return
            }
            let enqueued = now()
            shown += 1
            shownTotal += 1
            shownThisRun = true
            hasShownFrame = true
            lastFrameAt = receivedAt
            currentAt = receivedAt
            let captured = Date(timeIntervalSince1970: Double(video.captureMicros) / 1_000_000)
            timing = Timing(network: Self.millis(receivedAt.timeIntervalSince(captured)),
                            enqueue: Self.millis(enqueued.timeIntervalSince(receivedAt)))
        }
    }

    private static func millis(_ seconds: TimeInterval) -> Int { seconds.isFinite ? Int((seconds * 1000).rounded()) : 0 }

    // MARK: The display

    func attach(_ display: any LiveDisplay) {
        self.display = display
        if keyframeOnAttach {
            // The frames that came first had nowhere to go, and a still screen sends no more.
            keyframeOnAttach = false
            builder.lost()
            if greeted { askForKeyframe() }
        }
    }

    func detach(_ display: any LiveDisplay) {
        if self.display === display { self.display = nil }
    }

    /// The display started over by itself: carry on from the next keyframe.
    func displayLost() {
        builder.lost()
        if greeted { askForKeyframe() }
    }
}

extension LiveStreamClient {
    /// The live picture for a chat on its gateway. Without the session token (a gateway signed in
    /// another way) or a reachable linked Mac it closes at once, and the Watch screen keeps stills.
    @MainActor
    static func open(for chat: ChatSession) async -> LiveStreamClient {
        let target = try? await chat.runtime.liveTarget(profile: chat.profileName, sessionID: chat.storedID)
        return LiveStreamClient(target: target)
    }
}

extension LiveFeedRouter {
    /// This Mac's own host for a chat on its own runtime, else the chat's gateway.
    static func open(for chat: ChatSession) async -> any LiveFeed {
        if let feed = local?(chat.runtime.connection, chat.profileName, chat.storedID) { return feed }
        return await LiveStreamClient.open(for: chat)
    }
}
