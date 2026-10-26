import AppIntents

#if os(iOS) || os(macOS)
/// "Ask Nollie" from Control Center, the Lock Screen or the Action Button (and Control Center or
/// the menu bar on the Mac): opens the app straight into the main chat, ready to type. It only
/// opens the app, so iOS asks for the phone to be unlocked as it does for any app, and Nollie's
/// own App Lock still comes first.
///
/// Built into the app and the Controls extension: a control that opens its app needs its intent in
/// both. The system runs an open intent in the app. Siri and Shortcuts offer AskHelperIntent
/// under the same name, which asks by voice and reads the reply, so this one stays out of their lists.
struct AskNollieIntent: OpenIntent {
    static let title: LocalizedStringResource = "Ask Nollie"
    static let description = IntentDescription("Opens your main chat, ready to type.")
    static let isDiscoverable = false

    @Parameter(title: "Chat", default: .mainChat)
    var target: AskNollieTarget

    init() { target = .mainChat }

    @MainActor
    func perform() async throws -> some IntentResult {
        #if !NOLLIE_CONTROLS
        #if os(macOS)
        MacWindow.bringMainForward()
        #endif
        AppModel.shared.askNollie()
        #endif
        return .result()
    }
}

/// Where Ask Nollie opens. One place for now: the main chat.
enum AskNollieTarget: String, AppEnum {
    case mainChat

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Chat"
    static let caseDisplayRepresentations: [AskNollieTarget: DisplayRepresentation] = [.mainChat: "Main chat"]
}
#endif

/// The Ask Nollie control's words. Shared so tests can hold them to the copy rules.
enum AskNollieWords {
    static let control = "Ask Nollie"
    static let controlDescription = "Opens your main chat, ready to type."
    static let controlSymbol = "bubble.left.fill"
}
