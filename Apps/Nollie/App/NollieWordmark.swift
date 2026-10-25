import SwiftUI

/// The Nollie wordmark: the letters in the text colour, and the i drawn as a sky board mid-nollie.
/// Two vector layers, so the letters follow light and dark while the board keeps its colour.
struct NollieWordmark: View {
    var height: CGFloat = 40

    var body: some View {
        ZStack {
            Image("NollieWordmarkInk").resizable().renderingMode(.template).foregroundStyle(Ink.text)
            Image("NollieWordmarkBoard").resizable()
        }
        .aspectRatio(248.0 / 88.0, contentMode: .fit)
        .frame(height: height)
        .accessibilityElement()
        .accessibilityLabel("Nollie")
        .accessibilityAddTraits(.isHeader)
    }
}
