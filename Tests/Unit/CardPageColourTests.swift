#if os(macOS)
import Foundation
import Testing
@testable import Nollie

/// A web view on the Mac always paints a background, so the card puts its own colour into the
/// page: one hex colour for each appearance, written into the document's CSS.
@MainActor @Suite struct CardPageColourTests {
    @Test func eachAppearanceGetsItsOwnHexColourInTheDocument() throws {
        let light = try #require(HTMLCard.pageBackground(dark: false))
        let dark = try #require(HTMLCard.pageBackground(dark: true))
        for colour in [light, dark] {
            #expect(colour.count == 7 && colour.hasPrefix("#") && colour.dropFirst().allSatisfy { "0123456789ABCDEF".contains($0) }, "\(colour)")
        }
        #expect(light != dark)

        let painted = HTMLCard.document("<p>ok</p>", dark: false, background: light)
        #expect(painted.contains("background: \(light)"))
        #expect(!painted.contains("background: transparent"))
    }

    @Test func withoutAColourThePageStaysClearAsOnThePhone() {
        #expect(HTMLCard.document("<p>ok</p>", dark: false).contains("background: transparent"))
    }
}
#endif
