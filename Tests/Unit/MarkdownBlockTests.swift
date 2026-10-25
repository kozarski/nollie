import Foundation
import Testing
@testable import Nollie
@testable import NollieCore

private func parse(_ markdown: String) -> [MarkdownBlock] { MarkdownParser.blocks(from: markdown) }

private func entries(_ markdown: String, block: Int = 0) -> [MarkdownListItem] {
    let found = parse(markdown)
    guard found.indices.contains(block), case .list(let items) = found[block] else { return [] }
    return items
}

private func grid(_ markdown: String, block: Int = 0) -> MarkdownTable? {
    let found = parse(markdown)
    guard found.indices.contains(block), case .table(let table) = found[block] else { return nil }
    return table
}

private func dot(_ depth: Int, _ text: String) -> MarkdownListItem { MarkdownListItem(depth: depth, marker: .bullet, text: text) }
private func num(_ depth: Int, _ n: Int, _ text: String) -> MarkdownListItem { MarkdownListItem(depth: depth, marker: .number(n), text: text) }

@Suite struct MarkdownBlockTests {
    // MARK: code, headings, quotes

    @Test func aFenceIsOpenUntilItsClosingLineArrives() {
        #expect(parse("Preface\n```swift\nvar total = 2") == [
            .paragraph("Preface"), .code(language: "swift", text: "var total = 2", closed: false)])
        #expect(parse("Preface\n```swift\nvar total = 2\n```\nAfterwards") == [
            .paragraph("Preface"), .code(language: "swift", text: "var total = 2", closed: true), .paragraph("Afterwards")])
    }

    @Test func oneLineOfEachSimpleBlockKind() {
        let found = parse("# Headline\n- a\n- b\n1. one\n2. two\n> quoted\n---")
        #expect(found == [
            .heading(level: 1, text: "Headline"),
            .list([dot(0, "a"), dot(0, "b")]),
            .list([num(0, 1, "one"), num(0, 2, "two")]),
            .quote("quoted"),
            .rule,
        ])
    }

    @Test func sixHashesAreHeadingsAndSevenAreJustText() {
        let found = parse("# h1\n## h2\n### h3\n#### h4\n##### h5\n###### h6\n####### h7\n#nospace")
        #expect(found.count == 7)
        let levels = found.compactMap { block -> Int? in
            if case .heading(let level, _) = block { return level }
            return nil
        }
        #expect(levels == [1, 2, 3, 4, 5, 6])
        guard case .paragraph = found[6] else {
            Issue.record("seven hashes, or none followed by a space, should stay ordinary text")
            return
        }
    }

    @Test func eachHeadingLevelGetsItsOwnFont() {
        let levels = Array(1...6)
        let fonts = levels.map { MarkdownView.headingFont($0) }
        for pair in levels.indices.flatMap({ a in levels.indices.filter { $0 > a }.map { (a, $0) } }) {
            #expect(fonts[pair.0] != fonts[pair.1], "levels \(levels[pair.0]) and \(levels[pair.1]) look the same")
        }
    }

    // MARK: lists

    @Test func indentationBuildsDepthForBulletsAndNumbers() {
        #expect(entries("- a\n  - b\n    - c\n- d") == [dot(0, "a"), dot(1, "b"), dot(2, "c"), dot(0, "d")])
        let numbered = entries("1. x\n   1. y\n   2. z\n2. w")
        #expect(numbered.map(\.depth) == [0, 1, 1, 0])
        #expect(numbered.map(\.marker) == [.number(1), .number(1), .number(2), .number(2)])
    }

    @Test func aTabIsWorthFourSpaces() {
        #expect(entries("- a\n\t- b\n\t\t- c\n- d").map(\.depth) == [0, 1, 2, 0])
        #expect(entries("- a\n    - b\n\t- c").map(\.depth) == [0, 1, 1])
    }

    @Test func aNumberedListUnderABulletStaysInTheSameBlock() {
        let found = parse("- a\n  1. x\n  2. y\n- b")
        #expect(found.count == 1)
        #expect(entries("- a\n  1. x\n  2. y\n- b") == [dot(0, "a"), num(1, 1, "x"), num(1, 2, "y"), dot(0, "b")])
    }

    @Test func aTopLevelListOfAnotherKindBeginsANewBlock() {
        #expect(parse("- a\n- b\n1. x\n2. y").count == 2)
    }

    @Test func numberingStartsWhereTheListStartsThenCounts() {
        let fromThree = entries("3. a\n4. b")
        #expect(fromThree.map(\.marker) == [.number(3), .number(4)])
        let fromFive = entries("5. a\n1. b")
        #expect(fromFive.map(\.marker) == [.number(5), .number(6)])
    }

    @Test func depthStopsGrowingAtSix() {
        var lines: [String] = []
        for level in 0..<9 { lines.append(String(repeating: "  ", count: level) + "- level\(level)") }
        let found = entries(lines.joined(separator: "\n"))
        #expect(found.count == 9)
        #expect(found.map(\.depth).max() == 6)
    }

    @Test func checkboxesBelongToBulletsOnly() {
        let list = entries("- [ ] open\n- [x] done\n- [X] DONE\n- plain")
        let expectedTasks: [MarkdownListItem.Marker] = [.task(checked: false), .task(checked: true), .task(checked: true), .bullet]
        #expect(list.map(\.marker) == expectedTasks)
        #expect(list.map(\.text) == ["open", "done", "DONE", "plain"])
        let odd = entries("- [ ]\n- [x]\n- [ ]tight\n  - [x] nested")
        let expectedOdd: [MarkdownListItem.Marker] = [.task(checked: false), .task(checked: true), .bullet, .task(checked: true)]
        #expect(odd.map(\.marker) == expectedOdd)
        #expect(odd.map(\.text) == ["", "", "[ ]tight", "nested"])
        #expect(odd.map(\.depth) == [0, 0, 0, 1])
        #expect(entries("1. [ ] x") == [num(0, 1, "[ ] x")])
    }

    // MARK: tables

    @Test func alignmentsAndRaggedRowsAreNormalised() throws {
        let source = ["Prologue", "| Item | Count | Remark |", "|:--|:-:|--:|", "| a | 1 | x |", "| b | 2 |", "| c | 3 | y | extra |", "Epilogue"]
        let table = try #require(grid(source.joined(separator: "\n"), block: 1))
        #expect(table.header == ["Item", "Count", "Remark"])
        #expect(table.alignments == [.leading, .center, .trailing])
        #expect(table.rows == [["a", "1", "x"], ["b", "2", ""], ["c", "3", "y"]])
        let trimmed = source.prefix(4) + ["Epilogue"]
        #expect(parse(trimmed.joined(separator: "\n")).last == .paragraph("Epilogue"))
    }

    @Test func spacedDelimitersAndMissingColonsReadAsExpected() throws {
        let spaced = try #require(grid("| p | q | r |\n| :--- | :---: | ---: |\n| 4 | 5 | 6 |"))
        #expect(spaced.alignments == [.leading, .center, .trailing])
        let plain = try #require(grid("| e | f |\n|---|---|\n| 7 | 8 |"))
        #expect(plain.alignments == [.leading, .leading])
    }

    @Test func escapedPipesAndCodeSpansStayInsideTheirCell() throws {
        let table = try #require(grid("| left | right |\n|---|---|\n| x \\| y | `p|q` |"))
        #expect(table.rows == [["x | y", "`p|q`"]])
    }

    @Test func edgePipesAreOptionalAndCellsMayBeEmpty() throws {
        let bare = try #require(grid("a | b\n--|--\n1 | 2"))
        #expect(bare.header == ["a", "b"])
        #expect(bare.rows == [["1", "2"]])
        let sparse = try #require(grid("|a||c|\n|-|-|-|\n|1||3|"))
        #expect(sparse.header == ["a", "", "c"])
        #expect(sparse.rows == [["1", "", "3"]])
    }

    @Test func aHeaderWaitsForItsDelimiterRowWhileStreaming() throws {
        #expect(parse("| a | b |") == [.paragraph("| a | b |")])
        let started = try #require(grid("| a | b |\n|---|---|"))
        #expect(started.rows.isEmpty)
    }

    @Test(arguments: [
        "a | b\nnot a delimiter",
        "| x | y | z |\n|---|---|\n| 1 | 2 | 3 |",
    ])
    func textThatOnlyResemblesATableIsAParagraph(source: String) {
        let found = parse(source)
        #expect(!found.contains { if case .table = $0 { true } else { false } })
    }

    @Test func aBlankLineClosesATableAndAnotherMayFollow() {
        let found = parse(["| a | b |", "|---|---|", "| 1 | 2 |", "", "| c | d |", "|---|---|", "| 3 | 4 |"].joined(separator: "\n"))
        let headers = found.compactMap { block -> [String]? in
            if case .table(let table) = block { return table.header }
            return nil
        }
        #expect(headers == [["a", "b"], ["c", "d"]])
    }

    @Test func windowsLineEndingsAndFrontMatterTogether() throws {
        let windowsSource = "---\r\nname: Sam\r\n---\r\n| a | b |\r\n|---|---|\r\n| 1 | 2 |\r\n"
        let found = parse(windowsSource)
        #expect(found.count == 1)
        let table = try #require(grid(windowsSource))
        #expect(table.header == ["a", "b"])
        #expect(table.rows == [["1", "2"]])
    }

    // MARK: images

    @Test func anImageAloneOnALineIsABlockAndInlineOnesStayText() {
        let found = parse("![logo](https://x.test/a.png \"t\")\n\n[![badge](https://x.test/b.svg)](https://x.test)\n\nwords ![inline](https://x.test/c.png) after")
        #expect(found.count == 3)
        #expect(found[0] == .image(alt: "logo", url: "https://x.test/a.png", link: nil))
        #expect(found[1] == .image(alt: "badge", url: "https://x.test/b.svg", link: "https://x.test"))
        if case .paragraph = found[2] {} else { Issue.record("the inline image should stay in its paragraph") }
    }

    @Test func theParserKeepsAnyAddressAndLeavesFilteringToTheView() {
        #expect(parse("![a](file:///etc/hosts)") == [.image(alt: "a", url: "file:///etc/hosts", link: nil)])
        #expect(parse("![](https://x.test/a.png)") == [.image(alt: "", url: "https://x.test/a.png", link: nil)])
    }

    @Test func aLinkedImageWithNoClosingBracketIsText() {
        let found = parse("[![a](https://x.test/a.png)]")
        #expect(found.count == 1)
        if case .paragraph = found[0] {} else { Issue.record("expected a paragraph") }
    }

    @Test(arguments: [
        (false, false, false, MarkdownImageView.Display.spinner),
        (false, true, false, .placeholder),
        (false, false, true, .placeholder),
        (true, false, true, .image),
        (true, false, false, .image),
    ])
    func theImageViewShowsWhatTheLoadHasReached(success: Bool, failure: Bool, timedOut: Bool, shows: MarkdownImageView.Display) {
        #expect(MarkdownImageView.display(success: success, failure: failure, timedOut: timedOut) == shows)
    }

    @Test func aPlaceholderIsNamedByItsAltTextOrAGenericLine() {
        let named = MarkdownImageView.placeholderTitle(alt: "Chart")
        let unnamed = MarkdownImageView.placeholderTitle(alt: "")
        #expect(named == "Chart")
        #expect(unnamed == "Image unavailable")
    }

    // MARK: front matter

    @Test func frontMatterHidesOnlyWhenClosedAndKeyed() {
        #expect(parse("---\nname: Sam\ntags: [a]\n---\n# Body") == [.heading(level: 1, text: "Body")])
        #expect(parse("---\nhello\n---\nx").count == 4)
        #expect(parse("---\ntitle: Hi\nno close").first == .rule)
        #expect(parse("Opening\n\n---\nname: y\n---\nBody").contains(.rule))
    }

    @Test(arguments: ["\u{FEFF}---\nname: z\n---\nBody", "---\nname: z\n...\nBody"])
    func aByteOrderMarkOrDotsCloserStillCountsAsFrontMatter(source: String) {
        #expect(parse(source) == [.paragraph("Body")])
        #expect(parse("---\nname: z\n---").isEmpty)
    }
}
