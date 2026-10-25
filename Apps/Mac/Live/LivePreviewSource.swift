import CoreGraphics
import CoreVideo
import Foundation
import ImageIO
import NollieCore
import Synchronization

/// A helper's own computer, through the nollie-computer add-on's preview on this Mac's own
/// gateway. It asks again the moment an answer comes (`fresh=1` skips the add-on's cache), and
/// decodes on the side: while one picture decodes, a newer answer replaces any waiting one. The
/// add-on checks private bots and the exact chat on every call, and answers paused, with no
/// picture, while Nollie types a saved sign-in: the stream then holds pictures back until a
/// later answer isn't paused.
final class LivePreviewSource: LiveSource {
    let kind = LiveWire.ComputerKind.space
    static let path = "/api/plugins/nollie-computer/preview"
    static let timeout: TimeInterval = 8

    private let api: HermesAPI
    private let profile: String
    private let sessionID: String
    /// No live picture for this long ends the stream.
    private let unavailableAfter: Duration
    /// Between asks while the computer isn't live, or after a failed ask.
    private let rest: Duration
    /// An ask still waiting this long (or two frames at the level's rate) means the shown picture
    /// isn't current any more, though the computer may still be live.
    private let staleAfter: Duration
    private let state = Mutex(State())
    private let pictures = LockedLiveMailbox<Answer>()
    private let decoder = Decoder()

    private struct State {
        var level = LiveQuality.best
        var events: (@Sendable (LiveSourceEvent) -> Void)?
        var task: Task<Void, Never>?
        var stopped = false
        var size: LiveWire.PixelSize?
    }

    /// One live answer, waiting to be decoded.
    struct Answer: Sendable {
        var image: Data
        var captureMicros: UInt64
    }

    init(api: HermesAPI, profile: String, sessionID: String, unavailableAfter: Duration = .seconds(10), rest: Duration = .milliseconds(500),
         staleAfter: Duration = .seconds(2)) {
        self.api = api
        self.profile = profile
        self.sessionID = sessionID
        self.unavailableAfter = unavailableAfter
        self.rest = rest
        self.staleAfter = staleAfter
    }

    func start(level: Int, events: @escaping @Sendable (LiveSourceEvent) -> Void) {
        state.withLock { state in
            state.level = level
            state.events = events
        }
        let task = Task.detached(priority: .userInitiated) { [self] in await run() }
        state.withLock { state in
            if state.stopped { task.cancel() } else { state.task = task }
        }
    }

    func setLevel(_ level: Int) { state.withLock { $0.level = level } }

    func stop() {
        pictures.close()
        state.withLock { state in
            state.stopped = true
            state.task?.cancel()
            state.task = nil
        }
    }

    private func send(_ event: LiveSourceEvent) {
        let target = state.withLock { state -> (@Sendable (LiveSourceEvent) -> Void)? in
            guard !state.stopped else { return nil }
            if case .ended = event { state.stopped = true }
            return state.events
        }
        target?(event)
    }

    // MARK: Asking

    private enum Outcome {
        case live(ComputerPreviewFrame, Data)
        case notLive(ComputerPreviewFrame?)
        /// Paused for a saved sign-in: the computer is still in use, but nothing may be shown.
        case paused(ComputerPreviewFrame)
        case ended(LiveWire.EndReason)
    }

    private func run() async {
        let clock = ContinuousClock()
        var lastLive = clock.now
        var computer: String?
        var held = false
        func hold(_ next: Bool) {
            guard next != held else { return }
            held = next
            send(.hold(next ? .signIn : nil))
        }
        while !Task.isCancelled {
            let outcome = await askWatched()
            guard !Task.isCancelled else { return }
            switch outcome {
            case .ended(let reason):
                return send(.ended(reason))
            case .paused(let frame):
                // Not "unavailable": the pause ends on its own, and the stream waits for it.
                lastLive = clock.now
                send(.control(frame.control.flatMap(LiveWire.Control.init)))
                send(.fresh(false))
                hold(true)
                try? await Task.sleep(for: rest)
            case .live(let frame, let image):
                lastLive = clock.now
                hold(false)
                if let name = frame.computerName, name != computer {
                    computer = name
                    send(.computer(name))
                }
                send(.control(frame.control.flatMap(LiveWire.Control.init)))
                send(.pointer(frame.pointer.map { LiveWire.Pointer(x: $0.x, y: $0.y, at: $0.at) }))
                send(.fresh(true))
                offer(Answer(image: image, captureMicros: Self.captureMicros(frame.capturedAt)))
            case .notLive(let frame):
                // Only an answer that isn't paused ends a pause; a failed ask says nothing new.
                if let frame {
                    hold(false)
                    send(.control(frame.control.flatMap(LiveWire.Control.init)))
                }
                send(.fresh(false))
                if clock.now - lastLive >= unavailableAfter { return send(.ended(.unavailable)) }
                try? await Task.sleep(for: rest)
            }
        }
    }

    /// Asks, and says the picture isn't current while the answer is slow to come (the add-on
    /// can wait seconds on a stuck capture). Sent from the asking task, so it never lands after
    /// the next live answer's `.fresh(true)`.
    private func askWatched() async -> Outcome {
        let fps = LiveQuality.level(state.withLock { $0.level }).fps
        let stale = max(staleAfter, .seconds(2.0 / Double(max(fps, 1))))
        return await withTaskGroup(of: Outcome?.self) { group in
            group.addTask { [self] in await ask() }
            group.addTask {
                try? await Task.sleep(for: stale)
                return nil
            }
            var outcome = Outcome.notLive(nil)
            for await answer in group {
                guard let answer else {
                    if !Task.isCancelled { send(.fresh(false)) }
                    continue
                }
                outcome = answer
                group.cancelAll()
                break
            }
            return outcome
        }
    }

    private func ask() async -> Outcome {
        let query = [URLQueryItem(name: "session_id", value: sessionID), URLQueryItem(name: "fresh", value: "1")]
        do {
            let (data, _) = try await api.raw("GET", Self.path, query: query, profile: profile, body: nil, authenticated: true,
                                              timeout: Self.timeout)
            let frame = try JSONCoding.decoder.decode(ComputerPreviewFrame.self, from: data)
            switch frame.state {
            // Nothing to watch in this chat any more.
            case "idle": return .ended(.stopped)
            case "live":
                // A computer the add-on can't picture (this Mac, through Hermes) never streams here.
                if frame.kind == "mac" { return .ended(.unavailable) }
                guard let image = frame.imageData else { return .notLive(frame) }
                return .live(frame, image)
            case "paused":
                if frame.kind == "mac" { return .ended(.unavailable) }
                return .paused(frame)
            default:
                if frame.kind == "mac" { return .ended(.unavailable) }
                return .notLive(frame)
            }
        } catch HermesAPIError.http(status: 404, detail: _) {
            // No add-on on this gateway.
            return .ended(.unavailable)
        } catch {
            return .notLive(nil)
        }
    }

    /// The add-on's capture time, when it is a believable one; else now.
    static func captureMicros(_ capturedAt: Double?, now: Date = Date()) -> UInt64 {
        guard let capturedAt, capturedAt.isFinite, abs(now.timeIntervalSince1970 - capturedAt) < 10 else { return LiveWire.micros(now) }
        return LiveWire.micros(Date(timeIntervalSince1970: capturedAt))
    }

    // MARK: Decoding

    private func offer(_ answer: Answer) {
        guard case .encodeNow(let first) = pictures.admit(answer) else { return }
        Task.detached(priority: .userInitiated) { [self] in
            var next: LiveMailbox<Answer>.Handoff? = first
            while let handoff = next {
                decode(handoff.frame)
                next = pictures.encoderReturned()
            }
        }
    }

    private func decode(_ answer: Answer) {
        let longEdge = LiveQuality.level(state.withLock { $0.level }).longEdge
        guard let (size, buffer) = decoder.picture(answer.image, longEdge: longEdge) else { return }
        let changed = state.withLock { state -> Bool in
            defer { state.size = size }
            return state.size != size
        }
        if changed { send(.size(size)) }
        send(.picture(LivePicture(buffer: buffer, captureMicros: answer.captureMicros)))
    }

    /// PNG or JPEG into a pixel buffer no bigger than the level needs. Used one picture at a time.
    final class Decoder: @unchecked Sendable {
        private var pool: CVPixelBufferPool?
        private var poolSize = LiveWire.PixelSize(width: 0, height: 0)

        /// The picture's own size (where pointer spots are) and the scaled picture.
        func picture(_ data: Data, longEdge: Int) -> (LiveWire.PixelSize, CVPixelBuffer)? {
            guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
                  let type = CGImageSourceGetType(source) as String?, type == "public.png" || type == "public.jpeg",
                  let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
                  let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
                  (1...LiveWire.maximumSide).contains(width), (1...LiveWire.maximumSide).contains(height) else { return nil }
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: min(max(width, height), longEdge),
                kCGImageSourceCreateThumbnailWithTransform: false,
                kCGImageSourceShouldCacheImmediately: true,
            ]
            guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),
                  let buffer = draw(image) else { return nil }
            return (LiveWire.PixelSize(width: width, height: height), buffer)
        }

        private func draw(_ image: CGImage) -> CVPixelBuffer? {
            let size = LiveWire.PixelSize(width: image.width, height: image.height)
            if pool == nil || poolSize != size {
                let attributes: [CFString: Any] = [
                    kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
                    kCVPixelBufferWidthKey: size.width,
                    kCVPixelBufferHeightKey: size.height,
                    kCVPixelBufferIOSurfacePropertiesKey: [CFString: Any]() as CFDictionary,
                ]
                var made: CVPixelBufferPool?
                guard CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attributes as CFDictionary, &made) == kCVReturnSuccess else { return nil }
                pool = made
                poolSize = size
            }
            var out: CVPixelBuffer?
            guard let pool, CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &out) == kCVReturnSuccess, let out else { return nil }
            CVPixelBufferLockBaseAddress(out, [])
            defer { CVPixelBufferUnlockBaseAddress(out, []) }
            guard let context = CGContext(data: CVPixelBufferGetBaseAddress(out), width: size.width, height: size.height, bitsPerComponent: 8,
                                          bytesPerRow: CVPixelBufferGetBytesPerRow(out), space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else { return nil }
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: size.width, height: size.height))
            return out
        }
    }
}
