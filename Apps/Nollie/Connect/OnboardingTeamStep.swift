import SwiftUI

/// The step where the main assistant gets its name. Left empty, it stays Nollie.
struct OnboardingTeamStep: View {
    @Binding var assistantName: String
    var compact = false

    @FocusState private var editing: Bool
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            StepHeading(title: String(localized: "Name your assistant"), note: String(localized: "Your main contact for questions and tasks."))
            nameField
        }
        .glassCard(inset: compact ? 20 : 24, corner: 24, continuous: false)
        .frame(maxWidth: 700)
    }

    /// The edge is faint at rest, stronger with Increase Contrast, and the accent while typing.
    private var edge: (color: Color, width: CGFloat) {
        if editing { return (.accentColor, 2) }
        return (Color.primary.opacity(contrast == .increased ? 0.55 : 0.22), 1)
    }

    private var nameField: some View {
        let box = RoundedRectangle(cornerRadius: 14)
        return TextField("Nollie", text: $assistantName)
            .textFieldStyle(.plain)
            .font(.title2.weight(.semibold))
            .textContentType(.nickname)
            .autocorrectionDisabled()
            .focused($editing)
            .inset(h: 18)
            .frame(maxWidth: .infinity, minHeight: compact ? 56 : 64)
            .background(Color(.secondarySystemGroupedBackground), in: box)
            .overlay { box.stroke(edge.color, lineWidth: edge.width).allowsHitTesting(false) }
            .contentShape(.rect)
            .onTapGesture { editing = true }
            .accessibilityLabel("Assistant name")
            .accessibilityHint("Leave this blank to use Nollie. You can change it later.")
            .testID("onboarding.assistantName")
    }
}
