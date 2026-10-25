#if !os(macOS)
import UIKit

/// The composer's text view on the phone: a placeholder, a Paste that is always offered, and the
/// keys of a hardware keyboard (Return sends, Shift-Return breaks the line, the arrows recall).
final class PasteTextView: UITextView {
    let placeholderLabel = UILabel()
    weak var coordinator: ComposerTextView.Coordinator?

    /// A hardware Return noticed during composition, kept until the key is released. If the input
    /// method then sends on a line break, that break stands for this Return.
    var composedReturn: (shift: Bool, command: Bool)?

    /// One row per shortcut: the key, its modifiers, what it runs, and whether it beats the system.
    private struct Shortcut {
        let input: String
        let modifiers: UIKeyModifierFlags
        let action: Selector
        let firstInLine: Bool

        var command: UIKeyCommand {
            let made = UIKeyCommand(input: input, modifierFlags: modifiers, action: action)
            made.wantsPriorityOverSystemBehavior = firstInLine
            return made
        }
    }

    private static let shortcuts: [Shortcut] = [
        Shortcut(input: UIKeyCommand.inputUpArrow, modifiers: [], action: #selector(arrowUp), firstInLine: true),
        Shortcut(input: UIKeyCommand.inputDownArrow, modifiers: [], action: #selector(arrowDown), firstInLine: true),
        Shortcut(input: "\r", modifiers: [], action: #selector(returnPressed), firstInLine: true),
        Shortcut(input: "\r", modifiers: .shift, action: #selector(shiftReturnPressed), firstInLine: false),
        Shortcut(input: "\r", modifiers: .command, action: #selector(commandReturnPressed), firstInLine: false),
    ]

    override init(frame: CGRect, textContainer: NSTextContainer?) {
        let box = frame
        super.init(frame: box, textContainer: textContainer)
        installPlaceholder()
    }

    required init?(coder: NSCoder) { fatalError("not made from a storyboard") }

    private func installPlaceholder() {
        let label = placeholderLabel
        label.font = .preferredFont(forTextStyle: .body)
        label.adjustsFontForContentSizeCategory = true
        label.textColor = .placeholderText
        label.numberOfLines = 1
        label.isUserInteractionEnabled = false
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        label.leadingAnchor.constraint(equalTo: leadingAnchor).isActive = true
        label.topAnchor.constraint(equalTo: topAnchor).isActive = true
        label.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor).isActive = true
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        placeholderLabel.font = font
    }

    /// True while an input method holds marked text; its keys are then its own.
    var isComposing: Bool { InputComposition.isComposing(self) }

    // MARK: Menu and shortcuts

    private static func pasteboardHasSomething() -> Bool {
        let board = UIPasteboard.general
        return board.numberOfItems > 0 || board.hasStrings || board.hasImages || board.hasURLs
    }

    /// Paste is offered whenever anything is on the pasteboard. The stock check could say no for a
    /// lone picture and leave the menu without it.
    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        let isPaste = (action == #selector(paste(_:)))
        if isPaste { return Self.pasteboardHasSomething() }
        // Commands UIKit cached before composing began are refused so the key reaches the input method.
        let isOurs = Self.shortcuts.contains { $0.action == action }
        if isComposing && isOurs { return false }
        return super.canPerformAction(action, withSender: sender)
    }

    override var keyCommands: [UIKeyCommand]? {
        isComposing ? [] : Self.shortcuts.map(\.command)
    }

    @objc private func arrowUp() { step(by: -1) }
    @objc private func arrowDown() { step(by: 1) }
    @objc private func returnPressed() { sendReturn(shift: false, command: false) }
    @objc private func shiftReturnPressed() { sendReturn(shift: true, command: false) }
    @objc private func commandReturnPressed() { sendReturn(shift: false, command: true) }

    /// The arrows go to history recall first; when it declines they move the caret a line.
    private func step(by delta: Int) {
        guard !isComposing else { return }
        let taken = coordinator?.parent.onArrow(delta) ?? false
        if !taken { moveCaretOneLine(upward: delta < 0) }
    }

    private func sendReturn(shift: Bool, command: Bool) {
        guard !isComposing else { return }
        coordinator?.hardwareReturn(self, shift: shift, command: command)
    }

    private func moveCaretOneLine(upward: Bool) {
        guard let selection = selectedTextRange else { return }
        let origin = upward ? selection.start : selection.end
        let direction = UITextDirection.layout(upward ? .up : .down)
        guard let landing = tokenizer.position(from: origin, toBoundary: .line, inDirection: direction) else { return }
        selectedTextRange = textRange(from: landing, to: landing)
    }

    /// Hands over the noted Return, if any, and forgets it.
    func takeComposedReturn() -> (shift: Bool, command: Bool)? {
        let noted = composedReturn
        composedReturn = nil
        return noted
    }

    // MARK: Hardware presses

    private func returnPress(in presses: Set<UIPress>) -> UIKey? {
        let returnCodes: Set<UIKeyboardHIDUsage> = [.keyboardReturnOrEnter, .keypadEnter]
        return presses.lazy.compactMap(\.key).first { returnCodes.contains($0.keyCode) }
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        // Look now. Once the input method has the key, the marked text is gone.
        if isComposing, let key = returnPress(in: presses) {
            let flags = key.modifierFlags
            composedReturn = (shift: flags.contains(.shift), command: flags.contains(.command))
        }
        super.pressesBegan(presses, with: event)
    }

    /// Japanese and Chinese input methods take Return entirely. Letting go of the key ends the wait,
    /// so a break typed later on the on-screen keyboard is only a break.
    private func forgetReturn(if presses: Set<UIPress>) {
        if returnPress(in: presses) != nil { composedReturn = nil }
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        defer { forgetReturn(if: presses) }
        super.pressesEnded(presses, with: event)
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        defer { forgetReturn(if: presses) }
        super.pressesCancelled(presses, with: event)
    }
}
#endif
