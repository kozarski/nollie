#if os(iOS)
import SwiftUI
import NollieCore

/// The chats on iPhone and iPad. Narrow, it is the phone's one stack: the bot list, with a chat
/// pushed over it. Wide, the list keeps about a third on the left and the chat takes the rest at
/// a comfortable reading width. Both are the same navigation stack, so folding or unfolding mid-chat
/// leaves the chat itself in place (draft, scroll position and all); only the list moves.
struct ChatsRoot: View {
    /// Changes when Papertrail is asked for; it opens in the panel.
    var papertrailRequest: UUID?
    /// Reports whether the list and chat are side by side.
    @Binding var isWide: Bool

    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(AppModel.self) private var model
    @State private var path = NavigationPath()
    @State private var panel = SidePanelHost()
    @State private var size = CGSize.zero
    /// The crease's span while a fold is in use (iOS 27.1 and later).
    @State private var fold: ClosedRange<CGFloat>?

    private var wide: Bool { SplitLayout.showsSplit(regularWidth: sizeClass == .regular, width: size.width) }
    private var layout: SplitLayout {
        .make(width: size.width, fold: fold, panelOpen: panel.isOpen, expanded: panel.expanded)
    }

    var body: some View {
        // The chat's stack keeps its place in this stack whatever the width, so it is never rebuilt.
        ZStack(alignment: .topLeading) {
            if wide { listColumn }
            chatColumn
            if wide, let page = panel.page { panelColumn(page) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Ink.canvas.ignoresSafeArea())
        .onGeometryChange(for: CGSize.self) { $0.size } action: { size = $0 }
        .modifier(FoldWatcher(fold: $fold))
        .environment(\.sidePanel, wide ? panel : nil)
        .onChange(of: fold == nil, initial: true) { _, flat in panel.canExpand = flat }
        // A different chat, or the window turning narrow, puts the panel away.
        .onChange(of: path) { panel.close() }
        .onChange(of: wide, initial: true) { _, now in
            isWide = now
            if !now { panel.close() }
        }
        .onChange(of: papertrailRequest) { _, asked in if asked != nil { openPapertrail() } }
        .animation(.snappy, value: layout)
        #if DEBUG
        .task { await DemoOrientation.apply() }
        #endif
    }

    private func openPapertrail() {
        let summary = model.crewSummary
        withAnimation(.snappy) {
            panel.show("papertrail") { SidePanelPage(title: "Papertrail") { LeftYourMacPage(summary: summary) } }
        }
    }

    // MARK: Columns

    private var listColumn: some View {
        NavigationStack {
            ChatListView(detailPath: $path)
        }
        .environment(\.chatOpensBeside, true)
        .frame(width: layout.list.width)
        .frame(maxHeight: .infinity)
        // Covered by the chat while a panel is open; VoiceOver skips it then.
        .accessibilityHidden(layout.listCovered)
        .allowsHitTesting(!layout.listCovered)
    }

    private var chatColumn: some View {
        NavigationStack(path: $path) {
            Group {
                if wide {
                    ChatsEmptyState()
                } else {
                    ChatListView(detailPath: $path)
                }
            }
            // A new identity per route: beside the list a chat replaces the one on show in the same
            // place, and must open afresh rather than keep the last one's state.
            .navigationDestination(for: ChatRoute.self) { ChatDestination(route: $0).id($0) }
            .background(BackSwipeSwitch(allowed: !wide))
        }
        .environment(\.chatOpensBeside, wide)
        .frame(width: wide ? layout.chat.width : nil)
        .frame(maxWidth: wide ? nil : .infinity, maxHeight: .infinity)
        .background(Ink.canvas.ignoresSafeArea())
        .overlay(alignment: .leading) { if wide && layout.chat.x > 0 { ColumnRule() } }
        .offset(x: wide ? layout.chat.x : 0)
    }

    private func panelColumn(_ page: SidePanelHost.Page) -> some View {
        page.view
            .environment(\.inSidePanel, true)
            .id(page.id)
            .frame(width: layout.panel?.width ?? 0)
            .frame(maxHeight: .infinity)
            .background(Ink.canvas.ignoresSafeArea())
            .overlay(alignment: .leading) { if !layout.expanded { ColumnRule() } }
            .offset(x: layout.panel?.x ?? 0)
            .transition(.move(edge: .trailing).combined(with: .opacity))
    }
}

/// The hairline between two columns.
private struct ColumnRule: View {
    var body: some View {
        Rectangle().fill(Ink.line).frame(width: 0.5).ignoresSafeArea()
    }
}

/// What the chat side shows before a bot is picked.
private struct ChatsEmptyState: View {
    var body: some View {
        VStack(spacing: 14) {
            // Idle, the guide holds still; it only plays while something is working.
            CharacterView(look: .main, state: BotAmbient.shared.decorativeActive ? .listening : .idle,
                          size: 96, seed: CharacterLookID.seed("nollie-wide-empty"))
                .accessibilityHidden(true)
            Text("Pick a bot").font(Ink.headerName).foregroundStyle(Ink.text2)
        }
        // On the stack's own background, the same as behind a chat.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .toolbar(.hidden, for: .navigationBar)
        .accessibilityIdentifier("chats.empty")
    }
}

/// Follows the fold: on iOS 27.1 and later the system reports where the crease divides the
/// window while the device is held half open. Earlier systems have no such region and the columns
/// keep their usual shares.
private struct FoldWatcher: ViewModifier {
    @Binding var fold: ClosedRange<CGFloat>?

    private struct Reading: Equatable {
        var size: CGSize
        var regions: [CGRect]
    }

    func body(content: Content) -> some View {
        content.onGeometryChange(for: Reading.self, of: { proxy in
            Reading(size: proxy.size, regions: Self.divisions(proxy))
        }, action: { reading in
            fold = SplitLayout.fold(in: reading.regions, size: reading.size)
        })
    }

    private nonisolated static func divisions(_ proxy: GeometryProxy) -> [CGRect] {
        if #available(iOS 27.1, *) {
            return proxy.reservedRegions(kind: .division).filter(\.isActive).map(\.frame)
        }
        return []
    }
}

/// Turns the back swipe off while the chat sits beside the list (there is nothing to go back to)
/// and on again in the phone's stack.
private struct BackSwipeSwitch: UIViewControllerRepresentable {
    var allowed: Bool

    func makeUIViewController(context: Context) -> Controller { Controller() }

    func updateUIViewController(_ controller: Controller, context: Context) {
        controller.allowed = allowed
        controller.apply()
    }

    final class Controller: UIViewController {
        var allowed = true

        override func loadView() {
            view = UIView()
            view.isUserInteractionEnabled = false
        }

        override func didMove(toParent parent: UIViewController?) {
            super.didMove(toParent: parent)
            apply()
        }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            apply()
        }

        func apply() {
            guard let stack = navigationController ?? parent?.navigationController else { return }
            stack.interactivePopGestureRecognizer?.isEnabled = allowed
            for pan in stack.view.gestureRecognizers ?? [] where pan.name == "nollie.fullScreenPop" {
                pan.isEnabled = allowed
            }
        }
    }
}

#if DEBUG
/// For pictures: `-nollie-demo-orientation landscape` (or `portrait`) turns the window once it is up.
@MainActor
enum DemoOrientation {
    static func apply() async {
        let args = ProcessInfo.processInfo.arguments
        guard DemoMode.isOn, let i = args.firstIndex(of: "-nollie-demo-orientation"), i + 1 < args.count else { return }
        let mask: UIInterfaceOrientationMask = args[i + 1] == "landscape" ? .landscapeRight : .portrait
        try? await Task.sleep(for: .seconds(1))
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        scene?.keyWindow?.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
        scene?.requestGeometryUpdate(.iOS(interfaceOrientations: mask)) { error in
            NSLog("demo orientation: %@", error.localizedDescription)
        }
    }
}
#endif
#endif
