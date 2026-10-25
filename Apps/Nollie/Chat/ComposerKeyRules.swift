import UniformTypeIdentifiers
import SwiftUI
#if os(macOS)
import AppKit
import Carbon.HIToolbox
#else
import UIKit
#endif

/// Decides what Return does in the phone and iPad composer, for both keyboards.
/// Shift always adds a line. Command or a hardware key sends. The on-screen key sends only when the
/// person has turned that on in Settings, and otherwise adds a line.
enum ComposerReturnRule {
    enum Action: Equatable {
        case send
        case newline
    }

    static func action(hardware: Bool, shift: Bool, command: Bool, returnSends: Bool) -> Action {
        if shift { return .newline }
        if hardware || command { return .send }
        if returnSends { return .send }
        return .newline
    }
}

/// Is the focused field partway through a word under an input method such as Japanese, Chinese
/// or Korean? While "marked" text is uncommitted, the input method owns Return, the arrow keys, Backspace
/// and Escape. Composer and New Message sheet alike check here first, and hand the key
/// through unchanged whenever it says yes.
@MainActor
enum InputComposition {
    typealias Judge = (Responder) -> Bool

    /// Whether the first responder in the window is mid-composition.
    static var isActive: Bool {
        let focused = Self.focusedResponder
        return Self.isComposing(focused)
    }

    /// Marked text alone proves little: inline suggestions and dead-key accents are marked too and
    /// do not claim any keys. So the answer also needs the current keyboard to be an input method.
    /// This is a variable so tests can stand in for a keyboard they cannot switch.
    static var inputMethod: Judge = { responder in
        InputComposition.isInputMethod(responder)
    }

    /// Whether this responder has text an input method has not handed over yet.
    static func isComposing(_ candidate: Responder?) -> Bool {
        guard let candidate else { return false }
        return hasMarkedText(candidate) && inputMethod(candidate)
    }

    #if os(macOS)
    typealias Responder = NSResponder

    private static func hasMarkedText(_ responder: NSResponder) -> Bool {
        guard let client = responder as? NSTextInputClient else { return false }
        return client.hasMarkedText()
    }

    /// A plain keyboard layout is not an input method; every other kind of input source is.
    static func isInputMethod(sourceType: String) -> Bool {
        sourceType != (kTISTypeKeyboardLayout as String)
    }

    /// The Mac has a single input source for the whole app. When it cannot be read the answer is no,
    /// which leaves the keys with the composer.
    private static func isInputMethod(_ responder: NSResponder) -> Bool {
        let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue()
        let raw = source.flatMap { TISGetInputSourceProperty($0, kTISPropertyInputSourceType) }
        guard let raw else { return false }
        let name = Unmanaged<CFString>.fromOpaque(raw).takeUnretainedValue() as String
        return Self.isInputMethod(sourceType: name)
    }

    /// A SwiftUI field being typed in is represented by the window's field editor.
    private static var focusedResponder: NSResponder? {
        guard let window = NSApp.keyWindow else { return nil }
        return window.firstResponder
    }
    #else
    typealias Responder = UIResponder

    private static func hasMarkedText(_ responder: UIResponder) -> Bool {
        guard let input = responder as? UITextInput else { return false }
        return input.markedTextRange != nil
    }

    /// English keyboards have no input method. Dictation and emoji are modes with no candidate list,
    /// so they leave the keys alone as well. A keyboard with no stated language might be one.
    static func isInputMethod(language: String?) -> Bool {
        guard let language, !language.isEmpty else { return true }
        let candidateless: Set<String> = ["dictation", "emoji"]
        if candidateless.contains(language) { return false }
        let code = Locale.Language(identifier: language).languageCode
        return code != .english
    }

    private static func isInputMethod(_ responder: UIResponder) -> Bool {
        let language = responder.textInputMode?.primaryLanguage
        return Self.isInputMethod(language: language)
    }

    /// UIKit does not publish the first responder, but an action sent to nobody lands on it first,
    /// and the responder reports itself back.
    private static var focusedResponder: UIResponder? {
        lastReported = nil
        let ask = #selector(UIResponder.reportFirstResponder)
        UIApplication.shared.sendAction(ask, to: nil, from: nil, for: nil)
        return lastReported
    }

    private static weak var lastReported: UIResponder?
    fileprivate static func report(_ responder: UIResponder) { lastReported = responder }
    #endif
}

#if !os(macOS)
extension UIResponder {
    /// Target of the action `InputComposition` sends to nobody: the first responder answers.
    @objc(nollie_reportFirstResponder) fileprivate func reportFirstResponder() {
        let reporter: UIResponder = self
        InputComposition.report(reporter)
    }
}
#endif

/// Sorts what gets pasted and names it. Text remains text, while a picture, movie, PDF or sound
/// turns into an attachment named after its kind, with the extension its type prefers.
enum PastedAttachment {
    private static let stems: [UTType: String] = [.image: "photo", .movie: "video", .pdf: "document"]

    static func fileName(for type: UTType, concrete: UTType, fallbackStem: String = "audio") -> String {
        let stem = stems[type] ?? fallbackStem
        let ext = concrete.preferredFilenameExtension ?? type.preferredFilenameExtension ?? "bin"
        return "\(stem)-\(Int(Date().timeIntervalSince1970)).\(ext)"
    }

    /// True for text. A copied web picture can offer text as well as the image, and that is not text.
    static func isPlainText(_ provider: NSItemProvider) -> Bool {
        let offers = { (type: UTType) in provider.hasItemConformingToTypeIdentifier(type.identifier) }
        let textual = offers(.plainText) || offers(.text)
        return textual && !offers(.image)
    }

    /// The narrowest registered type that still fits `type`, or `type` itself.
    static func concreteType(of provider: NSItemProvider, fitting type: UTType) -> UTType {
        for identifier in provider.registeredTypeIdentifiers {
            if let candidate = UTType(identifier), candidate.conforms(to: type) { return candidate }
        }
        return type
    }
}
