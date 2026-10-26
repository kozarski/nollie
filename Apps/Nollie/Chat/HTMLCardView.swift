import SwiftUI

/// An HTML card as it sits in the thread: it grows with its page up to a cap, says so while
/// the page is still drawing, and can open full screen, show its source or copy it.
struct HTMLCardView: View {
    @Environment(\.colorScheme) private var scheme
    var html: String
    @State private var ready = false
    @State private var failed = false
    @State private var measured: CGFloat = 96
    /// The thread's Show Source, offered in the card's menu.
    var onShowSource: (() -> Void)? = nil
    @State private var showingFull = false
    /// Each live web view holds a web process, so only cards near the screen keep one.
    @State private var onScreen = true
    @State private var leaveTimer: Task<Void, Never>?

    /// How long a card that scrolled away keeps its web view, so a quick scroll back is free.
    static let awayGrace: TimeInterval = 4

    private let corner: CGFloat = 12
    private var cap: CGFloat { HTMLCard.heightCap }
    private var shownHeight: CGFloat { min(max(measured, 48), cap) }
    private var page: String { CardPage.make(html, dark: scheme == .dark) }
    private var paper: Color { Color(.secondarySystemBackground) }
    private var overflows: Bool { ready && measured > cap }

    var body: some View {
        ZStack(alignment: .topLeading) {
            content
        }
        .spread()
        .background(paper, in: .rect(cornerRadius: corner))
        .clipShape(.rect(cornerRadius: corner))
        .onScrollVisibilityChange(threshold: 0.05) { visible in
            visible ? comeBack() : startLeaving()
        }
        .overlay(alignment: .topTrailing) { fullScreenButton }
        .overlay(alignment: .bottom) { if overflows { fadeOut } }
        .animation(.snappy, value: ready)
        .sheet(isPresented: $showingFull) { HTMLCardSheet(html: html).sheetFrame(.wide).withAppModel() }
    }

    @ViewBuilder private var content: some View {
        if failed {
            CardNotDrawn(html: html)
        } else if onScreen {
            HTMLWebView(document: page, scrolls: false, height: $measured, loaded: $ready, failed: $failed, actions: menu)
                .frame(height: shownHeight)
                .opacity(ready ? 1 : 0.01)
            if !ready { DrawingLabel() }
        } else {
            Color.clear.frame(height: shownHeight)
        }
    }

    private var menu: HTMLCard.Actions {
        .init(copy: { CardPage.copy(html) }, full: { showingFull = true }, showSource: onShowSource)
    }

    /// A soft edge that tells the reader the card goes on past the cap.
    private var fadeOut: some View {
        LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: paper, location: 1)],
                       startPoint: .top, endPoint: .bottom)
            .allowsHitTesting(false)
            .frame(height: 28)
    }

    private var fullScreenButton: some View {
        PlainButton { showingFull = true } label: {
            Glyph("arrow.up.left.and.arrow.down.right", .caption.weight(.semibold))
                .padding(7)
                .background(Circle().fill(.thinMaterial))
        }
        .padding(6)
        .accessibilityLabel("Open the card full screen")
        .opacity(ready ? 1 : 0)
    }

    private func comeBack() {
        leaveTimer?.cancel()
        leaveTimer = nil
        onScreen = true
    }

    private func startLeaving() {
        leaveTimer?.cancel()
        let wait = Duration.milliseconds(Int(Self.awayGrace * 1000))
        leaveTimer = Task { @MainActor in
            try? await Task.sleep(for: wait)
            guard !Task.isCancelled else { return }
            ready = false
            onScreen = false
        }
    }
}

/// Shared by the inline card and the full screen sheet.
@MainActor private enum CardPage {
    static func make(_ html: String, dark: Bool) -> String {
        HTMLCard.document(html, dark: dark, background: HTMLCard.pageBackground(dark: dark))
    }

    static func copy(_ html: String) { UIPasteboard.general.string = html }
}

/// What a card shows when it can't be drawn safely: a short line and its source as plain text.
struct CardNotDrawn: View {
    var html: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("This card can't be shown right now.").quiet(.caption)
            Text(html)
                .font(.system(.footnote, design: .monospaced))
                .textSelection(.enabled)
                .lineLimit(12)
        }
        .padding(12)
        .spread(.leading)
        .accessibilityIdentifier("card.notDrawn")
    }
}

private struct DrawingLabel: View {
    var body: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text("Drawing the card…").quiet(.caption)
        }
        .padding(12)
    }
}

/// The card shown alone on its own page, scrollable, with its source one tap away.
struct HTMLCardSheet: View {
    @State private var viewingSource = false
    @Environment(\.colorScheme) private var scheme
    var html: String
    @State private var ready = false
    @Environment(\.dismiss) private var dismiss
    @State private var measured: CGFloat = 0
    @State private var failed = false

    var body: some View {
        NavigationStack {
            page
                .navigationTitle("Card")
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
                .toolbar {
                    ToolbarItem(placement: .primaryAction) { optionsMenu }
                    ToolbarItem(placement: .cancellationAction) { doneButton }
                }
        }
    }

    private var doneButton: some View {
        Button("Done", action: { dismiss() })
    }

    @ViewBuilder private var page: some View {
        if viewingSource || failed {
            ScrollView {
                Text(html)
                    .textSelection(.enabled)
                    .font(.system(.footnote, design: .monospaced))
                    .padding()
                    .spread()
            }
        } else {
            HTMLWebView(document: CardPage.make(html, dark: scheme == .dark), scrolls: true, height: $measured, loaded: $ready, failed: $failed)
                .ignoresSafeArea(edges: .bottom)
        }
    }

    private var optionsMenu: some View {
        Menu {
            Button { viewingSource.toggle() } label: {
                Label(viewingSource ? "Show Card" : "Show Source",
                      systemImage: viewingSource ? "rectangle.on.rectangle" : "chevron.left.forwardslash.chevron.right")
            }
            Button { CardPage.copy(html) } label: { Label("Copy HTML", systemImage: "doc.on.doc") }
        } label: { Label("Card options", systemImage: "ellipsis.circle") }
    }
}
