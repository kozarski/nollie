import SwiftUI
import Testing
#if canImport(UIKit)
import UIKit
#endif
@testable import Nollie

/// Accessibility polish: quiet words stay readable in both modes, and small round buttons get a
/// fingertip-sized target without moving anything.
@MainActor @Suite struct AccessibilityPolishTests {
    #if canImport(UIKit)
    /// Red, green and blue of a colour as the given appearance draws it.
    private func channels(_ color: Color, dark: Bool) -> [CGFloat] {
        let traits = UITraitCollection(userInterfaceStyle: dark ? .dark : .light)
        var (r, g, b, a): (CGFloat, CGFloat, CGFloat, CGFloat) = (0, 0, 0, 0)
        UIColor(color).resolvedColor(with: traits).getRed(&r, green: &g, blue: &b, alpha: &a)
        return [r, g, b]
    }

    /// WCAG relative luminance and contrast ratio.
    private func luminance(_ rgb: [CGFloat]) -> CGFloat {
        let linear = rgb.map { $0 <= 0.03928 ? $0 / 12.92 : pow(($0 + 0.055) / 1.055, 2.4) }
        return 0.2126 * linear[0] + 0.7152 * linear[1] + 0.0722 * linear[2]
    }

    private func contrast(_ a: Color, on b: Color, dark: Bool) -> CGFloat {
        let (x, y) = (luminance(channels(a, dark: dark)), luminance(channels(b, dark: dark)))
        return (max(x, y) + 0.05) / (min(x, y) + 0.05)
    }

    /// Where quiet words sit: the chat, the bot list's column, cards and the bot's bubbles.
    private var grounds: [(String, Color)] {
        [("canvas", Ink.canvas), ("sidebar", Ink.sidebar), ("card", Ink.card), ("bubble", Ink.bubble), ("hover", Ink.hover)]
    }

    @Test(arguments: [false, true])
    func quietWordsMeetFourAndAHalfToOne(dark: Bool) {
        for (name, ground) in grounds {
            let ratio = contrast(Ink.text3, on: ground, dark: dark)
            #expect(ratio >= 4.5, "text3 on \(name) (\(dark ? "dark" : "light")) is \(ratio)")
        }
    }

    @Test func theMeasuredRatiosAreTheOnesReported() {
        // Light: 5.15 on white, 4.77 on the sidebar. Dark: 5.71 on the canvas, 5.20 on the sidebar.
        #expect(abs(contrast(Ink.text3, on: Ink.canvas, dark: false) - 5.15) < 0.02)
        #expect(abs(contrast(Ink.text3, on: Ink.sidebar, dark: false) - 4.77) < 0.02)
        #expect(abs(contrast(Ink.text3, on: Ink.canvas, dark: true) - 5.71) < 0.02)
        #expect(abs(contrast(Ink.text3, on: Ink.sidebar, dark: true) - 5.20) < 0.02)
    }

    @Test(arguments: [false, true])
    func quietWordsStayQuieterThanSecondWords(dark: Bool) {
        // In dark the colour still steps down; in light the two meet at the readable floor and size does the rest.
        let quiet = contrast(Ink.text3, on: Ink.canvas, dark: dark)
        let second = contrast(Ink.text2, on: Ink.canvas, dark: dark)
        #expect(quiet <= second + 0.1)
    }
    #endif

    // MARK: Targets

    @Test func smallRoundButtonsReachFortyFourPoints() {
        #expect(Ink.minTarget == 44)
        let composer = Ink.target(face: Ink.composerButton)
        #expect(composer.side == 44)
        #expect(composer.overhang == (44 - Ink.composerButton) / 2)
        #expect(Ink.target(face: 24) == (side: 44, overhang: 10))
        #expect(Ink.target(face: 60) == (side: 60, overhang: 0), "a big face keeps its own size")
    }

    @Test func neighbouringComposerTargetsDoNotOverlap() {
        // The capsule puts 10 points between its round buttons; each target reaches past its face by the overhang.
        let gap: CGFloat = 10
        #expect(Ink.target(face: Ink.composerButton).overhang * 2 < gap)
        // And the reach above and below stays inside the capsule's own inset.
        #expect(Ink.target(face: Ink.composerButton).overhang <= Ink.composerInset)
    }

    #if canImport(UIKit)
    @Test func aBiggerTargetMovesNothing() {
        let face = Ink.composerButton
        let plain = UIHostingController(rootView: PlainButton(action: {}) { Color.red.frame(square: face) })
        let grown = UIHostingController(rootView: PlainButton(action: {}) { Color.red.frame(square: face) }
            .environment(\.tapTargetFace, face))
        let room = CGSize(width: 300, height: 300)
        #expect(plain.sizeThatFits(in: room) == CGSize(width: face, height: face))
        #expect(grown.sizeThatFits(in: room) == CGSize(width: face, height: face), "laid out as drawn")
    }
    #endif
}
