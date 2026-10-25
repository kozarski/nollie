#if NOLLIE_DIRECT
import SwiftUI

/// Settings > About on the Direct Mac edition: the switch for automatic checks and a button to check now.
struct UpdateSettingsSection: View {
    private let updater = AppUpdater.shared

    private var automatic: Binding<Bool> {
        Binding(get: { updater.automaticChecks }, set: { updater.setAutomaticChecks($0) })
    }

    private var lastChecked: String? {
        updater.lastCheck.map { $0.formatted(date: .abbreviated, time: .shortened) }
    }

    var body: some View {
        VStack(spacing: 12) {
            GlassSwitch("Check for updates automatically", isOn: automatic, id: "about.updates.automatic")
                .disabled(!updater.isConfigured)
            GlassButton("Check for Updates…", symbol: "arrow.triangle.2.circlepath", value: lastChecked, id: "about.updates.check") {
                updater.checkNow()
            }
            .disabled(!updater.canCheck)
            .opacity(updater.canCheck ? 1 : 0.5)
            PageNote(updater.isConfigured
                     ? "Nollie looks once a day, and asks before it installs anything."
                     : "This build does not update itself.")
        }
    }
}
#endif
