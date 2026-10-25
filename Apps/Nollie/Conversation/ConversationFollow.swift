import CoreGraphics

/// Whether the conversation keeps its newest row on screen. Two states, and only the person's own scrolling moves
/// between them: new rows and a growing reply never do. See "Following" in `Docs/specs/conversation-ui.md`.
struct ConversationFollow: Equatable {
    enum Mode: Equatable {
        /// The bottom of the chat is on screen and stays there as rows arrive.
        case following
        /// The person scrolled up: nothing on screen moves until they come back.
        case reading
    }

    /// How far from the bottom still counts as at the bottom, in points.
    static let threshold: CGFloat = 64

    private(set) var mode: Mode = .following

    var isFollowing: Bool { mode == .following }

    /// The list moved under the person's finger or a flick of it. Leaving the bottom starts reading; coming back
    /// waits until the list rests.
    mutating func personScrolled(distanceFromBottom: CGFloat) {
        if distanceFromBottom > Self.threshold { mode = .reading }
    }

    /// The list came to rest after the person moved it. At the bottom, with the newest rows in the window, it
    /// follows again.
    mutating func cameToRest(distanceFromBottom: CGFloat, atNewestEnd: Bool) {
        mode = distanceFromBottom <= Self.threshold && atNewestEnd ? .following : .reading
    }

    /// The jump button, or the person sent a message: back to the newest row.
    mutating func jumpToNewest() { mode = .following }

    /// The rows on screen from the indices a scroll view says are visible: the longest run of neighbours (gaps of
    /// a hidden row or two allowed), so a stray index far away does not count.
    static func visibleSpan(_ indices: [Int]) -> ClosedRange<Int>? {
        let sorted = indices.sorted()
        guard var start = sorted.first else { return nil }
        var best = start...start
        var previous = start
        for index in sorted.dropFirst() {
            if index - previous > 3 { start = index }
            previous = index
            if index - start > best.upperBound - best.lowerBound { best = start...index }
        }
        return best
    }
}
