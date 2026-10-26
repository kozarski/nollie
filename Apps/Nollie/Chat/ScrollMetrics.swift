import SwiftUI

/// Numbers that change on every frame of a scroll. Deliberately not observable: storing them in
/// view state re-evaluated the whole transcript, row by row, on each frame of a flick.
final class ScrollMetrics {
    #if os(iOS)
    /// The UIKit scroller wrapped by the SwiftUI one. Programmatic distance scrolls need it. Its content
    /// offset and the row frames (global space) are in one scale, so they can be subtracted directly.
    weak var scrollView: UIScrollView?
    #endif
    /// True means follow new output (tokens, tool calls, cards) at the bottom. Only the user dragging
    /// clears it; tapping the jump button or reaching the end sets it again.
    var stickToBottom: Bool = true
    var userScrolling: Bool = false
    var readingDisclosure: Bool = false
    /// Newest geometry waiting for the bounded disclosure task; taken once per layout pass.
    var disclosureTop: CGFloat?
    var distanceFromBottom: CGFloat = 0
    /// Distance from the end when the current touch began.
    var touchStartDistance: CGFloat = 0
    var offsetY: CGFloat = 0
    var contentHeight: CGFloat = 0
    var containerHeight: CGFloat = 0
    var reportedInsetBottom: CGFloat = 0
    /// The scroll view's size when its own inset was last measured; a new size measures again.
    var autoInsetBasis: CGSize = .zero

    /// Locked to the end and untouched: new content may be followed.
    var followsEnd: Bool { stickToBottom && !userScrolling }
    /// True once the thread has come to rest within a hair of the end.
    func isNearEnd(within slack: CGFloat = 8) -> Bool { abs(distanceFromBottom) <= slack }
}

#if os(macOS)
/// The Mac has no UIKit scroll view to locate, so distance scrolling goes through the SwiftUI
/// scroll position, which an empty probe view points at.
struct ScrollViewProbe: View {
    let metrics: ScrollMetrics
    var body: some View { Color.clear }
}
#else
/// Locates the scroller sitting under the thread and stores it in the metrics object.
struct ScrollViewProbe: UIViewRepresentable {
    let metrics: ScrollMetrics

    func makeUIView(context: Context) -> Finder {
        let finder = Finder()
        finder.metrics = metrics
        finder.isUserInteractionEnabled = false
        return finder
    }

    func updateUIView(_ finder: Finder, context: Context) { finder.metrics = metrics }

    final class Finder: UIView {
        var metrics: ScrollMetrics?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            metrics?.scrollView = enclosingScrollView
        }
    }
}

extension UIView {
    /// The closest scroll view among this view's ancestors, if there is one.
    var enclosingScrollView: UIScrollView? {
        sequence(first: superview, next: { $0?.superview })
            .compactMap { $0 as? UIScrollView }
            .first
    }
}
#endif

/// Cached time strings. Formatting runs through ICU and the thread re-evaluates its rows frequently.
@MainActor
enum TimeLabels {
    private static var minuteWords: [Int: String] = [:]

    /// Example output: "Nov 12, 2026 at 8:05 AM". Rebuilt every minute.
    static func hover(_ date: Date) -> String {
        let minute = Int(date.timeIntervalSinceReferenceDate / 60)
        if let cached = minuteWords[minute] { return cached }
        if minuteWords.count > 4096 { minuteWords.removeAll(keepingCapacity: true) }
        let text = date.formatted(date: .abbreviated, time: .shortened)
        minuteWords[minute] = text
        return text
    }
}
