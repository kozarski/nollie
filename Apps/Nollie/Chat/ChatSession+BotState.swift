import NollieCore

extension ChatSession {
    /// What to show the bot's character doing. A card awaiting an answer means needs-you. While a
    /// turn runs, the status line decides between thinking, using a tool and working. A failed
    /// open is an error, a reconnecting banner is a thinking state, and all else is idle. Talk mode
    /// and a reply being read aloud add listening and speaking.
    var botState: CharacterState {
        guard cards.isEmpty else { return .needsYou }
        if let voice = TalkMode.shared.mood(for: storedID, profile: profileName, running: isRunning) { return voice }
        if items.isEmpty, resumeError != nil { return .error }
        if let notice = banner, notice.hasPrefix("Reconnected") { return .thinking }
        guard isRunning else { return .idle }
        let status = statusLine ?? "Thinking…"
        if ["Thinking…", "Sending…"].contains(status) || status.hasPrefix("Queued") { return .thinking }
        if status.hasPrefix("Running") || status.hasPrefix("Preparing") { return .usingTool }
        return .working
    }
}
