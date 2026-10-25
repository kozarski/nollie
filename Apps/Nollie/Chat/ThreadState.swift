import SwiftUI

/// The display switches from Settings that the thread reads, kept together.
struct ThreadPrefs: DynamicProperty {
    @AppStorage(ChatStyle.showToolCalls) var showToolCalls = true
    @AppStorage(ChatStyle.showReasoning) var showReasoning = true
    @AppStorage(ChatStyle.showTurnStats) var showTurnStats = false
    @AppStorage(ChatStyle.showSystemNotes) var showSystemNotes = true
    @AppStorage(ChatStyle.collapseAfterTurn) var collapseAfterTurn = false
    @AppStorage(ChatStyle.showToolOutput) var showToolOutput = true
    @AppStorage(ChatStyle.compactTools) var compactTools = false
    @AppStorage(ChatStyle.currentStepOnly) var currentStepOnly = false
    @AppStorage(ChatStyle.groupSteps) var groupSteps = true
    @AppStorage(ChatStyle.wideReplies) var wideReplies = false
    @AppStorage(ChatStyle.textSize) var textSize = "default"

    /// Several steps in a row fold into one line, unless only the current step is shown (then
    /// there is nothing to fold: the step running is all there is).
    var foldsSteps: Bool { groupSteps && !currentStepOnly }
}

/// The delayed jobs the thread has under way. Each is cancelled by whatever supersedes it. A
/// plain object, since none of them is anything to draw.
final class ThreadTasks {
    /// Raises the keyboard floor once the keyboard has settled.
    var keyboardFloor: Task<Void, Never>?
    /// Follows the dock to its settled height.
    var insetSettle: Task<Void, Never>?
    /// The jump arrow's scroll.
    var jump: Task<Void, Never>?
    /// Keeps a disclosure's header still while it opens.
    var reveal: Task<Void, Never>?
    /// Brings the thread back from past its end.
    var overscroll: Task<Void, Never>?

    /// Everything that moves the thread by itself stops: a notification's target, or a disclosure
    /// being read, takes over.
    func stopMoving() {
        [jump, insetSettle, overscroll].forEach { $0?.cancel() }
    }
}
