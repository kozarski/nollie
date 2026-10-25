#if !os(macOS)
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// The phone composer's typing surface: a UIKit text view inside a SwiftUI wrapper. A stock
/// TextField gave up Paste on the phone and skipped pictures on the pasteboard, so the keyboard lost
/// "Paste from Screenshots". This one names the types it takes. Text goes
/// into the field. Images, video and documents go to `onPasteData` to become attachments. The
/// field begins one line tall, grows to `maxLines`, and scrolls past that.
struct ComposerTextView: UIViewRepresentable {
    static let acceptedTypes: [UTType] = [.image, .movie, .pdf, .audio] + [.plainText, .text, .fileURL, .data]

    @Binding var text: String
    let placeholder: String
    @Binding var focused: Bool
    var maxLines = 6
    var accessibilityID: String?
    /// Called for Return or the Send key when the field has something in it.
    var onSend: () -> Void = { () in }
    /// Receives a pasted image, video or document, named with the extension of its type.
    var onPasteData: @MainActor @Sendable (Data, String, UTType) -> Void = { (_: Data, _: String, _: UTType) in }
    /// Hardware Up (-1) and Down (1) keys for stepping through history. Return true if handled.
    var onArrow: (Int) -> Bool = { (_: Int) in false }
    /// The Settings switch that makes the on-screen Return send, rather than add a line.
    var returnSends = false

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeUIView(context: Context) -> PasteTextView {
        let field = PasteTextView()
        field.delegate = context.coordinator
        field.pasteDelegate = context.coordinator
        field.coordinator = context.coordinator
        field.pasteConfiguration = UIPasteConfiguration(acceptableTypeIdentifiers: Self.acceptedTypes.map(\.identifier))
        field.accessibilityIdentifier = accessibilityID
        Self.applyLook(to: field)
        applyReturnKey(to: field)
        field.placeholderLabel.text = placeholder
        show(text, in: field)
        return field
    }

    /// Plain styling: body type, no inner padding, clear background, scrolling off until needed.
    private static func applyLook(to field: PasteTextView) {
        field.font = .preferredFont(forTextStyle: .body)
        field.adjustsFontForContentSizeCategory = true
        field.backgroundColor = .clear
        field.textContainerInset = .zero
        field.textContainer.lineFragmentPadding = 0
        field.isScrollEnabled = false
        field.alwaysBounceVertical = false
        field.showsVerticalScrollIndicator = true
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
    }

    private var returnKey: UIReturnKeyType { returnSends ? .send : .default }

    /// The key reads "return" and adds a line, unless the setting turns it into Send.
    private func applyReturnKey(to field: UITextView) {
        field.returnKeyType = returnKey
        field.enablesReturnKeyAutomatically = returnSends
    }

    private func show(_ words: String, in field: PasteTextView) {
        field.text = words
        field.placeholderLabel.isHidden = !words.isEmpty
    }

    func updateUIView(_ field: PasteTextView, context: Context) {
        context.coordinator.parent = self
        if field.text != text { show(text, in: field) }
        if field.placeholderLabel.text != placeholder { field.placeholderLabel.text = placeholder }
        if field.returnKeyType != returnKey {
            applyReturnKey(to: field)
            field.reloadInputViews()
        }
        matchFocus(of: field)
    }

    /// Brings the keyboard up or down to match the binding, on the next pass of the run loop.
    private func matchFocus(of field: PasteTextView) {
        let hasFocus = field.isFirstResponder
        if focused && !hasFocus && field.window != nil {
            DispatchQueue.main.async { field.becomeFirstResponder() }
        } else if !focused && hasFocus {
            DispatchQueue.main.async { field.resignFirstResponder() }
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView field: PasteTextView, context: Context) -> CGSize? {
        let width = proposal.width ?? field.bounds.width
        guard width > 0 else { return nil }
        let lineHeight = field.font?.lineHeight ?? 22
        let tallest = ceil(lineHeight * CGFloat(maxLines))
        let natural = field.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height
        // Past the limit the text scrolls inside a field of the limit's height.
        let needsScroll = natural > tallest + 1
        if field.isScrollEnabled != needsScroll { field.isScrollEnabled = needsScroll }
        return CGSize(width: width, height: ceil(natural.clamped(to: lineHeight...tallest)))
    }
}

private extension CGFloat {
    func clamped(to range: ClosedRange<CGFloat>) -> CGFloat { Swift.min(Swift.max(self, range.lowerBound), range.upperBound) }
}

extension ComposerTextView {
    final class Coordinator: NSObject, UITextPasteDelegate, UITextViewDelegate {
        var parent: ComposerTextView

        init(parent: ComposerTextView) {
            self.parent = parent
            super.init()
        }

        private func sendIfAnyWords(in field: UITextView) {
            let words = field.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !words.isEmpty { parent.onSend() }
        }

        // MARK: Text and focus

        func textViewDidChange(_ field: UITextView) {
            (field as? PasteTextView)?.placeholderLabel.isHidden = !field.text.isEmpty
            if parent.text != field.text { parent.text = field.text }
        }

        func textViewDidBeginEditing(_ field: UITextView) {
            if !parent.focused { parent.focused = true }
        }

        func textViewDidEndEditing(_ field: UITextView) {
            if parent.focused { parent.focused = false }
        }

        // MARK: Return

        func textView(_ field: UITextView, shouldChangeTextIn range: NSRange, replacementText typed: String) -> Bool {
            // Only a line break needs a decision. On the on-screen keyboard it sends or breaks the line;
            // a hardware Return comes in through the key commands instead.
            guard typed == "\n" else { return true }
            if let remembered = (field as? PasteTextView)?.takeComposedReturn() {
                return finishComposedReturn(remembered, in: field)
            }
            let action = ComposerReturnRule.action(hardware: false, shift: false, command: false,
                                                   returnSends: parent.returnSends)
            if action == .send { sendIfAnyWords(in: field) }
            return action == .newline
        }

        /// Some input methods swallow a hardware Return and hand it back as a line break after their
        /// text lands (Korean does). That break is treated as a hardware Return, and Shift keeps it.
        private func finishComposedReturn(_ held: (shift: Bool, command: Bool), in field: UITextView) -> Bool {
            if !held.shift { hardwareReturn(field, shift: false, command: held.command) }
            return held.shift
        }

        /// Hardware Return: sends or adds a line, depending on Shift and Command.
        func hardwareReturn(_ field: UITextView, shift: Bool, command: Bool) {
            let action = ComposerReturnRule.action(hardware: true, shift: shift, command: command,
                                                   returnSends: parent.returnSends)
            switch action {
            case .newline: field.insertText("\n")
            case .send: sendIfAnyWords(in: field)
            }
        }

        // MARK: Pasting

        func textPasteConfigurationSupporting(_ target: any UITextPasteConfigurationSupporting,
                                              transform item: any UITextPasteItem) {
            let provider = item.itemProvider
            guard !PastedAttachment.isPlainText(provider), let kind = Self.attachmentKind(of: provider) else {
                item.setDefaultResult()
                return
            }
            let exact = PastedAttachment.concreteType(of: provider, fitting: kind)
            let stem = kind == .audio ? "audio" : "pasted"
            let name = PastedAttachment.fileName(for: kind, concrete: exact, fallbackStem: stem)
            let deliver = parent.onPasteData
            provider.loadDataRepresentation(forTypeIdentifier: exact.identifier) { data, _ in
                guard let data, !data.isEmpty else { return }
                Task { @MainActor in deliver(data, name, exact) }
            }
            item.setNoResult()
        }

        /// The kind of attachment a pasted item is: picture, movie, PDF or sound first, otherwise
        /// the first type it offers that is neither text nor a file address.
        private static func attachmentKind(of provider: NSItemProvider) -> UTType? {
            let common: [UTType] = [.image, .movie, .pdf, .audio]
            if let hit = common.first(where: { provider.hasItemConformingToTypeIdentifier($0.identifier) }) { return hit }
            for identifier in provider.registeredTypeIdentifiers {
                if let type = UTType(identifier), !type.conforms(to: .text), type != .fileURL { return type }
            }
            return nil
        }

        func textPasteConfigurationSupporting(_ target: any UITextPasteConfigurationSupporting,
                                              shouldAnimatePasteOf attributedString: NSAttributedString,
                                              to textRange: UITextRange) -> Bool { false }
    }
}
#endif
