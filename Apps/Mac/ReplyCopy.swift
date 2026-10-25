import NollieCore
import SwiftUI

extension TranscriptMedia {
    /// Copy puts the reply on the pasteboard exactly as written.
    static func copyText(_ text: String) -> String { text }
}

/// The small copy button that sits beside a reply bubble.
private struct CopyReplyButton: View {
    var copied: Bool
    var shown: Bool
    var enabled: Bool
    var action: () -> Void

    private var words: String { copied ? "Copied" : "Copy reply" }
    private var symbol: String { copied ? "checkmark" : "doc.on.doc" }
    private var tint: Color { copied ? .green : .secondary }

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .foregroundStyle(tint)
                .font(.system(.caption, weight: .semibold))
                .frame(square: 28)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help(words)
        .accessibilityLabel(words)
        .accessibilityIdentifier("message.copy")
        .accessibilityHidden(!enabled)
        .opacity(shown ? 1 : 0)
        .allowsHitTesting(shown)
    }
}

/// Puts a copy button next to a reply. The bubble and the button share one hover area, so the
/// button stays put while the pointer travels to it, and it has its own gap beside the bubble.
struct ReplyCopyHover: ViewModifier {
    @State private var copiedAt: Date? = nil
    @State private var hovering: Bool = false
    private let text: String
    private let enabled: Bool

    init(text: String, enabled: Bool) {
        self.text = text
        self.enabled = enabled
    }

    func body(content: Content) -> some View {
        let copied = copiedAt != nil
        return HStack(alignment: .bottom, spacing: 4) {
            content
            CopyReplyButton(copied: copied, shown: enabled && (hovering || copied), enabled: enabled, action: copy)
        }
        .contentShape(.rect)
        .onHover { hovering = $0 }
        // The tick fades 1.5 seconds after the latest copy.
        .task(id: copiedAt) {
            guard copiedAt != nil else { return }
            try? await Task.sleep(for: .seconds(1.5))
            if !Task.isCancelled { copiedAt = nil }
        }
    }

    private func copy() {
        UIPasteboard.general.string = TranscriptMedia.copyText(text)
        copiedAt = Date()
    }
}
