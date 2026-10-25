import AppKit
import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import NollieCore
@preconcurrency import ScreenCaptureKit
import Synchronization

/// Which window of this Mac a live picture shows: one window of the app Nollie Computer's task
/// last used, never anything else. Pure, so the choice is tested without a screen.
enum LiveWindowChoice {
    struct Window: Equatable, Sendable {
        var id: Int
        var pid: Int
        var layer: Int
        var onScreen: Bool
        /// In points, top left.
        var bounds: CGRect
    }

    enum Result: Equatable, Sendable {
        case window(Window)
        /// The task runs, but its app shows no window right now.
        case noWindow
        /// No task for this chat: the helper isn't using the Mac.
        case stopped
        /// A private bot, even one marked private while its task runs: never shown.
        case refused
    }

    /// The window the helper last acted in for its current app, else that app's frontmost window
    /// on screen. `windows` come front to back; only the approved app's own windows count.
    static func choose(task: ComputerTask?, profile: String, sessionID: String, pid: (ComputerTask.App) -> Int?,
                       lastWindow: (Int) -> Int?, windows: [Window],
                       isPrivate: (String) -> Bool = ComputerOtherControl.isPrivate) -> Result {
        guard !isPrivate(profile) else { return .refused }
        guard let task, task.isChat(profile: profile, sessionID: sessionID) else { return .stopped }
        guard let app = task.currentApp.flatMap(task.app(named:)) ?? task.apps.first, let pid = pid(app) else { return .noWindow }
        let candidates = windows.filter { $0.pid == pid && $0.layer == 0 && $0.onScreen && $0.bounds.width >= 2 && $0.bounds.height >= 2 }
        if let last = lastWindow(pid), let window = candidates.first(where: { $0.id == last }) { return .window(window) }
        return candidates.first.map(Result.window) ?? .noWindow
    }

    /// This Mac's normal windows on screen, front to back.
    static func onScreenWindows() -> [Window] {
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        return list.compactMap { info in
            guard let id = (info[kCGWindowNumber as String] as? NSNumber)?.intValue,
                  let pid = (info[kCGWindowOwnerPID as String] as? NSNumber)?.intValue,
                  let bounds = (info[kCGWindowBounds as String] as? NSDictionary).flatMap({ CGRect(dictionaryRepresentation: $0 as CFDictionary) })
            else { return nil }
            return Window(id: id, pid: pid, layer: (info[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0,
                          onScreen: (info[kCGWindowIsOnscreen as String] as? Bool) ?? true, bounds: bounds)
        }
    }
}

/// Whether pictures of every computer are paused because Nollie is typing a saved sign-in, by the
/// computer add-on's own rule (the one its preview pauses by).
enum LiveSignInPause: Equatable, Sendable {
    case paused
    case clear
    /// The add-on can't say: none on this gateway, or one older than 0.5.
    case unknown
    /// No clear answer came in time (Hermes busy, restarting or signed out): held as if paused,
    /// and after `giveUpAfter` of only these, no stream at all.
    case failed
}

/// One window of this Mac through ScreenCaptureKit: the one Nollie Computer's running task for
/// the same chat works in. It follows the task once a second (another app, another window, a new
/// size) and ends "stopped" when the task does, "refused" when its bot turns private. Pictures
/// come at the level's size, at most its frame rate, without the cursor: the helper's pointer is
/// drawn on the viewer's side. Nothing is captured until the add-on says no saved sign-in is
/// being typed, and capture stops whenever one is, asked twice a second. An answer slow to come
/// counts as paused, and a fill starting on this Mac holds every window stream at once.
final class LiveWindowSource: LiveSource {
    typealias Look = @MainActor @Sendable (_ profile: String, _ sessionID: String) async -> LiveWindowChoice.Result
    typealias Pause = @MainActor @Sendable () async -> LiveSignInPause

    let kind = LiveWire.ComputerKind.mac
    static let computerName = "This Mac"
    static let firstPictureWithin = Duration.seconds(10)
    /// Saved sign-ins wait 1.5 seconds after they start before typing: well inside that.
    static let pauseEvery = Duration.milliseconds(500)
    /// An ask unanswered this long holds pictures back until it is.
    static let answerWithin = Duration.milliseconds(750)

    /// Every window stream running now, so a fill can hold them all before it types.
    private static let running = Mutex<[ObjectIdentifier: LiveWindowOutput]>([:])

    private let profile: String
    private let sessionID: String
    private let allowed: @Sendable () -> Bool
    private let pause: Pause
    private let lookUp: Look
    private let output = LiveWindowOutput()
    private let follow = Mutex<Task<Void, Never>?>(nil)
    private let wantedLevel = Mutex(LiveQuality.best)
    private let answerWithin: Duration
    private let giveUpAfter: Duration

    /// `allowed`, `look` and `pause` stand in for Screen Recording, Nollie Computer and the add-on in tests.
    init(profile: String, sessionID: String, allowed: @escaping @Sendable () -> Bool = { CGPreflightScreenCaptureAccess() },
         look: @escaping Look = { await LiveWindowSource.look(profile: $0, sessionID: $1) },
         pause: @escaping Pause = { await LiveWindowSource.signInPause() },
         answerWithin: Duration = LiveWindowSource.answerWithin, giveUpAfter: Duration = LiveWindowSource.firstPictureWithin) {
        self.profile = profile
        self.sessionID = sessionID
        self.allowed = allowed
        self.pause = pause
        self.lookUp = look
        self.answerWithin = answerWithin
        self.giveUpAfter = giveUpAfter
    }

    /// Pictures are held back now (tests).
    var isHeld: Bool { output.isHeld }

    /// A saved sign-in is about to be typed on this Mac: every window stream holds its pictures
    /// back at once, before any answer from the add-on. The next look stops the capture.
    static func holdForSignIn() {
        for output in running.withLock({ Array($0.values) }) { output.hold(true) }
    }

    func start(level: Int, events: @escaping @Sendable (LiveSourceEvent) -> Void) {
        wantedLevel.withLock { $0 = level }
        output.events = events
        guard allowed() else {
            events(.ended(.unavailable))
            return
        }
        events(.computer(Self.computerName))
        // No holder: Take over pauses a helper's own computers, never Nollie Computer, which the
        // person stops with its own Stop.
        events(.control(nil))
        events(.pointer(nil))
        // Held until the add-on has said no sign-in is being typed.
        output.waitForPauseAnswer()
        Self.running.withLock { $0[ObjectIdentifier(self)] = output }
        let profile = profile, sessionID = sessionID, output = output, lookUp = lookUp, pause = pause
        let answerWithin = answerWithin, giveUpAfter = giveUpAfter
        let task = Task { @MainActor in
            let capture = LiveWindowCapture(output: output)
            @MainActor func giveUp() async {
                await capture.stop()
                output.send(.ended(.unavailable))
            }
            let watcher = Task { @MainActor in
                // Since when every ask has failed or gone unanswered.
                var failingSince: ContinuousClock.Instant?
                while !Task.isCancelled, !output.isClosed {
                    let asked = ContinuousClock.now
                    let deadline = (failingSince ?? asked) + giveUpAfter
                    // Silence counts as paused: an answer slow to come holds pictures back until it
                    // does, and one that never comes ends the stream.
                    let slow = Task { @MainActor in
                        try? await Task.sleep(for: answerWithin)
                        guard !Task.isCancelled else { return }
                        if output.hold(true) { await capture.stop() }
                        try? await Task.sleep(until: deadline)
                        guard !Task.isCancelled else { return }
                        await giveUp()
                    }
                    let answer = await withTaskCancellationHandler { await pause() } onCancel: { slow.cancel() }
                    slow.cancel()
                    guard !Task.isCancelled, !output.isClosed else { return }
                    switch answer {
                    case .unknown:
                        // No rule to follow, so no picture of this Mac: Watch keeps what it had.
                        return await giveUp()
                    case .failed:
                        if output.hold(true) { await capture.stop() }
                        let since = failingSince ?? asked
                        failingSince = since
                        if ContinuousClock.now - since >= giveUpAfter { return await giveUp() }
                    case .paused, .clear:
                        failingSince = nil
                        if output.hold(answer == .paused) { await capture.stop() }
                    }
                    try? await Task.sleep(for: Self.pauseEvery)
                }
            }
            defer { watcher.cancel() }
            var started = ContinuousClock.now
            while !Task.isCancelled {
                let choice = await lookUp(profile, sessionID)
                // Ended meanwhile: the person stopped the capture from the menu bar.
                if output.isClosed { break }
                if choice == .stopped || choice == .refused {
                    await capture.stop()
                    output.send(.ended(choice == .refused ? .refused : .stopped))
                    return
                }
                if output.isHeld {
                    // Nothing is captured while a saved sign-in is typed; the first picture is
                    // waited for again once it is over.
                    await capture.stop()
                    started = ContinuousClock.now
                    try? await Task.sleep(for: .milliseconds(250))
                    continue
                }
                await capture.show(choice, level: self.wantedLevel.withLock { $0 })
                // A window that never gives a picture is no live picture at all.
                if !output.hasPictured, ContinuousClock.now - started >= Self.firstPictureWithin {
                    await capture.stop()
                    output.send(.ended(.unavailable))
                    return
                }
                try? await Task.sleep(for: .seconds(1))
            }
            await capture.stop()
        }
        follow.withLock { $0 = task }
    }

    func setLevel(_ level: Int) {
        wantedLevel.withLock { $0 = level }
    }

    /// The task from Nollie Computer, the app's pid and the window list off the main thread
    /// (asking other apps can wait on them), then the choice.
    @MainActor static func look(profile: String, sessionID: String) async -> LiveWindowChoice.Result {
        if ComputerOtherControl.isPrivate(profile) { return .refused }
        let center = ComputerCenter.shared
        guard let task = center.task, task.isChat(profile: profile, sessionID: sessionID) else { return .stopped }
        let find = center.runningPID
        let app = task.currentApp.flatMap(task.app(named:)) ?? task.apps.first
        let (pid, windows) = await Task.detached { (app.flatMap(find), LiveWindowChoice.onScreenWindows()) }.value
        // The task may have ended or moved on meanwhile.
        guard let now = center.task, now.id == task.id else { return .stopped }
        let last = pid.flatMap(center.lastActedWindow(pid:))
        return LiveWindowChoice.choose(task: now, profile: profile, sessionID: sessionID, pid: { $0 == app ? pid : nil },
                                       lastWindow: { $0 == pid ? last : nil }, windows: windows)
    }

    /// Asks the add-on on the gateway this Mac types saved sign-ins for (SignInCenter's: a gateway
    /// on this Mac). A sign-in this Mac is approving or typing is paused whatever the add-on says,
    /// checked again once it answers, so an answer from before the fill never lifts the hold.
    /// With no gateway on this Mac and nothing being typed, no sign-in can be typed here.
    @MainActor static func signInPause() async -> LiveSignInPause {
        if !SignInCenter.shared.handling.isEmpty { return .paused }
        guard let runtime = AppModel.shared.runtime, runtime.gatewayIsOnThisMac else { return .clear }
        let answer: LiveSignInPause
        do {
            let (data, _) = try await runtime.api.raw("GET", Self.pausePath, body: nil, authenticated: true,
                                                      timeout: Self.answerWithin / .seconds(1))
            answer = try JSONCoding.decoder.decode(PauseAnswer.self, from: data).paused ? .paused : .clear
        } catch HermesAPIError.http(status: 404, detail: _) {
            answer = .unknown
        } catch {
            answer = .failed
        }
        return SignInCenter.shared.handling.isEmpty ? answer : .paused
    }

    static let pausePath = "/api/plugins/nollie-computer/paused"

    private struct PauseAnswer: Decodable { var paused: Bool }

    func stop() {
        output.close()
        _ = Self.running.withLock { $0.removeValue(forKey: ObjectIdentifier(self)) }
        follow.withLock { task in
            task?.cancel()
            task = nil
        }
    }
}

/// The stream itself, changed only from the main actor, one change at a time.
@MainActor
final class LiveWindowCapture {
    private let output: LiveWindowOutput
    private var stream: SCStream?
    private var window: LiveWindowChoice.Window?
    private var level = -1
    private var scale: CGFloat = 2

    init(output: LiveWindowOutput) { self.output = output }

    func show(_ choice: LiveWindowChoice.Result, level: Int) async {
        // A stream that stopped on its own is rebuilt from scratch.
        if output.takeStopped() { await stop() }
        guard case .window(let next) = choice else {
            // Nothing to show: keep the last picture, say it isn't current, and stop capturing.
            output.send(.fresh(false))
            await stop()
            return
        }
        if stream != nil, next.id == window?.id, next.bounds.size == window?.bounds.size, level == self.level { return }
        do {
            if next.id != window?.id || stream == nil {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                guard let found = content.windows.first(where: { Int($0.windowID) == next.id }) else {
                    output.send(.fresh(false))
                    return
                }
                let filter = SCContentFilter(desktopIndependentWindow: found)
                scale = CGFloat(max(filter.pointPixelScale, 1))
                let configuration = configure(next, level: level)
                // The size goes first, so the very first picture already has a hello to follow.
                output.send(.size(pixels(next)))
                if let stream {
                    try await stream.updateContentFilter(filter)
                    try await stream.updateConfiguration(configuration)
                } else {
                    let made = SCStream(filter: filter, configuration: configuration, delegate: output)
                    try made.addStreamOutput(output, type: .screen, sampleHandlerQueue: output.queue)
                    try await made.startCapture()
                    stream = made
                }
            } else if let stream {
                output.send(.size(pixels(next)))
                try await stream.updateConfiguration(configure(next, level: level))
            }
            window = next
            self.level = level
        } catch {
            output.send(.fresh(false))
            await stop()
        }
    }

    func stop() async {
        let stopping = stream
        stream = nil
        window = nil
        level = -1
        try? await stopping?.stopCapture()
    }

    private func pixels(_ window: LiveWindowChoice.Window) -> LiveWire.PixelSize {
        LiveWire.PixelSize(width: max(1, min(LiveWire.maximumSide, Int((window.bounds.width * scale).rounded()))),
                           height: max(1, min(LiveWire.maximumSide, Int((window.bounds.height * scale).rounded()))))
    }

    private func configure(_ window: LiveWindowChoice.Window, level: Int) -> SCStreamConfiguration {
        let quality = LiveQuality.level(level)
        let size = quality.size(for: pixels(window))
        let configuration = SCStreamConfiguration()
        configuration.width = size.width
        configuration.height = size.height
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(quality.fps))
        // Room for the frame being encoded, one waiting, the newest kept for a still screen and
        // one on its way, with one to spare: holding every surface stalls the capture.
        configuration.queueDepth = 6
        configuration.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        configuration.showsCursor = false
        configuration.scalesToFit = true
        configuration.ignoreShadowsSingleWindow = true
        return configuration
    }
}

/// Where ScreenCaptureKit's frames arrive. Only complete frames are pictures; an idle one means
/// the window hasn't changed, so the picture stays current.
final class LiveWindowOutput: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    let queue = DispatchQueue(label: "com.coreykozarski.nollie.live-window", qos: .userInteractive)
    private let state = Mutex<State>(State())

    private struct State {
        var events: (@Sendable (LiveSourceEvent) -> Void)?
        var closed = false
        var fresh: Bool?
        var pictured = false
        /// The stream stopped by itself and has to be made again.
        var stopped = false
        /// No picture goes out: a saved sign-in is being typed, or the add-on hasn't said yet.
        var held = false
        /// The host was told pictures are held back.
        var told = false
    }

    var hasPictured: Bool { state.withLock { $0.pictured } }
    var isHeld: Bool { state.withLock { $0.held } }

    /// Holds pictures back until the first answer, without telling anyone: nothing is known yet.
    func waitForPauseAnswer() { state.withLock { $0.held = true } }

    /// Holds pictures back while paused, telling the host when that changes. True when pictures
    /// were going out until now, so the capture has to stop.
    @discardableResult
    func hold(_ paused: Bool) -> Bool {
        let (began, events) = state.withLock { state -> (Bool, [LiveSourceEvent]) in
            let began = paused && !state.held
            state.held = paused
            guard !state.closed, paused != state.told else { return (began, []) }
            state.told = paused
            guard paused else { return (began, [.hold(nil)]) }
            state.fresh = false
            return (began, [.fresh(false), .hold(.signIn)])
        }
        let target = self.events
        for event in events { target?(event) }
        return began
    }

    var isClosed: Bool { state.withLock { $0.closed } }

    /// Whether the stream stopped since last asked.
    func takeStopped() -> Bool {
        state.withLock { state in
            defer { state.stopped = false }
            return state.stopped
        }
    }

    var events: (@Sendable (LiveSourceEvent) -> Void)? {
        get { state.withLock { $0.events } }
        set { state.withLock { $0.events = newValue } }
    }

    func send(_ event: LiveSourceEvent) {
        let target = state.withLock { state -> (@Sendable (LiveSourceEvent) -> Void)? in
            guard !state.closed else { return nil }
            // Held: no picture, and nothing says the last one is current.
            if state.held {
                if case .picture = event { return nil }
                if case .fresh(true) = event { return nil }
            }
            if case .fresh(let fresh) = event {
                guard state.fresh != fresh else { return nil }
                state.fresh = fresh
            }
            if case .ended = event { state.closed = true }
            if case .picture = event { state.pictured = true }
            return state.events
        }
        target?(event)
    }

    func close() { state.withLock { $0.closed = true } }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let raw = attachments.first?[.status] as? Int, let status = SCFrameStatus(rawValue: raw) else { return }
        switch status {
        case .complete:
            guard let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
            send(.fresh(true))
            send(.picture(LivePicture(buffer: buffer, captureMicros: Self.captureMicros(sampleBuffer))))
        case .idle:
            send(.fresh(true))
        case .suspended:
            send(.fresh(false))
        case .stopped:
            stopped(by: nil)
        default:
            break
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: any Error) {
        stopped(by: error)
    }

    /// The person stopping the capture (from the menu bar) ends the stream; any other stop keeps
    /// the last picture, not current, until the next look makes a new stream.
    func stopped(by error: (any Error)?) {
        let error = error.map { $0 as NSError }
        if error?.domain == SCStreamErrorDomain, error?.code == SCStreamError.Code.userStopped.rawValue {
            return send(.ended(.unavailable))
        }
        state.withLock { $0.stopped = true }
        send(.fresh(false))
    }

    /// The frame's time on the host clock, as Unix microseconds.
    private static func captureMicros(_ sample: CMSampleBuffer) -> UInt64 {
        let now = LiveWire.micros()
        let shown = CMSampleBufferGetPresentationTimeStamp(sample)
        guard shown.isValid else { return now }
        let age = CMTimeGetSeconds(CMTimeSubtract(CMClockGetTime(CMClockGetHostTimeClock()), shown))
        guard age.isFinite, age >= 0, age < 5 else { return now }
        return now - UInt64(age * 1_000_000)
    }
}
