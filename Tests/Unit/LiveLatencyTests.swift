import CoreMedia
import CoreVideo
import Foundation
import Testing
import VideoToolbox
@testable import Nollie
@testable import NollieCore

/// How late the live picture is, measured rather than guessed. Each test prints a `LIVE-LATENCY`
/// line with the median and 95th percentile; the bounds here are loose, the printed numbers are
/// what the report quotes.
struct LiveLatencyTests {
    /// The mock gateway's fixture decodes on this platform (the simulator too), and how long each
    /// frame takes to decode.
    @Test func fixtureFramesDecodeQuickly() throws {
        let messages = try Self.fixture()
        #expect(messages.count == 60)
        var builder = LiveSampleBuilder()
        let decoder = Decoder()
        var times: [Double] = []
        for message in messages {
            let video = try LiveWire.decodeVideo(message)
            guard case .sample(let sample) = builder.take(video) else {
                Issue.record("Frame \(video.sequence) was refused")
                continue
            }
            times.append(try decoder.decode(sample))
        }
        #expect(times.count == 60)
        #expect(decoder.lastSize == CGSize(width: 1280, height: 800))
        let line = Self.summary("decode, fixture 1280x800", times.dropFirst())
        print(line)
        #expect(Self.median(times.dropFirst()) < 50, "\(line)")
    }

    #if os(macOS)
    /// The whole way on this Mac: a picture is drawn and encoded, the Nollie Link door carries it
    /// over pinned TLS 1.3 on loopback, the viewer's own client reads it, and it is decoded.
    @Test func pictureToDecodedThroughTheDoor() async throws {
        let size = CGSize(width: 1280, height: 800)
        let encoder = Locked<LiveEncoder?>(nil)
        let encoded = Locked(0)
        let fixture = try await DoorFixture.start {
            $0.liveProvider = { _, sink in
                let hello = LiveWire.ServerMessage.hello(.init(kind: .space, computer: "Studio desktop",
                                                               source: .init(width: 1280, height: 800)))
                sink.send(Data(hello.encode().utf8), isText: true, isKeyframe: false)
                let made = LiveEncoder(level: 0) { output in
                    encoded.withLock { $0 += 1 }
                    sink.send(LiveWire.encode(output.video), isText: false, isKeyframe: output.video.keyframe)
                }
                encoder.withLock { $0 = made }
                return LinkDoorLiveFeed(control: { data in
                    if String(decoding: data, as: UTF8.self).contains("keyframe") { made.requestKeyframe() }
                }, close: { made.stop() })
            }
        }
        defer { fixture.stop() }
        let door = fixture.door
        let linked = try door.devices.claim(secret: door.devices.makeOffer().secret, name: "Phone")
        try await door.refresh()
        let port = Int(try #require(door.port))
        let target = LiveStreamClient.Target(gateway: try GatewayURL.normalize("https://127.0.0.1:\(port)"), profile: "career",
                                             sessionID: "s1", token: linked.credential, pin: door.identity.pin)
        let feed = LiveStreamClient(target: target, helloTimeout: 5)

        // Pictures at 30 a second for 4 seconds, each stamped when it was drawn.
        let drawing = Task.detached {
            var waited = 0
            while encoder.withLock({ $0 }) == nil, waited < 200 { try? await Task.sleep(for: .milliseconds(10)); waited += 1 }
            for index in 0..<120 {
                guard let picture = Self.picture(index, size: size) else { continue }
                encoder.withLock { $0 }?.encode(picture, captureMicros: LiveWire.micros())
                try? await Task.sleep(for: .milliseconds(33))
            }
        }

        // Never longer than 10 seconds, whatever happens.
        let watchdog = Task { try? await Task.sleep(for: .seconds(10)); feed.cancel() }
        defer { watchdog.cancel() }

        var builder = LiveSampleBuilder()
        let decoder = Decoder()
        var arrived: [Double] = []
        var decoded: [Double] = []
        var seen: [String] = []
        for await event in feed.events {
            switch event {
            case .message(let message): seen.append("\(message)".prefix(12).description)
            case .closed(let close): seen.append("closed \(close)")
            case .video: break
            }
            guard case .video(let video, let receivedAt) = event else { continue }
            let captured = Double(video.captureMicros) / 1_000_000
            guard case .sample(let sample) = builder.take(video) else {
                feed.send(.keyframe)
                continue
            }
            _ = try decoder.decode(sample)
            arrived.append((receivedAt.timeIntervalSince1970 - captured) * 1000)
            decoded.append((Date().timeIntervalSince1970 - captured) * 1000)
            if video.sequence >= 110 { feed.cancel() }
        }
        drawing.cancel()
        encoder.withLock { $0 }?.stop()

        // The first frames carry the encoder's warm-up; the steady state is what a viewer sees.
        let steadyArrived = arrived.dropFirst(10)
        let steadyDecoded = decoded.dropFirst(10)
        #expect(decoded.count > 60, "Only \(decoded.count) frames were decoded of \(encoded.withLock { $0 }) encoded; events \(seen)")
        print(Self.summary("picture to arrival through the door, 1280x800", steadyArrived))
        let line = Self.summary("picture to decoded through the door, 1280x800", steadyDecoded)
        print(line)
        #expect(Self.median(steadyDecoded) < 150, "\(line)")
        #expect(fixture.hermes.requests.isEmpty)
    }

    private static func picture(_ index: Int, size: CGSize) -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(nil, Int(size.width), Int(size.height), kCVPixelFormatType_32BGRA,
                            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer)
        guard let buffer else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let context = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: Int(size.width), height: Int(size.height),
                                      bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        context.setFillColor(CGColor(red: 0.9, green: 0.91, blue: 0.93, alpha: 1))
        context.fill(CGRect(origin: .zero, size: size))
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 160, y: 100, width: 960, height: 600))
        context.setFillColor(CGColor(red: 0.35, green: 0.5, blue: 0.75, alpha: 1))
        context.fill(CGRect(x: 200, y: 300, width: CGFloat(20 + (index * 7) % 860), height: 18))
        return buffer
    }
    #endif

    // MARK: Helpers

    /// Decodes one sample at a time and says how long it took, in milliseconds.
    final class Decoder {
        private var session: VTDecompressionSession?
        private var format: CMFormatDescription?
        private(set) var lastSize: CGSize?

        func decode(_ sample: CMSampleBuffer) throws -> Double {
            let description = try #require(CMSampleBufferGetFormatDescription(sample))
            if session == nil || format.map({ !CMFormatDescriptionEqual($0, otherFormatDescription: description) }) ?? true {
                if let session { VTDecompressionSessionInvalidate(session) }
                var made: VTDecompressionSession?
                let status = VTDecompressionSessionCreate(allocator: nil, formatDescription: description, decoderSpecification: nil,
                                                          imageBufferAttributes: nil, outputCallback: nil,
                                                          decompressionSessionOut: &made)
                try #require(status == noErr && made != nil, "No decoder: \(status)")
                session = made
                format = description
            }
            let start = Date()
            var size: CGSize?
            var failure: OSStatus = noErr
            let status = VTDecompressionSessionDecodeFrame(try #require(session), sampleBuffer: sample, flags: [], infoFlagsOut: nil) {
                status, _, image, _, _ in
                failure = status
                if let image { size = CGSize(width: CVPixelBufferGetWidth(image), height: CVPixelBufferGetHeight(image)) }
            }
            if let session { VTDecompressionSessionWaitForAsynchronousFrames(session) }
            try #require(status == noErr && failure == noErr && size != nil, "Decode failed: \(status) \(failure)")
            lastSize = size
            return Date().timeIntervalSince(start) * 1000
        }

        deinit { if let session { VTDecompressionSessionInvalidate(session) } }
    }

    final class Locked<Value>: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Value
        init(_ value: Value) { self.value = value }
        func withLock<T>(_ body: (inout Value) -> T) -> T { lock.lock(); defer { lock.unlock() }; return body(&value) }
    }

    static func fixture() throws -> [Data] {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Tools/mock-gateway/fixtures/live-desktop.hevclive")
        let data = try Data(contentsOf: url)
        try #require(data.prefix(4) == Data("NLV1".utf8))
        func number(_ at: Int) -> Int { data[at..<(at + 4)].reduce(0) { $0 << 8 | Int($1) } }
        var at = data.startIndex + 8
        var messages: [Data] = []
        for _ in 0..<number(data.startIndex + 4) {
            let length = number(at)
            messages.append(data[(at + 4)..<(at + 4 + length)])
            at += 4 + length
        }
        return messages
    }

    static func median<C: Collection>(_ values: C) -> Double where C.Element == Double {
        let sorted = values.sorted()
        return sorted.isEmpty ? .infinity : sorted[sorted.count / 2]
    }

    static func summary<C: Collection>(_ what: String, _ values: C) -> String where C.Element == Double {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return "LIVE-LATENCY \(what): no frames" }
        let p95 = sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))]
        return String(format: "LIVE-LATENCY %@: median %.1f ms, p95 %.1f ms, min %.1f ms, max %.1f ms, %d frames",
                      what, sorted[sorted.count / 2], p95, sorted[0], sorted[sorted.count - 1], sorted.count)
    }
}
