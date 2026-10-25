// Makes the mock gateway's live picture: a few seconds of a synthetic desktop, encoded by the real
// LiveEncoder and framed by the real LiveWire from NollieCore, so the mock sends exactly what a
// host would. Built and run by make-live-fixture.sh; never a capture of a real computer.
//
//   live-fixture <output .hevclive>
//
// The file: ASCII "NLV1", a u32 big-endian message count, then each message as a u32 big-endian
// length and the bytes LiveWire.encode made. The first frame is the only keyframe.
import CoreGraphics
import CoreVideo
import Dispatch
import Foundation
import Synchronization

@main
struct LiveFixture {
    static let width = 1280
    static let height = 800
    static let fps = 15
    static let frames = 60
    /// Where the progress bar starts and how long it can grow, in source pixels. The mock puts
    /// the helper's pointer at the bar's end (`mock_gateway.py`, `live_pointer`).
    static let barX = 384, barY = 556, barHeight = 26, barShortest = 40, barLongest = 708

    static func main() {
        guard CommandLine.arguments.count == 2 else { fail("usage: live-fixture <output .hevclive>") }
        let outputPath = CommandLine.arguments[1]

        let outputs = Mutex<[LiveEncoder.Output]>([])
        let arrived = DispatchSemaphore(value: 0)
        // Software from the start: this Mac's hardware encoder answers with no frames, and the
        // fixture should not depend on which encoder a Mac has.
        let encoder = LiveEncoder(level: 1, preferHardware: false) { output in
            outputs.withLock { $0.append(output) }
            arrived.signal()
        }
        let started = DispatchTime.now()
        for index in 0..<frames {
            guard let picture = desktop(frame: index) else { fail("could not draw frame \(index)") }
            // Paced like a real 15 fps capture, one frame in the encoder at a time, so none is
            // replaced while it waits.
            encoder.encode(picture, captureMicros: UInt64(index) * 1_000_000 / UInt64(fps))
            guard arrived.wait(timeout: .now() + 10) == .success else { fail("the encoder gave nothing back for frame \(index)") }
            let next = started + .nanoseconds((index + 1) * 1_000_000_000 / fps)
            let now = DispatchTime.now()
            if next > now { Thread.sleep(forTimeInterval: Double(next.uptimeNanoseconds - now.uptimeNanoseconds) / 1e9) }
        }
        encoder.stop()

        let videos = outputs.withLock { $0.map(\.video) }
        guard videos.count == frames else { fail("expected \(frames) frames, got \(videos.count)") }
        for (index, video) in videos.enumerated() {
            guard video.keyframe == (index == 0) else { fail("frame \(index) keyframe=\(video.keyframe); only the first may be one") }
            guard video.sequence == UInt32(index), video.width == width, video.height == height else {
                fail("frame \(index) is #\(video.sequence) at \(video.width)x\(video.height)")
            }
        }
        guard videos[0].parameterSets?.count == 3 else { fail("the keyframe should carry VPS, SPS and PPS") }

        var file = Data("NLV1".utf8)
        append(UInt32(videos.count), to: &file)
        for video in videos {
            let message = LiveWire.encode(video)
            guard (try? LiveWire.decodeVideo(message)) == video else { fail("frame \(video.sequence) does not read back") }
            append(UInt32(message.count), to: &file)
            file.append(message)
        }
        do {
            try file.write(to: URL(fileURLWithPath: outputPath), options: .atomic)
        } catch {
            fail("could not write \(outputPath): \(error)")
        }
        let engine = outputs.withLock { $0.first?.engine.rawValue ?? "?" }
        print("\(videos.count) frames, \(file.count) bytes, keyframe \(LiveWire.encode(videos[0]).count) bytes, \(engine) encoder")
    }

    // MARK: Drawing

    /// A calm light desktop: a menu strip, one window with a title bar, a sidebar, lines of
    /// text as bars and a progress bar that grows across the clip. Neutral colours, no marks.
    static func desktop(frame: Int) -> CVPixelBuffer? {
        var made: CVPixelBuffer?
        let attributes: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [CFString: Any]() as CFDictionary]
        guard CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA,
                                  attributes as CFDictionary, &made) == kCVReturnSuccess, let buffer = made else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let context = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        // Top-left origin, like the source pixels pointer spots are measured in.
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)

        let wallpaper = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [rgb(228, 233, 239), rgb(204, 212, 222)] as CFArray,
                                   locations: [0, 1])!
        context.drawLinearGradient(wallpaper, start: .zero, end: CGPoint(x: 0, y: height), options: [])
        fill(context, rgb(240, 242, 246), CGRect(x: 0, y: 0, width: width, height: 24))
        fill(context, rgb(196, 202, 212), CGRect(x: 1140, y: 8, width: 120, height: 8))

        let window = CGRect(x: 132, y: 112, width: 1018, height: 578)
        context.saveGState()
        context.setShadow(offset: CGSize(width: 0, height: 10), blur: 30, color: rgb(40, 50, 70, 0.18))
        fill(context, rgb(250, 251, 253), window)
        context.restoreGState()
        fill(context, rgb(226, 230, 237), CGRect(x: window.minX, y: window.minY, width: window.width, height: 54))
        for dot in 0..<3 {
            context.setFillColor(rgb(184, 190, 200))
            context.fillEllipse(in: CGRect(x: 154 + dot * 26, y: 132, width: 14, height: 14))
        }
        fill(context, rgb(200, 206, 216), CGRect(x: 560, y: 134, width: 162, height: 10))
        fill(context, rgb(241, 243, 247), CGRect(x: window.minX, y: 166, width: 208, height: window.maxY - 166))
        for row in 0..<6 {
            fill(context, rgb(208, 214, 223), CGRect(x: 160, y: 196 + row * 40, width: row == 1 ? 132 : 104 + (row * 17) % 40, height: 12))
        }
        for (row, top) in [216, 282, 348, 414].enumerated() {
            fill(context, rgb(201, 209, 220), CGRect(x: barX, y: top, width: [708, 640, 690, 520][row], height: 28))
        }
        fill(context, rgb(229, 233, 239), CGRect(x: barX, y: barY, width: barLongest, height: barHeight))
        fill(context, rgb(92, 132, 190), CGRect(x: barX, y: barY, width: barLength(frame: frame), height: barHeight))
        fill(context, rgb(210, 216, 225, 0.85), CGRect(x: 476, y: 730, width: 328, height: 50))
        return buffer
    }

    static func barLength(frame: Int) -> Int { barShortest + frame * (barLongest - barShortest) / (frames - 1) }

    static func rgb(_ red: Int, _ green: Int, _ blue: Int, _ alpha: CGFloat = 1) -> CGColor {
        CGColor(srgbRed: CGFloat(red) / 255, green: CGFloat(green) / 255, blue: CGFloat(blue) / 255, alpha: alpha)
    }

    static func fill(_ context: CGContext, _ color: CGColor, _ rect: CGRect) {
        context.setFillColor(color)
        context.fill(rect)
    }

    static func append(_ value: UInt32, to data: inout Data) {
        withUnsafeBytes(of: value.bigEndian) { data.append(contentsOf: $0) }
    }

    static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data("live-fixture: \(message)\n".utf8))
        exit(1)
    }
}
