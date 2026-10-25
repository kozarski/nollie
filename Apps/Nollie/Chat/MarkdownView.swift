import NollieCore
import SwiftUI

/// Shows markdown as a stack of blocks, with the parser's inline styling inside each.
struct MarkdownView: View, Equatable {
    var text: String
    var style: Style = .reply
    /// Whether text can be selected right where it is. iPhone chat bubbles switch it off; see
    /// `selectable`.
    var inlineSelection = true

    /// The look given to blocks. Replies follow the thread's text size and colour. Reasoning cards
    /// use footnote type in the secondary colour with small headings, and keep html fences as plain
    /// code, because a model's private notes should not turn into a live web card.
    enum Style: Equatable {
        case reply, reasoning

        var showsCards: Bool { self == .reply }
        var codeFont: Font { showsCards ? Ink.codeBlock : .system(.caption, design: .monospaced) }
    }

    /// Positions of html cards that are currently showing their source.
    @State private var sourceShown: Set<Int> = []

    static func == (a: MarkdownView, b: MarkdownView) -> Bool {
        guard a.text == b.text else { return false }
        return a.style == b.style && a.inlineSelection == b.inlineSelection
    }

    static func blocks(_ text: String) -> [MarkdownBlock] { MarkdownCaches.blocks.value(for: text) }
    static func inline(_ text: String) -> AttributedString { MarkdownCaches.inline.value(for: text) }

    private var stack: some View {
        let parsed = Self.blocks(text)
        return VStack(alignment: .leading, spacing: style == .reasoning ? 6 : 8) {
            ForEach(Array(parsed.enumerated()), id: \.offset) { slot in
                MarkdownBlockView(block: slot.element, position: slot.offset, style: style, sourceShown: $sourceShown)
            }
        }
    }

    var body: some View {
        let _ = Perf.tick("markdown")
        // No font is set on a reply, so the text size chosen for the thread carries through.
        switch style {
        case .reply:
            selectable(stack)
        case .reasoning:
            selectable(stack).foregroundStyle(.secondary).font(.footnote)
        }
    }

    /// Text can be selected where it sits, except inside an iPhone chat bubble: there, selection
    /// swallowed the taps meant for neighbouring content, so a Reasoning card over a reply would
    /// not toggle. In that case use Select Text from the bubble menu. The Mac selects in place.
    @ViewBuilder private func selectable(_ content: some View) -> some View {
        #if os(macOS)
        content.textSelection(.enabled)
        #else
        if inlineSelection { content.textSelection(.enabled) } else { content }
        #endif
    }
}

/// Parsed and styled results are remembered per text, so a row scrolling off and back skips the
/// work. Both caches are limited in count and in bytes: streaming adds an entry for every token,
/// and a lengthy report once piled up hundreds, each carrying the reply so far two times over.
@MainActor private enum MarkdownCaches {
    static let blocks = Memo<[MarkdownBlock]>(count: 400, bytes: 4_000_000, make: MarkdownParser.blocks(from:))
    static let inline = Memo<AttributedString>(count: 2000, bytes: 2_000_000, make: MarkdownParser.inline)
}

/// A size-limited cache of something derived from a text.
private final class Memo<Value> {
    private final class Box { let value: Value; init(_ value: Value) { self.value = value } }

    private let cache = NSCache<NSString, Box>()
    private let derive: (String) -> Value

    init(count: Int, bytes: Int, make: @escaping (String) -> Value) {
        cache.countLimit = count
        cache.totalCostLimit = bytes
        derive = make
    }

    func value(for text: String) -> Value {
        let key = text as NSString
        if let box = cache.object(forKey: key) { return box.value }
        let fresh = derive(text)
        cache.setObject(Box(fresh), forKey: key, cost: text.utf8.count)
        return fresh
    }
}

// MARK: - Heading fonts

extension MarkdownView {
    /// Levels 1 and 2 keep their familiar sizes; levels 3 to 6 shrink in turn so all stay apart.
    static func headingFont(_ level: Int) -> Font { Ink.heading(level) }

    /// Reasoning cards keep headings near their footnote size. A title-sized heading in the notes
    /// would shout over the reply beneath.
    static func headingFont(_ level: Int, style: Style) -> Font {
        if style != .reasoning { return headingFont(level) }
        let quiet: [Font] = [
            .subheadline.weight(.bold), .subheadline.weight(.semibold), .footnote.weight(.bold), .footnote.weight(.semibold),
        ]
        return quiet[min(max(level, 1), quiet.count) - 1]
    }
}

/// A single block of a reply.
private struct MarkdownBlockView: View {
    var block: MarkdownBlock
    var position: Int
    var style: MarkdownView.Style
    @Binding var sourceShown: Set<Int>

    var body: some View {
        switch block {
        case .paragraph(let words):
            // Never clipped: a reply under an expanded Reasoning card on the Mac once showed just
            // the first line of its final paragraph.
            prose(words)
        case .heading(let level, let words):
            prose(words).font(MarkdownView.headingFont(level, style: style))
        case .code(let language, let code, let closed):
            if showsAsCard(language, closed: closed) {
                card(code)
            } else {
                MarkdownCodeBlock(language: language, code: code, closed: closed, style: style,
                                  isHTML: isHTML(language, closed: closed), onShowCard: hideSource)
            }
        case .list(let items):
            MarkdownListView(items: items)
        case .rule:
            Divider()
        case .quote(let words):
            HStack(spacing: 10) {
                Capsule().fill(.secondary).frame(width: 3)
                prose(words).foregroundStyle(.secondary)
            }
        case .image(let alt, let url, let link):
            MarkdownImageView(alt: alt, url: url, link: link)
        case .table(let table):
            MarkdownTableView(table: table)
        }
    }

    private func prose(_ words: String) -> some View {
        Text(MarkdownView.inline(words)).fixedSize(horizontal: false, vertical: true)
    }

    private func isHTML(_ language: String?, closed: Bool) -> Bool {
        style.showsCards && closed && HTMLCard.isCard(language: language)
    }

    /// An html fence becomes a card once it has closed. While text still streams in it is a code
    /// block, and Show Source turns a card back into one.
    private func showsAsCard(_ language: String?, closed: Bool) -> Bool {
        isHTML(language, closed: closed) && !sourceShown.contains(position)
    }

    private func showSource() { withAnimation(.snappy) { _ = sourceShown.insert(position) } }
    private func hideSource() { withAnimation(.snappy) { _ = sourceShown.remove(position) } }

    private func card(_ code: String) -> some View {
        HTMLCardView(html: code, onShowSource: showSource)
            .contextMenu {
                Button("Show Source", systemImage: "chevron.left.forwardslash.chevron.right", action: showSource)
                Button("Copy HTML", systemImage: "doc.on.doc") { UIPasteboard.general.string = code }
            }
    }
}

/// A fenced block of code. Lines wrap rather than scroll, since code is read top to bottom and
/// copied in one go; only tables slide sideways (the time reveal yields to them). Copy sits at the
/// top corner.
private struct MarkdownCodeBlock: View {
    var language: String?
    var code: String
    var closed: Bool
    var style: MarkdownView.Style
    var isHTML: Bool
    var onShowCard: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            topBar
            Text(code)
                .padding(10)
                .font(style.codeFont)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
        .spread()
        .background(Color(.secondarySystemBackground), in: .rect(cornerRadius: 16, style: .continuous))
    }

    private var topBar: some View {
        HStack {
            if let language, !language.isEmpty { Text(language).quiet(.caption2) }
            Spacer(minLength: 0)
            if isHTML { showCardButton }
            if !closed {
                ProgressView().controlSize(.mini)
            } else {
                CopyButton(text: code)
            }
        }
        .inset(h: 10)
        .padding(.top, 6)
    }

    private var showCardButton: some View {
        PlainButton(action: onShowCard) {
            Label("Show Card", systemImage: "rectangle.on.rectangle").font(.caption2).labelStyle(.titleAndIcon)
        }
        .foregroundStyle(.tint)
        .padding(.trailing, 6)
    }
}

private struct MarkdownListView: View {
    var items: [MarkdownListItem]

    private static let bullets = ["•", "◦"]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(items.indices, id: \.self) { index in
                row(items[index])
            }
        }
    }

    private func row(_ item: MarkdownListItem) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            marker(for: item)
            Text(MarkdownView.inline(item.text)).fixedSize(horizontal: false, vertical: true)
        }
        .padding(.leading, CGFloat(item.depth) * 18)
    }

    @ViewBuilder private func marker(for item: MarkdownListItem) -> some View {
        switch item.marker {
        case .bullet:
            Text(item.depth < Self.bullets.count ? Self.bullets[item.depth] : "▪")
        case .number(let number):
            Text(verbatim: "\(number).").monospacedDigit()
        case .task(let checked):
            taskMark(done: checked)
        }
    }

    private func taskMark(done: Bool) -> some View {
        let symbol = done ? "checkmark.square.fill" : "square"
        let tint: Color = done ? .accentColor : .secondary
        return Image(systemName: symbol)
            .accessibilityLabel(done ? "Done" : "Not done")
            .foregroundStyle(tint)
    }
}
