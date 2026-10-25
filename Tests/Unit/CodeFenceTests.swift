import Foundation
import Testing
@testable import NollieCore

/// Long fenced code blocks, the kind tool output and reasoning cards hold. The parser used to
/// re-copy all the lines on every line read, so cost grew quadratically with length, on the main
/// thread, for each streamed redraw.
@Suite struct CodeFenceTests {
    /// The language and body of a document that is nothing but one fenced block, or nil.
    private func fencedBlock(in blocks: [MarkdownBlock], at index: Int) -> (language: String?, body: String, closed: Bool)? {
        guard blocks.indices.contains(index), case .code(let language, let body, let closed) = blocks[index] else { return nil }
        return (language, body, closed)
    }

    @Test func aHugeFenceIsParsedInOnePass() throws {
        let count = 40_000
        let lines = (0..<count).map { n -> String in
            let second = String(format: "%02d", n % 60)
            return "2026-11-02 08:00:\(second) worker-\(n) DEBUG handled in \(n % 70 + 5) ms"
        }
        let source = "Log follows:\n\n```\n\(lines.joined(separator: "\n"))\n```\n\nThat's it."

        let clock = ContinuousClock()
        var blocks: [MarkdownBlock] = []
        let elapsed = clock.measure { blocks = MarkdownParser.blocks(from: source) }

        let fence = try #require(fencedBlock(in: blocks, at: 1), "the middle block should be code")
        #expect(blocks.count == 3)
        #expect(fence.language == nil && fence.closed)
        #expect(fence.body.components(separatedBy: "\n").count == count)
        #expect(fence.body.hasPrefix(lines[0]) && fence.body.hasSuffix(lines[count - 1]))
        // Loose, for a debug build under a test runner; the quadratic version took minutes.
        #expect(elapsed < .seconds(3), "parsing took \(elapsed)")
    }

    @Test func aFenceStillOpenKeepsAllItsLines() throws {
        let blocks = MarkdownParser.blocks(from: ["```swift", "let x = 10", "let y = 20"].joined(separator: "\n"))
        #expect(blocks.count == 1)
        let fence = try #require(fencedBlock(in: blocks, at: 0))
        #expect(fence.language == "swift")
        #expect(fence.closed == false)
        #expect(fence.body == "let x = 10\nlet y = 20")
    }
}
