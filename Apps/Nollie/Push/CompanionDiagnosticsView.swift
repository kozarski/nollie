import SwiftUI

/// Companion, Diagnostics: how the latest notification and push registration looked.
struct CompanionDiagnosticsView: View {
    @Bindable var setup: PushSetupModel

    private var footerWords: String {
        #if os(iOS)
        String(localized: "Every alert arrives as a notification.")
        #else
        String(localized: "On the Mac every alert arrives as a notification. Running turns and waiting approvals also sit in the menu bar.")
        #endif
    }

    var body: some View {
        SettingsList {
            SettingsHeaderSection(title: "Diagnostics")
            Section {
                LabeledContent("Last notification") {
                    Text(setup.extensionBreadcrumb ?? String(localized: "none handled yet", comment: "No notification has been handled yet"))
                        .multilineTextAlignment(.trailing)
                        .small(.caption)
                }
                RecentLog(lines: PushLog.lines.suffix(6))
            } footer: {
                Text(footerWords)
            }
        }
        .untitledPage()
    }
}

/// The newest lines of the push log, in small type; nothing at all while the log is empty.
private struct RecentLog: View {
    let lines: [String]

    init(lines: some Sequence<String>) { self.lines = Array(lines) }

    var body: some View {
        if !lines.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(lines.indices, id: \.self) { index in
                    Text(lines[index]).small(.caption2.monospaced())
                }
            }
        }
    }
}
