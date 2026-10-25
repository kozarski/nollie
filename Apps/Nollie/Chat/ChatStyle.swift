import SwiftUI

/// Names of the stored settings for Appearance and Chat, plus the one rule that turns a
/// text-size choice into a Dynamic Type step.
enum ChatStyle {
    static let showToolCalls = "chat.showToolCalls"
    static let showReasoning = "chat.showReasoning"
    static let showTurnStats = "chat.showTurnStats"
    static let showSystemNotes = "chat.showSystemNotes"
    /// When on, the on-screen keyboard's Return key sends the message (as before 1.4) and does not begin a new
    /// line. Off unless chosen. With a physical keyboard Return sends and Shift-Return breaks the line, either way.
    static let returnSends = "chat.returnSends"
    /// Drag the thread sideways to reveal when messages were sent.
    static let timeReveal = "chat.timeReveal"
    /// Fold away the tool cards and reasoning once a turn is over.
    static let collapseAfterTurn = "chat.collapseAfterTurn"
    /// Whether an opened tool card shows its Output section.
    static let showToolOutput = "chat.showToolOutput"
    /// Shrinks tool cards to a single line.
    static let compactTools = "chat.compactTools"
    /// Keep only the step in progress: completed tool cards and finished replies' reasoning are hidden.
    static let currentStepOnly = "chat.currentStepOnly"
    /// Gathers a turn's tool calls into one muted line such as "6 steps · 41s" that opens when clicked.
    static let groupSteps = "chat.groupSteps"
    /// Lets reply bubbles stretch to the right edge rather than keeping a margin there.
    static let wideReplies = "chat.wideReplies"
    /// "small", "default" or "large", shifting just the thread a single Dynamic Type step smaller or bigger.
    static let textSize = "chat.textSize"
    /// Bubble look: "tailed" like Messages, "rounded" with no tails, or "plain", where replies have
    /// no bubble and read like a page.
    static let bubbleStyle = "chat.bubbleStyle"
    /// Tints reply bubbles with the bot's own colour in place of grey.
    static let botTint = "chat.botTint"
    /// Colour of your bubbles: "ink" (black on light screens, white on dark) or "accent" (the app's
    /// accent colour, as it used to be).
    static let userBubble = "chat.userBubble"
    static let headerShowsTitle = "chatHeaderShowsTitle"
    /// Mac only: the reading column the thread and composer both sit in, centred in the pane.
    static let macColumn: CGFloat = 860

    /// Type size the thread uses for a `textSize` choice, measured from the phone's own setting.
    static func stepped(_ base: DynamicTypeSize, _ choice: String) -> DynamicTypeSize {
        let sizes = DynamicTypeSize.allCases
        guard let here = sizes.firstIndex(of: base) else { return base }
        switch choice {
        case "small": return sizes[max(sizes.startIndex, here - 1)]
        case "large": return sizes[min(sizes.endIndex - 1, here + 1)]
        default: return base
        }
    }
}
