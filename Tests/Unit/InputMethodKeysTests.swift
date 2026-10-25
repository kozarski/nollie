#if os(iOS)
import SwiftUI
import Testing
import UIKit
@testable import Nollie

/// Keyboard handling while an input method is mid-composition (Japanese, Chinese, Korean and
/// similar). Until the person accepts the text, Return and the arrow keys are the input method's:
/// Return chooses a candidate rather than sending a half-converted message, and the arrows step
/// through candidates, not message history. When nothing is marked, the keys work as the composer
/// always had them. The simulator only has an English keyboard with no input method, so tests
/// that compose first declare the keyboard to be one.
@MainActor @Suite struct InputMethodKeysTests {
    /// Declares the keyboard an input method (or not) until the returned closure restores it.
    private func keyboardIsInputMethod(_ yes: Bool) -> () -> Void {
        let original = InputComposition.inputMethod
        InputComposition.inputMethod = { _ in yes }
        return { InputComposition.inputMethod = original }
    }

    /// Records what the composer was told to do.
    private final class Asked {
        var sent = 0
        var arrowSteps: [Int] = []
        var nothing: Bool { sent == 0 && arrowSteps.isEmpty }
    }

    /// A stand-in hardware key, since UIKit has no public way to construct one for a text view.
    private final class FakeKey: UIKey {
        private let usage: UIKeyboardHIDUsage, held: UIKeyModifierFlags
        init(_ usage: UIKeyboardHIDUsage, _ held: UIKeyModifierFlags = []) { self.usage = usage; self.held = held; super.init() }
        required init?(coder: NSCoder) { nil }
        override var keyCode: UIKeyboardHIDUsage { usage }
        override var modifierFlags: UIKeyModifierFlags { held }
    }

    private final class FakePress: UIPress {
        private let pressed: UIKey
        init(_ pressed: UIKey) { self.pressed = pressed; super.init() }
        override var key: UIKey? { pressed }
    }

    private func presses(_ usage: UIKeyboardHIDUsage, _ held: UIKeyModifierFlags = []) -> Set<UIPress> {
        [FakePress(FakeKey(usage, held))]
    }

    /// The composer's text view set up the way the representable does, with callbacks that record.
    private struct Rig {
        let view: PasteTextView
        let coordinator: ComposerTextView.Coordinator
        let asked: Asked

        @MainActor init(text: String = "", returnSends: Bool = false) {
            let asked = Asked()
            let typed = Binding.constant(text), unfocused = Binding.constant(false)
            let parent = ComposerTextView(text: typed, placeholder: "Message", focused: unfocused,
                                          onSend: { asked.sent += 1 },
                                          onArrow: { step in asked.arrowSteps.append(step); return true },
                                          returnSends: returnSends)
            let coordinator = parent.makeCoordinator()
            let view = PasteTextView()
            view.delegate = coordinator
            view.coordinator = coordinator
            view.text = text
            (self.view, self.coordinator, self.asked) = (view, coordinator, asked)
        }

        func command(_ input: String, _ modifiers: UIKeyModifierFlags = []) -> UIKeyCommand? {
            view.keyCommands?.first { $0.input == input && $0.modifierFlags == modifiers }
        }

        func fire(_ command: UIKeyCommand) { _ = view.perform(command.action) }

        func compose(_ text: String) {
            view.setMarkedText(text, selectedRange: NSRange(location: (text as NSString).length, length: 0))
        }

        var endOfText: NSRange { NSRange(location: (view.text as NSString).length, length: 0) }

        /// Types a line break as the text view's delegate sees it.
        func lineBreakAccepted() -> Bool {
            coordinator.textView(view, shouldChangeTextIn: endOfText, replacementText: "\n")
        }
    }

    /// Shows the view in its own window as first responder, the way it is when someone types.
    private func takeFocus(_ view: UIView) throws -> () -> Void {
        // The test host can still be opening its window when the first test starts: give it a moment.
        func windowScenes() -> [UIWindowScene] { UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene } }
        let deadline = Date().addingTimeInterval(5)
        while windowScenes().isEmpty && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        let scene = try #require(windowScenes().first)
        let previouslyKey = scene.keyWindow
        let stage = UIWindow(windowScene: scene)
        let area = CGRect(origin: CGPoint(x: 20, y: 100), size: CGSize(width: 300, height: 80))
        view.frame = area
        stage.addSubview(view)
        stage.makeKeyAndVisible()
        let focused = view.becomeFirstResponder()
        #expect(focused)
        return {
            _ = view.resignFirstResponder()
            stage.isHidden = true
            previouslyKey?.makeKey()
        }
    }

    // MARK: marked text and the keys

    @Test func withNothingMarkedTheKeysBelongToTheComposer() throws {
        let rig = Rig(text: "hello")
        #expect(!rig.view.isComposing)
        let send = try #require(rig.command("\r"))
        #expect(rig.view.canPerformAction(try #require(send.action), withSender: send))
        rig.fire(send)
        #expect(rig.asked.sent == 1)

        rig.fire(try #require(rig.command(UIKeyCommand.inputUpArrow)))
        rig.fire(try #require(rig.command(UIKeyCommand.inputDownArrow)))
        #expect(rig.asked.arrowSteps == [-1, 1])
        rig.fire(try #require(rig.command("\r", .command)))
        #expect(rig.asked.sent == 2)
    }

    @Test func whileComposingEveryKeyIsLeftToTheInputMethod() throws {
        let undo = keyboardIsInputMethod(true)
        defer { undo() }
        let rig = Rig()
        // The commands UIKit may still hold from before composing began.
        let stale = try #require(rig.view.keyCommands)
        #expect(stale.count == 5)
        rig.compose("にほん")
        #expect(rig.view.markedTextRange != nil && rig.view.isComposing)

        // Nothing is offered now, and a command that was already held gets refused so the key passes through.
        #expect(rig.view.keyCommands?.isEmpty == true)
        for command in stale {
            #expect(!rig.view.canPerformAction(try #require(command.action), withSender: command))
            rig.fire(command)   // called anyway, it must do nothing
        }
        #expect(rig.asked.nothing)
        #expect(rig.view.text == "にほん" && rig.view.markedTextRange != nil, "no line break added, still marked")
    }

    @Test func onceTheCandidateIsAcceptedReturnSendsAgain() throws {
        let undo = keyboardIsInputMethod(true)
        defer { undo() }
        let rig = Rig()
        rig.compose("ni")
        #expect(rig.command("\r") == nil)
        rig.compose("日本")
        #expect(rig.command(UIKeyCommand.inputDownArrow) == nil)

        rig.view.unmarkText()
        #expect(rig.view.markedTextRange == nil && rig.view.text == "日本")
        #expect(rig.view.keyCommands?.count == 5, "all the composer's keys are back")
        rig.fire(try #require(rig.command("\r")))
        #expect(rig.asked.sent == 1)
        rig.fire(try #require(rig.command(UIKeyCommand.inputUpArrow)))
        #expect(rig.asked.arrowSteps == [-1])
    }

    // MARK: a Return the input method took

    /// Japanese and Chinese swallow a whole Return (it confirms either the candidate or the raw
    /// letters). The wait lasts only while the key is held, so a line break that arrives afterwards,
    /// as from the software keyboard, is a new line and never a send.
    @Test func aReturnTakenWholeIsDroppedWhenTheKeyComesUp() {
        let undo = keyboardIsInputMethod(true)
        defer { undo() }
        let rig = Rig()
        let view = rig.view
        // Nothing marked, so the key command owns the Return and no wait begins.
        view.pressesBegan(presses(.keyboardReturnOrEnter), with: nil)
        #expect(view.composedReturn == nil)
        view.pressesEnded(presses(.keyboardReturnOrEnter), with: nil)

        rig.compose("にほん")
        // A different key while composing (arrows moving through candidates) starts no wait either.
        view.pressesBegan(presses(.keyboardDownArrow), with: nil)
        #expect(view.composedReturn == nil)
        view.pressesEnded(presses(.keyboardDownArrow), with: nil)

        view.pressesBegan(presses(.keyboardReturnOrEnter), with: nil)
        #expect(view.composedReturn != nil)
        view.unmarkText()
        view.pressesEnded(presses(.keyboardDownArrow), with: nil)
        #expect(view.composedReturn != nil, "some other key coming up leaves the wait alone")
        view.pressesEnded(presses(.keyboardReturnOrEnter), with: nil)
        #expect(view.composedReturn == nil)
        #expect(rig.lineBreakAccepted())
        #expect(rig.asked.sent == 0)

        // Cancelling a press also ends the wait, and keypad Enter is treated as Return.
        rig.compose("ni")
        view.pressesBegan(presses(.keypadEnter), with: nil)
        #expect(view.composedReturn != nil)
        view.pressesCancelled(presses(.keypadEnter), with: nil)
        #expect(view.composedReturn == nil)
        #expect(rig.asked.nothing)
    }

    /// With Korean, Return takes the block and the Return then travels onward as a line break. Because that
    /// break originates in the hardware key it sends; Shift-Return inserts a line; Command-Return sends.
    @Test func aReturnPassedOnAfterTheTextIsInFollowsTheHardwareRule() {
        let undo = keyboardIsInputMethod(true)
        defer { undo() }
        let rig = Rig(text: "안")

        func returnAfterBlock(holding flags: UIKeyModifierFlags) -> Bool {
            rig.compose("녕")
            rig.view.pressesBegan(presses(.keyboardReturnOrEnter, flags), with: nil)
            #expect(rig.view.composedReturn?.shift == flags.contains(.shift))
            rig.view.unmarkText()
            let accepted = rig.lineBreakAccepted()
            #expect(rig.view.composedReturn == nil, "the line break used up the wait")
            rig.view.pressesEnded(presses(.keyboardReturnOrEnter, flags), with: nil)
            return accepted
        }

        #expect(returnAfterBlock(holding: []) == false)
        #expect(rig.view.text == "안녕" && rig.asked.sent == 1)
        #expect(returnAfterBlock(holding: .shift) == true)
        #expect(rig.asked.sent == 1)
        #expect(returnAfterBlock(holding: .command) == false)
        #expect(rig.asked.sent == 2)
        // A line break that no hardware Return stands behind comes from the on-screen keyboard: insert a line.
        #expect(rig.lineBreakAccepted())
        #expect(rig.asked.sent == 2)
    }

    /// With both settings, Shift-Return inserts a line. The break it produces is distinct from the
    /// software Return, which sends if the setting calls for it.
    @Test(arguments: [false, true])
    func hardwareShiftReturnAddsALineWhateverTheSetting(returnSends: Bool) throws {
        let rig = Rig(text: "hi", returnSends: returnSends)
        let release = try takeFocus(rig.view)   // text only gets typed into a field that is being edited
        defer { release() }
        rig.fire(try #require(rig.command("\r", .shift)))
        #expect(rig.asked.sent == 0)
        #expect(rig.view.text == "hi\n")
    }

    /// Without an input method, marked text is only a grey in-line suggestion (or a dead key's
    /// accent) and the keys stay with the composer.
    @Test func markedTextWithNoInputMethodLeavesTheKeysAlone() throws {
        let undo = keyboardIsInputMethod(false)
        defer { undo() }
        let rig = Rig(text: "see you tomor")
        rig.view.setMarkedText("row", selectedRange: NSRange(location: 0, length: 0))
        #expect(rig.view.markedTextRange != nil && !rig.view.isComposing)
        #expect(rig.view.keyCommands?.count == 5)
        let up = try #require(rig.command(UIKeyCommand.inputUpArrow))
        #expect(rig.view.canPerformAction(try #require(up.action), withSender: up))
        rig.fire(up)
        #expect(rig.asked.arrowSteps == [-1])
        rig.view.pressesBegan(presses(.keyboardReturnOrEnter), with: nil)
        #expect(rig.view.composedReturn == nil)
    }

    // MARK: which keyboards count

    /// English has no input method, most other languages may have one, and an unidentified language is
    /// assumed to. Dictation and the emoji keyboard lack any, so Command-Return and the arrow keys
    /// stay with the composer while dictating.
    @Test func onlyEnglishDictationAndEmojiKeyboardsHaveNoInputMethod() {
        let plain = ["en", "en-US", "en-GB", "en_AU", "dictation", "emoji"]
        let withMethods = ["ja-JP", "zh-Hans", "zh-Hant", "yue-Hant", "ko-KR", "vi-VN", "hi"]
        let verdicts = plain.map { ($0, false) } + withMethods.map { ($0, true) }
        for (language, expected) in verdicts {
            let verdict = InputComposition.isInputMethod(language: language)
            #expect(verdict == expected, "\(language)")
        }
        let unknownLanguage = InputComposition.isInputMethod(language: nil)
        #expect(unknownLanguage)
    }

    /// The To: field in the New Message sheet is a SwiftUI field. It is located through the
    /// responder chain, so Backspace leaves the recipient chips alone during composition.
    @Test func aFocusedPlainFieldIsSeenComposing() throws {
        let undo = keyboardIsInputMethod(true)
        defer { undo() }
        let field = UITextField()
        let release = try takeFocus(field)
        defer { release() }
        var activity = [field.isFirstResponder, InputComposition.isActive]
        field.setMarkedText("zhong", selectedRange: NSRange(location: 5, length: 0))
        activity.append(InputComposition.isActive)
        field.unmarkText()
        activity.append(InputComposition.isActive)
        #expect(activity == [true, false, true, false])
    }
}
#elseif os(macOS)
import AppKit
import Carbon.HIToolbox
import Combine
import SwiftUI
import Testing
@testable import Nollie

/// On the Mac the composer's key handling yields whenever the field editor holds marked text from
/// an input method. SwiftUI invokes the composer's handlers ahead of the input method seeing the
/// key, so a handler that consumes the text but passes the key on (Korean behaves so) puts that
/// key into the field, where it acts as though nothing were composing. This Mac has just a keyboard
/// layout, therefore a key delivered to a window whose field has marked text only commits it and
/// continues into the field. The composing tests declare the keyboard to be an input method.
@MainActor @Suite(.serialized) struct InputMethodKeysTests {
    private func keyboardIsInputMethod(_ yes: Bool) -> () -> Void {
        let original = InputComposition.inputMethod
        InputComposition.inputMethod = { _ in yes }
        return { InputComposition.inputMethod = original }
    }

    private let anywhere = NSRange(location: NSNotFound, length: 0)

    /// A text view standing in for the field editor.
    private func bareEditor() -> NSTextView { NSTextView(frame: NSRect(origin: .zero, size: NSSize(width: 200, height: 40))) }

    /// Leaves `text` marked in the editor, with the insertion point at its end.
    private func mark(_ text: String, in editor: NSTextView) {
        let tail = NSRange(location: (text as NSString).length, length: 0)
        editor.setMarkedText(text, selectedRange: tail, replacementRange: anywhere)
    }

    /// A titled window showing `content`, with its first editable field focused. Returns the
    /// window and the field editor that took focus.
    private func focusedField<Content: View>(showing content: Content) async throws -> (window: NSWindow, editor: NSTextView) {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: NSSize(width: 420, height: 120)),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: content)
        window.contentView = host
        let fields = try await Self.textFields(in: host)
        let field = try #require(fields.first)
        let accepted = window.makeFirstResponder(field)
        #expect(accepted)
        let editor = try #require(window.firstResponder as? NSTextView)
        #expect(editor !== field && editor.isFieldEditor)
        return (window, editor)
    }

    /// SwiftUI reports Caps Lock and keypad keys as modifiers. The composer does not see them as
    /// chords: Return under them stays a plain Return, and keypad Enter is the Return the handler
    /// listens for.
    @Test func capsLockAndKeypadMakeNoChord() {
        let held: [(SwiftUI.EventModifiers, SwiftUI.EventModifiers)] = [([.capsLock, .numericPad], []), ([.shift, .capsLock], [.shift]), ([.command], [.command])]
        for (pressed, counted) in held { #expect(ComposedKeys.plain(pressed) == counted) }
        let enter = ComposedKeys.keypadEnter
        #expect(enter == KeyEquivalent("\u{3}") && enter != .return)
    }

    @Test func aFieldEditorHoldingMarkedTextIsComposing() {
        let undo = keyboardIsInputMethod(true)
        defer { undo() }
        let editor = bareEditor()
        var seen = [InputComposition.isComposing(editor)]
        mark("にほん", in: editor)
        seen.append(InputComposition.isComposing(editor))
        editor.unmarkText()
        seen.append(InputComposition.isComposing(editor))
        #expect(seen == [false, true, false])
        #expect(InputComposition.isComposing(nil) == false)
    }

    /// On a plain layout, marked text is a grey in-line suggestion, or the accent of a dead key.
    @Test func markedTextUnderALayoutIsNotComposing() {
        let undo = keyboardIsInputMethod(false)
        defer { undo() }
        let editor = bareEditor()
        mark("row", in: editor)
        #expect(editor.hasMarkedText() && !InputComposition.isComposing(editor))
        let sources: [(CFString, Bool)] = [(kTISTypeKeyboardLayout, false), (kTISTypeKeyboardInputMode, true), (kTISTypeKeyboardInputMethodWithoutModes, true)]
        for (type, isMethod) in sources { #expect(InputComposition.isInputMethod(sourceType: type as String) == isMethod) }
    }

    /// The composer is a TextField from SwiftUI. During typing, the first responder of the window is
    /// its field editor, and that editor holds the marked text which the key handling examines.
    @Test func theComposerIsReadThroughTheWindowsFieldEditor() async throws {
        let undo = keyboardIsInputMethod(true)
        defer { undo() }
        let empty = Binding.constant(""), unfocused = Binding.constant(false)
        let (window, editor) = try await focusedField(showing: ComposerTextView(text: empty, placeholder: "Message", focused: unfocused))
        defer { window.close() }
        func composing() -> Bool { InputComposition.isComposing(window.firstResponder) }
        var timeline = [composing()]
        mark("にほん", in: editor)
        timeline.append(composing())
        editor.unmarkText()
        timeline.append(composing())
        #expect(timeline == [false, true, false])
    }

    // MARK: keys sent to a real composer

    /// Korean: if the final block is still composing, Shift-Return commits that block and forwards the
    /// key. A line gets inserted where the key landed and nothing is sent (it once triggered the field's
    /// submit action and sent the message).
    @Test func aPassedOnShiftReturnAddsALine() async throws {
        let undo = keyboardIsInputMethod(true)
        defer { undo() }
        let bench = try await Bench()
        defer { bench.window.close() }
        bench.compose("안", marked: "녕")
        try await bench.settle { bench.model.text == "안" }
        try await bench.press("\r", 36, .shift)
        try await bench.settle { bench.model.text == "안녕\n" }
        #expect(bench.model.sent.isEmpty)

        // Within the field: the insertion point lands after the break and typing resumes there.
        let editor = try #require(bench.editor)
        let afterBreak = (editor.string, editor.selectedRange())
        #expect(afterBreak == ("안녕\n", NSRange(location: 3, length: 0)))
        editor.insertText("x", replacementRange: anywhere)
        try await bench.settle { bench.model.text == "안녕\nx" }

        // With text after the cursor, the break lands when the block ends and before the rest. (A value
        // assigned in the very turn it is typed never makes it into a SwiftUI field, hence the brief wait.)
        try await Task.sleep(for: .milliseconds(100))
        bench.model.text = "ab de"
        try await bench.settle { bench.editor?.string == "ab de" }
        bench.editor?.setSelectedRange(NSRange(location: 2, length: 0))
        bench.compose("", marked: "c")
        try await bench.press("\r", 36, .shift)
        try await bench.settle { bench.model.text == "abc\n de" }
        #expect(bench.editor?.selectedRange() == NSRange(location: 4, length: 0))
        #expect(bench.model.sent.isEmpty)
    }

    /// Korean: a plain Return forwarded after the block is committed sends, same as with no composition.
    @Test func aPassedOnReturnSends() async throws {
        let undo = keyboardIsInputMethod(true)
        defer { undo() }
        let bench = try await Bench()
        defer { bench.window.close() }
        bench.compose("안", marked: "녕")
        try await bench.settle { bench.model.text == "안" }
        try await bench.press("\r", 36)
        try await bench.settle { bench.model.sent == ["안녕"] }
    }

    /// Japanese and Chinese consume Return, Tab and Escape while composing (accept, move to the
    /// next candidate, keep the raw text) and forward nothing, so nothing is sent and the text
    /// stays as the input method left it.
    @Test(arguments: [("\r", UInt16(36)), ("\t", 48), ("\u{1b}", 53)])
    func keysTakenWholeBelongToTheInputMethodAlone(characters: String, code: UInt16) async throws {
        let undo = keyboardIsInputMethod(true)
        defer { undo() }
        let release = Self.makeInputMethodTakeKeysWhole()
        defer { release() }
        let bench = try await Bench()
        defer { bench.window.close() }
        bench.compose("a", marked: "も")
        try await bench.settle { bench.model.text == "a" }
        try await Task.sleep(for: .milliseconds(200))
        try await bench.press(characters, code)
        try await Task.sleep(for: .milliseconds(100))
        #expect(bench.model.sent.isEmpty, "key \(code)")
        #expect(bench.model.text == "a", "key \(code)")
        #expect(bench.editor?.string == "aも" && bench.editor?.hasMarkedText() == true, "key \(code)")
    }

    /// Holding Return repeats it. With Shift each repeat inserts a line and nothing is sent (repeats
    /// used to hit the field's submit action and send a half-written message). When a block is still
    /// composing (Korean), the first press commits it and later repeats insert lines. Option-Return
    /// is the field's own line break, and a plain held Return sends a single time.
    @Test func aHeldReturnSendsJustOnce() async throws {
        let undo = keyboardIsInputMethod(true)   // only the marked text further down counts as composing
        defer { undo() }
        let bench = try await Bench()
        defer { bench.window.close() }
        bench.editor?.insertText("hello", replacementRange: anywhere)
        try await bench.settle { bench.model.text == "hello" }
        try await bench.press("\r", 36, .shift, repeats: 3)
        try await bench.settle { bench.model.text == "hello\n\n\n\n" }
        #expect(bench.model.sent.isEmpty)
        bench.editor?.setSelectedRange(NSRange(location: 2, length: 0))
        try await bench.press("\r", 36, .shift, repeats: 1)
        try await bench.settle { bench.model.text == "he\n\nllo\n\n\n\n" }
        try await bench.press("\r", 36, .option, repeats: 1)
        try await bench.settle { bench.model.text == "he\n\n\n\nllo\n\n\n\n" }
        #expect(bench.model.sent.isEmpty)

        try await Task.sleep(for: .milliseconds(100))
        bench.model.text = "안"
        try await bench.settle { bench.editor?.string == "안" }
        bench.editor?.setSelectedRange(NSRange(location: 1, length: 0))
        bench.compose("", marked: "녕")
        try await bench.press("\r", 36, .shift, repeats: 2)
        try await bench.settle { bench.model.text == "안녕\n\n\n" }
        #expect(bench.model.sent.isEmpty)

        try await bench.press("\r", 36, repeats: 3)
        try await bench.settle { !bench.model.sent.isEmpty }
        try await Task.sleep(for: .milliseconds(200))
        #expect(bench.model.sent == ["안녕\n\n\n"])
    }

    /// Patches the text-input context so that it acts like an input method which swallows Return, Tab
    /// and Escape while composing, as Japanese and Chinese do. Such a key goes nowhere else and the
    /// text stays put. The Mac keyboard is merely a layout, so the patch lasts until the closure runs.
    private static func makeInputMethodTakeKeysWhole() -> () -> Void {
        let target = #selector(NSTextInputContext.handleEvent(_:))
        guard let method = class_getInstanceMethod(NSTextInputContext.self, target) else { return {} }
        let originalIMP = method_getImplementation(method)
        typealias Forward = @convention(c) (NSTextInputContext, Selector, NSEvent) -> Bool
        let forward = unsafeBitCast(originalIMP, to: Forward.self)
        let swallowed: Set<UInt16> = [36, 48, 53]
        let patched: @convention(block) (NSTextInputContext, NSEvent) -> Bool = { context, event in
            MainActor.assumeIsolated {
                let holdsMarked = (context.client as? NSTextView)?.hasMarkedText() ?? false
                if holdsMarked, event.type == .keyDown, swallowed.contains(event.keyCode) { return true }
                return forward(context, target, event)
            }
        }
        let patch = imp_implementationWithBlock(patched)
        method_setImplementation(method, patch)
        return {
            method_setImplementation(method, originalIMP)
            imp_removeBlock(patch)
        }
    }

    /// Japanese and Chinese swallow a Return and pass nothing on. Releasing the key finishes the wait, which
    /// makes the next Return an ordinary one again, while a Return with nothing composing discards a leftover.
    @Test func aReturnTakenWholeLeavesNothingBehind() async throws {
        let undo = keyboardIsInputMethod(true)
        defer { undo() }
        let keys = ComposedKeys()
        let (window, editor) = try await focusedField(showing: Field(model: Model(), keys: keys))
        defer { window.close() }
        #expect(!keys.isComposing)
        #expect(!keys.returnDown([]))

        mark("にほん", in: editor)
        #expect(keys.isComposing)
        #expect(keys.returnDown([.shift]))
        let waiting = keys.composedReturn
        #expect(waiting?.shift == true && waiting?.tail == 0)
        editor.unmarkText()
        keys.returnUp()
        let leftOver = keys.takeReturn()
        #expect(leftOver == nil)

        mark("ni", in: editor)
        #expect(keys.returnDown([]))
        editor.unmarkText()
        // Nothing composing now, so a Return forgets the one left over.
        #expect(keys.returnDown([]) == false && keys.composedReturn == nil)
    }

    /// Marked text under a layout (a grey prediction) leaves the arrows to the composer; an
    /// input method's marked text keeps them for itself.
    @Test func theArrowsGiveWayOnlyToAnInputMethod() async throws {
        let bench = try await Bench()
        defer { bench.window.close() }
        bench.compose("see you tomor", marked: "row")
        var undo = keyboardIsInputMethod(false)
        try await bench.press(String(Character(UnicodeScalar(NSUpArrowFunctionKey)!)), 126, [.numericPad, .function])
        undo()
        #expect(bench.model.arrowSteps == [-1])
        bench.compose("", marked: "ni")
        undo = keyboardIsInputMethod(true)
        try await bench.press(String(Character(UnicodeScalar(NSDownArrowFunctionKey)!)), 125, [.numericPad, .function])
        undo()
        #expect(bench.model.arrowSteps == [-1])
    }

    // MARK: the composer hosted in a window

    /// Records the composer's requests and holds its text.
    @MainActor private final class Model: ObservableObject {
        @Published var text = ""
        var sent: [String] = []
        var arrowSteps: [Int] = []
    }

    /// A field with the composer's key tracker attached to its window.
    private struct Field: View {
        @ObservedObject var model: Model
        let keys: ComposedKeys
        private var tracker: ComposedKeys.Anchor { ComposedKeys.Anchor(keys: keys) }
        var body: some View { TextField("Message", text: $model.text).background(tracker) }
    }

    /// The composer as a chat uses it.
    private struct Host: View {
        @ObservedObject var model: Model
        private var composer: ComposerTextView {
            ComposerTextView(text: $model.text, placeholder: "Message", focused: .constant(false),
                             onSend: { [model] in model.sent.append(model.text) },
                             onArrow: { [model] step in model.arrowSteps.append(step); return true })
        }
        var body: some View { composer.frame(width: 400).padding(.all) }
    }

    /// The composer hosted in a window and focused for typing. The window never becomes key (events
    /// are delivered straight to it) and sits on screen but off all displays, because SwiftUI
    /// postpones height changes of the field, and the text prompting them, until a window is visible.
    @MainActor private final class Bench {
        let model = Model()
        let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: -6000, y: -6000), size: NSSize(width: 440, height: 160)),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        let field: NSTextField

        init() async throws {
            window.isReleasedWhenClosed = false
            let host = NSHostingView(rootView: Host(model: model))
            window.contentView = host
            window.orderFront(nil)
            field = try #require(try await InputMethodKeysTests.textFields(in: host).first)
            let focusedOK = window.makeFirstResponder(field)
            #expect(focusedOK)
            #expect(editor != nil)
        }

        /// The field editor while the composer has focus.
        var editor: NSTextView? {
            guard let candidate = window.firstResponder as? NSTextView, candidate.delegate as? NSView === field else { return nil }
            return candidate
        }

        /// Types `typed`, then leaves `marked` as text still being composed.
        func compose(_ typed: String, marked: String) {
            guard let editor else { return }
            let anywhere = NSRange(location: NSNotFound, length: 0)
            if !typed.isEmpty { editor.insertText(typed, replacementRange: anywhere) }
            let tail = NSRange(location: (marked as NSString).length, length: 0)
            editor.setMarkedText(marked, selectedRange: tail, replacementRange: anywhere)
        }

        /// Presses and releases a key the way the window would receive it from the keyboard. With
        /// `repeats`, it holds the key and repeats that many times, a beat apart, as a real key does.
        func press(_ characters: String, _ code: UInt16, _ flags: NSEvent.ModifierFlags = [], repeats: Int = 0) async throws {
            func keyEvent(_ kind: NSEvent.EventType, isRepeat: Bool) throws -> NSEvent {
                let stamp = ProcessInfo.processInfo.systemUptime
                let number = window.windowNumber
                return try #require(NSEvent.keyEvent(
                    with: kind, location: .zero, modifierFlags: flags, timestamp: stamp, windowNumber: number,
                    context: nil, characters: characters, charactersIgnoringModifiers: characters,
                    isARepeat: isRepeat, keyCode: code))
            }
            let beat = Duration.milliseconds(100)
            window.sendEvent(try keyEvent(.keyDown, isRepeat: false))
            var left = repeats
            while left > 0 {
                try await Task.sleep(for: beat)
                window.sendEvent(try keyEvent(.keyDown, isRepeat: true))
                left -= 1
            }
            window.sendEvent(try keyEvent(.keyUp, isRepeat: false))
            try await Task.sleep(for: beat)
        }

        /// Lets SwiftUI catch up, for a few seconds at most.
        func settle(until condition: () -> Bool, sourceLocation: SourceLocation = #_sourceLocation) async throws {
            let clock = ContinuousClock()
            let limit = clock.now.advanced(by: .seconds(3))
            while !condition(), clock.now < limit { try await Task.sleep(for: .milliseconds(20)) }
            #expect(condition(), sourceLocation: sourceLocation)
        }
    }

    /// The editable text fields inside a hosting view, after SwiftUI has finished layout.
    static func textFields(in host: NSView) async throws -> [NSTextField] {
        func collect(_ view: NSView) -> [NSTextField] {
            view.subviews.flatMap { sub -> [NSTextField] in
                if let field = sub as? NSTextField, field.isEditable { return [field] }
                return collect(sub)
            }
        }
        var found: [NSTextField] = []
        for _ in 0..<40 {
            host.layoutSubtreeIfNeeded()
            found = collect(host)
            if !found.isEmpty { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        return found
    }
}
#endif
