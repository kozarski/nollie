import SwiftUI
import NollieCore

// Everything about keeping the thread on its end (or letting go): following new content,
// keyboard and dock changes, the jump arrow, and corrections for lazy-stack estimates.

extension TranscriptView {
    /// Jumps to the end instantly.
    func pinToEnd() { scrollPosition.scrollTo(edge: .bottom) }

    /// Waits, then reports whether the surrounding task is still live.
    func pause(_ milliseconds: Int) async -> Bool {
        try? await Task.sleep(for: .milliseconds(milliseconds))
        return !Task.isCancelled
    }

    /// Glides to the end.
    func easeToBottom(_ seconds: Double = 0.2) {
        withAnimation(.easeOut(duration: seconds)) { pinToEnd() }
    }

    func easeToBottomIfFollowing() {
        if mayFollow() { easeToBottom() }
    }

    /// A new card brings a thread that is on its end down with it.
    func followApprovals() { easeToBottomIfFollowing() }

    /// Whether new content may carry the thread along. It needs the follow flag, no touch in
    /// progress, and the end close by. If the end is over 1.5 screens away someone is reading
    /// earlier text, so the flag is cleared instead of pulling them down.
    func mayFollow() -> Bool {
        if !metrics.followsEnd { return false }
        let tooFar = metrics.distanceFromBottom > max(900, metrics.containerHeight * 1.5)
        if tooFar { metrics.stickToBottom = false }
        return !tooFar
    }

    /// A complete reply can drop in several screens at once, further than `mayFollow` allows. If
    /// the thread was on its end, pin it now and again up to four times while rows get measured,
    /// unless the reader touches it.
    func landArrivedReply() {
        guard metrics.followsEnd else { return }
        pinToEnd()
        Task { @MainActor in
            var remaining = 4
            while remaining > 0, await pause(60), !metrics.userScrolling {
                metrics.stickToBottom = true
                pinToEnd()
                remaining -= 1
            }
        }
    }

    /// Rows appeared or disappeared while following: move with them.
    func followRows(from old: Int, to new: Int) {
        if !mayFollow() { return }
        // Moving rows into the lazy part alters the content above the viewport, so jump instead
        // of animating.
        let boundaryMoved = TranscriptRowModel.split(count: new, tailFrom: tailFrom)
            != TranscriptRowModel.split(count: old, tailFrom: tailFrom)
        if settling || boundaryMoved { pinToEnd() } else { easeToBottom(0.28) }
    }

    /// React to a dock height change once it holds still.
    func followDockHeight() {
        guard metrics.followsEnd else { return }
        tasks.insetSettle?.cancel()
        tasks.insetSettle = Task {
            guard await pause(80), metrics.followsEnd else { return }
            if settling { pinToEnd() } else { easeToBottom() }
        }
    }

    func landAfterResume() async {
        if chat.isResuming { return }
        for delay in [300, 900] {
            guard await pause(delay), metrics.followsEnd else { return }
            if !metrics.isNearEnd() { pinToEnd() }
        }
    }

    /// After a quiet moment, shifts the boundary between lazy and eager rows. It requires the
    /// thread to sit on its end (so the crossing rows are off screen and a re-pin hides the
    /// change), and no turn in progress, because a pause during a tool call looks idle while
    /// freshly lazy rows briefly overlap their neighbours. During a turn it may only set a
    /// boundary that does not exist yet.
    func settleTail() async {
        guard await pause(400) else { return }
        let total = rows.count
        let goal = TranscriptRowModel.tailStart(total)
        guard metrics.followsEnd, tailFrom != goal else { return }
        let wouldCross = TranscriptRowModel.split(count: total, tailFrom: tailFrom) != goal
        if wouldCross && chat.isRunning { return }
        tailFrom = goal
        if wouldCross { pinToEnd() }
    }

    // MARK: What the scroll view reports

    /// Learns the scroll view's own inset from the first report after the dock is known, and again
    /// whenever the scroll view changes size (a rotated, resized or unfolded window). Never while
    /// only the dock moves, which would feed back into itself.
    func measureAutoInset(from reported: CGFloat) {
        guard dockTop > 0 else { return }
        #if os(iOS)
        let size = metrics.scrollView?.bounds.size ?? .zero
        guard autoInsetFixed == nil || size != metrics.autoInsetBasis else { return }
        metrics.autoInsetBasis = size
        let extra = max(0, reported - (bottomInset + 8))
        autoInsetFixed = (homeIndicatorHeight > 0 && extra > homeIndicatorHeight / 2) ? homeIndicatorHeight : 0
        #else
        if autoInsetFixed == nil { autoInsetFixed = 0 } // a window has no home indicator
        #endif
    }

    func distanceFromBottomChanged(from was: CGFloat, to distance: CGFloat) {
        metrics.distanceFromBottom = distance
        let fingerDown = metrics.userScrolling
        let idle = !fingerDown && !metrics.readingDisclosure
        // Scrolled past the real end with no touch: an estimate-based jump went too far and the
        // view would stay blank until nudged. Correct it.
        if idle, distance < -60 { scheduleOverscrollFix() }
        let farFromEnd = distance > 120
        if farFromEnd != awayFromBottom {
            withAnimation(.snappy) { awayFromBottom = farFromEnd }
        }
        // Content growth can make the end look distant for a frame, so only a touch may release
        // the follow flag: dragging up from the touch's starting distance. Lifting the finger at
        // the end sets it again.
        if fingerDown, distance > 24 || distance > metrics.touchStartDistance + 6 { metrics.stickToBottom = false }
        // Only a gap that closed steadily re-engages. Content that shrinks for one frame (rows swapped,
        // a lazy row measured again) clamps the offset and would fake an arrival.
        if idle, distance < 4, was < 60 { metrics.stickToBottom = true }
    }

    func scrollPhaseChanged(_ phase: ScrollPhase) {
        // A touch counts from first contact, before anything moves.
        let touching = [ScrollPhase.tracking, .interacting, .decelerating].contains(phase)
        if touching {
            if !metrics.userScrolling { metrics.touchStartDistance = metrics.distanceFromBottom }
            metrics.readingDisclosure = false
            revealAnchor = nil
            tasks.reveal?.cancel()
            cancelledFocus = notificationFocus?.token
        }
        metrics.userScrolling = touching
        if !touching, !metrics.readingDisclosure, metrics.distanceFromBottom < 4 { metrics.stickToBottom = true }
    }

    #if os(iOS)
    /// The home indicator height of the window the thread is in; 0 if it has none.
    var homeIndicatorHeight: CGFloat { metrics.scrollView?.window?.safeAreaInsets.bottom ?? 0 }

    func keyboardMoved(_ note: Notification) {
        guard let raised = ThreadMetrics.keyboardInset(note, in: metrics.scrollView?.window) else { return }
        // A spring tuned to the system keyboard's, so content and composer land together.
        let followKeyboard = Animation.interpolatingSpring(mass: 3, stiffness: 1000, damping: 500)
        withAnimation(followKeyboard) {
            keyboardInset = raised
            if metrics.stickToBottom { pinToEnd() }
        }
        tasks.keyboardFloor?.cancel()
        if raised <= 0 {
            keyboardFloor = 0
            return
        }
        tasks.keyboardFloor = Task { @MainActor in
            guard await pause(450) else { return }
            keyboardFloor = raised
            if metrics.followsEnd { pinToEnd() }
        }
    }
    #endif

    // MARK: Fixing up, and the jump arrow

    func scheduleOverscrollFix() {
        guard tasks.overscroll == nil else { return }
        tasks.overscroll = Task { @MainActor in
            let stillValid = await pause(120)
            defer { tasks.overscroll = nil }
            guard stillValid, !metrics.userScrolling, metrics.distanceFromBottom < -8 else { return }
            Perf.tick("overscrollFix")
            clampToMeasuredEnd()
        }
    }

    /// If the tail shrinks, the "bottom edge" target may still count as met while content sits
    /// beneath the composer. On iPhone the offset is therefore written directly.
    private func clampToMeasuredEnd() {
        #if os(iOS)
        guard let scroller = metrics.scrollView else { return pinToEnd() }
        let insets = scroller.adjustedContentInset
        let lastOffset = scroller.contentSize.height + insets.bottom - scroller.bounds.height
        scrollPosition = ScrollPosition(idType: String.self)
        scroller.setContentOffset(CGPoint(x: scroller.contentOffset.x, y: max(-insets.top, lastOffset)), animated: false)
        #else
        pinToEnd()
        #endif
    }

    /// The arrow button. Animating a long way through lazy rows made bubbles flicker, so a far jump
    /// lands without animation and a near one eases.
    func jumpToBottom() {
        metrics.readingDisclosure = false
        metrics.stickToBottom = true
        revealAnchor = nil
        tasks.reveal?.cancel()
        tasks.jump?.cancel()
        let farAway = metrics.distanceFromBottom > 900
        tasks.jump = Task { @MainActor in
            if farAway { await landFlatAtEnd() } else { await glideToEnd() }
        }
    }

    /// True when the thread is a little above the end.
    private var shortOfEnd: Bool { metrics.distanceFromBottom > 24 }

    /// With the end far away, lazy heights are guesses; so pin without animation, repeatedly, as
    /// the rows get measured and the true end moves, until the thread has arrived.
    private func landFlatAtEnd() async {
        pinToEnd()
        for _ in 1...20 {
            guard await pause(70), !metrics.userScrolling else { return }
            if !shortOfEnd { break }
            pinToEnd()
        }
        if shortOfEnd { scrollPosition.scrollTo(id: "bottom", anchor: .bottom) }
    }

    private func glideToEnd() async {
        easeToBottom(0.35)
        // Fallback in case the ease fell short: pin it without animation.
        guard await pause(500), shortOfEnd else { return }
        pinToEnd()
        guard await pause(60), shortOfEnd else { return }
        scrollPosition.scrollTo(id: "bottom", anchor: .bottom)
    }
}
