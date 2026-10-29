import SwiftUI
import NollieCore

// Holding a disclosure's header still while it opens, and bringing a notification's message into view.

extension TranscriptView {
    /// Only the header's movement matters. A long body remains available by scrolling down.
    func revealRow(_ note: Notification) {
        guard let event = TranscriptDisclosureEvent(notification: note),
              event.scope == disclosureScope,
              chat.items.contains(where: { $0.id == event.id }) else { return }
        if event.began {
            beginHolding(DisclosureScrollAnchor(id: event.id, top: event.top))
        } else if let anchor = revealAnchor, anchor.id == event.id, !metrics.userScrolling {
            metrics.disclosureTop = event.top
        }
    }

    /// A disclosure was tapped: its header's place is kept for a short while as it grows.
    private func beginHolding(_ anchor: DisclosureScrollAnchor) {
        revealAnchor = anchor
        metrics.disclosureTop = nil
        metrics.readingDisclosure = true
        metrics.stickToBottom = false
        tasks.stopMoving()
        // Clear the edge target without asking SwiftUI to scroll to a competing point. The geometry
        // callbacks only record a position; they never scroll or change view state while SwiftUI is
        // laying out the disclosure.
        scrollPosition = ScrollPosition(idType: String.self)
        tasks.reveal?.cancel()
        tasks.reveal = Task { @MainActor in
            // Each correction gets a fresh layout, with a hard end even if geometry never settles.
            // The main run loop stays free for taps and scrolling.
            for _ in 0..<20 {
                guard await pause(33) else { return }
                guard revealAnchor == anchor, !metrics.userScrolling else { return }
                if let top = metrics.disclosureTop {
                    metrics.disclosureTop = nil
                    correctDisclosureOffset(anchor, headerTop: top)
                }
            }
            guard !Task.isCancelled, revealAnchor == anchor else { return }
            (revealAnchor, metrics.disclosureTop) = (nil, nil)
        }
    }

    private func correctDisclosureOffset(_ anchor: DisclosureScrollAnchor, headerTop: CGFloat) {
        guard abs(headerTop - anchor.top) > 0.5 else { return }
        #if os(iOS)
        guard let scroller = metrics.scrollView else { return }
        let inset = scroller.adjustedContentInset
        let lowest = -inset.top
        let highest = max(lowest, scroller.contentSize.height + inset.bottom - scroller.bounds.height)
        let target = anchor.offset(current: scroller.contentOffset.y, headerTop: headerTop, minimum: lowest, maximum: highest)
        guard abs(target - scroller.contentOffset.y) > 0.5 else { return }
        scroller.setContentOffset(CGPoint(x: scroller.contentOffset.x, y: target), animated: false)
        #else
        let highest = max(0, metrics.contentHeight - metrics.containerHeight + bottomInset + 8)
        let target = anchor.offset(current: metrics.offsetY, headerTop: headerTop, minimum: 0, maximum: highest)
        guard abs(target - metrics.offsetY) > 0.5 else { return }
        var still = Transaction()
        still.disablesAnimations = true
        withTransaction(still) { scrollPosition.scrollTo(y: target) }
        #endif
    }

    func revealNotificationMessage() async {
        guard let focus = notificationFocus else { return }
        cancelledFocus = nil
        (highlightedMessage, messageNotice) = (nil, nil)
        tasks.stopMoving()
        tasks.reveal?.cancel()
        metrics.stickToBottom = false
        metrics.readingDisclosure = true
        func stillWanted() -> Bool {
            !Task.isCancelled && model.isCurrentNotification(focus.token) && model.runtime === chat.runtime
                && notificationFocus == focus && cancelledFocus != focus.token
        }
        // The history may still be arriving; give it a while.
        let giveUp = Date().addingTimeInterval(12)
        while chat.isResuming, Date() < giveUp {
            guard stillWanted(), await pause(100) else { return }
        }
        guard stillWanted() else { return }
        guard let target = focus.anchor(in: rows) else {
            messageNotice = chat.isResuming || chat.resumeError != nil
                ? String(localized: "That message couldn’t be loaded. Try opening the notification again when connected.")
                : String(localized: "That message is no longer available. You’re in the right conversation.")
            return
        }
        highlightedMessage = target
        // Let the history and lazy row identities settle before asking SwiftUI to position it.
        guard await pause(150), stillWanted() else { return }
        scrollPosition = ScrollPosition(idType: String.self)
        if reduceMotion || settling {
            scrollPosition.scrollTo(id: target, anchor: .center)
        } else {
            withAnimation(.easeInOut(duration: 0.35)) { scrollPosition.scrollTo(id: target, anchor: .center) }
        }
        // Lazy rows have their measured height after the first landing.
        guard await pause(400), stillWanted(), !metrics.userScrolling else { return }
        scrollPosition.scrollTo(id: target, anchor: .center)
    }
}
