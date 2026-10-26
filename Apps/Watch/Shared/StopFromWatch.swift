#if os(watchOS)
import AppIntents

/// Stop from the Watch's Control Center, Smart Stack or Action button: opens Nollie on the Watch at
/// the crew and sends the same Stop the iPhone's Lock Screen offers. It runs in the app, the only
/// place on the Watch that can reach the phone.
struct StopFromWatchIntent: AppIntent {
    static var title: LocalizedStringResource { "Stop Nollie" }
    static var description: IntentDescription { IntentDescription("Ends the helper's task, stops replies and pauses schedules.") }
    static var openAppWhenRun: Bool { true }

    @MainActor
    func perform() async throws -> some IntentResult {
        #if !NOLLIE_WATCH_WIDGETS
        WatchModel.shared.stopFromControl()
        #endif
        return .result()
    }
}
#endif
