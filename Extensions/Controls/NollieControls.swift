import AppIntents
import SwiftUI
import WidgetKit

/// What Nollie puts outside the app on the iPhone: the Ask Nollie control (Control Center, the
/// Lock Screen and the Action Button) and the Live Activity shown while a helper is working.
@main
struct NollieControls: WidgetBundle {
    var body: some Widget {
        AskNollieControl()
        HelperAtWorkLiveActivity()
    }
}

/// One tap opens Nollie in the main chat with the keyboard up.
struct AskNollieControl: ControlWidget {
    static let kind = "com.coreykozarski.nollie.ask"

    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: Self.kind) {
            ControlWidgetButton(action: AskNollieIntent()) {
                Label(AskNollieWords.control, systemImage: AskNollieWords.controlSymbol)
            }
        }
        .displayName(LocalizedStringResource(stringLiteral: AskNollieWords.control))
        .description(LocalizedStringResource(stringLiteral: AskNollieWords.controlDescription))
    }
}
