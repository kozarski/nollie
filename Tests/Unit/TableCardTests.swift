import Foundation
import SwiftUI
import Testing
@testable import Nollie
@testable import NollieCore

// Tables as a reply delivers them: parsing, Copy as Markdown, the words VoiceOver speaks, and the
// column sums behind the scrolling card, plus the styling of the Reasoning card. No view gets
// drawn, and none of it is specific to iPhone, so the Mac runs these too.

@Suite struct TableCardTests {
    /// Six columns holding emoji, bold text, an em dash and half stars: a table that once collapsed
    /// into single characters in a phone bubble.
    private static let ranking = [
        "| Place | Team / Entry | Size | Licence | Strength | Score |",
        "|---|---|---|---|---|---|",
        "| 🥇 | **Team Red — Entry A** | 1.2T / 80B live | Open | Fast on long jobs | ⭐⭐⭐⭐⭐ |",
        "| 🥈 | **Team Blue — Entry B** | 500B / 30B live | MIT | Careful with tools | ⭐⭐⭐⭐½ |",
    ].joined(separator: "\n")

    private func soleTable(_ text: String) -> MarkdownTable? {
        guard case .table(let table)? = MarkdownParser.blocks(from: text).onlyElement else { return nil }
        return table
    }

    @Test func theWideTableKeepsEveryCell() throws {
        // A single block: the delimiter row is eaten, not left over as a paragraph.
        let table = try #require(soleTable(Self.ranking))
        #expect(table.header == ["Place", "Team / Entry", "Size", "Licence", "Strength", "Score"])
        #expect(table.alignments == Array(repeating: .leading, count: 6))
        #expect(table.rows.count == 2)
        #expect(table.rows.allSatisfy { $0.count == 6 })
        #expect(table.rows[0] == ["🥇", "**Team Red — Entry A**", "1.2T / 80B live", "Open", "Fast on long jobs", "⭐⭐⭐⭐⭐"])
        #expect(table.rows[1] == ["🥈", "**Team Blue — Entry B**", "500B / 30B live", "MIT", "Careful with tools", "⭐⭐⭐⭐½"])
        // Emoji stay whole characters: one medal, five or four-and-a-half stars.
        let lengths = [table.rows[0][0], table.rows[0][5], table.rows[1][5]].map(\.count)
        #expect(lengths == [1, 5, 5])
        // Bold and the dash survive the inline pass.
        let styled = MarkdownParser.inline(table.rows[0][1])
        #expect(String(styled.characters) == "Team Red — Entry A")
        #expect(styled.runs.contains { $0.inlinePresentationIntent?.contains(.stronglyEmphasized) == true })
    }

    @Test func voiceOverSaysTheColumnThenTheValueWithoutMarkup() throws {
        let table = try #require(soleTable(Self.ranking))
        #expect(table.spokenCell(row: 0, column: 1) == "Team / Entry: Team Red — Entry A")
        #expect(table.spokenCell(row: 1, column: 5) == "Score: ⭐⭐⭐⭐½")
        #expect(table.spokenCell(row: 0, column: 0) == "Place: 🥇")
        // Beyond a short row: the column name alone, and an empty cell, never a crash.
        #expect(table.spokenCell(row: 9, column: 2) == "Size")
        #expect(table.cell(row: 0, column: 9) == "")
    }

    @Test func copyAsMarkdownReadsBackAsTheSameTable() throws {
        let table = try #require(soleTable(Self.ranking))
        #expect(soleTable(table.markdown) == table)
        #expect(table.markdown.hasPrefix("| Place | Team / Entry | Size | Licence | Strength | Score |\n| --- | --- | --- | --- | --- | --- |\n"))
    }

    @Test func copyKeepsAlignmentAndEscapesPipes() throws {
        let source = "| p | q | r |\n|:--|:-:|--:|\n| m \\| n | `s\\|t` | |"
        let table = try #require(soleTable(source))
        let copied = table.markdown
        #expect(table.rows == [["m | n", "`s|t`", ""]])
        #expect(copied.split(separator: "\n").map(String.init) == ["| p | q | r |", "| --- | :---: | ---: |", "| m \\| n | `s\\|t` |  |"])
        #expect(soleTable(copied) == table)
    }

    // MARK: columns

    @Test func aTableTooWideToFitScrollsWithEachColumnBetweenItsLimits() {
        let natural: [CGFloat] = [20, 100, 500]
        // Wider than the room in all: no stretching, so the card scrolls. With no width to fill, or
        // an unbounded one, the answer is the same.
        for room in [300, nil, CGFloat.infinity] as [CGFloat?] {
            let widths = MarkdownTableMetrics.columnWidths(natural: natural, fill: room, min: 64, max: 220)
            #expect(widths == [64, 100, 220], "room \(String(describing: room))")
        }
    }

    @Test func aTableThatFitsFillsTheWidthAndUnwrapsBeforeItStretches() {
        func widths(_ natural: [CGFloat], room: CGFloat) -> [CGFloat] {
            MarkdownTableMetrics.columnWidths(natural: natural, fill: room, min: 64, max: 220)
        }
        // Of the 500 available, 64 + 100 + 220 = 384 is committed, so 116 is spare. The capped column
        // first wins back its single-line width (80), and the remaining 36 is split in proportion.
        let roomy = widths([20, 100, 300], room: 500)
        #expect(roomy.reduce(0, +).distance(to: 500).magnitude < 0.001)
        #expect(roomy[2] >= 300 && roomy[0] >= 64 && roomy[1] >= 100)
        #expect(roomy.sorted() == roomy && Set(roomy).count == 3)

        // Not enough spare to unwrap everything: the wrapped columns share it, the short one stays.
        let snug = widths([20, 260, 300], room: 520)
        #expect(snug.reduce(0, +).distance(to: 520).magnitude < 0.001)
        #expect(snug[0] == 64)
        #expect(snug.dropFirst().allSatisfy { $0 > 220 })
    }

    @Test func theEdgeFadesShowWhereMoreTableIs() {
        let views: [(from: CGFloat, to: CGFloat, fades: (leading: Bool, trailing: Bool))] = [(0, 300, (false, true)), (150, 450, (true, true)), (300, 600, (true, false))]
        for view in views {
            let fades = MarkdownTableMetrics.overflow(contentWidth: 600, visibleMinX: view.from, visibleMaxX: view.to)
            #expect(fades.leading == view.fades.leading && fades.trailing == view.fades.trailing, "showing \(view.from) to \(view.to)")
        }
    }
}

/// The Reasoning card draws markdown its own way; replies are untouched and html stays code.
@Suite struct ReasoningStyleTests {
    @MainActor @Test func repliesKeepTheirLookAndReasoningDiffers() {
        let sameAsReply = (1...6).allSatisfy { MarkdownView.headingFont($0, style: .reply) == MarkdownView.headingFont($0) }
        #expect(sameAsReply)
        #expect(MarkdownView.headingFont(1, style: .reasoning) != MarkdownView.headingFont(1))
        let cards = [MarkdownView.Style.reply, .reasoning].map(\.showsCards)
        #expect(cards == [true, false])
        // Style takes part in equality, so a row redraws when it changes.
        let plain = MarkdownView(text: "z")
        #expect(plain == MarkdownView(text: "z") && plain != MarkdownView(text: "z", style: .reasoning))
    }
}

private extension Array {
    /// The one element, if there is exactly one.
    var onlyElement: Element? { count == 1 ? first : nil }
}
