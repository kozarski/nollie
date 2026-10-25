import SwiftUI

/// Swiping the thread sideways uncovers each message's timestamp, like Messages does.
/// The column moves with one offset transform while the timestamps wait off the trailing edge,
/// which means a drag only re-renders this wrapper. The gesture is a UIKit pan installed on the
/// thread's scroll view (see `TimeRevealPan`), so all threads respond identically.
struct TimeRevealColumn<Content: View>: View {
    @ViewBuilder var content: Content

    @AppStorage(ChatStyle.timeReveal) private var enabled: Bool = true
    /// 0 when closed, 1 when fully pulled.
    @State private var reveal: CGFloat = .zero

    /// How far the bubbles slide at full reveal, in points.
    private static var travel: CGFloat { 80 }

    var body: some View {
        content
            .offset(x: -reveal * Self.travel)
            #if os(iOS)
            .background { TimeRevealPan(reveal: $reveal, enabled: enabled) }
            #endif
    }
}

#if os(iOS)
/// The numbers that decide whether a touch becomes a reveal drag.
private enum RevealRule {
    /// Smallest sideways travel before the drag may start.
    static let minimumLeft: CGFloat = 10
    /// Sideways travel has to beat vertical travel by this factor.
    static let sidewaysBias: CGFloat = 3
    /// The thread must have been still this long.
    static let restingTime: TimeInterval = 0.3
    /// Sideways distance that counts as fully revealed.
    static let fullPull: CGFloat = 100

    static func accepts(_ moved: CGPoint, velocityX: CGFloat) -> Bool {
        moved.x < -minimumLeft && velocityX < 0 && abs(moved.x) > abs(moved.y) * sidewaysBias
    }
}

/// Remembers when the thread last actually moved, by watching its vertical offset.
@MainActor
private final class StillnessWatch {
    private var watch: NSKeyValueObservation?
    private var lastY: CGFloat = 0
    private var movedAt = Date.distantPast

    func start(on scroll: UIScrollView) {
        lastY = scroll.contentOffset.y
        watch = scroll.observe(\.contentOffset, options: [.new]) { [weak self] view, _ in
            guard let self, abs(view.contentOffset.y - lastY) > 0.5 else { return }
            lastY = view.contentOffset.y
            movedAt = Date()
        }
    }

    func hasRested(for seconds: TimeInterval) -> Bool {
        Date().timeIntervalSince(movedAt) > seconds
    }
}

/// Finds the scroll view around the column and puts the reveal pan on it.
private struct TimeRevealPan: UIViewRepresentable {
    @Binding var reveal: CGFloat
    var enabled = true

    func makeCoordinator() -> Coordinator { Coordinator(reveal: $reveal) }

    func makeUIView(context: Context) -> Probe {
        let probe = Probe()
        probe.isUserInteractionEnabled = false
        probe.owner = context.coordinator
        return probe
    }

    func updateUIView(_ probe: Probe, context: Context) {
        context.coordinator.enabled = enabled
        context.coordinator.reveal = $reveal
    }

    /// Invisible view whose only job is to notice it has a window, then call back.
    final class Probe: UIView {
        weak var owner: Coordinator?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard window != nil else { return }
            owner?.attach(from: self)
        }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var reveal: Binding<CGFloat>
        var enabled = true
        private weak var scroller: UIScrollView?
        private weak var pan: UIPanGestureRecognizer?
        private let stillness = StillnessWatch()

        init(reveal: Binding<CGFloat>) { self.reveal = reveal }

        func attach(from view: UIView) {
            guard let found = view.enclosingScrollView, found !== scroller else { return }
            if let pan, let previous = scroller { previous.removeGestureRecognizer(pan) }
            scroller = found
            pan = installPan(on: found)
            stillness.start(on: found)
        }

        private func installPan(on scroll: UIScrollView) -> UIPanGestureRecognizer {
            let made = UIPanGestureRecognizer(target: self, action: #selector(dragged(_:)))
            made.maximumNumberOfTouches = 1
            made.delegate = self
            made.name = "nollie.timeReveal"
            scroll.addGestureRecognizer(made)
            return made
        }

        // MARK: Whether to begin

        func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
            guard recognizer === pan, let scroller, let drag = recognizer as? UIPanGestureRecognizer else { return true }
            guard enabled, !scroller.isDecelerating, stillness.hasRested(for: RevealRule.restingTime) else { return false }
            // A thumb drifting diagonally while reading must not slide the chat sideways.
            return RevealRule.accepts(drag.translation(in: scroller), velocityX: drag.velocity(in: scroller).x)
        }

        func gestureRecognizer(_ recognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            other === scroller?.panGestureRecognizer
        }

        /// Views with their own horizontal scrolling, such as a wide table inside a bubble, get their touches first.
        func gestureRecognizer(_ recognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            guard recognizer === pan else { return true }
            return !Self.startsInSideScroller(touch.view, below: scroller)
        }

        static func startsInSideScroller(_ view: UIView?, below thread: UIScrollView?) -> Bool {
            var node = view
            while let current = node, current !== thread {
                if let scroll = current as? UIScrollView, scroll.contentSize.width > scroll.bounds.width + 1 { return true }
                node = current.superview
            }
            return false
        }

        // MARK: Following the finger

        @objc private func dragged(_ drag: UIPanGestureRecognizer) {
            guard let scroller else { return }
            let pulled = -drag.translation(in: scroller).x / RevealRule.fullPull
            let amount = min(1, max(0, pulled))
            switch drag.state {
            case .began:
                releaseScrollPan(of: scroller)
                reveal.wrappedValue = amount
            case .changed:
                reveal.wrappedValue = amount
            default:
                withAnimation(.snappy) { reveal.wrappedValue = 0 }
            }
        }

        /// Toggling the scroll view's own pan makes it let go of this touch.
        private func releaseScrollPan(of scroll: UIScrollView) {
            scroll.panGestureRecognizer.isEnabled = false
            scroll.panGestureRecognizer.isEnabled = true
        }
    }
}
#endif
