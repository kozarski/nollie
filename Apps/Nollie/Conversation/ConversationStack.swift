import CoreGraphics

/// The conversation list's geometry, pure so both collection views (UIKit and AppKit) share it and tests can
/// drive it: one column of items, each as tall as it measured (or an estimate until it has), resting on the
/// bottom when they do not fill the room. Heights are kept by item id for the current width, so rows that page
/// out and back in come back at the height they had. See "Layout" in `Docs/specs/conversation-ui.md`.
struct ConversationStack: Equatable {
    /// The height of an item not measured yet.
    var estimate: CGFloat = 80
    private(set) var ids: [String] = []
    private(set) var width: CGFloat = 0
    /// Room between the insets: a short chat sits at its bottom.
    private(set) var room: CGFloat = 0
    /// Measured heights at `width`, by item id.
    private(set) var heights: [String: CGFloat] = [:]
    /// The top of each item, and the total, worked out by `layOut()`.
    private(set) var tops: [CGFloat] = []
    private(set) var contentHeight: CGFloat = 0

    /// Space above the first item so a chat shorter than the room rests on its bottom.
    var lead: CGFloat { max(0, room - total) }
    private var total: CGFloat = 0

    /// New items, in order. Heights of items that left are dropped; ones that stay keep theirs.
    mutating func set(ids new: [String]) {
        guard new != ids else { return }
        ids = new
        if heights.count > new.count * 2 {
            let kept = Set(new)
            heights = heights.filter { kept.contains($0.key) }
        }
        layOut()
    }

    /// The list's size. A new width forgets every height (text wraps differently); a new room only moves the lead.
    mutating func set(width newWidth: CGFloat, room newRoom: CGFloat) {
        if abs(newWidth - width) > 0.5 {
            width = newWidth
            heights.removeAll()
        }
        room = max(0, newRoom)
        layOut()
    }

    func height(of id: String) -> CGFloat { heights[id] ?? estimate }

    func isMeasured(_ id: String) -> Bool { heights[id] != nil }

    /// An item measured itself. Returns how much taller it got (negative if shorter), or nil if no change.
    @discardableResult
    mutating func measured(_ id: String, height: CGFloat) -> CGFloat? {
        let new = max(1, height.rounded(.up))
        let old = self.height(of: id)
        let wasMeasured = isMeasured(id)
        heights[id] = new
        guard abs(new - old) > 0.25 || !wasMeasured else { return nil }
        layOut()
        return new - old
    }

    mutating func layOut() {
        var y: CGFloat = 0
        tops.removeAll(keepingCapacity: true)
        tops.reserveCapacity(ids.count)
        for id in ids {
            tops.append(y)
            y += height(of: id)
        }
        total = y
        let lead = lead
        if lead > 0 { tops = tops.map { $0 + lead } }
        contentHeight = max(total, room)
    }

    func frame(at index: Int) -> CGRect {
        guard tops.indices.contains(index) else { return .zero }
        return CGRect(x: 0, y: tops[index], width: width, height: height(of: ids[index]))
    }

    /// Indices of the items that meet `minY..<maxY`, found by bisection.
    func indices(from minY: CGFloat, to maxY: CGFloat) -> Range<Int> {
        guard !ids.isEmpty else { return 0..<0 }
        var low = 0, high = ids.count
        // The first item whose bottom is below minY.
        while low < high {
            let mid = (low + high) / 2
            if tops[mid] + height(of: ids[mid]) <= minY { low = mid + 1 } else { high = mid }
        }
        var end = low
        while end < ids.count, tops[end] < maxY { end += 1 }
        return low..<end
    }

    /// How far the offset must move so a change in an item's height leaves what is on screen where it is.
    /// `visibleTop` is the top of the room in content coordinates. An item coming into view across the top edge
    /// (its first measure) grows upward; an item already measured that changes (a reply growing) grows at its
    /// end, so it only moves the screen when it is wholly above it.
    static func offsetAdjustment(itemTop: CGFloat, itemBottom: CGFloat, delta: CGFloat, firstMeasure: Bool,
                                 visibleTop: CGFloat) -> CGFloat {
        if firstMeasure { return itemTop < visibleTop - 0.5 ? delta : 0 }
        return itemBottom <= visibleTop + 0.5 ? delta : 0
    }
}

/// The row at the top of the screen and where it sits there, so the list can put it back after rows arrive above
/// it.
struct ConversationAnchor: Equatable {
    var id: String
    /// From the top of the room to the top of the row; negative when the row starts above it.
    var offset: CGFloat

    /// The first item that reaches below the top of the room.
    static func find(in stack: ConversationStack, visibleTop: CGFloat) -> ConversationAnchor? {
        let range = stack.indices(from: visibleTop, to: visibleTop + 1)
        guard let index = range.first ?? (stack.ids.isEmpty ? nil : stack.ids.count - 1) else { return nil }
        let frame = stack.frame(at: index)
        return ConversationAnchor(id: stack.ids[index], offset: frame.minY - visibleTop)
    }

    /// The new top of the room that keeps the anchor row where it was, or nil if it is gone.
    func visibleTop(in stack: ConversationStack) -> CGFloat? {
        guard let index = stack.ids.firstIndex(of: id) else { return nil }
        return stack.frame(at: index).minY - offset
    }
}
