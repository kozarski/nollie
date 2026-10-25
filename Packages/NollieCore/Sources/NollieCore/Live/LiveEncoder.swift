import CoreMedia
import CoreVideo
import Dispatch
import Foundation
import Synchronization
import VideoToolbox

/// Real-time HEVC for a live picture. Pictures of any size come in from capture; each is scaled to
/// the current quality level and encoded one at a time, newest first, with no frame reordering.
/// Keyframes come on demand, and a still screen is encoded again so a keyframe never waits for the
/// next repaint. The hardware encoder goes first; if it can't make a session or keeps failing, the
/// stream moves to the software encoder for good. A software session that keeps failing is made again.
///
/// Thread-safe. Outputs arrive one at a time on the encoder's own queue.
public final class LiveEncoder: @unchecked Sendable {
    public enum Engine: String, Sendable { case hardware, software }

    public struct Output: Sendable {
        public var video: LiveWire.Video
        public var engine: Engine
        /// From handing the picture over (scaling included) to the encoded frame.
        public var encodeMicros: Int
    }

    /// A captured picture. Capture hands these over and never draws into them again.
    struct Picture: @unchecked Sendable {
        var buffer: CVPixelBuffer
        var captureMicros: UInt64
    }

    /// Without a new picture for this long, a wanted keyframe is made from the last one.
    static let stillAfter = Duration.milliseconds(50)
    /// Two frames in a row that VideoToolbox fails end the session: a hardware one gives way to
    /// software for good, a software one is made again.
    static let failuresToRebuild = 2
    /// A keyframe that keeps failing on a still screen is tried again at most this often in a row,
    /// waiting a little longer each time. Then it waits for a new picture or a new request.
    static let stillRetries = 4

    private let queue = DispatchQueue(label: "com.coreykozarski.nollie.live-encoder", qos: .userInteractive)
    private let onQueue = DispatchSpecificKey<Void>()
    private let mailbox = LockedLiveMailbox<Picture>()
    private let lastPictureAt = Mutex<ContinuousClock.Instant?>(nil)
    private let shared: Mutex<Shared>
    /// False once `stop()` has begun. Held while an output is delivered, so `stop()` waits it out.
    private let outputOpen = Mutex(true)
    private let submitted = Mutex(0)
    private let output: @Sendable (Output) -> Void

    private struct Shared {
        var level: Int
        var engine: Engine?
    }

    // Everything below belongs to `queue`.
    private var level: Int
    private var hardwareAllowed: Bool
    private var session: VTCompressionSession?
    private var sessionEngine: Engine = .software
    private var sessionLevel = -1
    private var sessionSize = LiveWire.PixelSize(width: 0, height: 0)
    private var transfer: VTPixelTransferSession?
    private var pool: CVPixelBufferPool?
    private var poolSize = LiveWire.PixelSize(width: 0, height: 0)
    private var forceKeyframe = false
    /// Failed frames of any kind, for the still-screen retries.
    private var failuresInARow = 0
    /// Frames VideoToolbox itself failed on the current session.
    private var encoderFailuresInARow = 0
    private var stillGaveUp = false
    private var sequence: UInt32 = 0
    private var lastTimestamp = CMTime.invalid
    private var stillCheckScheduled = false
    private var stopped = false

    public init(level: Int = LiveQuality.best, preferHardware: Bool = true, output: @escaping @Sendable (Output) -> Void) {
        let level = LiveQuality.level(level).level
        self.level = level
        self.hardwareAllowed = preferHardware
        self.output = output
        shared = Mutex(Shared(level: level, engine: nil))
        queue.setSpecific(key: onQueue, value: ())
    }

    /// The encoder the current session runs on, once there is one.
    public var engine: Engine? { shared.withLock { $0.engine } }
    public var currentLevel: Int { shared.withLock { $0.level } }
    /// Pictures replaced by newer ones before the encoder got to them.
    public var dropped: Int { mailbox.dropped }
    /// Pictures handed to a session so far, repeats included.
    var attempts: Int { submitted.withLock { $0 } }

    /// Encodes a picture now, or soon if the encoder is busy; a newer picture replaces it if it
    /// is still waiting by then.
    public func encode(_ pixelBuffer: CVPixelBuffer, captureMicros: UInt64) {
        lastPictureAt.withLock { $0 = .now }
        if case .encodeNow(let handoff) = mailbox.admit(Picture(buffer: pixelBuffer, captureMicros: captureMicros)) {
            queue.async { self.submit(handoff) }
        }
    }

    public func requestKeyframe() {
        mailbox.requestKeyframe()
        queue.async {
            self.stillGaveUp = false
            self.repeatForKeyframe(immediately: false)
        }
    }

    /// Moves to another quality level: a new session at the new size and rate, starting with a
    /// keyframe made from the latest picture right away.
    public func setLevel(_ level: Int) {
        let level = LiveQuality.level(level).level
        shared.withLock { $0.level = level }
        queue.async {
            guard level != self.level, !self.stopped else { return }
            self.level = level
            self.stillGaveUp = false
            self.mailbox.requestKeyframe()
            self.repeatForKeyframe(immediately: true)
        }
    }

    /// Finishes the frame in the encoder, if any, and lets the session go. Nothing comes out once
    /// this returns: called while an output is being delivered, it waits for that one to return.
    public func stop() {
        mailbox.close()
        if DispatchQueue.getSpecific(key: onQueue) != nil {
            // From inside an output, which holds `outputOpen`.
            stopped = true
        } else {
            outputOpen.withLock { $0 = false }
        }
        queue.async {
            self.stopped = true
            self.endSession()
            self.transfer.map(VTPixelTransferSessionInvalidate)
            self.transfer = nil
            self.pool = nil
        }
    }

    // MARK: On the queue

    /// Hands a picture to the session. `repeated` marks the last picture sent again for a keyframe.
    private func submit(_ handoff: LiveMailbox<Picture>.Handoff, repeated: Bool = false) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard !stopped else { return finished(.notSent, keyframe: false) }
        if !repeated { stillGaveUp = false }
        submitted.withLock { $0 += 1 }
        let picture = handoff.frame
        let source = LiveWire.PixelSize(width: CVPixelBufferGetWidth(picture.buffer), height: CVPixelBufferGetHeight(picture.buffer))
        let quality = LiveQuality.level(level)
        let size = quality.size(for: source)
        if session == nil || sessionLevel != level || sessionSize != size || (sessionEngine == .hardware && !hardwareAllowed) {
            startSession(size: size, quality: quality)
        }
        // A new session's first frame is a keyframe too, and is asked for again if it fails.
        let keyframe = handoff.keyframe || forceKeyframe
        guard let session, let input = scaled(picture.buffer, to: size) else { return finished(.notSent, keyframe: keyframe) }
        forceKeyframe = false
        let started = ContinuousClock.now
        let engine = sessionEngine
        let captureMicros = picture.captureMicros
        let once = Once()
        let handler: VTCompressionOutputHandler = { [self] status, flags, sample in
            guard once.claim() else { return }
            let encoded = status == noErr && !flags.contains(.frameDropped) ? sample.flatMap(Self.encoded) : nil
            let micros = Self.micros(ContinuousClock.now - started)
            queue.async {
                self.finished(encoded.map { .encoded(Finished(frame: $0, captureMicros: captureMicros, engine: engine, micros: micros)) }
                              ?? .encoderFailed, keyframe: keyframe)
            }
        }
        let properties = keyframe ? [kVTEncodeFrameOptionKey_ForceKeyFrame: kCFBooleanTrue] as CFDictionary : nil
        let status = VTCompressionSessionEncodeFrame(session, imageBuffer: input, presentationTimeStamp: nextTimestamp(),
                                                     duration: .invalid, frameProperties: properties, infoFlagsOut: nil,
                                                     outputHandler: handler)
        if status != noErr, once.claim() { finished(.encoderFailed, keyframe: keyframe) }
    }

    private enum Outcome {
        case encoded(Finished)
        /// VideoToolbox refused the frame, failed it, dropped it or gave back nothing usable.
        case encoderFailed
        /// The frame never reached an encoder: no session could be made or the picture couldn't be scaled.
        case notSent
    }

    private struct Finished {
        var frame: Encoded
        var captureMicros: UInt64
        var engine: Engine
        var micros: Int
    }

    private func finished(_ outcome: Outcome, keyframe: Bool) {
        dispatchPrecondition(condition: .onQueue(queue))
        var sent = false
        if case .encoded(let result) = outcome, !stopped {
            let video = LiveWire.Video(keyframe: result.frame.keyframe, sequence: sequence, captureMicros: result.captureMicros,
                                       width: result.frame.width, height: result.frame.height,
                                       parameterSets: result.frame.parameterSets, sample: result.frame.sample)
            if (try? video.validate()) != nil {
                sent = true
                failuresInARow = 0
                encoderFailuresInARow = 0
                sequence &+= 1
                outputOpen.withLock { open in
                    if open && !stopped { output(Output(video: video, engine: result.engine, encodeMicros: result.micros)) }
                }
            }
        }
        if !sent && !stopped {
            failuresInARow += 1
            // A lost keyframe is asked for again, or a viewer waiting on a still screen waits forever.
            if keyframe { mailbox.requestKeyframe() }
            if case .notSent = outcome {} else { encoderFailed() }
            if failuresInARow > Self.stillRetries { stillGaveUp = true }
        }
        if let next = mailbox.encoderReturned() {
            // After a failure the next picture goes in later, so failures that come back at once
            // never pile up on the stack.
            if sent { submit(next) } else { queue.async { self.submit(next) } }
        } else if sent {
            repeatForKeyframe(immediately: false)
        } else if !stopped && !stillGaveUp {
            queue.asyncAfter(deadline: .now() + .milliseconds(10 << min(failuresInARow - 1, 4))) {
                self.repeatForKeyframe(immediately: true)
            }
        }
    }

    /// Ends a session VideoToolbox keeps failing, so the next picture gets a fresh one: on
    /// software, or on hardware for the last time.
    private func encoderFailed() {
        encoderFailuresInARow += 1
        guard encoderFailuresInARow >= Self.failuresToRebuild, session != nil else { return }
        if sessionEngine == .hardware { hardwareAllowed = false }
        endSession()
        mailbox.requestKeyframe()
    }

    /// When a keyframe is wanted and nothing new is coming, encodes the last picture again. A
    /// picture that arrived in the last 50 ms gets the chance to carry the keyframe instead.
    private func repeatForKeyframe(immediately: Bool) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard !stopped, !stillGaveUp, mailbox.keyframeRequested, !mailbox.inFlight else { return }
        let since = lastPictureAt.withLock { $0.map { ContinuousClock.now - $0 } }
        if immediately || since.map({ $0 >= Self.stillAfter }) ?? true {
            guard var handoff = mailbox.repeatLatest() else { return }
            handoff.frame.captureMicros = LiveWire.micros()
            submit(handoff, repeated: true)
        } else if !stillCheckScheduled, let since {
            stillCheckScheduled = true
            let wait = Self.micros(Self.stillAfter - since + .milliseconds(10))
            queue.asyncAfter(deadline: .now() + .microseconds(max(wait, 0))) {
                self.stillCheckScheduled = false
                self.repeatForKeyframe(immediately: false)
            }
        }
    }

    static func micros(_ duration: Duration) -> Int {
        Int(duration.components.seconds) * 1_000_000 + Int(duration.components.attoseconds / 1_000_000_000_000)
    }

    private func nextTimestamp() -> CMTime {
        var now = CMClockGetTime(CMClockGetHostTimeClock())
        if lastTimestamp.isValid, CMTimeCompare(now, lastTimestamp) <= 0 {
            now = CMTimeAdd(lastTimestamp, CMTime(value: 1, timescale: 1000))
        }
        lastTimestamp = now
        return now
    }

    // MARK: Sessions

    private func startSession(size: LiveWire.PixelSize, quality: LiveQuality) {
        endSession()
        var choices: [(Engine, [CFString: Any])] = []
        if hardwareAllowed {
            choices.append((.hardware, [kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: true,
                                        kVTVideoEncoderSpecification_EnableLowLatencyRateControl: true]))
            choices.append((.hardware, [kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: true]))
        }
        choices.append((.software, [kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder: false]))
        for (engine, specification) in choices {
            guard let made = Self.makeSession(size: size, quality: quality, specification: specification) else { continue }
            session = made
            sessionEngine = engine
            sessionLevel = quality.level
            sessionSize = size
            forceKeyframe = true
            encoderFailuresInARow = 0
            shared.withLock { $0.engine = engine }
            return
        }
        // No hardware session at all: never ask for one again in this stream.
        hardwareAllowed = false
    }

    private static func makeSession(size: LiveWire.PixelSize, quality: LiveQuality,
                                    specification: [CFString: Any]) -> VTCompressionSession? {
        var made: VTCompressionSession?
        guard VTCompressionSessionCreate(allocator: kCFAllocatorDefault, width: Int32(size.width), height: Int32(size.height),
                                         codecType: kCMVideoCodecType_HEVC, encoderSpecification: specification as CFDictionary,
                                         imageBufferAttributes: nil, compressedDataAllocator: nil, outputCallback: nil,
                                         refcon: nil, compressionSessionOut: &made) == noErr, let session = made else { return nil }
        // Without reordering a frame can be shown the moment it decodes; the rest is best effort,
        // since encoders differ in what they take.
        guard VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse) == noErr else {
            VTCompressionSessionInvalidate(session)
            return nil
        }
        let optional: [(CFString, CFTypeRef)] = [
            (kVTCompressionPropertyKey_RealTime, kCFBooleanTrue),
            (kVTCompressionPropertyKey_ProfileLevel, kVTProfileLevel_HEVC_Main_AutoLevel),
            (kVTCompressionPropertyKey_ExpectedFrameRate, quality.fps as CFNumber),
            (kVTCompressionPropertyKey_AverageBitRate, quality.bitsPerSecond as CFNumber),
            (kVTCompressionPropertyKey_DataRateLimits, [quality.bytesPerSecondLimit as CFNumber, 1 as CFNumber] as CFArray),
            (kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, 10 as CFNumber),
            (kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality, kCFBooleanTrue),
        ]
        for (key, value) in optional { _ = VTSessionSetProperty(session, key: key, value: value) }
        _ = VTCompressionSessionPrepareToEncodeFrames(session)
        return session
    }

    /// Lets the session go, after any frame inside it has come out.
    private func endSession() {
        guard let session else { return }
        VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
        VTCompressionSessionInvalidate(session)
        self.session = nil
        sessionLevel = -1
        shared.withLock { $0.engine = nil }
    }

    // MARK: Scaling

    /// The picture at the coded size in 4:2:0, copied into the encoder's own buffers so capture
    /// gets its buffer back. A picture already that size and format goes straight in.
    private func scaled(_ buffer: CVPixelBuffer, to size: LiveWire.PixelSize) -> CVPixelBuffer? {
        let format = CVPixelBufferGetPixelFormatType(buffer)
        if CVPixelBufferGetWidth(buffer) == size.width, CVPixelBufferGetHeight(buffer) == size.height,
           format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange || format == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange {
            return buffer
        }
        if transfer == nil {
            var made: VTPixelTransferSession?
            guard VTPixelTransferSessionCreate(allocator: kCFAllocatorDefault, pixelTransferSessionOut: &made) == noErr else { return nil }
            transfer = made
        }
        if pool == nil || poolSize != size {
            let attributes: [CFString: Any] = [
                kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
                kCVPixelBufferWidthKey: size.width,
                kCVPixelBufferHeightKey: size.height,
                kCVPixelBufferIOSurfacePropertiesKey: [CFString: Any]() as CFDictionary,
            ]
            var made: CVPixelBufferPool?
            guard CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attributes as CFDictionary, &made) == kCVReturnSuccess else {
                return nil
            }
            pool = made
            poolSize = size
        }
        guard let transfer, let pool else { return nil }
        var out: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &out) == kCVReturnSuccess, let out,
              VTPixelTransferSessionTransferImage(transfer, from: buffer, to: out) == noErr else { return nil }
        return out
    }

    // MARK: Output

    /// Lets exactly one of VideoToolbox's answer and a refused hand-over finish a frame.
    final class Once: Sendable {
        private let claimed = Mutex(false)
        func claim() -> Bool { claimed.withLock { claimed in defer { claimed = true }; return !claimed } }
    }

    /// What a frame from VideoToolbox becomes before it leaves the encoder's thread.
    struct Encoded: Sendable {
        var keyframe: Bool
        var width: Int
        var height: Int
        var parameterSets: [Data]?
        var sample: Data
    }

    static func encoded(_ sample: CMSampleBuffer) -> Encoded? {
        guard let format = CMSampleBufferGetFormatDescription(sample), let block = CMSampleBufferGetDataBuffer(sample) else { return nil }
        let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[CFString: Any]]
        let keyframe = !((attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool) ?? false)
        let length = CMBlockBufferGetDataLength(block)
        guard length > 0 else { return nil }
        var bytes = Data(count: length)
        let copied = bytes.withUnsafeMutableBytes { buffer -> OSStatus in
            guard let base = buffer.baseAddress else { return -1 }
            return CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: base)
        }
        guard copied == noErr else { return nil }
        let dimensions = CMVideoFormatDescriptionGetDimensions(format)
        var parameterSets: [Data]?
        if keyframe {
            guard let sets = Self.parameterSets(format) else { return nil }
            parameterSets = sets
        }
        return Encoded(keyframe: keyframe, width: Int(dimensions.width), height: Int(dimensions.height),
                       parameterSets: parameterSets, sample: bytes)
    }

    /// VPS, SPS and PPS in VideoToolbox's order, provided its NAL lengths are 4 bytes like the wire's.
    static func parameterSets(_ format: CMFormatDescription) -> [Data]? {
        var count = 0
        var headerLength: Int32 = 0
        guard CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(format, parameterSetIndex: 0, parameterSetPointerOut: nil,
                                                                 parameterSetSizeOut: nil, parameterSetCountOut: &count,
                                                                 nalUnitHeaderLengthOut: &headerLength) == noErr,
              headerLength == 4, count > 0 else { return nil }
        var sets: [Data] = []
        for index in 0..<count {
            var pointer: UnsafePointer<UInt8>?
            var size = 0
            guard CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(format, parameterSetIndex: index, parameterSetPointerOut: &pointer,
                                                                     parameterSetSizeOut: &size, parameterSetCountOut: nil,
                                                                     nalUnitHeaderLengthOut: nil) == noErr, let pointer else { return nil }
            sets.append(Data(bytes: pointer, count: size))
        }
        return sets
    }
}
