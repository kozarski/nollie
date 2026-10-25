import SwiftUI

/// The round down-arrow that appears over a thread once it has been scrolled up from the bottom.
struct JumpToBottomButton: View {
    let visible: Bool
    let action: () -> Void

    var body: some View {
        ZStack {
            if visible {
                GlassCircleButton(symbol: "chevron.down", diameter: 38, action: action)
                    .transition(.opacity.combined(with: .scale))
                    .accessibilityLabel("Jump to latest")
            }
        }
    }
}

// MARK: Picking out part of a message

#if os(macOS)
/// SwiftUI's selectable text already lets people select a range on the Mac.
struct SelectableText: View {
    var text: String

    private var face: Font {
        guard monospaced else { return .body }
        return .system(.footnote, design: .monospaced)
    }

    var monospaced = false

    var body: some View {
        ScrollView {
            Text(text)
                .font(face)
                .padding(12)
                .spread()
                .textSelection(.enabled)
        }
        .frame(minWidth: 420).frame(minHeight: 320)
    }
}
#else
/// Selectable by range, with drag handles and UIKit's Copy and Look Up menu. The SwiftUI
/// equivalent can only select the string as a whole.
struct SelectableText: UIViewRepresentable {
    var text: String

    private var bodyFont: UIFont {
        if !monospaced { return .preferredFont(forTextStyle: .body) }
        let size = UIFont.preferredFont(forTextStyle: .footnote).pointSize
        return .monospacedSystemFont(ofSize: size, weight: .regular)
    }

    var monospaced = false

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.isEditable = false
        view.isSelectable = true
        view.alwaysBounceVertical = true
        view.dataDetectorTypes = .link
        view.adjustsFontForContentSizeCategory = true
        view.backgroundColor = .clear
        view.textContainerInset = UIEdgeInsets(top: 12, left: 12, bottom: 24, right: 12)
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        view.textColor = .label
        view.font = bodyFont
        if view.text != text { view.text = text }
    }
}
#endif

/// A message as plain text that can be selected in part and copied.
struct SelectTextSheet: View {
    var text: String

    var body: some View {
        NavigationStack {
            SelectableText(text: text)
                .toolbar { SelectTextBar(text: text) }
                .navigationBarTitleDisplayMode(.inline)
                .navigationTitle("Select Text")
        }
    }
}

private struct SelectTextBar: ToolbarContent {
    var text: String
    @Environment(\.dismiss) private var dismiss

    var body: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Button(action: copyAll) {
                Label("Copy all", systemImage: "doc.on.doc")
            }
        }
        ToolbarItem(placement: .cancellationAction) {
            Button("Done", action: { dismiss() })
        }
    }

    private func copyAll() {
        UIPasteboard.general.string = text
    }
}
