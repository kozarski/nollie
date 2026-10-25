import NollieCore
import SwiftUI

/// What the Board page says when there are no lanes to draw.
struct BoardEmpty {
    let title: String
    let symbol: String
    let detail: String

    static let noGateway = BoardEmpty(
        title: "No gateway", symbol: "antenna.radiowaves.left.and.right.slash",
        detail: "Add a gateway in Settings and its board will show up here.")

    static let pluginOff = BoardEmpty(
        title: "Kanban is off on this gateway", symbol: "rectangle.split.3x1",
        detail: "Switch on the kanban plugin in the gateway dashboard (under Plugins) and the Board will appear.")

    static func unreadable(_ problem: String) -> BoardEmpty {
        BoardEmpty(title: "Could not read the board", symbol: "exclamationmark.triangle", detail: problem)
    }

    var view: some View {
        ContentUnavailableView {
            Label(title, systemImage: symbol)
        } description: {
            Text(detail)
        }
    }
}

/// The three lanes side by side, scrolling sideways when the window is narrow.
struct BoardLanes<Card: View>: View {
    let board: KanbanBoard
    let selection: String?
    /// A lane the page wants in view; cleared once it has been shown.
    @Binding var reveal: KanbanPresentationGroup?
    let onDrop: ([String], KanbanPresentationGroup) -> Bool
    @ViewBuilder let card: (KanbanTask) -> Card

    var body: some View {
        GeometryReader { space in
            let laneWidth = max(MacBoardView.columnWidth, (space.size.width - 64) / 3)
            ScrollViewReader { scroller in
                ScrollView(.horizontal) {
                    HStack(alignment: .top, spacing: 16) {
                        ForEach(KanbanPresentationGroup.allCases) { group in
                            lane(group, width: laneWidth)
                        }
                    }
                    .padding(16)
                    .frame(height: space.size.height)
                }
                .onChange(of: reveal, initial: true) { _, wanted in
                    guard let wanted else { return }
                    scroller.scrollTo(wanted.rawValue, anchor: .center)
                    reveal = nil
                }
                .onChange(of: selection) { _, id in
                    let owner = id.flatMap { board.task(id: $0) }.flatMap(KanbanPresentationGroup.group(for:))
                    if let owner { scroller.scrollTo(owner.rawValue, anchor: .center) }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func lane(_ group: KanbanPresentationGroup, width: CGFloat) -> some View {
        let tasks = group.tasks(in: board)
        return BoardLane(group: group, count: tasks.count, onDrop: { onDrop($0, group) }, selection: selection) {
            ForEach(tasks) { task in card(task).id(task.id) }
        }
        .frame(width: width)
        .id(group.rawValue)
    }
}

/// One card on the Board: a glass tile that chooses itself when pressed and can be dragged away.
struct BoardCardButton<MenuItems: View>: View {
    let task: KanbanTask
    let chosen: Bool
    let dragID: String
    let choose: () -> Void
    @ViewBuilder var menu: () -> MenuItems

    var body: some View {
        Button(action: choose) {
            BoardTaskRow(task: task)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .nollieGlass(.regular, in: .rect(cornerRadius: 16))
                .overlay { outline }
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .draggable(dragID)
        .contextMenu(menuItems: menu)
        .accessibilityAddTraits(chosen ? .isSelected : [])
        .accessibilityHint("Shows task details")
        .accessibilityIdentifier("board.card." + task.id)
    }

    private var outline: some View {
        RoundedRectangle(cornerRadius: 16)
            .strokeBorder(chosen ? Color.accentColor : Color.clear, lineWidth: 2)
    }
}

/// The strip under the lanes: live or polling, a problem if there is one, and the last read.
struct BoardStatusBar: View {
    let store: KanbanStore

    /// How the board is being kept fresh, as words, a symbol and how loudly to say it.
    private var freshness: (words: String, symbol: String, tone: HierarchicalShapeStyle, spoken: String?) {
        store.liveConnected
            ? ("Live", "dot.radiowaves.left.and.right", .secondary, "Live updates on")
            : ("Reading every minute", "clock", .tertiary, nil)
    }

    var body: some View {
        HStack(spacing: 12) {
            Label(freshness.words, systemImage: freshness.symbol)
                .foregroundStyle(freshness.tone)
                .accessibilityLabel(freshness.spoken ?? freshness.words)
            if let problem = store.lastError {
                Label(problem, systemImage: "exclamationmark.triangle").foregroundStyle(.orange).lineLimit(1)
            }
            Spacer()
            if let when = store.lastRead {
                Text("Updated \(when, format: .relative(presentation: .named))").foregroundStyle(.tertiary)
            }
        }
        .font(.caption)
        .inset(h: 14, v: 6)
        .background(.bar)
    }
}

/// The menu that switches between boards, with how many tasks on each need the person.
struct BoardPicker: View {
    let store: KanbanStore
    let pick: (String) -> Void

    private func label(for entry: KanbanBoardMeta) -> String {
        let summary = BoardReviewSummary(boards: [entry], selectedBoard: store.selectedBoard, loadedBoard: store.board)
        let waiting = summary.entries.first { $0.slug == entry.slug }?.count ?? 0
        return waiting > 0 ? "\(entry.displayName) (\(waiting) needing your help)" : entry.displayName
    }

    var body: some View {
        Menu {
            ForEach(store.boards) { entry in
                Button { pick(entry.slug) } label: {
                    if entry.slug == store.selectedBoard {
                        Label(label(for: entry), systemImage: "checkmark")
                    } else {
                        Text(label(for: entry))
                    }
                }
            }
        } label: {
            Label(store.selectedBoardMeta?.displayName ?? "Board", systemImage: "square.stack")
        }
        .accessibilityLabel("Choose a board")
        .help("Choose a board")
    }
}

/// The Board page's toolbar: a board picker when there are several, an options menu, and New Task.
struct BoardToolbar: ToolbarContent {
    let store: KanbanStore?
    let pickBoard: (String) -> Void
    let options: [BoardOption]
    let addTask: () -> Void

    /// One entry of the options menu.
    struct BoardOption: Identifiable {
        let title: String
        let symbol: String
        let run: () -> Void
        var id: String { title }
    }

    private var usable: Bool { store?.isPresent == true }

    var body: some ToolbarContent {
        if let store, store.boards.count > 1 {
            ToolbarItem(placement: .navigation) { BoardPicker(store: store, pick: pickBoard) }
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Menu {
                ForEach(options) { Button($0.title, systemImage: $0.symbol, action: $0.run) }
            } label: {
                Label("Board options", systemImage: "ellipsis")
            }
            .disabled(!usable)

            Button(action: addTask) { Label("New Task", systemImage: "plus") }
                .disabled(!usable)
                .accessibilityIdentifier("board.new")
                .help("New Task (⌘N)")
        }
    }
}
