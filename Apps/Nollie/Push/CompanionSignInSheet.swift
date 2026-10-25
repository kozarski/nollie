import SwiftUI
import NollieCore

/// Signs the companion in to the gateway with credentials of its own. They never touch this device's
/// session and go straight into the config that gets uploaded.
struct CompanionSignInSheet: View {
    let runtime: GatewayRuntime
    let onSignedIn: (GatewaySecrets) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var form = Entry()
    @State private var auth = NativeAuthClient()

    /// What the person has typed, and where the attempt stands.
    private struct Entry {
        var username = ""
        var password = ""
        var busy = false
        var problem: String?

        var canSubmit: Bool { !busy && !username.isEmpty && !password.isEmpty }
    }

    private var connection: GatewayConnection { runtime.connection }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("Signs the companion in to \(connection.name) with credentials of its own. Use the account you use for the dashboard.")
                        .note()
                }
                if connection.authMode == .password {
                    PasswordSection(username: $form.username, password: $form.password,
                                    busy: form.busy, canSubmit: form.canSubmit) {
                        attempt { try await passwordSignIn() }
                    }
                } else {
                    BrowserSection(busy: form.busy) {
                        attempt { try await browserSignIn() }
                    }
                }
                if let problem = form.problem { Text(problem).note(.problem) }
            }
            .toolbar { CancelItem { dismiss() } }
            .navigationBarTitleDisplayMode(.inline)
            .navigationTitle("Companion sign-in")
        }
        .presentationDetents([Self.height])
    }

    private static let height = PresentationDetent.medium

    // MARK: Signing in

    /// Runs one sign-in, then hands the result up and closes, or shows what went wrong.
    private func attempt(_ signIn: @escaping () async throws -> GatewaySecrets) {
        form.busy = true
        Task {
            do {
                let secrets = try await signIn()
                form.password = ""
                form.busy = false
                onSignedIn(secrets)
                dismiss()
            } catch {
                form.problem = error.localizedDescription
                form.busy = false
            }
        }
    }

    private func browserSignIn() async throws -> GatewaySecrets {
        try await auth.signInWithBrowser(gateway: connection.gateway, provider: connection.authProvider,
                                         access: runtime.secrets.access)
    }

    private func passwordSignIn() async throws -> GatewaySecrets {
        let access = runtime.secrets.access
        let provider = await providerName()
        return try await NativeAuthClient.signInWithPassword(gateway: connection.gateway, provider: provider,
                                                             username: form.username, password: form.password, access: access)
    }

    /// Which provider name to send: the one this device signed in with, one the gateway marks as
    /// password-based, or "basic". Note "password" describes a mode here and is not a provider.
    private func providerName() async -> String {
        let known = runtime.secrets.provider ?? connection.authProvider ?? ""
        if !known.isEmpty { return known }
        guard let offered = try? await NativeAuthClient.providers(gateway: connection.gateway, access: runtime.secrets.access) else {
            return "basic"
        }
        let pick = offered.first(where: { $0.supportsPassword == true }) ?? offered.first
        let name = pick?.name ?? ""
        return name.isEmpty ? "basic" : name
    }
}

/// The Cancel button in the sheet's corner.
private struct CancelItem: ToolbarContent {
    let action: () -> Void

    var body: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button("Cancel", action: action)
        }
    }
}

/// Username and password fields with the button that sends them.
private struct PasswordSection: View {
    @Binding var username: String
    @Binding var password: String
    let busy: Bool
    let canSubmit: Bool
    let submit: () -> Void

    var body: some View {
        Section {
            // Tagged as a sign-in so Passwords can offer to fill them.
            TextField("Username", text: $username)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .textContentType(.username)
            SecureField("Password", text: $password)
                .textContentType(.password)
        }
        Section {
            Button(action: submit) { Text(busy ? "Signing in…" : "Sign in") }
                .disabled(!canSubmit)
        }
    }
}

/// One button that opens the gateway's own sign-in page.
private struct BrowserSection: View {
    let busy: Bool
    let open: () -> Void

    var body: some View {
        Section {
            Button(busy ? "Waiting for the browser…" : "Sign in with browser", action: open).disabled(busy)
        }
    }
}

/// Team ID read from the provisioning profile embedded in this build (TestFlight, App Store and
/// device builds). Nil in the simulator, where it gets typed in.
enum ProvisioningProfile {
    static var teamID: String? {
        guard let profile = embeddedProfile(), let text = embeddedPlist(in: profile),
              let plist = try? PropertyListSerialization.propertyList(from: text, format: nil) as? [String: Any] else { return nil }
        if let team = (plist["TeamIdentifier"] as? [String])?.first { return team }
        return (plist["Entitlements"] as? [String: Any])?["com.apple.developer.team-identifier"] as? String
    }

    private static func embeddedProfile() -> Data? {
        #if os(macOS)
        // On the Mac the profile sits next to Info.plist instead of in the resources.
        let location = Bundle.main.bundleURL.appendingPathComponent("Contents/embedded.provisionprofile")
        #else
        guard let location = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision") else { return nil }
        #endif
        return try? Data(contentsOf: location)
    }

    /// The profile is a CMS-signed DER blob that holds the property list as readable text.
    private static func embeddedPlist(in data: Data) -> Data? {
        guard let open = data.range(of: Data("<?xml".utf8)), let close = data.range(of: Data("</plist>".utf8)) else { return nil }
        return data[open.lowerBound..<close.upperBound]
    }
}
