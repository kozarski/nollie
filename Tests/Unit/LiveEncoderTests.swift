#if os(macOS)
import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import Synchronization
import Testing
import VideoToolbox
@testable import NollieCore

/// The live encoder on this Mac's real VideoToolbox: drawn desktop pictures go in, HEVC frames come
/// out that survive the wire, become sample buffers and decode back to pictures of the right size.
/// Prints the per-frame encode and decode times.
@Suite(.serialized, .timeLimit(.minutes(2)))
struct LiveEncoderTests {
    /// A pretend desktop: a window with lines of text and a progress bar that grows each frame.
    static func picture(_ frame: Int, width: Int = 1440, height: Int = 900) -> CVPixelBuffer {
        var made: CVPixelBuffer?
        let attributes = [kCVPixelBufferIOSurfacePropertiesKey: [CFString: Any]() as CFDictionary] as CFDictionary
        CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, attributes, &made)
        let buffer = made!
        CVPixelBufferLockBaseAddress(buffer, [])
        let context = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: width, height: height, bitsPerComponent: 8,
                                bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
        context.setFillColor(CGColor(red: 0.42, green: 0.62, blue: 0.86, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let window = CGRect(x: width / 8, y: height / 8, width: width * 3 / 4, height: height * 3 / 4)
        context.setFillColor(CGColor(red: 0.98, green: 0.98, blue: 0.97, alpha: 1))
        context.fill(window)
        context.setFillColor(CGColor(red: 0.25, green: 0.25, blue: 0.27, alpha: 1))
        for line in 0..<18 {
            context.fill(CGRect(x: window.minX + 24, y: window.maxY - 40 - CGFloat(line * 22), width: CGFloat(120 + (line * 53 + frame * 7) % 500), height: 8))
        }
        context.setFillColor(CGColor(red: 0.2, green: 0.45, blue: 0.95, alpha: 1))
        context.fill(CGRect(x: window.minX + 24, y: window.minY + 30, width: CGFloat(20 + frame * 23 % Int(window.width - 48)), height: 14))
        CVPixelBufferUnlockBaseAddress(buffer, [])
        return buffer
    }

    final class Outputs: Sendable {
        private let items = Mutex<[LiveEncoder.Output]>([])
        func add(_ output: LiveEncoder.Output) { items.withLock { $0.append(output) } }
        var all: [LiveEncoder.Output] { items.withLock { $0 } }

        func wait(for count: Int, within seconds: Double = 20) async -> [LiveEncoder.Output] {
            let deadline = Date().addingTimeInterval(seconds)
            while all.count < count && Date() < deadline { try? await Task.sleep(for: .milliseconds(2)) }
            return all
        }
    }

    final class Decoded: Sendable {
        let result = Mutex<(status: OSStatus, width: Int, height: Int)?>(nil)
    }

    private static func median(_ values: [Int]) -> Int { values.isEmpty ? 0 : values.sorted()[values.count / 2] }

    @Test func encodesKeyframesOnDemandAndTheFramesDecode() async throws {
        let outputs = Outputs()
        let encoder = LiveEncoder(level: 1) { outputs.add($0) }
        defer { encoder.stop() }

        encoder.encode(Self.picture(0), captureMicros: LiveWire.micros())
        let first = try #require(await outputs.wait(for: 1).first)
        #expect(first.video.keyframe)
        #expect(first.video.parameterSets?.count == 3)
        #expect(first.video.sequence == 0)
        #expect((first.video.width, first.video.height) == (1280, 800))
        #expect(encoder.engine != nil)

        for frame in 1...15 {
            encoder.encode(Self.picture(frame), captureMicros: LiveWire.micros())
            _ = await outputs.wait(for: frame + 1)
        }
        var all = outputs.all
        try #require(all.count == 16)
        #expect(all.dropFirst().allSatisfy { !$0.video.keyframe && $0.video.parameterSets == nil })
        #expect(all.map(\.video.sequence) == Array(0..<16))

        // A keyframe asked for with a new picture on its way.
        encoder.requestKeyframe()
        encoder.encode(Self.picture(16), captureMicros: LiveWire.micros())
        all = await outputs.wait(for: 17)
        try await Task.sleep(for: .milliseconds(150))
        all = outputs.all
        #expect(all.dropFirst(16).contains { $0.video.keyframe && $0.video.parameterSets?.count == 3 })

        // A keyframe asked for on a still screen comes from the last picture again.
        let count = all.count
        let asked = LiveWire.micros()
        encoder.requestKeyframe()
        all = await outputs.wait(for: count + 1)
        let still = try #require(all.last)
        #expect(all.count == count + 1)
        #expect(still.video.keyframe)
        #expect(still.video.captureMicros >= asked)

        // Then plain frames again.
        encoder.encode(Self.picture(17), captureMicros: LiveWire.micros())
        all = await outputs.wait(for: count + 2)
        #expect(all.last?.video.keyframe == false)
        #expect(all.map(\.video.sequence) == Array(0..<UInt32(all.count)))

        // Every frame survives the wire.
        for output in all { #expect(try LiveWire.decodeVideo(LiveWire.encode(output.video)) == output.video) }

        // And decodes, through a sample buffer, to a picture of the coded size.
        var builder = LiveSampleBuilder()
        var decoder: VTDecompressionSession?
        var decodeMicros: [Int] = []
        for output in all {
            let wire = LiveWire.encode(output.video)
            guard case .sample(let sample) = builder.take(try LiveWire.decodeVideo(wire)) else {
                Issue.record("frame \(output.video.sequence) was refused"); continue
            }
            let format = try #require(builder.formatDescription)
            if decoder.map({ !VTDecompressionSessionCanAcceptFormatDescription($0, formatDescription: format) }) ?? true {
                decoder.map(VTDecompressionSessionInvalidate)
                VTDecompressionSessionCreate(allocator: kCFAllocatorDefault, formatDescription: format, decoderSpecification: nil,
                                             imageBufferAttributes: nil, outputCallback: nil, decompressionSessionOut: &decoder)
            }
            let session = try #require(decoder)
            let decoded = Decoded()
            let started = ContinuousClock.now
            let status = VTDecompressionSessionDecodeFrame(session, sampleBuffer: sample, flags: [], infoFlagsOut: nil) { status, _, image, _, _ in
                decoded.result.withLock {
                    $0 = (status, image.map(CVPixelBufferGetWidth) ?? 0, image.map(CVPixelBufferGetHeight) ?? 0)
                }
            }
            VTDecompressionSessionWaitForAsynchronousFrames(session)
            decodeMicros.append(LiveEncoder.micros(ContinuousClock.now - started))
            #expect(status == noErr)
            let result = try #require(decoded.result.withLock { $0 })
            #expect(result.status == noErr)
            #expect((result.width, result.height) == (output.video.width, output.video.height))
        }
        decoder.map(VTDecompressionSessionInvalidate)
        #expect(builder.late == 0)

        let encodeMicros = all.map(\.encodeMicros)
        let keyBytes = all.filter(\.video.keyframe).map { LiveWire.encode($0.video).count }
        let deltaBytes = all.filter { !$0.video.keyframe }.map { LiveWire.encode($0.video).count }
        print("LIVE-TIMING engine=\(all.last?.engine.rawValue ?? "?") size=1280x800 frames=\(all.count)")
        print("LIVE-TIMING encode_us first=\(encodeMicros[0]) after=\(Array(encodeMicros.dropFirst())) median=\(Self.median(Array(encodeMicros.dropFirst())))")
        print("LIVE-TIMING decode_us all=\(decodeMicros) median=\(Self.median(decodeMicros))")
        print("LIVE-TIMING bytes keyframe_median=\(Self.median(keyBytes)) delta_median=\(Self.median(deltaBytes))")
    }

    @Test func aNewLevelStartsWithAKeyframeAtItsSize() async throws {
        let outputs = Outputs()
        let encoder = LiveEncoder(level: 0, preferHardware: false) { outputs.add($0) }
        defer { encoder.stop() }
        encoder.encode(Self.picture(0, width: 2560, height: 1600), captureMicros: LiveWire.micros())
        let first = try #require(await outputs.wait(for: 1).first)
        #expect((first.video.width, first.video.height) == (1600, 1000))
        #expect(first.engine == .software)
        #expect(encoder.engine == .software)

        // On a still screen the new level's keyframe comes at once, from the last picture.
        encoder.setLevel(3)
        #expect(encoder.currentLevel == 3)
        let light = try #require(await outputs.wait(for: 2).last)
        #expect(light.video.keyframe)
        #expect((light.video.width, light.video.height) == (640, 400))
        #expect(light.video.sequence == 1)

        encoder.encode(Self.picture(1, width: 2560, height: 1600), captureMicros: LiveWire.micros())
        let next = try #require(await outputs.wait(for: 3).last)
        #expect(!next.video.keyframe)
        #expect((next.video.width, next.video.height) == (640, 400))

        // A source that changes size starts again with a keyframe too.
        encoder.encode(Self.picture(2, width: 1000, height: 700), captureMicros: LiveWire.micros())
        let resized = try #require(await outputs.wait(for: 4).last)
        #expect(resized.video.keyframe)
        #expect((resized.video.width, resized.video.height) == (640, 448))
        let timings = outputs.all.dropFirst().map(\.encodeMicros)
        print("LIVE-TIMING software level3 640x400 encode_us=\(timings)")
    }

    @Test func nothingComesOutAfterStop() async throws {
        let outputs = Outputs()
        let encoder = LiveEncoder(level: 3, preferHardware: false) { outputs.add($0) }
        encoder.encode(Self.picture(0), captureMicros: LiveWire.micros())
        _ = await outputs.wait(for: 1)
        encoder.stop()
        encoder.encode(Self.picture(1), captureMicros: LiveWire.micros())
        encoder.requestKeyframe()
        try await Task.sleep(for: .milliseconds(300))
        #expect(outputs.all.count == 1)
    }

    @Test func nothingComesOutOnceStopReturns() async throws {
        let outputs = Outputs()
        let encoder = LiveEncoder(level: 3, preferHardware: false) { outputs.add($0) }
        encoder.encode(Self.picture(0), captureMicros: LiveWire.micros())
        encoder.stop()
        try await Task.sleep(for: .milliseconds(800))
        #expect(outputs.all.isEmpty)
    }

    @Test func stopFromInsideAnOutputDoesNotHang() async throws {
        let outputs = Outputs()
        let holder = Mutex<LiveEncoder?>(nil)
        let encoder = LiveEncoder(level: 3, preferHardware: false) { output in
            outputs.add(output)
            holder.withLock { $0 }?.stop()
        }
        holder.withLock { $0 = encoder }
        encoder.encode(Self.picture(0), captureMicros: LiveWire.micros())
        _ = await outputs.wait(for: 1)
        encoder.encode(Self.picture(1), captureMicros: LiveWire.micros())
        encoder.requestKeyframe()
        try await Task.sleep(for: .milliseconds(300))
        #expect(outputs.all.count == 1)
        holder.withLock { $0 = nil }
    }

    /// A picture the encoder can't take: VideoToolbox can't convert this format to 4:2:0.
    static func unusable() -> CVPixelBuffer {
        var made: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, 64, 64, kCVPixelFormatType_DisparityFloat16, nil, &made)
        return made!
    }

    @Test func aPictureThatKeepsFailingIsTriedABoundedNumberOfTimes() async throws {
        let outputs = Outputs()
        let encoder = LiveEncoder(level: 3, preferHardware: false) { outputs.add($0) }
        defer { encoder.stop() }
        encoder.encode(Self.unusable(), captureMicros: LiveWire.micros())
        try await Task.sleep(for: .milliseconds(1500))
        // The picture and its four retries, then nothing until something new comes.
        #expect(encoder.attempts == 1 + LiveEncoder.stillRetries)
        try await Task.sleep(for: .milliseconds(300))
        #expect(encoder.attempts == 1 + LiveEncoder.stillRetries)

        // Each new request gets one more try.
        encoder.requestKeyframe()
        try await Task.sleep(for: .milliseconds(300))
        #expect(encoder.attempts == 2 + LiveEncoder.stillRetries)
        encoder.setLevel(2)
        try await Task.sleep(for: .milliseconds(800))
        #expect(encoder.attempts == 3 + LiveEncoder.stillRetries)
        #expect(outputs.all.isEmpty)

        // A picture that works comes out as a keyframe, on the same software encoder.
        encoder.encode(Self.picture(0), captureMicros: LiveWire.micros())
        let first = try #require(await outputs.wait(for: 1).first)
        #expect(first.video.keyframe)
        #expect(first.engine == .software)
    }

    @Test func theSampleBuilderWaitsForAKeyframeAfterAGap() async throws {
        let outputs = Outputs()
        let encoder = LiveEncoder(level: 3, preferHardware: false) { outputs.add($0) }
        defer { encoder.stop() }
        // Built from real frames so the format is real.
        for frame in 0..<4 {
            encoder.encode(Self.picture(frame), captureMicros: LiveWire.micros())
            _ = await outputs.wait(for: frame + 1)
        }
        let videos = outputs.all.map(\.video)
        try #require(videos.count == 4)

        // Joining mid-stream asks for a keyframe once.
        var builder = LiveSampleBuilder()
        guard case .waitingForKeyframe(let justLost) = builder.take(videos[1]) else { Issue.record("took a frame before a keyframe"); return }
        #expect(justLost)
        guard case .waitingForKeyframe(false) = builder.take(videos[2]) else { Issue.record("asked twice"); return }
        builder.askAgain()
        guard case .waitingForKeyframe(true) = builder.take(videos[3]) else { Issue.record("didn't ask again"); return }
        guard case .sample = builder.take(videos[0]) else { Issue.record("refused a keyframe"); return }
        guard case .waitingForKeyframe(true) = builder.take(videos[2]) else { Issue.record("missed the gap"); return }
        guard case .waitingForKeyframe(false) = builder.take(videos[3]) else { Issue.record("left the wait without a keyframe"); return }
        #expect(builder.late == 5)
        guard case .sample = builder.take(videos[0]) else { Issue.record("refused the keyframe again"); return }
        guard case .sample = builder.take(videos[1]) else { Issue.record("refused the next frame"); return }

        // A keyframe whose size doesn't match its format is refused.
        var wrong = videos[0]
        wrong.width = 320
        guard case .waitingForKeyframe = builder.take(wrong) else { Issue.record("took a mismatched keyframe"); return }
        #expect(LiveSampleBuilder.format([]) == nil)
        #expect(LiveSampleBuilder.format([Data([1, 2, 3])]) == nil)
    }
}
#endif
