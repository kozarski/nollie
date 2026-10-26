import AppIntents
import SwiftUI
import WidgetKit

/// What Nollie puts outside the app: the Ask Nollie and Stop controls (Control Center, the Lock
/// Screen and the Action Button on iPhone; Control Center and the menu bar on the Mac) and, on
/// iPhone, the Live Activity shown while a helper is working.
@main
struct NollieControls: WidgetBundle {
    var body: some Widget {
        AskNollieControl()
        StopHelpersControl()
        #if os(iOS)
        HelperAtWorkLiveActivity()
        #endif
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

/// One press stops every helper: the same Stop as the Lock Screen card and Siri. The intent runs in
/// the app, which holds the link to the Mac (or, on the Mac, the helpers themselves). The iPhone
/// asks to be unlocked first.
struct StopHelpersControl: ControlWidget {
    static let kind = "com.coreykozarski.nollie.stop"

    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: Self.kind) {
            ControlWidgetButton(action: StopMacIntent()) {
                Label(StopControlWords.control, systemImage: StopControlWords.controlSymbol)
            }
            .tint(.red)
        }
        .displayName(LocalizedStringResource(stringLiteral: StopControlWords.control))
        .description(LocalizedStringResource(stringLiteral: StopControlWords.controlDescription))
    }
}
