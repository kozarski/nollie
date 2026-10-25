import SwiftUI

/// The two wide buttons: ink glass for the one answer people usually give, and clear glass for the
/// rest. A destructive role turns the clear one's words red.
struct InkButtonStyle: ButtonStyle {
    var compact = false
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font((compact ? Font.subheadline : .body).weight(.semibold))
            .lineLimit(1)
            .minimumScaleFactor(0.85)
            .foregroundStyle(Color(.systemBackground))
            .padding(.horizontal, compact ? 16 : 20).padding(.vertical, compact ? 11 : 15)
            .frame(maxWidth: .infinity)
            .nollieGlass(.regular.tint(Color.primary), in: Capsule(), solid: Color.primary)
            .opacity(!enabled ? 0.3 : (configuration.isPressed ? 0.8 : 1))
            .contentShape(.capsule)
            .animation(.snappy(duration: 0.15), value: configuration.isPressed)
    }
}

struct SoftButtonStyle: ButtonStyle {
    var compact = false
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font((compact ? Font.subheadline : .body).weight(.medium))
            .lineLimit(1)
            .minimumScaleFactor(0.85)
            .foregroundStyle(configuration.role == .destructive ? Color.red : Color.primary)
            .padding(.horizontal, compact ? 16 : 20).padding(.vertical, compact ? 11 : 15)
            .frame(maxWidth: .infinity)
            .nollieGlass(.regular, in: Capsule(), solid: Color.primary.opacity(0.07))
            .opacity(!enabled ? 0.4 : (configuration.isPressed ? 0.75 : 1))
            .contentShape(.capsule)
            .animation(.snappy(duration: 0.15), value: configuration.isPressed)
    }
}
