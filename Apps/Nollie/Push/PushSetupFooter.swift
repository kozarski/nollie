import SwiftUI

/// Continue (Done at the end). Below it: Exit on step one, Cancel setup afterwards.
struct SetupFooter: View {
    let step: PushSetupView.SetupStep
    /// A wait is on: the Continue button shows a spinner.
    let busy: Bool
    /// Files are uploading or the gateway is restarting, so leaving or skipping is not possible.
    let locked: Bool
    let stepDone: Bool
    let allDone: Bool
    let advance: () -> Void
    let finish: () -> Void
    let exit: () -> Void
    let cancel: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            primary
            secondary
        }
        .modifier(NarrowOnMac())
        .padding(EdgeInsets(top: 28, leading: 24, bottom: 16, trailing: 24))
        .background { backdrop.ignoresSafeArea() }
        .animation(.snappy, value: step)
    }

    /// Solid behind the buttons and fading out above, so the form scrolls underneath.
    private var backdrop: some View {
        let page = Color(.systemGroupedBackground)
        return LinearGradient(stops: [.init(color: page.opacity(0), location: 0), .init(color: page, location: 0.3)],
                              startPoint: .top, endPoint: .bottom)
    }

    @ViewBuilder private var primary: some View {
        if step == .overview {
            WideGlassButton(action: finish) { Text("Done") }
                .disabled(locked || !allDone)
                .accessibilityIdentifier("setup.done")
        } else {
            WideGlassButton(action: advance) {
                ZStack {
                    Text("Continue").opacity(busy ? 0 : 1)
                    if busy { ProgressView().tint(.white) }
                }
            }
            .disabled(!stepDone || locked)
            .accessibilityIdentifier("setup.continue")
        }
    }

    @ViewBuilder private var secondary: some View {
        switch step {
        case .apple:
            Button("Exit", action: exit)
                .small(.subheadline)
                .accessibilityIdentifier("setup.exit")
        case .overview:
            // Keeps the footer the same height as on the other steps.
            Text(" ").font(.subheadline)
        default:
            Button("Cancel setup", action: cancel)
                .small(.subheadline)
                .disabled(locked)
                .accessibilityIdentifier("setup.cancel")
        }
    }
}

/// On the Mac the footer is a plain, centred column; elsewhere it is left as it is.
private struct NarrowOnMac: ViewModifier {
    func body(content: Content) -> some View {
        #if os(macOS)
        content
            .buttonStyle(.borderless)
            .frame(maxWidth: 340)
            .frame(maxWidth: .infinity)
        #else
        content
        #endif
    }
}

/// A full-width prominent glass button.
private struct WideGlassButton<Face: View>: View {
    let action: () -> Void
    @ViewBuilder var label: () -> Face

    var body: some View {
        Button(action: action) { label().fullWidthLabel() }
            .buttonStyle(.nollieGlassProminent)
    }
}

/// The round glass button at the top left that goes back a step.
struct WizardBackButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "chevron.left")
                .frame(square: 40)
                .font(.body.weight(.semibold))
        }
        .buttonBorderShape(.circle)
        .buttonStyle(.nollieGlass)
        .accessibilityLabel("Back")
        .padding(EdgeInsets(top: 10, leading: 16, bottom: 0, trailing: 0))
    }
}
