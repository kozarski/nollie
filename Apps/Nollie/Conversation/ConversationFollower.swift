import SwiftUI
import NollieCore

/// The follow state shared by the screen (the jump button) and the list that moves it. The list reports the
/// person's scrolling here; the screen asks for the trip back to the newest row here.
@MainActor
@Observable
final class ConversationFollower {
    private(set) var follow = ConversationFollow()
    var isFollowing: Bool { follow.isFollowing }
    /// The list that carries out a jump.
    @ObservationIgnored weak var driver: (any ConversationListDriver)?

    func personScrolled(distanceFromBottom distance: CGFloat) {
        var next = follow
        next.personScrolled(distanceFromBottom: distance)
        if next != follow { follow = next }
    }

    func cameToRest(distanceFromBottom distance: CGFloat, atNewestEnd: Bool) {
        var next = follow
        next.cameToRest(distanceFromBottom: distance, atNewestEnd: atNewestEnd)
        if next != follow { follow = next }
    }

    /// The jump button, or a message sent while reading: follow again and go to the newest row.
    func jumpToNewest() {
        if !follow.isFollowing { follow.jumpToNewest() }
        driver?.jumpToNewest()
    }

    /// The status bar tap that scrolls to the top: reading from here.
    func leftTheBottom() { personScrolled(distanceFromBottom: .greatestFiniteMagnitude) }
}

@MainActor
protocol ConversationListDriver: AnyObject {
    func jumpToNewest()
}
