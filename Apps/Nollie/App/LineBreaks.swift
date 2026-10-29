import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Where words may break. At the largest text sizes the system hyphenates to fill a line, which
/// cut a web address into "ex-ample" and a short word into "work-ing". These hold such words
/// together with invisible word joiners, leaving only the breaks that read naturally.
enum LineBreaks {
    private static let joiner = "\u{2060}"
    private static let breakHere = "\u{200B}"

    /// A web address or host may break after a dot, a slash, a colon, an at sign or its own
    /// hyphen or underscore, never inside a name and never with an added hyphen. Show it with the plain address as its
    /// accessibility label, since the joiners are not meant to be read or copied.
    static func address(_ text: String) -> String {
        let breaks: Set<Character> = [".", "/", ":", "@", "-", "_"]
        var out = ""
        var previous: Character?
        for character in text {
            if let previous, !breaks.contains(previous), !breaks.contains(character), previous != " ", character != " " {
                out += joiner
            }
            out.append(character)
            if breaks.contains(character) { out += breakHere }
            previous = character
        }
        return out
    }

    /// Each word stays whole: lines break only between words. For short labels whose words
    /// always fit a line (a count, a state), where a hyphen would only look broken.
    static func wholeWords(_ text: String) -> String {
        text.split(separator: " ", omittingEmptySubsequences: false)
            .map { $0.map(String.init).joined(separator: joiner) }
            .joined(separator: " ")
    }

    /// A number stays on the line of the word after it ("5 times"), so a title never ends a line
    /// on a lone number.
    static func keepingNumbers(_ text: String) -> String {
        text.replacing(/(\d) (?=\p{L})/) { "\($0.output.1)\u{00A0}" }
    }
}


/// An address shown for reading: at the largest text sizes it breaks only where `LineBreaks.address`
/// allows. VoiceOver reads the plain address, and Copy in its menu copies it without the joiners;
/// text selection is offered only while the plain address is what is drawn.
struct AddressText: View {
    var address: String
    @Environment(\.dynamicTypeSize) private var typeSize

    init(_ address: String) { self.address = address }

    var body: some View {
        if typeSize.isAccessibilitySize {
            Text(verbatim: LineBreaks.address(address))
                .accessibilityLabel(Text(verbatim: address))
                .contextMenu { Button("Copy", systemImage: "doc.on.doc") { Self.copy(address) } }
        } else {
            Text(verbatim: address).textSelection(.enabled)
        }
    }

    private static func copy(_ text: String) {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #else
        UIPasteboard.general.string = text
        #endif
    }
}
