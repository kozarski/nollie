#if os(iOS)
import SwiftUI
import UIKit
import NollieCore

/// The conversation list on iPhone and iPad: a `UICollectionView` whose cells host the SwiftUI row views
/// (`UIHostingConfiguration`), on a one-column layout of its own (`ConversationStack`). It keeps the newest row on
/// the composer while following, and keeps the row at the top of the screen where it is when rows arrive above
/// it, also while a finger drags the list or it coasts. Rows are measured here, a screen ahead of where the list
/// is going, rather than by UIKit's self-sizing: reused cells measured themselves with the last row's height now
/// and then (54 points off, then back), which moved what was on screen. See `Docs/specs/conversation-ui.md`.
struct ConversationList: UIViewRepresentable {
    let engine: ConversationEngine
    let items: [ConversationListItem]
    let follower: ConversationFollower
    /// The header above and the composer (and keyboard) below: the list scrolls under both.
    let insets: EdgeInsets
    let answer: (ConversationCard, ConversationCardAction) -> Void
    let post: (ConversationPost, ConversationPostTap) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(engine: engine, follower: follower, answer: answer, post: post) }

    func makeUIView(context: Context) -> UICollectionView { context.coordinator.makeView() }

    func updateUIView(_ view: UICollectionView, context: Context) {
        let coordinator = context.coordinator
        coordinator.engine = engine
        coordinator.answer = answer
        coordinator.post = post
        coordinator.set(insets: UIEdgeInsets(top: insets.top, left: 0, bottom: insets.bottom, right: 0))
        coordinator.update(items)
    }

    @MainActor
    final class Coordinator: NSObject, UICollectionViewDelegate, ConversationListDriver {
        var engine: ConversationEngine
        let follower: ConversationFollower
        var answer: (ConversationCard, ConversationCardAction) -> Void
        var post: (ConversationPost, ConversationPostTap) -> Void
        private var collection: ConversationCollectionView!
        private var layout: ConversationListLayout!
        private var dataSource: UICollectionViewDiffableDataSource<Int, String>!
        private var items: [ConversationListItem] = []
        private var byID: [String: ConversationListItem] = [:]
        /// Each transcript row's index in the transcript last applied, for paging.
        private var transcriptIndex: [String: Int] = [:]
        private var appliedTranscriptCount = 0
        /// Above zero while the list moves itself, so it is not taken for the person scrolling.
        private var moving = 0
        /// A trip to the newest row under way (an animated scroll).
        private var jumping = false
        private var reportedSpan: ClosedRange<Int>?
        /// When rows near an end of the window were last reported again, unchanged.
        private var edgeReportedAt: CFTimeInterval = 0
        private var width: CGFloat = 0
        /// Hosting controllers that measure rows at the list's width, one for each kind of entry.
        private var sizers: [String: UIHostingController<AnyView>] = [:]
        private var measuring = false
        /// Measures rows off screen a little each frame while some are not measured yet.
        private var ticker: CADisplayLink?

        init(engine: ConversationEngine, follower: ConversationFollower, answer: @escaping (ConversationCard, ConversationCardAction) -> Void,
             post: @escaping (ConversationPost, ConversationPostTap) -> Void = { _, _ in }) {
            self.engine = engine
            self.follower = follower
            self.answer = answer
            self.post = post
        }

        func makeView() -> UICollectionView {
            layout = ConversationListLayout()
            collection = ConversationCollectionView(frame: .zero, collectionViewLayout: layout)
            collection.coordinator = self
            collection.backgroundColor = .clear
            collection.contentInsetAdjustmentBehavior = .never
            collection.alwaysBounceVertical = true
            collection.keyboardDismissMode = .interactive
            collection.delegate = self
            collection.accessibilityIdentifier = "conversation.list"
            // One registration for each kind of entry: a reused cell then keeps the same SwiftUI structure.
            var registrations: [String: UICollectionView.CellRegistration<ConversationCell, String>] = [:]
            for kind in ConversationListItem.kinds {
                registrations[kind] = UICollectionView.CellRegistration<ConversationCell, String> { [unowned self] cell, _, id in
                    guard let item = self.byID[id] else { return }
                    let content = self.content(for: item)
                    cell.contentConfiguration = UIHostingConfiguration { content }
                        .margins(.all, 0)
                    cell.backgroundConfiguration = .clear()
                }
            }
            dataSource = UICollectionViewDiffableDataSource(collectionView: collection) { [unowned self] view, path, id in
                let kind = self.byID[id]?.kind ?? "note"
                return view.dequeueConfiguredReusableCell(using: registrations[kind]!, for: path, item: id)
            }
            follower.driver = self
            return collection
        }

        /// One entry as a cell draws it and as it is measured: the same view at the list's width.
        private func content(for item: ConversationListItem) -> some View {
            ConversationItemView(item: item, bubbleWidth: ConversationMetrics.bubbleWidth(listWidth: collection.bounds.width),
                                 answer: answer, post: post)
                .padding(.horizontal, ConversationMetrics.side)
        }

        // MARK: Rows

        /// The engine's entries, applied without moving what is on screen: while following the newest row stays on
        /// the composer; while reading the row at the top of the screen stays at the same height.
        func update(_ new: [ConversationListItem]) {
            let change = ConversationListChange(from: items, to: new)
            let firstLoad = items.isEmpty && !new.isEmpty
            guard !change.isEmpty || firstLoad else { return }
            #if DEBUG
            let started = CACurrentMediaTime()
            defer {
                let ms = (CACurrentMediaTime() - started) * 1000
                ConversationListTiming.updateMs += ms
                ConversationListTiming.updates += 1
                ConversationListTiming.longestUpdateMs = max(ConversationListTiming.longestUpdateMs, ms)
            }
            #endif
            let keepBottom = firstLoad || (follower.isFollowing && !collection.isTracking && !jumping)
            let anchor = keepBottom ? nil : ConversationAnchor.find(in: layout.stack, visibleTop: visibleTop)
            items = new
            byID = Dictionary(new.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            var index: [String: Int] = [:]
            var count = 0
            for item in new {
                guard let row = item.row else { continue }
                index[row.id] = count
                count += 1
            }
            transcriptIndex = index
            appliedTranscriptCount = count
            if !change.sameOrder { reportedSpan = nil }

            var snapshot: NSDiffableDataSourceSnapshot<Int, String>
            if change.sameOrder {
                snapshot = dataSource.snapshot()
            } else {
                snapshot = NSDiffableDataSourceSnapshot()
                snapshot.appendSections([0])
                snapshot.appendItems(change.ids)
            }
            if !change.changed.isEmpty { snapshot.reconfigureItems(change.changed) }
            moving += 1
            layout.set(ids: change.ids)
            // Rows that changed (a reply growing) are measured again now, and the ones about to be on screen.
            for id in change.changed where layout.stack.isMeasured(id) { measure(id) }
            if keepBottom {
                measureBottom()
            } else if let anchor, let top = anchor.visibleTop(in: layout.stack) {
                measureAround(top: top)
            }
            layout.pending = keepBottom ? .bottom : anchor.map { .anchor($0) }
            UIView.performWithoutAnimation {
                dataSource.apply(snapshot, animatingDifferences: false)
                collection.layoutIfNeeded()
                if keepBottom {
                    toBottom()
                } else if let anchor, let top = anchor.visibleTop(in: layout.stack) {
                    let target = top - collection.adjustedContentInset.top
                    if abs(collection.contentOffset.y - target) > 0.25 { collection.contentOffset.y = target }
                }
            }
            layout.pending = nil
            moving -= 1
            reportVisible()
            measureLater()
        }

        func set(insets: UIEdgeInsets) {
            guard collection.contentInset != insets else { return }
            let keepBottom = follower.isFollowing && !collection.isTracking && !jumping
            moving += 1
            collection.contentInset = insets
            collection.verticalScrollIndicatorInsets = insets
            layout.invalidateLayout()
            collection.layoutIfNeeded()
            if keepBottom { toBottom() }
            moving -= 1
        }

        /// Called after every layout pass of the list: a width change redraws the rows for it, and while following
        /// the end stays on the composer however the rows grew.
        func didLayout() {
            if abs(collection.bounds.width - width) > 0.5 {
                width = collection.bounds.width
                if !items.isEmpty {
                    // After this pass: rows are measured and drawn again for the new width.
                    DispatchQueue.main.async { [weak self] in
                        guard let self, !self.items.isEmpty else { return }
                        self.moving += 1
                        if self.follower.isFollowing { self.measureBottom() } else { self.measureAround(top: self.visibleTop) }
                        var snapshot = self.dataSource.snapshot()
                        snapshot.reconfigureItems(snapshot.itemIdentifiers)
                        self.dataSource.apply(snapshot, animatingDifferences: false)
                        self.collection.layoutIfNeeded()
                        if self.follower.isFollowing { self.toBottom() }
                        self.moving -= 1
                        self.measureLater()
                    }
                }
            }
            guard moving == 0, follower.isFollowing, !collection.isTracking, !collection.isDecelerating, !jumping else { return }
            if abs(collection.contentOffset.y - bottomOffset) > 0.5 {
                moving += 1
                toBottom()
                moving -= 1
            }
        }

        // MARK: Measuring

        /// Measures one row at the list's width. While the person reads, a row that turned out taller or shorter
        /// above the screen moves the offset by as much, so nothing on screen moves.
        private func measure(_ id: String) {
            guard let entry = byID[id], collection.bounds.width > 0, let index = layout.stack.ids.firstIndex(of: id) else { return }
            let measurer = sizer(for: entry.kind)
            measurer.rootView = AnyView(content(for: entry))
            #if DEBUG
            let started = CACurrentMediaTime()
            defer {
                ConversationListTiming.measureMs += (CACurrentMediaTime() - started) * 1000
                ConversationListTiming.measured += 1
            }
            #endif
            let size = measurer.sizeThatFits(in: CGSize(width: collection.bounds.width, height: .greatestFiniteMagnitude))
            let before = layout.stack.frame(at: index)
            let first = !layout.stack.isMeasured(id)
            let top = visibleTop
            guard let delta = layout.measured(id, height: size.height), moving == 0, !follower.isFollowing else { return }
            let adjustment = ConversationStack.offsetAdjustment(itemTop: before.minY, itemBottom: before.maxY, delta: delta,
                                                                firstMeasure: first, visibleTop: top)
            if adjustment != 0 { adjust(by: adjustment) }
        }

        private func sizer(for kind: String) -> UIHostingController<AnyView> {
            if let sizer = sizers[kind] { return sizer }
            let sizer = UIHostingController(rootView: AnyView(EmptyView()))
            sizer.safeAreaRegions = []
            // In the list's hierarchy, so rows are measured with its text size.
            sizer.view.isHidden = true
            sizer.view.isUserInteractionEnabled = false
            collection.addSubview(sizer.view)
            sizers[kind] = sizer
            return sizer
        }

        /// Measures the newest rows not measured yet, two screens' worth.
        private func measureBottom() {
            var height: CGFloat = 0
            for id in layout.stack.ids.reversed() {
                if !layout.stack.isMeasured(id) { measure(id) }
                height += layout.stack.height(of: id)
                if height > 2 * max(room, 400) { break }
            }
        }

        /// Measures the rows not measured yet from a screen above `top` to two screens below it.
        private func measureAround(top: CGFloat) {
            guard !measuring else { return }
            measuring = true
            defer { measuring = false }
            var index = layout.stack.indices(from: top - room, to: top + 2 * room).lowerBound
            // Measuring moves rows (and the offset), so the range is walked again as it goes.
            while index < layout.stack.ids.count, layout.stack.frame(at: index).minY < visibleTop + 2 * room {
                let id = layout.stack.ids[index]
                if !layout.stack.isMeasured(id) { measure(id) }
                index += 1
            }
        }

        /// Rows not measured yet are measured a few at a time, nearest the screen first, in at most 1.5 ms a
        /// frame, so a flick reaches rows that already know their height.
        private func measureLater() {
            guard ticker == nil, layout.stack.ids.contains(where: { !layout.stack.isMeasured($0) }) else { return }
            let link = CADisplayLink(target: ConversationTicker(self), selector: #selector(ConversationTicker.tick))
            link.add(to: .main, forMode: .common)
            ticker = link
        }

        fileprivate func measureSome() {
            guard collection.bounds.width > 0, moving == 0 else { return }
            let stack = layout.stack
            let center = stack.indices(from: visibleTop, to: visibleTop + 1).first ?? max(stack.ids.count - 1, 0)
            let waiting = stack.ids.indices.filter { !stack.isMeasured(stack.ids[$0]) }
            guard !waiting.isEmpty else {
                ticker?.invalidate()
                ticker = nil
                return
            }
            let deadline = CACurrentMediaTime() + 0.0015
            for index in waiting.sorted(by: { abs($0 - center) < abs($1 - center) }) {
                measure(stack.ids[index])
                if CACurrentMediaTime() > deadline { break }
            }
            if follower.isFollowing, !collection.isTracking, !collection.isDecelerating, !jumping { toBottom() }
        }

        private func adjust(by dy: CGFloat) {
            moving += 1
            collection.contentOffset.y += dy
            moving -= 1
        }

        // MARK: Geometry

        private var visibleTop: CGFloat { collection.contentOffset.y + collection.adjustedContentInset.top }

        private var room: CGFloat {
            max(0, collection.bounds.height - collection.adjustedContentInset.top - collection.adjustedContentInset.bottom)
        }

        private var bottomOffset: CGFloat {
            max(collection.contentSize.height + collection.adjustedContentInset.bottom - collection.bounds.height,
                -collection.adjustedContentInset.top)
        }

        private var distanceFromBottom: CGFloat { bottomOffset - collection.contentOffset.y }

        private func toBottom() {
            let target = bottomOffset
            if abs(collection.contentOffset.y - target) > 0.25 { collection.contentOffset.y = target }
        }

        /// The rows on screen, to the engine, so it pages ahead of the scroll in either direction.
        private func reportVisible() {
            #if DEBUG
            let top = ConversationAnchor.find(in: layout.stack, visibleTop: visibleTop)?.id ?? "-"
            collection.accessibilityValue = "\(follower.isFollowing ? "following" : "reading") top=\(top)"
            #endif
            guard engine.transcript.count == appliedTranscriptCount else { return }
            let range = layout.stack.indices(from: visibleTop, to: collection.contentOffset.y + collection.bounds.height
                                             - collection.adjustedContentInset.bottom)
            let rows = range.compactMap { transcriptIndex[layout.stack.ids[$0]] }
            guard let span = ConversationFollow.visibleSpan(rows) else { return }
            // Near an end of the window the same rows are reported again now and then: a page asked for while
            // another was loading is not asked for again otherwise, and the list would rest at the top for good.
            let margin = engine.configuration.window.prefetchMargin
            let nearEnd = span.lowerBound < margin || span.upperBound >= appliedTranscriptCount - margin
            let now = CACurrentMediaTime()
            guard span != reportedSpan || (nearEnd && now - edgeReportedAt > 0.25) else { return }
            if span == reportedSpan { edgeReportedAt = now }
            reportedSpan = span
            engine.showing(row: span.lowerBound)
            engine.showing(row: span.upperBound)
        }

        // MARK: Following

        func jumpToNewest() {
            guard engine.historyAtNewestEnd else {
                // The window dropped the newest rows to page older ones in: they come back first, and the list
                // lands on them as they arrive (it follows again).
                reportedSpan = nil
                engine.showNewest()
                return
            }
            let target = bottomOffset
            guard abs(collection.contentOffset.y - target) > 0.5 else { return }
            jumping = true
            collection.setContentOffset(CGPoint(x: 0, y: target), animated: true)
        }

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            #if DEBUG
            ConversationListTiming.moving = scrollView.isTracking || scrollView.isDecelerating
            #endif
            if moving == 0 { measureAround(top: visibleTop) }
            if moving == 0, scrollView.isTracking || scrollView.isDecelerating || scrollView.isDragging {
                follower.personScrolled(distanceFromBottom: distanceFromBottom)
            }
            reportVisible()
        }

        func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
            // A finger on the list stops a jump under way.
            jumping = false
        }

        func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
            if !decelerate { cameToRest() }
        }

        func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) { cameToRest() }

        func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) {
            jumping = false
            if follower.isFollowing { toBottom() }
            reportVisible()
        }

        func scrollViewShouldScrollToTop(_ scrollView: UIScrollView) -> Bool {
            follower.leftTheBottom()
            return true
        }

        private func cameToRest() {
            #if DEBUG
            ConversationListTiming.moving = false
            #endif
            follower.cameToRest(distanceFromBottom: distanceFromBottom, atNewestEnd: engine.historyAtNewestEnd)
            if follower.isFollowing {
                moving += 1
                toBottom()
                moving -= 1
            }
            reportVisible()
        }

        #if DEBUG
        // For tests: the list as the person would see it.
        var debugStack: ConversationStack { layout.stack }
        func debugItem(_ id: String) -> ConversationListItem? { byID[id] }
        func debugContent(for item: ConversationListItem) -> some View { content(for: item) }
        var debugDistanceFromBottom: CGFloat { distanceFromBottom }
        var debugTopRow: String? { ConversationAnchor.find(in: layout.stack, visibleTop: visibleTop)?.id }
        func debugTopOffset(of id: String) -> CGFloat? {
            guard let index = layout.stack.ids.firstIndex(of: id) else { return nil }
            return layout.stack.frame(at: index).minY - visibleTop
        }
        /// The person moves the list by `dy` (up into history when positive) and lets go.
        func debugPersonScrolls(by dy: CGFloat) {
            collection.contentOffset.y -= dy
            follower.personScrolled(distanceFromBottom: distanceFromBottom)
            collection.layoutIfNeeded()
            cameToRest()
        }
        #endif
    }
}

/// Calls the coordinator each frame without keeping it alive.
private final class ConversationTicker: NSObject {
    weak var coordinator: ConversationList.Coordinator?
    init(_ coordinator: ConversationList.Coordinator) { self.coordinator = coordinator }

    @MainActor @objc func tick(_ link: CADisplayLink) {
        guard let coordinator else { return link.invalidate() }
        coordinator.measureSome()
    }
}

/// Reports each layout pass to the coordinator, which keeps the end on the composer while following.
final class ConversationCollectionView: UICollectionView {
    weak var coordinator: ConversationList.Coordinator?

    /// The list places its rows between the header and the composer itself (its content insets). The window's
    /// safe area must not reach the cells: a cell reaching up under the header handed it to its row, which then
    /// drew pushed down and short of room (a message cut to one line).
    override var safeAreaInsets: UIEdgeInsets { .zero }

    override func layoutSubviews() {
        super.layoutSubviews()
        coordinator?.didLayout()
    }
}

/// A cell exactly as tall as the layout says: rows are measured by the coordinator, not by the cell.
final class ConversationCell: UICollectionViewCell {
    override var safeAreaInsets: UIEdgeInsets { .zero }

    override func preferredLayoutAttributesFitting(_ attributes: UICollectionViewLayoutAttributes) -> UICollectionViewLayoutAttributes {
        attributes
    }
}

/// One column of rows from `ConversationStack`, measured by the coordinator.
final class ConversationListLayout: UICollectionViewLayout {
    enum Pending {
        case bottom
        case anchor(ConversationAnchor)
    }

    private(set) var stack = ConversationStack()
    /// Where an update being applied should leave the offset.
    var pending: Pending?

    func set(ids: [String]) {
        stack.set(ids: ids)
        invalidateLayout()
    }

    @discardableResult
    func measured(_ id: String, height: CGFloat) -> CGFloat? {
        let delta = stack.measured(id, height: height)
        if delta != nil { invalidateLayout() }
        return delta
    }

    override func prepare() {
        super.prepare()
        guard let view = collectionView else { return }
        let insets = view.adjustedContentInset
        stack.set(width: view.bounds.width, room: view.bounds.height - insets.top - insets.bottom)
    }

    override var collectionViewContentSize: CGSize { CGSize(width: stack.width, height: stack.contentHeight) }

    override func layoutAttributesForElements(in rect: CGRect) -> [UICollectionViewLayoutAttributes]? {
        stack.indices(from: rect.minY, to: rect.maxY).map(attributes)
    }

    override func layoutAttributesForItem(at indexPath: IndexPath) -> UICollectionViewLayoutAttributes? {
        guard stack.ids.indices.contains(indexPath.item) else { return nil }
        return attributes(indexPath.item)
    }

    private func attributes(_ index: Int) -> UICollectionViewLayoutAttributes {
        let attributes = UICollectionViewLayoutAttributes(forCellWith: IndexPath(item: index, section: 0))
        attributes.frame = stack.frame(at: index)
        return attributes
    }

    override func shouldInvalidateLayout(forBoundsChange newBounds: CGRect) -> Bool {
        guard let view = collectionView else { return false }
        return abs(newBounds.width - view.bounds.width) > 0.5 || abs(newBounds.height - view.bounds.height) > 0.5
    }

    override func shouldInvalidateLayout(forPreferredLayoutAttributes preferred: UICollectionViewLayoutAttributes,
                                         withOriginalAttributes original: UICollectionViewLayoutAttributes) -> Bool {
        false
    }

    override func targetContentOffset(forProposedContentOffset proposed: CGPoint) -> CGPoint {
        guard let view = collectionView, let pending else { return proposed }
        let insets = view.adjustedContentInset
        switch pending {
        case .bottom:
            return CGPoint(x: proposed.x, y: max(stack.contentHeight + insets.bottom - view.bounds.height, -insets.top))
        case .anchor(let anchor):
            guard let top = anchor.visibleTop(in: stack) else { return proposed }
            return CGPoint(x: proposed.x, y: top - insets.top)
        }
    }
}
#endif
