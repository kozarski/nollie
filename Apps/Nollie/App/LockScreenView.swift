import SwiftUI

/// Shown over the app while it is locked. Authentication starts as soon as it appears (biometrics or
/// the device passcode), and starts again whenever the button is pressed.
struct LockScreenView: View {
    private let gap: CGFloat = 20
    @Environment(AppModel.self) private var model

    var body: some View {
        ZStack {
            Color.clear.background(.regularMaterial)
            VStack(spacing: gap) {
                padlock
                if let reason = model.lock.lastError {
                    Text(reason).small(.footnote).multilineTextAlignment(.center)
                }
                unlockButton
            }
            .padding()
        }
        .task { await model.lock.unlock() }
    }

    private var padlock: some View {
        VStack(spacing: gap) {
            Image(systemName: "lock.fill")
                .accessibilityHidden(true)
                .font(Font.system(size: 44))
                .foregroundStyle(HierarchicalShapeStyle.secondary)
            Text("Nollie is locked").font(.title2.weight(.semibold))
        }
    }

    private var unlockButton: some View {
        Button("Unlock with \(model.lock.biometryName)") {
            Task { await model.lock.unlock() }
        }
        .buttonStyle(.nollieGlassProminent)
    }
}
