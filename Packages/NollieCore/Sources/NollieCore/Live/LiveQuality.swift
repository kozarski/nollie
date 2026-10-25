/// The quality ladder for a live picture, from 0 (best) to 3 (lightest). `LiveJudge` picks the
/// level; the encoder and capture follow it.
public struct LiveQuality: Sendable, Equatable {
    public let level: Int
    /// The longest side of the coded picture, in pixels. Smaller pictures are never enlarged.
    public let longEdge: Int
    public let fps: Int
    public let bitsPerSecond: Int

    public static let ladder: [LiveQuality] = [
        LiveQuality(level: 0, longEdge: 1600, fps: 30, bitsPerSecond: 6_000_000),
        LiveQuality(level: 1, longEdge: 1280, fps: 24, bitsPerSecond: 3_000_000),
        LiveQuality(level: 2, longEdge: 960, fps: 15, bitsPerSecond: 1_500_000),
        LiveQuality(level: 3, longEdge: 640, fps: 10, bitsPerSecond: 600_000),
    ]
    public static let best = 0
    public static let lightest = 3

    public static func level(_ level: Int) -> LiveQuality { ladder[min(max(level, best), lightest)] }

    /// The most bytes the encoder may spend in any one second: half again the average.
    public var bytesPerSecondLimit: Int { bitsPerSecond / 8 * 3 / 2 }

    /// The coded size for a source: scaled down so the long side fits, never up, and rounded
    /// down to even sides (4:2:0 needs them). At least 2 × 2.
    public func size(for source: LiveWire.PixelSize) -> LiveWire.PixelSize {
        let width = max(source.width, 1), height = max(source.height, 1)
        let long = max(width, height)
        let scaledWidth = long > longEdge ? width * longEdge / long : width
        let scaledHeight = long > longEdge ? height * longEdge / long : height
        return LiveWire.PixelSize(width: max(2, scaledWidth & ~1), height: max(2, scaledHeight & ~1))
    }
}
