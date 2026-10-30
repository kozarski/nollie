import SwiftUI
import NollieCore

/// The scrolling list of a conversation. It draws the rows, any approvals still open and the
/// typing bubble, and looks after position: sticking to the newest line, making room for the
/// keyboard and dock, and landing on a message named by a notification. The extensions hold
/// most of that work and share the state declared below.
struct TranscriptView: View {
    static let ignoreText: (String) -> Void = { _ in }

    @Bindable var chat: ChatSession
    /// Edit & resend (long-press): hands the message text to the composer.
    var onEditMessage: (String) -> Void = Self.ignoreText
    /// Called when a link points at another bot.
    var onOpenBot: (String) -> Void = Self.ignoreText
    /// Reply from a bubble: the composer then quotes that message.
    var onReply: (String) -> Void = Self.ignoreText
    var onStartIdea: ((String) -> Void)? = nil
    var notificationFocus: NotificationMessageFocus? = nil
    /// Screen y of the dock's top edge, 0 until measured. The bottom margin is worked out from this
    /// position directly; adding up heights instead left an empty strip on some phones.
    var dockTop: CGFloat = 0
    /// Margin used before the dock reports in.
    var fallbackInset: CGFloat = 60
    /// The floating header's height (the navigation bar is hidden in chats).
    var topInset: CGFloat = 96

    @Environment(AppModel.self) var model
    @Environment(\.accessibilityReduceMotion) var reduceMotion
    @Environment(\.dynamicTypeSize) private var phoneTypeSize
    var prefs = ThreadPrefs()

    // MARK: Scroll state

    /// Scroll target expressed as "the bottom edge". Aiming at a marker view was unreliable, as a
    /// view the lazy stack has not built yet only has a guessed position.
    @State var scrollPosition = ScrollPosition(edge: .bottom)
    @State var scrollBottom: CGFloat = 0
    /// Numbers that move with every scroll frame. A plain object holds them because @State writes
    /// at that rate would rebuild the whole body and all its rows each frame.
    @State var metrics = ScrollMetrics()
    @State var tasks = ThreadTasks()
    /// Extra inset the scroll view adds on its own: its reported inset minus the margin set here.
    /// Some phones already pad the safe area, which otherwise lifted the last reply off the
    /// composer by the indicator's height. Read once and snapped to 0 or that height, since
    /// recomputing it while the dock resizes fed back into itself.
    @State var autoInsetFixed: CGFloat?
    /// Keyboard height once it has come to rest. Margins cannot animate, so using it mid-rise
    /// would push the thread up ahead of the dock.
    @State var keyboardFloor: CGFloat = 0
    /// Part of the scroll view covered by the keyboard (past the safe area). The thread lifts with
    /// it, keeping the end in view if it was there.
    @State var keyboardInset: CGFloat = 0
    /// First row of the eagerly built tail (see `threadRows`), nil before it is chosen. Moves only
    /// when the thread is resting at the end; `TranscriptRowModel.split` knows when to disregard it.
    @State var tailFrom: Int?
    /// Set when the person drags away from the end. While unset, new tokens, tool calls and
    /// cards carry the thread with them; the jump button or scrolling down clears it.
    @State var awayFromBottom = false
    /// When the chat appeared. For its first moments layout is still moving, so adjustments are
    /// made without animation.
    @State var openedAt = Date()
    /// Mac only: current width of the reading column.
    @State var columnWidth: CGFloat = 760

    // MARK: Open or pending things

    /// The card just opened and the y of its top at tap time.
    @State var revealAnchor: DisclosureScrollAnchor?
    @State var cancelledFocus: UUID?
    @State var highlightedMessage: String?
    @State var messageNotice: String?
    @State var showAwayGrace = false
    @State var selectText: String?
    /// Id of a stopped screen action whose System control card the person put away.
    @State var dismissedStop: String?
    /// Which reasoning blocks are expanded. Stored on the thread so a rebuilt row still knows.
    @State var openReasoning: Set<String> = []
    /// Which tool cards are expanded. Kept here so reused rows stay open and a finished turn can fold all.
    @State var openTools: Set<String> = []
    /// One set of row callbacks for the view's whole life (see `RowContext`).
    @State var actions = RowActions()

    // MARK: Body

    var body: some View {
        counted(followingChanges(of: scrolling))
            .task(id: notificationFocus) { await revealNotificationMessage() }
            .overlay(alignment: .top) { notificationNotice }
            .onChange(of: model.lock.isLocked) { _, locked in
                if locked { cancelledFocus = notificationFocus?.token }
            }
            .environment(\.transcriptDisclosureScope, disclosureScope)
    }

    private func counted<Content: View>(_ content: Content) -> Content {
        Perf.tick("transcript")
        return content
    }

    /// The scroll view plus everything that reacts when the chat changes.
    private func followingChanges(of content: some View) -> some View {
        content
            .onAppear { openedAt = .now }
            // Compares the whole item rather than its kind, because the speed footer appears after
            // the text and also needs the end brought into view.
            .onChange(of: visibleItems.last) { old, new in
                if let old, let new, old.id == new.id, Self.isStreaming(old), !Self.isStreaming(new) {
                    landArrivedReply()
                } else if mayFollow() {
                    pinToEnd()
                }
            }
            .onChange(of: rows.count) { followRows(from: $0, to: $1) }
            // Runs again after each turn, the only time rows may move into the lazy part.
            .task(id: [rows.count, chat.isRunning ? 1 : 0]) { await settleTail() }
            // After resumed history lays out, confirm the newest line is visible.
            .task(id: chat.isResuming) { await landAfterResume() }
            // When a turn stops, the bubble and status line below the last reply vanish, so a thread
            // on its end shifts down to close the gap.
            .onChange(of: chat.isRunning) { _, running in
                if !running && prefs.collapseAfterTurn {
                    withAnimation(.snappy) { (openReasoning, openTools) = ([], []) }
                }
                easeToBottomIfFollowing()
            }
            .onChange(of: chat.statusLine) { easeToBottomIfFollowing() }
            // Dock height changes (approval cards arriving or leaving) alter the margin. Follow once
            // it has stopped moving; chasing it frame by frame scrolled into empty space.
            .onChange(of: bottomInset) { followDockHeight() }
    }

    @ViewBuilder private var notificationNotice: some View {
        if let words = messageNotice {
            HStack(spacing: 8) {
                Text(words).font(.footnote)
                Button("Dismiss", systemImage: "xmark") { messageNotice = nil }.labelStyle(.iconOnly)
            }
            .padding(12)
            .background(.regularMaterial, in: .rect(cornerRadius: 16))
            .inset(h: 16)
            .padding(.top, topInset + 8)
            .accessibilityIdentifier("notification.message.unavailable")
        }
    }

    // MARK: Scroll view

    private var scrolling: some View {
        let jump = JumpToBottomButton(visible: awayFromBottom, action: jumpToBottom)
        return watchedScroll(of: scrollView)
            .overlay(alignment: .bottomTrailing) {
                jump.padding(EdgeInsets(top: 0, leading: 0, bottom: dockReach + 12, trailing: 16))
            }
            .overlay(alignment: .topLeading) { geometryReadout }
            #if os(iOS)
            // iPhone: content may extend behind the status bar and the floating header.
            .ignoresSafeArea(.container, edges: .top)
            #endif
            .sheet(item: selectedTextItem) { selectTextSheet($0).withAppModel() }
            .sheet(isPresented: $showAwayGrace) { awayGraceSheet().withAppModel() }
            #if DEBUG
            .task {
                // For pictures of what opens the main chat (the weekly note, the morning's Night shift):
                // `-nollie-demo-thread-top` scrolls to the start once the thread has settled.
                guard DemoMode.isOn, ProcessInfo.processInfo.arguments.contains("-nollie-demo-thread-top") else { return }
                try? await Task.sleep(for: .seconds(8))
                scrollPosition.scrollTo(edge: .top)
            }
            #endif
    }

    private var selectedTextItem: Binding<SelectTextItem?> {
        Binding(get: { selectText.map(SelectTextItem.init) }, set: { selectText = $0?.text })
    }

    private func selectTextSheet(_ item: SelectTextItem) -> some View {
        SelectTextSheet(text: item.text).sheetFrame(.wide)
    }

    private func awayGraceSheet() -> some View {
        AwayGraceSheet(runtime: chat.runtime).sheetFrame(.compact)
    }

    private var scrollView: some View {
        let margins = (top: topInset + 8, bottom: bottomInset + 8)
        return ScrollView { TimeRevealColumn { column } }
            .scrollPosition($scrollPosition)
            .defaultScrollAnchor(.bottom)
            .defaultScrollAnchor(.top, for: .sizeChanges)
            .scrollDismissesKeyboard(.interactively)
            // Bottom margin = how far the dock (and keyboard) reach in; the system adds the safe area.
            .contentMargins(.top, margins.top, for: .scrollContent)
            .contentMargins(.bottom, margins.bottom, for: .scrollContent)
            // The keyboard is accounted for by hand, since the built-in avoidance would add it twice.
            .ignoresSafeArea(.keyboard)
    }

    /// Observers for scroll geometry and the notifications that move the thread.
    private func watchedScroll(of content: some View) -> some View {
        content
            .onGeometryChange(for: CGFloat.self, of: bottomEdge) { scrollBottom = $0 }
            .onScrollGeometryChange(for: ScrollReading.self, of: ScrollReading.init(_:), action: scrolled)
            .onScrollPhaseChange { _, phase in scrollPhaseChanged(phase) }
            // Expanding a disclosure pins its header in place.
            .onReceive(NotificationCenter.default.publisher(for: .hermesRevealRow), perform: revealRow)
            // A sent message returns the thread to the end from any position.
            .onReceive(NotificationCenter.default.publisher(for: .hermesMessageSent), perform: messageSent)
            #if os(iOS)
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillChangeFrameNotification), perform: keyboardMoved)
            #endif
    }

    private nonisolated func bottomEdge(_ proxy: GeometryProxy) -> CGFloat { proxy.frame(in: .global).maxY }

    private func messageSent(_ note: Notification) {
        guard (note.object as? ChatSession) === chat else { return }
        if metrics.stickToBottom && metrics.distanceFromBottom <= 24 { return }
        jumpToBottom()
    }

    /// The column of rows. It has no animation of its own: animating on row count also animated
    /// whatever else changed in that update, so text could be painted over a footer or card while
    /// the old layout was still sliding. Rows go straight to their place, new ones fade in
    /// themselves (`rowView`), and the only motion is scrolling (`followRows`).
    private var column: some View {
        let sidePad: CGFloat = prefs.wideReplies ? 10 : 16
        return VStack(alignment: .leading, spacing: 10) {
            // The week's note and the morning's Night shift open the main chat and scroll away with it, so they
            // never cover the thread.
            WeeklyNoteStrip(chat: chat)
            NightShiftStrip(chat: chat)
            threadContent
            Color.clear.frame(height: 0).id("bottom")
        }
        .scrollTargetLayout(isEnabled: notificationFocus != nil)
        .onChange(of: approvals.count) { followApprovals() }
        .padding(EdgeInsets(top: 8, leading: sidePad, bottom: 0, trailing: sidePad))
        // The thread is a centred column about a page wide on a wide screen, whatever the window size.
        .frame(maxWidth: ReadingColumn.thread + 32)
        #if os(macOS)
        .onGeometryChange(for: CGFloat.self, of: { 20 * ($0.size.width / 20).rounded() }) { columnWidth = $0 }
        #endif
        .spread(.center)
        .dynamicTypeSize(ChatStyle.stepped(phoneTypeSize, prefs.textSize))
        .environment(\.threadWaitsOnYou, !approvals.isEmpty)
        .background(ScrollViewProbe(metrics: metrics))
    }

    /// Passes whichever scroll figures changed on to their users.
    private func scrolled(from old: ScrollReading, to new: ScrollReading) {
        metrics.contentHeight = new.contentHeight
        metrics.containerHeight = new.containerHeight
        if old.insetBottom != new.insetBottom {
            metrics.reportedInsetBottom = new.insetBottom
            measureAutoInset(from: new.insetBottom)
        }
        if old.offsetY != new.offsetY {
            metrics.offsetY = new.offsetY
            if metrics.userScrolling { BotAmbient.shared.scrolled(dy: new.offsetY - old.offsetY) }
        }
        if old.distanceFromEnd != new.distanceFromEnd {
            distanceFromBottomChanged(from: old.distanceFromEnd, to: new.distanceFromEnd)
        }
    }

    /// Debug aid, shown with `-nollie-geometry`: prints the thread's measurements. iPhone only,
    /// as it reads UIScrollView insets.
    @ViewBuilder private var geometryReadout: some View {
        #if DEBUG && os(iOS)
        if ProcessInfo.processInfo.arguments.contains("-nollie-geometry") {
            Text(geometryFacts.joined(separator: " "))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.black)
                .padding(4)
                .background(.yellow)
                .padding(.top, 120)
        }
        #endif
    }

    #if DEBUG && os(iOS)
    private var geometryFacts: [String] {
        let scroller = metrics.scrollView
        let frameTop = scroller.map { Int($0.convert($0.bounds, to: nil).minY) } ?? -1
        let adjusted = scroller?.adjustedContentInset
        return [
            "dockTop \(Int(dockTop))", "scrollBottom \(Int(scrollBottom))", "inset \(Int(bottomInset))",
            "dist \(Int(metrics.distanceFromBottom))", "top \(Int(topInset))",
            "sv \(frameTop)/\(Int(scroller?.bounds.height ?? -1))",
            "adj \(Int(adjusted?.top ?? -1))/\(Int(adjusted?.bottom ?? -1))",
            "rep \(Int(metrics.reportedInsetBottom))",
        ]
    }
    #endif
}

/// What the thread reads from its scroll view, bundled so one callback sees every change.
struct ScrollReading: Equatable {
    var insetBottom: CGFloat
    var contentHeight: CGFloat
    var containerHeight: CGFloat
    var offsetY: CGFloat
    /// Distance from the last line to the bottom edge, counting insets. Without the insets a
    /// slightly taller dock pushed this past the arrow's threshold even at the very end.
    var distanceFromEnd: CGFloat

    init(_ scroll: ScrollGeometry) {
        offsetY = scroll.contentOffset.y
        insetBottom = scroll.contentInsets.bottom
        contentHeight = scroll.contentSize.height
        containerHeight = scroll.containerSize.height
        distanceFromEnd = scroll.contentSize.height + scroll.contentInsets.bottom - scroll.visibleRect.maxY
    }
}
