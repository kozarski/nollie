import AppIntents

/// The sentences Stop answers with. Shared so the tests can check them against the copy rules.
enum MacStopWords {
    static let stopped = "Done. Your Mac is ending the task, the replies and the schedules."
    static let notLinked = "Link Nollie to your Mac first, then Stop will work."
    static let unreachable = "Can't reach your Mac right now. Try at home, or with Tailscale on both."
    static let notSent = "That didn't get through, so nothing was stopped."
}

#if os(iOS)
/// Ends what Nollie is doing on the Mac: the task stops, replies stop, schedules pause. Offered from
/// the Lock Screen card, Siri, Shortcuts and the Stop alert; it goes over Nollie Link and needs the
/// phone unlocked.
///
/// The Controls extension compiles this too, so the card's button can name it. As a
/// LiveActivityIntent the system runs it in the app, the only place the link to the Mac lives.
struct StopMacIntent: LiveActivityIntent {
    static var title: LocalizedStringResource { "Stop Nollie" }
    static var description: IntentDescription { IntentDescription("Ends the helper's task, stops replies and pauses schedules.") }
    static var authenticationPolicy: IntentAuthenticationPolicy { .requiresAuthentication }
    static var openAppWhenRun: Bool { false }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let line: String
        #if NOLLIE_CONTROLS
        // Should not happen, as the app runs this. If it ever does, say nothing was stopped.
        line = MacStopWords.notSent
        #else
        line = await MacStop.press()
        #endif
        return .result(dialog: IntentDialog(stringLiteral: line))
    }
}
#endif
