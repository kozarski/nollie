#if os(macOS)
import SwiftUI

struct ConfigurationImportView: View {
    @Bindable var setup: MacHermesSetup
    var preferences: OnboardingPreferences
    var connectExisting: () -> Void
    var backup: () -> Void
    var continueSetup: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            SetupChecklistRow(title: String(localized: "Copy your setup"), subtitle: String(localized: "Your original stays where it is."), symbol: "doc.on.doc", state: setup.importCompleted ? .ready : .needed, expanded: true) {
                Text("Copies its instructions and settings. Chats, bots and schedules stay where they are.")
                    .foregroundStyle(.secondary)
                Button(setup.importPreview == nil ? "Choose a setup to preview" : "Choose another setup") {
                    Task { await setup.previewImport() }
                }
                .buttonStyle(.nollieGlass).tint(.blue)
                .disabled(setup.isBusy)
                .accessibilityIdentifier("onboarding.import.preview")
                if let preview = setup.importPreview {
                    Text(preview.summary).font(.subheadline)
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(preview.files, id: \.name) { file in
                            HStack {
                                Label(file.name, systemImage: "doc")
                                Spacer(minLength: 8)
                                Text(ByteCountFormatter.string(fromByteCount: Int64(clamping: file.bytes), countStyle: .file))
                                    .foregroundStyle(.secondary)
                            }
                            .font(.subheadline)
                        }
                    }
                    DisclosureGroup("What stays behind") {
                        VStack(alignment: .leading, spacing: 5) {
                            ForEach(preview.exclusions, id: \.self) { Text($0) }
                        }
                        .font(.footnote).foregroundStyle(.secondary).padding(.top, 8)
                    }
                    DisclosureGroup("File checks") {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(preview.files, id: \.name) { file in
                                Text(file.name).font(.caption.weight(.semibold))
                                Text(file.sha256).font(.caption2.monospaced()).textSelection(.enabled)
                            }
                        }
                        .padding(.top, 8)
                    }
                    Text("Settings can hold private details. The copy stays on this Mac.")
                        .foregroundStyle(.secondary)
                    Button(setup.importCompleted ? "Copied" : "Copy these files") {
                        Task { await setup.importExisting(preferences: preferences) }
                    }
                    .buttonStyle(.nollieGlassProminent).tint(.blue)
                    .disabled(setup.isBusy || setup.importCompleted)
                    .accessibilityIdentifier("onboarding.import.copy")
                }
                if setup.isBusy { ProgressView("Checking the copy") }
                if setup.importCompleted {
                    Label(setup.importDetail, systemImage: "checkmark.circle.fill")
                        .font(.footnote).foregroundStyle(Color.readableGreen)
                    Button("Continue setup", action: continueSetup)
                        .buttonStyle(.nollieGlass).tint(.blue)
                        .accessibilityIdentifier("onboarding.import.continue")
                }
                if let error = setup.error { Text(error).font(.footnote).foregroundStyle(.secondary) }
            }
            HStack(spacing: 12) {
                Button("Back up first", action: backup)
                    .buttonStyle(.nollieGlass)
                    .accessibilityIdentifier("onboarding.backup")
                Button("Connect instead", action: connectExisting)
                    .buttonStyle(.nollieGlass)
                    .accessibilityIdentifier("onboarding.import.connectExisting")
            }
        }
    }
}
#endif
