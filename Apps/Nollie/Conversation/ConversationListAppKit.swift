#if os(macOS)
import SwiftUI
import AppKit
import NollieCore

/// The conversation list on the Mac: an `NSCollectionView` whose items host the SwiftUI row views
/// (`NSHostingView`), on the same one-column geometry as the phone (`ConversationStack`). Rows are measured a
/// screen ahead of where the list is going, so a row that turns out taller or shorter than its estimate changes
/// size while it is still off screen, and the offset moves by as much when it is above. See
/// `Docs/specs/conversation-ui.md`.
struct ConversationList: NSViewRepresentable {
    let engine: ConversationEngine
    let items: [ConversationListItem]
    let follower: ConversationFollower
    let insets: EdgeInsets
    let answer: (ConversationCard, ConversationCardAction) -> Void
    let post: (ConversationPost, ConversationPostTap) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(engine: engine, follower: follower, answer: answer, post: post) }

    func makeNSView(context: Context) -> NSScrollView { context.coordinator.makeView() }

    func updateNSView(_ view: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.engine = engine
        coordinator.answer = answer
        coordinator.post = post
        coordinator.set(insets: NSEdgeInsets(top: insets.top, left: 0, bottom: insets.bottom, right: 0))
        coordinator.update(items)
    }

    @MainActor
    final class Coordinator: NSObject, NSCollectionViewDelegate, ConversationListDriver {
        var engine: ConversationEngine
        let follower: ConversationFollower
        var answer: (ConversationCard, ConversationCardAction) -> Void
        var post: (ConversationPost, ConversationPostTap) -> Void
        private(set) var scrollView: ConversationScrollView!
        private(set) var collection: NSCollectionView!
        private var layout: ConversationListLayout!
        private var dataSource: NSCollectionViewDiffableDataSource<Int, String>!
        private var items: [ConversationListItem] = []
        private var byID: [String: ConversationListItem] = [:]
        private var transcriptIndex: [String: Int] = [:]
        private var appliedTranscriptCount = 0
        private var moving = 0
        private var reportedSpan: ClosedRange<Int>?
        /// When rows near an end of the window were last reported again, unchanged.
        private var edgeReportedAt: CFTimeInterval = 0
        /// The person's scroll wheel or trackpad moved the list a moment ago.
        private var personScrolling = false
        private var rest: DispatchWorkItem?
        /// Hosting controllers that measure rows at the list's width, one for each kind of entry.
        private var sizers: [String: NSHostingController<AnyView>] = [:]
        /// Measures rows off screen a little at a time while some are not measured yet.
        private var ticker: CADisplayLink?
        private var measuredWidth: CGFloat = 0
        private var measuring = false

        init(engine: ConversationEngine, follower: ConversationFollower, answer: @escaping (ConversationCard, ConversationCardAction) -> Void,
             post: @escaping (ConversationPost, ConversationPostTap) -> Void = { _, _ in }) {
            self.engine = engine
            self.follower = follower
            self.answer = answer
            self.post = post
        }

        func makeView() -> NSScrollView {
            layout = ConversationListLayout()
            collection = NSCollectionView()
            collection.collectionViewLayout = layout
            collection.backgroundColors = [.clear]
            collection.isSelectable = false
            collection.delegate = self
            collection.register(ConversationItem.self, forItemWithIdentifier: ConversationItem.identifier)
            scrollView = ConversationScrollView()
            scrollView.coordinator = self
            collection.autoresizingMask = [.width]
            scrollView.documentView = collection
            scrollView.drawsBackground = false
            scrollView.hasVerticalScroller = true
            scrollView.automaticallyAdjustsContentInsets = false
            scrollView.contentView.postsBoundsChangedNotifications = true
            scrollView.setAccessibilityIdentifier("conversation.list")
            NotificationCenter.default.addObserver(self, selector: #selector(boundsChanged), name: NSView.boundsDidChangeNotification,
                                                   object: scrollView.contentView)
            dataSource = NSCollectionViewDiffableDataSource(collectionView: collection) { [unowned self] view, path, id in
                let item = view.makeItem(withIdentifier: ConversationItem.identifier, for: path) as! ConversationItem
                if let entry = self.byID[id] { item.show(self.view(for: entry)) }
                return item
            }
            follower.driver = self
            return scrollView
        }

        private func view(for entry: ConversationListItem) -> AnyView {
            AnyView(ConversationItemView(item: entry, bubbleWidth: ConversationMetrics.bubbleWidth(listWidth: listWidth), answer: answer,
                                         post: post)
                .padding(.horizontal, ConversationMetrics.side)
                // The list handles the toolbar and the composer itself, never the rows.
                .ignoresSafeArea())
        }

        // MARK: Rows

        func update(_ new: [ConversationListItem]) {
            let change = ConversationListChange(from: items, to: new)
            let firstLoad = items.isEmpty && !new.isEmpty
            guard !change.isEmpty || firstLoad else { return }
            let keepBottom = firstLoad || (follower.isFollowing && !personScrolling)
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

            moving += 1
            layout.set(ids: change.ids)
            // Rows that changed (a reply growing) are measured again now; the new ones near the screen first time.
            for id in change.changed where layout.stack.isMeasured(id) { measure(id) }
            var snapshot = NSDiffableDataSourceSnapshot<Int, String>()
            snapshot.appendSections([0])
            snapshot.appendItems(change.ids)
            if !change.changed.isEmpty { snapshot.reloadItems(change.changed) }
            if keepBottom {
                measureBottom()
            } else if let anchor, let top = anchor.visibleTop(in: layout.stack) {
                measureAround(top: top)
            }
            dataSource.apply(snapshot, animatingDifferences: false)
            collection.layoutSubtreeIfNeeded()
            if keepBottom {
                toBottom()
            } else if let anchor, let top = anchor.visibleTop(in: layout.stack) {
                scroll(to: top - insetsTop)
            }
            moving -= 1
            reportVisible()
            measureLater()
        }

        /// Rows not measured yet are measured a few at a time, nearest the screen first, in at most 1.5 ms a
        /// frame, so a scroll reaches rows that already know their height.
        private func measureLater() {
            guard ticker == nil, layout.stack.ids.contains(where: { !layout.stack.isMeasured($0) }) else { return }
            let link = scrollView.displayLink(target: ConversationMacTicker(self), selector: #selector(ConversationMacTicker.tick))
            link.add(to: .main, forMode: .common)
            ticker = link
        }

        fileprivate func measureSome() {
            guard listWidth > 0, moving == 0 else { return }
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
            if follower.isFollowing, !personScrolling { toBottom() }
        }

        func set(insets: NSEdgeInsets) {
            let current = scrollView.contentInsets
            guard current.top != insets.top || current.bottom != insets.bottom else { return }
            moving += 1
            scrollView.contentInsets = insets
            layout.invalidateLayout()
            collection.layoutSubtreeIfNeeded()
            if follower.isFollowing { toBottom() }
            moving -= 1
        }

        /// The scroll view was laid out: a new width measures the rows again; while following the end stays put.
        func didLayout() {
            if abs(listWidth - measuredWidth) > 0.5 {
                measuredWidth = listWidth
                layout.invalidateLayout()
                if !items.isEmpty {
                    moving += 1
                    var snapshot = dataSource.snapshot()
                    snapshot.reloadItems(snapshot.itemIdentifiers)
                    dataSource.apply(snapshot, animatingDifferences: false)
                    measureAround(top: visibleTop)
                    moving -= 1
                    measureLater()
                }
            }
            if follower.isFollowing, !personScrolling, moving == 0 { toBottom() }
        }

        // MARK: Measuring

        private func measure(_ id: String) {
            guard let entry = byID[id], listWidth > 0 else { return }
            let measurer = sizers[entry.kind] ?? NSHostingController(rootView: AnyView(EmptyView()))
            sizers[entry.kind] = measurer
            measurer.rootView = view(for: entry)
            let size = measurer.sizeThatFits(in: CGSize(width: listWidth, height: .greatestFiniteMagnitude))
            guard let index = layout.stack.ids.firstIndex(of: id) else { return }
            let before = layout.stack.frame(at: index)
            let first = !layout.stack.isMeasured(id)
            let top = visibleTop
            guard let delta = layout.measured(id, height: size.height) else { return }
            guard !follower.isFollowing || personScrolling, moving == 0 else { return }
            let adjustment = ConversationStack.offsetAdjustment(itemTop: before.minY, itemBottom: before.maxY, delta: delta,
                                                                firstMeasure: first, visibleTop: top)
            if adjustment != 0 { scroll(to: offset + adjustment) }
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

        @objc private func boundsChanged() {
            measureAround(top: visibleTop)
            if moving == 0, personScrolling { follower.personScrolled(distanceFromBottom: distanceFromBottom) }
            reportVisible()
        }

        /// The person's wheel or trackpad moved the list; it counts as at rest a moment after the last event.
        func personScrolled() {
            personScrolling = true
            follower.personScrolled(distanceFromBottom: distanceFromBottom)
            rest?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.cameToRest() }
            rest = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
        }

        private func cameToRest() {
            personScrolling = false
            follower.cameToRest(distanceFromBottom: distanceFromBottom, atNewestEnd: engine.historyAtNewestEnd)
            if follower.isFollowing { toBottom() }
            reportVisible()
        }

        // MARK: Geometry

        private var listWidth: CGFloat { scrollView.contentView.bounds.width }
        private var insetsTop: CGFloat { scrollView.contentInsets.top }
        private var room: CGFloat { max(0, scrollView.contentView.bounds.height - insetsTop - scrollView.contentInsets.bottom) }
        private var offset: CGFloat { scrollView.contentView.bounds.origin.y }
        private var visibleTop: CGFloat { offset + insetsTop }
        private var bottomOffset: CGFloat {
            max(layout.stack.contentHeight + scrollView.contentInsets.bottom - scrollView.contentView.bounds.height, -insetsTop)
        }
        private var distanceFromBottom: CGFloat { bottomOffset - offset }

        private func scroll(to y: CGFloat) {
            guard abs(offset - y) > 0.25 else { return }
            moving += 1
            scrollView.contentView.scroll(to: NSPoint(x: 0, y: y))
            scrollView.reflectScrolledClipView(scrollView.contentView)
            moving -= 1
        }

        private func toBottom() { scroll(to: bottomOffset) }

        private func reportVisible() {
            #if DEBUG
            let top = ConversationAnchor.find(in: layout.stack, visibleTop: visibleTop)?.id ?? "-"
            scrollView.setAccessibilityValue("\(follower.isFollowing ? "following" : "reading") top=\(top)")
            #endif
            guard engine.transcript.count == appliedTranscriptCount else { return }
            let range = layout.stack.indices(from: visibleTop, to: visibleTop + room)
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

        func jumpToNewest() {
            guard engine.historyAtNewestEnd else {
                reportedSpan = nil
                engine.showNewest()
                return
            }
            toBottom()
            reportVisible()
        }

        #if DEBUG
        // For tests: the list as the person would see it.
        var debugDistanceFromBottom: CGFloat { distanceFromBottom }
        var debugTopRow: String? { ConversationAnchor.find(in: layout.stack, visibleTop: visibleTop)?.id }
        func debugTopOffset(of id: String) -> CGFloat? {
            guard let index = layout.stack.ids.firstIndex(of: id) else { return nil }
            return layout.stack.frame(at: index).minY - visibleTop
        }
        /// The person moves the list by `dy` (up into history when positive) and lets go.
        func debugPersonScrolls(by dy: CGFloat) {
            personScrolling = true
            scrollView.contentView.scroll(to: NSPoint(x: 0, y: offset - dy))
            scrollView.reflectScrolledClipView(scrollView.contentView)
            follower.personScrolled(distanceFromBottom: distanceFromBottom)
            collection.layoutSubtreeIfNeeded()
            cameToRest()
        }
        #endif
    }
}

/// Calls the coordinator each frame without keeping it alive.
private final class ConversationMacTicker: NSObject {
    weak var coordinator: ConversationList.Coordinator?
    init(_ coordinator: ConversationList.Coordinator) { self.coordinator = coordinator }

    @MainActor @objc func tick(_ link: CADisplayLink) {
        guard let coordinator else { return link.invalidate() }
        coordinator.measureSome()
    }
}

/// Tells the coordinator about the person's scrolling and about each layout pass.
final class ConversationScrollView: NSScrollView {
    weak var coordinator: ConversationList.Coordinator?

    override func scrollWheel(with event: NSEvent) {
        super.scrollWheel(with: event)
        coordinator?.personScrolled()
    }

    override func layout() {
        super.layout()
        coordinator?.didLayout()
    }
}

/// An item that shows one SwiftUI row.
final class ConversationItem: NSCollectionViewItem {
    static let identifier = NSUserInterfaceItemIdentifier("ConversationItem")
    private var hosting: NSHostingView<AnyView>?

    override func loadView() {
        let hosting = NSHostingView(rootView: AnyView(EmptyView()))
        hosting.sizingOptions = []
        self.hosting = hosting
        view = hosting
    }

    func show(_ content: AnyView) { hosting?.rootView = content }
}

/// One column of rows from `ConversationStack`, measured by the coordinator.
final class ConversationListLayout: NSCollectionViewLayout {
    private(set) var stack = ConversationStack()

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
        guard let scroll = collectionView?.enclosingScrollView else { return }
        let insets = scroll.contentInsets
        let clip = scroll.contentView.bounds
        stack.set(width: clip.width, room: clip.height - insets.top - insets.bottom)
    }

    override var collectionViewContentSize: NSSize { NSSize(width: stack.width, height: stack.contentHeight) }

    override func layoutAttributesForElements(in rect: NSRect) -> [NSCollectionViewLayoutAttributes] {
        stack.indices(from: rect.minY, to: rect.maxY).map(attributes)
    }

    override func layoutAttributesForItem(at indexPath: IndexPath) -> NSCollectionViewLayoutAttributes? {
        guard stack.ids.indices.contains(indexPath.item) else { return nil }
        return attributes(indexPath.item)
    }

    private func attributes(_ index: Int) -> NSCollectionViewLayoutAttributes {
        let attributes = NSCollectionViewLayoutAttributes(forItemWith: IndexPath(item: index, section: 0))
        attributes.frame = stack.frame(at: index)
        return attributes
    }

    override func shouldInvalidateLayout(forBoundsChange newBounds: NSRect) -> Bool {
        abs(newBounds.width - stack.width) > 0.5
    }
}
#endif
