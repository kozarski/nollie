import CoreGraphics

/// How the wide layout shares out its width: the bot list on the left, the chat beside it, and a
/// panel (Watch, a card, a file, Papertrail) that takes the right half while the chat moves to
/// the left half. A fold in use (an iPhone Duo held half open like a book) sets the dividing line
/// itself, so no column sits on the crease.
struct SplitLayout: Equatable {
    struct Column: Equatable {
        var x: CGFloat
        var width: CGFloat
        var maxX: CGFloat { x + width }
    }

    var list: Column
    var chat: Column
    var panel: Column?
    /// The panel covers the whole width; the chat stays laid out beneath it.
    var expanded = false

    /// While a panel is open the chat takes the list's place.
    var listCovered: Bool { panel != nil }

    /// About a third for the list, within comfortable limits.
    static let listShare: CGFloat = 1.0 / 3.0
    static let listMin: CGFloat = 300
    static let listMax: CGFloat = 420

    /// The columns for `width`. `fold` is the crease's span across the width, when one is in use.
    static func make(width: CGFloat, fold: ClosedRange<CGFloat>? = nil, panelOpen: Bool = false,
                     expanded: Bool = false) -> SplitLayout {
        let width = max(0, width)
        if let fold, fold.lowerBound > 0, fold.upperBound < width {
            let left = Column(x: 0, width: fold.lowerBound)
            let right = Column(x: fold.upperBound, width: width - fold.upperBound)
            // Half open, both halves stay put: the panel cannot spread over the crease.
            return panelOpen ? SplitLayout(list: left, chat: left, panel: right)
                : SplitLayout(list: left, chat: right, panel: nil)
        }
        let listWidth = min(max(width * listShare, listMin), listMax, width / 2).rounded()
        let list = Column(x: 0, width: listWidth)
        guard panelOpen else {
            return SplitLayout(list: list, chat: Column(x: listWidth, width: width - listWidth), panel: nil)
        }
        let half = (width / 2).rounded()
        let chat = Column(x: 0, width: half)
        let panel = expanded ? Column(x: 0, width: width) : Column(x: half, width: width - half)
        return SplitLayout(list: list, chat: chat, panel: panel, expanded: expanded)
    }

    /// The crease to keep clear, from the division regions the system reports in this view's
    /// space: one active region running top to bottom, near the middle. A crease across the
    /// screen (held the other way up) leaves the columns alone; the thread scrolls past it.
    static func fold(in regions: [CGRect], size: CGSize) -> ClosedRange<CGFloat>? {
        guard size.width > 0, size.height > 0 else { return nil }
        for region in regions {
            let upright = region.height > region.width && region.height >= size.height / 2
            let central = region.midX > size.width * 0.25 && region.midX < size.width * 0.75
            guard upright, central else { continue }
            let low = max(0, region.minX), high = min(size.width, region.maxX)
            if low < high { return low...high }
        }
        return nil
    }

    /// Whether the window is wide enough to show the list beside a chat. The size class decides,
    /// with a floor so a regular but narrow window keeps the phone's single stack.
    static func showsSplit(regularWidth: Bool, width: CGFloat) -> Bool {
        regularWidth && width >= 600
    }
}
