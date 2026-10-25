import CoreVideo
import Dispatch
import Foundation
import NollieCore

/// A captured picture. Sources hand these over and never draw into them again.
struct LivePicture: @unchecked Sendable {
    let buffer: CVPixelBuffer
    /// The host's Unix time in microseconds when the picture was captured.
    let captureMicros: UInt64
}

/// What a source tells its host. Any thread; the host puts them in order.
enum LiveSourceEvent: Sendable {
    /// The picture's own pixel size, the space pointer spots are in. Comes before the first picture.
    case size(LiveWire.PixelSize)
    case picture(LivePicture)
    case pointer(LiveWire.Pointer?)
    case control(LiveWire.Control?)
    /// Whether the picture is current. An unchanged screen stays fresh without new pictures.
    case fresh(Bool)
    /// Pictures are held back (nil: no longer), as the computer add-on's preview pauses while
    /// Nollie types a saved sign-in. No picture taken before the hold ended is sent.
    case hold(LiveWire.Hold?)
    case computer(String)
    /// Nothing more comes.
    case ended(LiveWire.EndReason)
}

/// Where a host's pictures come from: one window of this Mac, or a helper's own computer.
protocol LiveSource: AnyObject, Sendable {
    var kind: LiveWire.ComputerKind { get }
    /// Starts at a quality level. Called once.
    func start(level: Int, events: @escaping @Sendable (LiveSourceEvent) -> Void)
    /// Captures for another level: smaller or fewer pictures, never bigger than the source.
    func setLevel(_ level: Int)
    func stop()
}

/// One viewer of a host: the Mac's own Watch screen, or a phone through Nollie Runtime.
/// Calls come one at a time from the host's queue and must not wait on it.
protocol LiveHostViewer: AnyObject, Sendable {
    func send(_ message: LiveWire.ServerMessage)
    /// One encoded frame, and its wire message (made once for every viewer).
    func send(_ video: LiveWire.Video, encoded: Data)
    /// Tells the viewer why and closes. Nothing follows.
    func end(_ reason: LiveWire.EndReason)
}

/// The encoder a host feeds; `LiveEncoder` on this Mac, a pretend one in tests.
protocol LiveHostEncoding: AnyObject, Sendable {
    func encode(_ picture: LivePicture)
    func requestKeyframe()
    func setLevel(_ level: Int)
    func stop()
}

/// Real-time HEVC through NollieCore's encoder.
final class LiveHostEncoder: LiveHostEncoding {
    private let encoder: LiveEncoder

    init(level: Int, output: @escaping @Sendable (LiveWire.Video) -> Void) {
        encoder = LiveEncoder(level: level) { output($0.video) }
    }

    var engine: LiveEncoder.Engine? { encoder.engine }
    func encode(_ picture: LivePicture) { encoder.encode(picture.buffer, captureMicros: picture.captureMicros) }
    func requestKeyframe() { encoder.requestKeyframe() }
    func setLevel(_ level: Int) { encoder.setLevel(level) }
    func stop() { encoder.stop() }
}

/// The live picture of one chat's computer, shared by everyone watching it: one source, one
/// encoder, and for each viewer its own hello, beats and link judge. The quality level is the
/// lightest any viewer needs, and never better than this Mac's own Low Power Mode or warmth
/// allows. The last viewer leaving stops the source.
///
/// Thread-safe. Its work runs on its own queue, off the main thread.
final class LiveHost: @unchecked Sendable {
    struct Key: Hashable, Sendable {
        var profile: String
        var sessionID: String
    }

    typealias ViewerID = Int

    /// What a viewer says: its own messages, or (for a phone) the door's counts for a second.
    enum Input: Sendable, Equatable {
        case viewer(LiveWire.ViewerMessage)
        case stats(LiveJudge.Second)
    }

    enum Attached: Equatable, Sendable {
        case viewer(ViewerID)
        case full
        case ended
    }

    struct Environment: Sendable {
        /// What this Mac allows right now.
        var macLimit: @Sendable () -> LiveWire.Limit = LiveHost.macLimit
        var now: @Sendable () -> UInt64 = { LiveWire.micros() }
        var makeEncoder: @Sendable (_ level: Int, _ output: @escaping @Sendable (LiveWire.Video) -> Void) -> any LiveHostEncoding = {
            LiveHostEncoder(level: $0, output: $1)
        }
        /// Beats once a second by themselves; tests call `beat()`.
        var beats = true
    }

    /// The Mac's own Watch, a phone or two: more is too many for one encoder.
    static let maximumViewers = 4

    let key: Key
    private let source: any LiveSource
    private let environment: Environment
    private let finished: @Sendable (LiveHost) -> Void
    private let queue = DispatchQueue(label: "com.coreykozarski.nollie.live-host", qos: .userInteractive)

    private struct Viewer {
        let sink: any LiveHostViewer
        /// A phone through the door, whose link is judged from the door's counts.
        let judged: Bool
        var judge = LiveJudge()
        var limit = LiveWire.Limit.none
        /// The level this viewer needs.
        var level = LiveQuality.best
        var greeted = false
        /// Frames before its first keyframe can't be shown, so none are sent.
        var hasKeyframe = false
    }

    // Everything below belongs to `queue`.
    private var viewers: [ViewerID: Viewer] = [:]
    private var nextID = 1
    private var started = false
    private var ended = false
    private var level = LiveQuality.best
    private var macFloor = LiveQuality.best
    private var encoder: (any LiveHostEncoding)?
    private var timer: (any DispatchSourceTimer)?
    private var computer: String
    private var size: LiveWire.PixelSize?
    private var pointer: LiveWire.Pointer?
    private var control: LiveWire.Control?
    private var fresh = false
    private var pictured = false
    private var hold: LiveWire.Hold?
    /// When pictures were last held back: nothing captured before then is encoded afterwards.
    private var heldAtMicros: UInt64 = 0
    /// Which encoder is current; frames from one already let go are dropped.
    private var encoderGeneration = 0
    /// Keeps Nollie out of App Nap while anyone watches, so beats and pictures stay on time.
    private var activity: (any NSObjectProtocol)?

    init(key: Key, source: any LiveSource, computer: String = "Computer", environment: Environment = Environment(),
         finished: @escaping @Sendable (LiveHost) -> Void = { _ in }) {
        self.key = key
        self.source = source
        self.computer = computer
        self.environment = environment
        self.finished = finished
    }

    /// Adds a viewer. Its hello comes as soon as the picture's size is known, then a keyframe.
    func attach(_ sink: any LiveHostViewer, judged: Bool) -> Attached {
        queue.sync {
            guard !ended else { return .ended }
            guard viewers.count < Self.maximumViewers else { return .full }
            let id = nextID
            nextID += 1
            viewers[id] = Viewer(sink: sink, judged: judged)
            if started {
                greet(id)
                encoder?.requestKeyframe()
            } else {
                start()
            }
            return .viewer(id)
        }
    }

    func receive(_ input: Input, from id: ViewerID) {
        queue.async { [self] in
            guard !ended, var viewer = viewers[id] else { return }
            switch input {
            case .viewer(.keyframe):
                encoder?.requestKeyframe()
            case .viewer(.report(let report)):
                viewer.limit = report.limit
                viewer.level = max(viewer.judged ? viewer.judge.level : LiveQuality.best, LiveJudge.floor(for: report.limit))
            case .stats(let second):
                guard viewer.judged else { return }
                let verdict = viewer.judge.judge(second, limit: viewer.limit)
                viewer.level = verdict.level
                if verdict.needsKeyframe { encoder?.requestKeyframe() }
            }
            viewers[id] = viewer
            relevel()
        }
    }

    /// The viewer left. The last one leaving stops the host.
    func detach(_ id: ViewerID) {
        queue.async { [self] in
            guard viewers.removeValue(forKey: id) != nil, viewers.isEmpty, !ended else { return }
            shutDown()
        }
    }

    /// Ends the host for everyone, saying why.
    func stop(_ reason: LiveWire.EndReason) {
        queue.async { [self] in finish(reason) }
    }

    /// The once-a-second beat: this Mac's floor, then each viewer's beat.
    func beat() {
        queue.async { [self] in
            guard !ended else { return }
            macFloor = LiveJudge.floor(for: environment.macLimit())
            relevel()
            for id in viewers.keys { sendBeat(id) }
        }
    }

    /// Waits for everything handed to the host so far (tests).
    func settle() { queue.sync {} }

    var currentLevel: Int { queue.sync { level } }
    var viewerCount: Int { queue.sync { viewers.count } }
    var keepsAppAwake: Bool { queue.sync { activity != nil } }

    // MARK: On the queue

    private func start() {
        started = true
        // Never the display or system sleep: only timers and work kept from being slowed.
        activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiatedAllowingIdleSystemSleep, .latencyCritical],
                                                         reason: "Live picture")
        macFloor = LiveJudge.floor(for: environment.macLimit())
        level = macFloor
        makeEncoder()
        source.start(level: level) { [weak self] event in
            guard let self else { return }
            queue.async { self.handle(event) }
        }
        guard environment.beats else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1, repeating: 1, leeway: .milliseconds(50))
        timer.setEventHandler { [weak self] in self?.beat() }
        timer.resume()
        self.timer = timer
    }

    private func handle(_ event: LiveSourceEvent) {
        guard !ended else { return }
        switch event {
        case .size(let next):
            guard next != size else { return }
            let first = size == nil
            size = next
            if first {
                for id in viewers.keys { greet(id) }
            } else {
                send(.source(next))
            }
        case .picture(let picture):
            guard size != nil, hold == nil, picture.captureMicros > heldAtMicros else { return }
            encoder?.encode(picture)
        case .pointer(let next):
            guard next != pointer else { return }
            pointer = next
            send(.pointer(next))
        case .control(let next):
            control = next
        case .fresh(let next):
            fresh = next
        case .hold(let next):
            guard next != hold else { return }
            hold = next
            if next != nil {
                // The encoder goes with the picture it keeps for keyframes, so nothing from before
                // the hold can be sent again; every viewer waits for a keyframe taken after it.
                heldAtMicros = environment.now()
                encoder?.stop()
                encoder = nil
                encoderGeneration += 1
                pictured = false
                for id in viewers.keys { viewers[id]?.hasKeyframe = false }
            } else {
                makeEncoder()
            }
            // Said at once, not up to a second later.
            for id in viewers.keys { sendBeat(id) }
        case .computer(let name):
            computer = name
        case .ended(let reason):
            finish(reason)
        }
    }

    private func makeEncoder() {
        let generation = encoderGeneration
        encoder = environment.makeEncoder(level) { [weak self] video in self?.deliver(video, generation: generation) }
    }

    private func deliver(_ video: LiveWire.Video, generation: Int) {
        queue.async { [self] in
            guard !ended, hold == nil, generation == encoderGeneration else { return }
            let encoded = LiveWire.encode(video)
            pictured = true
            for (id, viewer) in viewers where viewer.greeted {
                if !viewer.hasKeyframe {
                    guard video.keyframe else { continue }
                    viewers[id]?.hasKeyframe = true
                }
                viewer.sink.send(video, encoded: encoded)
            }
        }
    }

    /// Hello, where the pointer is, and a first beat, once the size is known.
    private func greet(_ id: ViewerID) {
        guard let size, let viewer = viewers[id], !viewer.greeted else { return }
        viewers[id]?.greeted = true
        viewer.sink.send(.hello(LiveWire.Hello(kind: source.kind, computer: computer, source: size)))
        viewer.sink.send(.pointer(pointer))
        sendBeat(id)
    }

    private func sendBeat(_ id: ViewerID) {
        guard let viewer = viewers[id], viewer.greeted else { return }
        viewer.sink.send(.beat(LiveWire.Beat(micros: environment.now(), fresh: fresh && pictured && hold == nil,
                                             link: viewer.judged ? viewer.judge.state : .fine, level: level, control: control,
                                             hold: hold)))
    }

    private func send(_ message: LiveWire.ServerMessage) {
        for viewer in viewers.values where viewer.greeted { viewer.sink.send(message) }
    }

    /// The lightest level any viewer needs, and at least this Mac's floor. A new level means a
    /// new session in the encoder, starting from a keyframe, and a smaller or bigger capture.
    private func relevel() {
        let wanted = min(max(macFloor, viewers.values.map(\.level).max() ?? LiveQuality.best), LiveQuality.lightest)
        guard wanted != level else { return }
        level = wanted
        encoder?.setLevel(wanted)
        encoder?.requestKeyframe()
        source.setLevel(wanted)
    }

    private func finish(_ reason: LiveWire.EndReason) {
        guard !ended else { return }
        let leaving = viewers.values
        viewers = [:]
        for viewer in leaving { viewer.sink.end(reason) }
        shutDown()
    }

    private func shutDown() {
        ended = true
        timer?.cancel()
        timer = nil
        source.stop()
        encoder?.stop()
        encoder = nil
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
        activity = nil
        finished(self)
    }

    // MARK: This Mac

    /// Low Power Mode or a warm Mac keeps the picture light; a hot one, lightest.
    static func macLimit() -> LiveWire.Limit {
        switch ProcessInfo.processInfo.thermalState {
        case .critical: .lowest
        case .serious: .low
        default: ProcessInfo.processInfo.isLowPowerModeEnabled ? .low : .none
        }
    }

    /// A message from a viewer through Nollie Runtime: the phone's own JSON, or the door's
    /// once-a-second counts. Anything else is nil.
    static func input(_ data: Data) -> Input? {
        guard data.count <= NollieLiveRelayConfiguration.requestLimit, let text = String(data: data, encoding: .utf8) else { return nil }
        if let message = try? LiveWire.ViewerMessage.decode(text) { return .viewer(message) }
        guard let fields = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], fields["type"] as? String == "stats",
              let heard = fields["heard"] as? Bool else { return nil }
        func count(_ key: String) -> Int? {
            guard let number = fields[key] as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
            let value = number.doubleValue
            guard value.isFinite, value.rounded(.towardZero) == value, value >= 0, value <= 1e12 else { return nil }
            return Int(value)
        }
        guard let sent = count("sent"), let withheld = count("withheld"), let taken = count("taken"),
              let waiting = count("waiting") else { return nil }
        return .stats(LiveJudge.Second(sent: sent, withheld: withheld, bytesTaken: taken, bytesWaiting: waiting, heard: heard))
    }
}
