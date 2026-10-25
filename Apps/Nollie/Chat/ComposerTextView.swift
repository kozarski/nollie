#if os(macOS)
import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// The composer on the Mac: a SwiftUI text field that grows up to `maxLines`. Return sends, Shift-Return
/// or Option-Return adds a line, and the Up and Down arrows try `onArrow` before moving the caret
/// (that is how history recall works). Command-V on a picture, movie, PDF or sound hands the bytes to
/// `onPasteData`, which stages them as an attachment.
struct ComposerTextView: View {
    private static let attachmentTypes: [UTType] = [.image, .movie, .pdf, .audio]
    static let acceptedTypes: [UTType] = attachmentTypes + [.plainText, .text, .fileURL, .data]

    @FocusState private var fieldFocus: Bool
    /// Watches for an input method in the middle of a word.
    @State private var composed = ComposedKeys()

    @Binding var text: String
    let placeholder: String
    @Binding var focused: Bool
    var maxLines = 6
    var accessibilityID: String?
    var onSend: () -> Void = { () in }
    var onPasteData: @MainActor @Sendable (Data, String, UTType) -> Void = { (_: Data, _: String, _: UTType) in }
    var onArrow: (Int) -> Bool = { (_: Int) in false }
    /// Only here so callers look the same on both platforms. On the Mac Return always sends.
    var returnSends = false

    var body: some View {
        field
            // While an input method composes, all of these let the key through.
            .onKeyPress(.upArrow) { recall(-1) }
            .onKeyPress(.downArrow) { recall(1) }
            .onKeyPress(keys: Self.returnKeys, phases: [.down, .repeat, .up], action: returnKey)
            .onKeyPress(KeyEquivalent("v"), phases: .down, action: commandV)
            .onPasteCommand(of: Self.attachmentTypes) { stage($0) }
            .accessibilityIdentifier(accessibilityID ?? "composer.field")
            .onChange(of: fieldFocus) { _, actual in fieldFocusChanged(to: actual) }
            .onChange(of: focused) { _, wanted in requestedFocusChanged(to: wanted) }
            .onAppear { fieldFocus = focused }
    }

    private static let returnKeys: Set<KeyEquivalent> = [.return, ComposedKeys.keypadEnter]

    private var field: some View {
        TextField(placeholder, text: $text, axis: .vertical)
            .lineLimit(1...max(1, maxLines))
            .onSubmit(submit)
            .background { ComposedKeys.Anchor(keys: composed) }
            .focused($fieldFocus)
            .textFieldStyle(.plain)
    }

    /// The caller's focus binding follows the field's own focus, and the other way round.
    private func fieldFocusChanged(to actual: Bool) {
        if focused != actual { focused = actual }
    }

    private func requestedFocusChanged(to wanted: Bool) {
        if fieldFocus != wanted { fieldFocus = wanted }
    }

    private var hasWords: Bool { !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    /// Sends if there is something to send.
    private func sendIfAnything() {
        if hasWords { onSend() }
    }

    private func recall(_ step: Int) -> KeyPress.Result {
        if composed.isComposing { return .ignored }
        return onArrow(step) ? .handled : .ignored
    }

    /// The field editor treats `paste:` as text only and ignores a picture, so the paste command
    /// attached above fires for text alone. Command-V is caught here to cover everything else.
    private func commandV(_ press: KeyPress) -> KeyPress.Result {
        let chord = ComposedKeys.plain(press.modifiers)
        guard chord == .command, !composed.isComposing else { return .ignored }
        return stagePasteboard(.general) ? .handled : .ignored
    }

    private func submit() {
        guard let passedOn = composed.takeReturn() else {
            sendIfAnything()
            return
        }
        handOn(passedOn)
    }

    /// Return and Shift-Return, held or tapped.
    /// - Releasing the key clears what composition remembered.
    /// - Shift adds a line at every repeat. It goes through the field editor because `text` can lag
    ///   behind fast repeats.
    /// - A held plain Return must not repeat into submit: that once re-sent a half-written message.
    ///   Option-Return is left to the field, which already knows what to do.
    /// Keypad Enter counts as Return. Caps Lock and keypad flags are removed before checking modifiers.
    private func returnKey(_ press: KeyPress) -> KeyPress.Result {
        if press.phase == .up {
            composed.returnUp()
            return .ignored
        }
        let chord = ComposedKeys.plain(press.modifiers)
        if composed.returnDown(chord) { return .ignored }
        if chord.contains(.shift) {
            addLineBreak()
            return .handled
        }
        let isRepeat = press.phase == .repeat
        return isRepeat && !chord.contains(.option) ? .handled : .ignored
    }

    private func addLineBreak(after remembered: ComposedKeys.Return? = nil) {
        let done = remembered.map { composed.insertLineBreak($0) } ?? composed.insertLineBreak()
        if !done { text += "\n" }
    }

    /// Korean commits its block and sends Return on to the field. The field takes that as a submit,
    /// ends editing and re-enters it with everything selected, so the break or the send is put off
    /// to the next pass of the run loop, once the selection has settled.
    private func handOn(_ key: ComposedKeys.Return) {
        let afterwards: () -> Void = key.shift ? { addLineBreak(after: key) } : { sendIfAnything() }
        DispatchQueue.main.async(execute: afterwards)
    }

    // MARK: Pasting

    private static func provider(from item: NSPasteboardItem) -> NSItemProvider? {
        let offered = item.types.compactMap { UTType($0.rawValue) }
        guard let kind = attachmentTypes.first(where: { want in offered.contains { $0.conforms(to: want) } }),
              let exact = offered.first(where: { $0.conforms(to: kind) }),
              let bytes = item.data(forType: NSPasteboard.PasteboardType(exact.identifier)) else { return nil }
        let provider = NSItemProvider()
        provider.registerDataRepresentation(forTypeIdentifier: exact.identifier, visibility: .all) { done in
            done(bytes, nil)
            return nil
        }
        return provider
    }

    /// Takes pictures, PDFs, movies and sounds off the pasteboard and stages them. Text is left for
    /// the field. True when anything was staged.
    private func stagePasteboard(_ board: NSPasteboard) -> Bool {
        let providers = (board.pasteboardItems ?? []).compactMap(Self.provider(from:))
        stage(providers)
        return !providers.isEmpty
    }

    /// Same rule as on the phone: text is typed in, anything else becomes a named attachment.
    private func stage(_ providers: [NSItemProvider]) {
        for provider in providers {
            if PastedAttachment.isPlainText(provider) {
                appendText(from: provider)
            } else if let kind = Self.attachmentTypes.first(where: { provider.hasItemConformingToTypeIdentifier($0.identifier) }) {
                deliverAttachment(from: provider, kind: kind)
            }
        }
    }

    private func appendText(from provider: NSItemProvider) {
        provider.loadDataRepresentation(forTypeIdentifier: UTType.plainText.identifier) { data, _ in
            guard let data, let words = String(data: data, encoding: .utf8) else { return }
            Task { @MainActor in text += words }
        }
    }

    private func deliverAttachment(from provider: NSItemProvider, kind: UTType) {
        let exact = PastedAttachment.concreteType(of: provider, fitting: kind)
        let name = PastedAttachment.fileName(for: kind, concrete: exact)
        let deliver = onPasteData
        provider.loadDataRepresentation(forTypeIdentifier: exact.identifier) { data, _ in
            guard let data, !data.isEmpty else { return }
            Task { @MainActor in deliver(data, name, exact) }
        }
    }
}
#endif
