import Testing
@testable import NollieCore

/// The quality ladder and the coded size for any source: even sides, never enlarged.
struct LiveQualityTests {
    private func size(_ width: Int, _ height: Int, level: Int) -> LiveWire.PixelSize {
        LiveQuality.level(level).size(for: .init(width: width, height: height))
    }

    @Test func theLadder() {
        #expect(LiveQuality.ladder.map(\.longEdge) == [1600, 1280, 960, 640])
        #expect(LiveQuality.ladder.map(\.fps) == [30, 24, 15, 10])
        #expect(LiveQuality.ladder.map(\.bitsPerSecond) == [6_000_000, 3_000_000, 1_500_000, 600_000])
        #expect(LiveQuality.ladder.map(\.level) == [0, 1, 2, 3])
        #expect(LiveQuality.level(0).bytesPerSecondLimit == 1_125_000)
        #expect(LiveQuality.level(-1).level == 0)
        #expect(LiveQuality.level(7).level == 3)
    }

    @Test func aRetinaScreenScalesDownEachStep() {
        #expect(size(2560, 1600, level: 0) == .init(width: 1600, height: 1000))
        #expect(size(2560, 1600, level: 1) == .init(width: 1280, height: 800))
        #expect(size(2560, 1600, level: 2) == .init(width: 960, height: 600))
        #expect(size(2560, 1600, level: 3) == .init(width: 640, height: 400))
        #expect(size(1000, 3000, level: 3) == .init(width: 212, height: 640))
    }

    @Test func smallPicturesAreNeverEnlargedAndOddSidesRoundDown() {
        #expect(size(1280, 800, level: 0) == .init(width: 1280, height: 800))
        #expect(size(1001, 601, level: 0) == .init(width: 1000, height: 600))
        #expect(size(640, 400, level: 3) == .init(width: 640, height: 400))
        #expect(size(3, 3, level: 0) == .init(width: 2, height: 2))
        #expect(size(1, 1, level: 0) == .init(width: 2, height: 2))
    }

    @Test func everySizeIsEvenFitsAndKeepsItsShape() {
        var random = LiveWireTests.Seeded(state: 7)
        for _ in 0..<5000 {
            let width = Int.random(in: 2...8192, using: &random), height = Int.random(in: 2...8192, using: &random)
            for quality in LiveQuality.ladder {
                let out = quality.size(for: .init(width: width, height: height))
                #expect(out.width % 2 == 0 && out.height % 2 == 0)
                #expect(out.width <= width && out.height <= height)
                #expect(max(out.width, out.height) <= quality.longEdge)
                if max(width, height) <= quality.longEdge {
                    #expect(out.width == width & ~1 && out.height == height & ~1)
                } else {
                    // The long side lands on the edge, give or take rounding to even.
                    #expect(max(out.width, out.height) >= quality.longEdge - 1)
                }
                if min(out.width, out.height) >= 100 {
                    let before = Double(width) / Double(height), after = Double(out.width) / Double(out.height)
                    #expect(abs(after / before - 1) < 0.03)
                }
            }
        }
    }
}
