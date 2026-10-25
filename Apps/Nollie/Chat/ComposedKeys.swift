#if os(macOS)
import AppKit
import SwiftUI

/// Keeps the Mac composer out of an input method's way. SwiftUI offers key presses to the composer
/// before the input method has seen them, so while text is marked the composer's handlers do nothing
/// and the key travels on. Japanese and Chinese swallow Return whole. Korean commits its block and
/// then sends Return to the field as if nothing were composing, so this class remembers that Return
/// and lets the composer treat it like a normal one (Shift adds a line, plain sends).
@MainActor
final class ComposedKeys {
    /// Modifiers without the two SwiftUI adds for Caps Lock and for keypad keys; neither is a chord.
    nonisolated static func plain(_ held: EventModifiers) -> EventModifiers {
        let noise: EventModifiers = [.numericPad, .capsLock]
        return held.subtracting(noise)
    }

    /// Keypad Enter as SwiftUI names it (fn-Return on a laptop).
    static let keypadEnter: KeyEquivalent = "\u{3}"

    /// A Return seen during composition. `tail` counts the characters after the composed text, which
    /// is where the line break belongs.
    struct Return {
        var shift = false
        var tail = 0
    }

    /// The view that owned the field editor the last time composition was seen.
    private weak var field: NSView?
    private weak var anchor: NSView?
    private(set) var composedReturn: Return? = nil

    // MARK: Finding the editor

    private var editor: NSTextView? {
        let responder = anchor?.window?.firstResponder as? NSTextView
        return responder.flatMap { $0.isFieldEditor ? $0 : nil }
    }

    /// The editor, but only while it is working for the remembered field.
    private var editorOfField: NSTextView? {
        guard let editor, let field else { return nil }
        return (editor.delegate as? NSView) === field ? editor : nil
    }

    var isComposing: Bool {
        let current = editor
        return InputComposition.isComposing(current)
    }

    // MARK: Return

    /// Notes a Return going down. True means it was during composition and has been remembered.
    func returnDown(_ held: EventModifiers) -> Bool {
        guard isComposing, let editor else {
            composedReturn = nil
            return false
        }
        field = editor.delegate as? NSView
        let end = NSMaxRange(editor.markedRange())
        let tail = (editor.string as NSString).length - end
        composedReturn = Return(shift: held.contains(.shift), tail: tail)
        return true
    }

    /// The key coming up means the input method kept the Return, so nothing is owed.
    func returnUp() { composedReturn = nil }

    /// Called from the field's submit: a remembered Return means it came from the input method.
    func takeReturn() -> Return? {
        let noted = composedReturn
        composedReturn = nil
        return noted
    }

    // MARK: Line breaks

    /// Adds a line break at the caret through the window's editor, as Option-Return does.
    func insertLineBreak() -> Bool {
        guard let editor else { return false }
        editor.insertNewlineIgnoringFieldEditor(nil)
        return true
    }

    /// Adds the break where the remembered Return belongs, `tail` characters from the end.
    func insertLineBreak(_ key: Return) -> Bool {
        guard let editor = editorOfField else { return false }
        let total = (editor.string as NSString).length
        editor.setSelectedRange(NSRange(location: max(0, total - key.tail), length: 0))
        editor.insertNewlineIgnoringFieldEditor(nil)
        return true
    }

    // MARK: Anchor

    /// An invisible view behind the field. It only exists to give `ComposedKeys` a window to ask.
    struct Anchor: NSViewRepresentable {
        let keys: ComposedKeys

        func makeNSView(context: Context) -> NSView {
            let probe = AnchorView()
            keys.anchor = probe
            return probe
        }

        func updateNSView(_ nsView: NSView, context: Context) {
            keys.anchor = nsView
        }
    }

    private final class AnchorView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? {
            return nil
        }
    }
}
#endif
