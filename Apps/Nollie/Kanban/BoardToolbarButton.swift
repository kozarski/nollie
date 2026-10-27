import SwiftUI
import NollieCore

/// Tasks that need the user, excluding routine agent review and recovery.
struct BoardReviewSummary {
    struct Entry {
        let slug: String
        let count: Int
    }

    let entries: [Entry]
    var count: Int { entries.reduce(0) { $0 + $1.count } }

    init(boards: [KanbanBoardMeta], selectedBoard: String?, loadedBoard: KanbanBoard?, attentionCounts: [String: Int]? = nil) {
        var seen = Set<String>()
        var result: [Entry] = []
        for board in boards where seen.insert(board.slug).inserted {
            guard board.archived != true else { continue }
            let count: Int
            if board.slug == selectedBoard, let loadedBoard {
                count = Self.reviewCount(in: loadedBoard)
            } else if let attentionCounts, let preciseCount = attentionCounts[board.slug] {
                count = max(0, preciseCount)
            } else {
                count = max(0, board.counts?[KanbanStatus.blocked.rawValue] ?? 0)
            }
            result.append(Entry(slug: board.slug, count: count))
        }
        if let selectedBoard, let loadedBoard, !seen.contains(selectedBoard) {
            result.append(Entry(slug: selectedBoard, count: Self.reviewCount(in: loadedBoard)))
        }
        entries = result
    }

    func boardToOpen(current: String?) -> String? {
        if let current, entries.contains(where: { $0.slug == current && $0.count > 0 }) { return current }
        return entries.first(where: { $0.count > 0 })?.slug ?? current
    }

    private static func reviewCount(in board: KanbanBoard) -> Int {
        Set(board.allTasks.filter(\.needsUserAction).map(\.id)).count
    }
}

/// The same Board entry in the phone toolbar and the Mac sidebar.
struct BoardToolbarButton: View {
    /// Drawn as a sidebar row (wide iPhone and iPad) rather than a bar button.
    var asRow = false
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("kanban.column") private var columnRaw = KanbanStatus.ready.rawValue
    @State private var metadata: Metadata?

    private struct Metadata {
        let gatewayID: UUID
        let boards: [KanbanBoardMeta]
        let attentionCounts: [String: Int]?
        let readAt: Date
    }

    private struct RefreshKey: Hashable {
        let gatewayID: UUID?
        let active: Bool
        let present: Bool
    }

    private var store: KanbanStore? { model.runtime?.kanban }
    private var refreshKey: RefreshKey {
        RefreshKey(gatewayID: model.runtime?.connection.id, active: scenePhase == .active, present: store?.isPresent == true)
    }
    private var summary: BoardReviewSummary {
        let currentMetadata = metadata?.gatewayID == model.runtime?.connection.id ? metadata : nil
        // A review resolved on the open board is newer than the last metadata read.
        let useLoadedBoard = (store?.lastRead ?? .distantPast) >= (currentMetadata?.readAt ?? .distantPast)
        return BoardReviewSummary(boards: currentMetadata?.boards ?? store?.boards ?? [],
                                  selectedBoard: store?.selectedBoard,
                                  loadedBoard: useLoadedBoard ? store?.board : nil,
                                  attentionCounts: currentMetadata?.attentionCounts)
    }
    private var reviewDescription: String {
        String(localized: "\(summary.count) tasks needing your help")
    }

    var body: some View {
        styled
        .accessibilityLabel("Board")
        .accessibilityValue(summary.count > 0 ? reviewDescription : String(localized: "No tasks needing your help"))
        .accessibilityHint(summary.count > 0 ? "Opens tasks that need your help" : "Opens the Board")
        .accessibilityIdentifier("chats.board")
        .task(id: refreshKey) { await refreshCounts() }
    }

    private func open() {
        if let board = summary.boardToOpen(current: store?.selectedBoard) { store?.select(board: board) }
        if summary.count > 0 { columnRaw = KanbanStatus.review.rawValue }
        model.selectedTab = .kanban
    }

    @ViewBuilder private var countBadge: some View {
        if summary.count > 0 {
            Text(summary.count, format: .number)
                .font(.caption2.weight(.bold))
                .monospacedDigit()
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .foregroundStyle(.white)
                .background(.blue, in: .capsule)
                .accessibilityIdentifier("chats.board.reviewCount")
        }
    }

    @ViewBuilder private var styled: some View {
        #if os(iOS)
        if asRow {
            SidebarActionRow(title: String(localized: "Board", comment: "The Board, Nollie's task board; a name"), symbol: "rectangle.split.3x1", action: open) { countBadge }
        } else {
            bar
        }
        #else
        bar
        #endif
    }

    private var bar: some View {
        Button(action: open) {
            HStack(spacing: 5) {
                countBadge
                Image(systemName: "rectangle.split.3x1")
            }
        }
        #if os(macOS)
        .buttonStyle(BoardToolbarStyle(needsReview: summary.count > 0))
        .help(summary.count > 0 ? String(localized: "Board: \(reviewDescription) (⌘B)", comment: "%@ says how many tasks need help")
                                 : String(localized: "Board: no tasks needing your help (⌘B)"))
        #else
        .tint(summary.count > 0 ? .blue : .primary)
        #endif
    }

    private struct AttentionCounts: Decodable { let counts: [String: Int] }

    /// The companion separates user questions from agent recovery without fetching task text.
    private func refreshCounts() async {
        guard refreshKey.active, refreshKey.present, let runtime = model.runtime, let api = store?.api else { return }
        while !Task.isCancelled {
            if let response = try? await api.boards(), !Task.isCancelled,
               model.runtime?.connection.id == runtime.connection.id {
                let attention: AttentionCounts? = try? await runtime.api.get("/api/plugins/nollie-workflow/attention")
                guard !Task.isCancelled, model.runtime?.connection.id == runtime.connection.id else { return }
                metadata = Metadata(gatewayID: runtime.connection.id, boards: response.boards,
                                    attentionCounts: attention?.counts, readAt: Date())
            }
            do { try await Task.sleep(for: .seconds(60)) } catch { return }
        }
    }
}

#if os(macOS)
private struct BoardToolbarStyle: ButtonStyle {
    let needsReview: Bool
    func makeBody(configuration: Configuration) -> some View {
        BoardToolbarFace(label: configuration.label, needsReview: needsReview, pressed: configuration.isPressed)
    }
}

private struct BoardToolbarFace<Label: View>: View {
    let label: Label
    let needsReview: Bool
    let pressed: Bool
    @State private var hovering = false

    var body: some View {
        label
            .font(.system(size: 15, weight: .medium))
            .foregroundStyle(needsReview ? Color.blue : Ink.text.opacity(0.85))
            .padding(.horizontal, 10)
            .frame(minWidth: 32, minHeight: 32)
            // On its own glass capsule in the sidebar: a tint only for a review, or under the pointer.
            .background(needsReview ? Color.blue.opacity(hovering || pressed ? 0.2 : 0.12) : (hovering || pressed ? Ink.text.opacity(0.1) : Color.clear), in: .capsule)
            .contentShape(.capsule)
            .onHover { hovering = $0 }
    }
}
#endif
