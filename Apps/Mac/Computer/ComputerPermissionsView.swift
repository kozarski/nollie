#if os(macOS)
import AppKit
import ApplicationServices
import CoreGraphics
import Observation
import SwiftUI

/// Accessibility and Screen Recording, as macOS reports them for Nollie. Read without prompting;
/// asking shows macOS's own prompt, which only the person answers.
@MainActor
@Observable
final class ComputerPermissions {
    static let shared = ComputerPermissions()

    enum Kind: CaseIterable { case accessibility, screenRecording }

    private(set) var accessibility = false
    private(set) var screenRecording = false
    /// The kinds the person has asked macOS about from this screen.
    private(set) var asked: Set<Kind> = []

    @ObservationIgnored var read: (Kind) -> Bool = { kind in
        switch kind {
        case .accessibility: AXIsProcessTrusted()
        case .screenRecording: CGPreflightScreenCaptureAccess()
        }
    }
    @ObservationIgnored var request: (Kind) -> Void = { kind in
        switch kind {
        case .accessibility:
            _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        case .screenRecording:
            _ = CGRequestScreenCaptureAccess()
        }
    }

    var allGranted: Bool { accessibility && screenRecording }

    func granted(_ kind: Kind) -> Bool { kind == .accessibility ? accessibility : screenRecording }

    func refresh() {
        accessibility = read(.accessibility)
        screenRecording = read(.screenRecording)
    }

    /// Shows macOS's prompt for one permission. The person answers it; Nollie never does.
    func ask(_ kind: Kind) {
        asked.insert(kind)
        request(kind)
        refresh()
    }

    func openPrivacySettings(_ kind: Kind) {
        let anchor = kind == .accessibility ? "Privacy_Accessibility" : "Privacy_ScreenCapture"
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") {
            NSWorkspace.shared.open(url)
        }
    }
}

/// The walkthrough: what each permission is for, its state, and one button that shows macOS's
/// prompt. Nollie never clicks a macOS prompt, and neither does anyone but the person.
struct ComputerPermissionsView: View {
    @State var permissions: ComputerPermissions
    var close: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Let Nollie use your Mac")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(Ink.text)
                Text("Only the apps you approve, one task at a time.")
                    .font(Ink.cardBody)
                    .foregroundStyle(Ink.text2)
            }
            VStack(spacing: 10) {
                row(.accessibility)
                row(.screenRecording)
            }
            if !permissions.allGranted {
                // Needed: macOS sometimes only applies Screen Recording after a restart.
                Text("macOS may ask you to reopen Nollie.")
                    .font(Ink.pill)
                    .foregroundStyle(Ink.text3)
            }
            HStack {
                Spacer()
                Button(permissions.allGranted ? "Done" : "Not Now", action: close)
                    .buttonStyle(permissions.allGranted ? AnyPrimitiveButtonStyle(.nollieGlassProminent) : AnyPrimitiveButtonStyle(.nollieGlass))
                    .controlSize(.large)
                    .buttonBorderShape(.capsule)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(32)
        .frame(width: 560)
        .task {
            // macOS doesn't announce a change: look again while the screen is open.
            while !Task.isCancelled {
                permissions.refresh()
                try? await Task.sleep(for: .seconds(1.5))
            }
        }
    }

    /// The same row as setup and Settings use. macOS cannot say "refused" apart from "never asked",
    /// so a permission that was asked for and is still off offers Settings instead of Allow.
    private func row(_ kind: ComputerPermissions.Kind) -> some View {
        let shown: PermissionKind = kind == .accessibility ? .accessibility : .screenRecording
        let state: PermissionState = permissions.granted(kind) ? .granted : permissions.asked.contains(kind) ? .denied : .notAsked
        return PermissionRow(kind: shown, state: state,
                             allow: { permissions.ask(kind) },
                             openSettings: { permissions.openPrivacySettings(kind) })
    }
}

/// Either glass button style, chosen at run time.
struct AnyPrimitiveButtonStyle: PrimitiveButtonStyle {
    private let make: (Configuration) -> AnyView
    init<S: PrimitiveButtonStyle>(_ style: S) { make = { AnyView(Button($0).buttonStyle(style)) } }
    func makeBody(configuration: Configuration) -> some View { make(configuration) }
}
#endif
