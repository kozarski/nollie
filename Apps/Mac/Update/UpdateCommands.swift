#if NOLLIE_DIRECT
import SwiftUI

/// Check for Updates… under About Nollie in the app menu.
struct MacUpdateCommands: Commands {
    private let updater = AppUpdater.shared

    var body: some Commands {
        CommandGroup(after: .appInfo) {
            Button("Check for Updates…") { updater.checkNow() }
                .disabled(!updater.canCheck)
        }
    }
}
#endif
