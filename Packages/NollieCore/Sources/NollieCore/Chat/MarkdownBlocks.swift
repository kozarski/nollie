import Foundation

/// One entry of a bulleted, numbered or task list, possibly nested.
public struct MarkdownListItem: Hashable, Sendable {
    public init(depth: Int, marker: Marker, text: String) {
        (self.depth, self.marker, self.text) = (depth, marker, text)
    }

    /// 0 for the outermost list, one more for each level in.
    public var depth: Int
    public var marker: Marker
    public var text: String

    public enum Marker: Hashable, Sendable {
        case bullet
        /// The number to show, already worked out for this nesting level.
        case number(Int)
        case task(checked: Bool)
    }
}

public enum MarkdownColumnAlignment: Hashable, Sendable {
    case center, trailing, leading

    /// How the column is marked in a table's delimiter row.
    fileprivate var delimiter: String {
        self == .center ? ":---:" : self == .trailing ? "---:" : "---"
    }
}

public struct MarkdownTable: Hashable, Sendable {
    public init(header: [String], alignments: [MarkdownColumnAlignment], rows: [[String]]) {
        self.rows = rows
        self.alignments = alignments
        self.header = header
    }

    public var header: [String]
    public var alignments: [MarkdownColumnAlignment]
    /// Every row has as many cells as the header.
    public var rows: [[String]]
}

// Only computed members belong here. A block's `id` is the hash of its table, so a stored
// property would change every id and make rows rebuild while a reply streams in.
extension MarkdownTable {
    /// The text in a body cell, or "" where a hand-built table is short.
    public func cell(row: Int, column: Int) -> String {
        rows.indices.contains(row) ? (rows[row].indices.contains(column) ? rows[row][column] : "") : ""
    }

    public func alignment(of column: Int) -> MarkdownColumnAlignment {
        if column >= 0 && column < alignments.count { return alignments[column] }
        return .leading
    }

    /// Spoken label for a body cell under VoiceOver: column title, then value ("Params: 744B").
    /// Inline markdown is flattened to plain words so no asterisks get read out.
    public func spokenCell(row: Int, column: Int) -> String {
        let value = Self.plain(cell(row: row, column: column))
        let title = column >= 0 ? header.dropFirst(column).first.map(Self.plain) ?? "" : ""
        switch (title.isEmpty, value.isEmpty) {
        case (true, _): return value
        case (_, true): return title
        default: return String(localized: "\(title): \(value)", table: "Core", comment: "VoiceOver: a table column's title, then the cell's value")
        }
    }

    /// Inline markdown flattened to plain words: bold becomes its text and a link becomes its title.
    /// Cached, since each cell's label is derived from it on every table redraw.
    public static func plain(_ text: String) -> String {
        wordCache.words(for: text) {
            String(MarkdownParser.inline(text).characters).trimmingCharacters(in: .whitespaces)
        }
    }

    private static let wordCache = WordCache()

    /// A bounded memory of inline text turned into words.
    private final class WordCache: @unchecked Sendable {
        private let store: NSCache<NSString, NSString> = {
            let made = NSCache<NSString, NSString>()
            made.countLimit = 2000
            return made
        }()

        func words(for text: String, make: () -> String) -> String {
            if let known = store.object(forKey: text as NSString) { return known as String }
            let made = make()
            store.setObject(made as NSString, forKey: text as NSString)
            return made
        }
    }

    /// Renders the table back to GFM, for the Copy as Markdown action. A `\|` is read by the parser as
    /// a plain pipe (code spans included), so cell pipes get escaped and the output parses to the same table.
    public var markdown: String {
        func line(_ cells: [String]) -> String {
            let padded = cells + [String](repeating: "", count: Swift.max(0, header.count - cells.count))
            let escaped = padded.prefix(header.count).map { $0.replacingOccurrences(of: "|", with: "\\|") }
            return "| \(escaped.joined(separator: " | ")) |"
        }
        let delimiters = header.indices.map { alignment(of: $0).delimiter }
        let lines = [line(header), line(delimiters)] + rows.map(line)
        return lines.joined(separator: "\n")
    }
}

/// One piece of a reply. Replies are chopped into pieces so streaming only redraws what changed.
/// Emphasis, links and the like are left to `AttributedString(markdown:)`. A code fence still open
/// renders as code, and the piece firms up when the closing fence lands.
public enum MarkdownBlock: Hashable, Identifiable, Sendable {
    case rule
    case paragraph(String)
    case quote(String)
    case heading(level: Int, text: String)
    /// Standalone image line, possibly linked: `[![alt](src)](href)`.
    case image(alt: String, url: String, link: String?)
    case table(MarkdownTable)
    /// Bulleted, numbered or checkbox list. Each item carries its own `depth` for nesting.
    case list([MarkdownListItem])
    case code(language: String?, text: String, closed: Bool)

    /// Equal blocks share an id, so an unchanged block keeps its view while others stream.
    public var id: Int { hashValue }
}

public enum MarkdownParser {
    public static func blocks(from text: String) -> [MarkdownBlock] {
        var reader = BlockReader(lines: lines(of: text))
        return reader.run()
    }

    /// Inline markdown as styled text; plain text if it cannot be read.
    public static func inline(_ text: String) -> AttributedString {
        var options = AttributedString.MarkdownParsingOptions()
        options.interpretedSyntax = .inlineOnlyPreservingWhitespace
        options.failurePolicy = .returnPartiallyParsedIfPossible
        options.allowsExtendedAttributes = true
        do {
            return try AttributedString(markdown: text, options: options)
        } catch {
            return AttributedString(text)
        }
    }

    // MARK: Lines

    private static func lines(of text: String) -> [String] {
        let unix = text.replacingOccurrences(of: "\r\n", with: "\n")
        return withoutFrontMatter(unix).split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    }

    /// Hides a leading YAML block (`---`, a `key:` line, more lines, `---` or `...`). A reply
    /// that merely starts with a rule is left alone, as is a block that never closes.
    static func withoutFrontMatter(_ text: String) -> String {
        // Runs for every streamed update, so the common path should exit early.
        let body = text.hasPrefix("\u{FEFF}") ? String(text.dropFirst()) : text
        guard body.hasPrefix("---") else { return text }

        var remaining = body.split(separator: "\n", omittingEmptySubsequences: false)[...]
        func shut(_ line: Substring) -> Bool { ["---", "..."].contains(line.trimmingCharacters(in: .whitespaces)) }
        guard remaining.count > 2, remaining.removeFirst().trimmingCharacters(in: .whitespaces) == "---",
              remaining.first?.range(of: #"^[A-Za-z0-9_-]+\s*:"#, options: .regularExpression) != nil else {
            return text
        }
        while let line = remaining.popFirst() {
            if shut(line) { return remaining.joined(separator: "\n") }
        }
        return text
    }

    // MARK: Line shapes

    /// Width of the leading whitespace, a tab counting as four.
    static func indentWidth(_ line: String) -> Int {
        line.prefix { $0 == " " || $0 == "\t" }.reduce(0) { $0 + ($1 == "\t" ? 4 : 1) }
    }

    static func bulletText(_ line: String) -> String? {
        guard ["- ", "* ", "+ "].contains(where: line.hasPrefix) else { return nil }
        return line.dropFirst(2).trimmingCharacters(in: .whitespaces)
    }

    /// "12. words" or "3) words": the number and the words after it.
    static func numberedText(_ line: String) -> (number: Int, text: String)? {
        let end = line.firstIndex { !($0.isASCII && $0.isNumber) } ?? line.endIndex
        let count = line.distance(from: line.startIndex, to: end)
        guard count >= 1, count <= 9 else { return nil }
        let rest = line[end...]
        guard rest.hasPrefix(". ") || rest.hasPrefix(") ") else { return nil }
        return (Int(line[..<end]) ?? 1, rest.dropFirst(2).trimmingCharacters(in: .whitespaces))
    }

    /// The pieces of an image line, in the order they are matched.
    private static let imageLine: NSRegularExpression = {
        let opening = #"(\[)?"#
        let picture = #"!\[([^\]]*)\]\(\s*([^)\s]+)(?:\s+"[^"]*")?\s*\)"#
        let closing = #"(?:\]\(\s*([^)\s]+)\s*\))?"#
        return try! NSRegularExpression(pattern: "^" + opening + picture + closing + "$")
    }()

    /// `![alt](src "title")`, or that wrapped as `[![alt](src)](href)`, alone on its line.
    static func imageOnly(_ line: String) -> (alt: String, url: String, link: String?)? {
        guard line.contains("![") else { return nil }
        let whole = NSRange(line.startIndex..., in: line)
        guard let hit = imageLine.firstMatch(in: line, range: whole) else { return nil }
        func part(_ index: Int) -> String? { Range(hit.range(at: index), in: line).map { String(line[$0]) } }
        // A link that is opened must be closed, and the other way round.
        guard (part(1) != nil) == (part(4) != nil) else { return nil }
        return (part(2) ?? "", part(3) ?? "", part(4))
    }

    /// The cells of a table row. `\|` and pipes inside backticks do not split. A backslash
    /// before anything but a pipe stays, for the inline parser.
    static func rowCells(_ row: String) -> [String] {
        let line = row.trimmingCharacters(in: .whitespaces)
        var splitter = CellSplitter()
        for char in line { splitter.take(char) }
        var cells = splitter.finish()
        // What stood before a leading pipe and after a closing one is not a cell.
        if line.hasPrefix("|") { cells.removeFirst() }
        if line.hasSuffix("|"), !line.hasSuffix("\\|"), !cells.isEmpty { cells.removeLast() }
        return cells.map { $0.trimmingCharacters(in: .whitespaces) }
    }

    /// Cuts a row at its pipes, one character at a time.
    private struct CellSplitter {
        private var done: [String] = []
        private var open = ""
        private var insideCode = false
        private var escaping = false

        mutating func take(_ char: Character) {
            if escaping {
                escaping = false
                // Only a pipe loses its backslash; any other escape is for the inline parser.
                open += char == "|" ? "|" : "\\\(char)"
            } else if char == "\\" {
                escaping = true
            } else if char == "|" && !insideCode {
                done.append(open)
                open = ""
            } else {
                if char == "`" { insideCode.toggle() }
                open.append(char)
            }
        }

        mutating func finish() -> [String] {
            if escaping { open += "\\" }
            return done + [open]
        }
    }

    /// Column alignments if `line` is a delimiter row such as `|:--|:-:|--:|`.
    static func delimiterAlignments(_ line: String) -> [MarkdownColumnAlignment]? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.contains("-"), trimmed.contains("|"), trimmed.allSatisfy({ "|-: \t".contains($0) }) else {
            return nil
        }
        let cells = rowCells(trimmed)
        let kinds = cells.compactMap { cell -> MarkdownColumnAlignment? in
            let dashes = cell.drop { $0 == ":" }.reversed().drop { $0 == ":" }
            guard !dashes.isEmpty, dashes.allSatisfy({ $0 == "-" }) else { return nil }
            switch (cell.first == ":", cell.last == ":") {
            case (true, true): return .center
            case (_, true): return .trailing
            default: return .leading
            }
        }
        return !cells.isEmpty && kinds.count == cells.count ? kinds : nil
    }
}

// MARK: Reading blocks

/// Walks the lines once, collecting runs of paragraph, list and quote lines until something
/// ends them.
private struct BlockReader {
    let lines: [String]
    private var position = 0
    private var blocks: [MarkdownBlock] = []

    private var paragraph: [String] = []
    private var quote: [String] = []
    private var list = ListBuilder()
    private var code: OpenFence?

    private struct OpenFence {
        var marker: String
        var language: String?
        var lines: [String] = []
    }

    init(lines: [String]) { self.lines = lines }

    mutating func run() -> [MarkdownBlock] {
        while position < lines.count {
            let line = lines[position]
            position += 1
            handle(line, trimmed: line.trimmingCharacters(in: .whitespaces))
        }
        if let open = code {
            blocks.append(.code(language: open.language, text: open.lines.joined(separator: "\n"), closed: false))
        }
        endRuns()
        return blocks
    }

    private mutating func handle(_ line: String, trimmed: String) {
        if code != nil {
            if trimmed.hasPrefix(code!.marker) {
                blocks.append(.code(language: code!.language, text: code!.lines.joined(separator: "\n"), closed: true))
                code = nil
            } else {
                // Append to the existing array. Copying the lines for every row made long blocks cost quadratic
                // time on each streaming redraw.
                code!.lines.append(line)
            }
            return
        }
        if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
            endRuns()
            let language = trimmed.dropFirst(3).trimmingCharacters(in: .whitespaces)
            code = OpenFence(marker: String(trimmed.prefix(3)), language: language.isEmpty ? nil : language)
            return
        }
        if trimmed.isEmpty { endRuns(); return }
        if ["---", "***", "___"].contains(trimmed) {
            endRuns()
            blocks.append(.rule)
            return
        }
        if let heading = Self.heading(in: trimmed) {
            endRuns()
            blocks.append(heading)
            return
        }
        if let picture = MarkdownParser.imageOnly(trimmed) {
            endRuns()
            blocks.append(.image(alt: picture.alt, url: picture.url, link: picture.link))
            return
        }
        if let table = tableStarting(with: trimmed) {
            endRuns()
            blocks.append(.table(table))
            return
        }

        let indent = MarkdownParser.indentWidth(line)
        if let text = MarkdownParser.bulletText(trimmed) {
            endParagraph()
            endQuote()
            if let done = list.add(indent: indent, ordered: false, number: nil, text: text) { blocks.append(.list(done)) }
        } else if let item = MarkdownParser.numberedText(trimmed) {
            endParagraph()
            endQuote()
            if let done = list.add(indent: indent, ordered: true, number: item.number, text: item.text) {
                blocks.append(.list(done))
            }
        } else if trimmed.hasPrefix(">") {
            endParagraph()
            flushList()
            quote.append(trimmed.dropFirst().trimmingCharacters(in: .whitespaces))
        } else if list.hasItems, indent >= 2 {
            list.extendLast(with: trimmed)
        } else {
            flushList()
            endQuote()
            paragraph.append(line)
        }
    }

    private static func heading(in line: String) -> MarkdownBlock? {
        let level = line.prefix { $0 == "#" }.count
        guard (1...6).contains(level), line.dropFirst(level).hasPrefix(" ") else { return nil }
        return .heading(level: level, text: line.dropFirst(level).trimmingCharacters(in: .whitespaces))
    }

    /// A table only counts once its delimiter row is there, so a lone header line is a paragraph until
    /// the next line comes in. Also consumes the body rows, advancing `position` beyond them.
    private mutating func tableStarting(with headerLine: String) -> MarkdownTable? {
        guard headerLine.contains("|"), position < lines.count,
              let alignments = MarkdownParser.delimiterAlignments(lines[position]) else { return nil }
        let header = MarkdownParser.rowCells(headerLine)
        guard header.count == alignments.count else { return nil }
        position += 1
        var rows: [[String]] = []
        while position < lines.count {
            let text = lines[position].trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty, text.contains("|") else { break }
            var cells = MarkdownParser.rowCells(text)
            if cells.count < header.count { cells += [String](repeating: "", count: header.count - cells.count) }
            rows.append(Array(cells.prefix(header.count)))
            position += 1
        }
        return MarkdownTable(header: header, alignments: alignments, rows: rows)
    }

    // MARK: Ending runs

    private mutating func endParagraph() {
        guard !paragraph.isEmpty else { return }
        blocks.append(.paragraph(paragraph.joined(separator: "\n")))
        paragraph = []
    }

    private mutating func endQuote() {
        guard !quote.isEmpty else { return }
        blocks.append(.quote(quote.joined(separator: "\n")))
        quote = []
    }

    private mutating func flushList() {
        if let items = list.finish() { blocks.append(.list(items)) }
    }

    private mutating func endRuns() {
        endParagraph()
        flushList()
        endQuote()
    }
}

/// Builds a list item by item. Depth is read off the leading indentation; numbering counts the
/// earlier items at the same depth.
private struct ListBuilder {
    private var items: [MarkdownListItem] = []
    private var ordered = false
    private var indents: [Int] = []
    private var counts: [Int: Int] = [:]
    private static let deepest = 6

    var hasItems: Bool { !items.isEmpty }

    /// Adds an item. When it starts a different kind of list at the top level, the list so far
    /// is closed and returned.
    @discardableResult
    mutating func add(indent: Int, ordered isOrdered: Bool, number: Int?, text: String) -> [MarkdownListItem]? {
        let closed = (hasItems && ordered != isOrdered && indent <= (indents.first ?? 0)) ? finish() : nil
        if items.isEmpty { ordered = isOrdered }

        let depth = depth(forIndent: indent)
        let (marker, body) = isOrdered
            ? (numbered(at: depth, startingFrom: number), text)
            : bulleted(at: depth, text)
        items.append(MarkdownListItem(depth: depth, marker: marker, text: body))
        return closed
    }

    /// Works out how far in an item is: deeper than anything open, or back at a level seen.
    private mutating func depth(forIndent indent: Int) -> Int {
        indents.removeAll { $0 > indent }
        if indents.last != indent { indents.append(indent) }
        let depth = Swift.min(indents.count - 1, Self.deepest)
        counts = counts.filter { $0.key <= depth }
        return depth
    }

    private mutating func numbered(at depth: Int, startingFrom first: Int?) -> MarkdownListItem.Marker {
        let value = (counts[depth] ?? ((first ?? 1) - 1)) + 1
        counts[depth] = value
        return .number(value)
    }

    /// A bullet, or a task when the words start with a `[ ]` or `[x]` box.
    private mutating func bulleted(at depth: Int, _ text: String) -> (MarkdownListItem.Marker, String) {
        counts[depth] = nil
        let start = text.lowercased().prefix(3)
        let boxed = (start == "[ ]" || start == "[x]") && (text.count == 3 || text.dropFirst(3).first == " ")
        guard boxed else { return (.bullet, text) }
        return (.task(checked: start == "[x]"), text.dropFirst(3).trimmingCharacters(in: .whitespaces))
    }

    mutating func extendLast(with text: String) {
        items[items.count - 1].text += " " + text
    }

    /// The finished list, if there is one, and a clean slate.
    mutating func finish() -> [MarkdownListItem]? {
        defer { items = []; indents = []; counts = [:] }
        return items.isEmpty ? nil : items
    }
}
