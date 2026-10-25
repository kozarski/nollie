import NollieCore

/// Where the arrow keys move the chosen card. Plain functions over a board and the current choice.
struct BoardCursor {
    let board: KanbanBoard
    let current: String?

    private var laneContents: [[KanbanTask]] {
        KanbanPresentationGroup.allCases.map { $0.tasks(in: board) }
    }

    /// The task id a key press leads to, or nil when the press goes nowhere.
    func target(for key: BoardKeys.Key) -> String? {
        switch key {
        case .left: acrossLanes(by: -1)
        case .right: acrossLanes(by: 1)
        case .up: withinLane(by: -1)
        case .down: withinLane(by: 1)
        default: nil
        }
    }

    /// The top card of the next lane that has cards, going the way `step` points. With nothing chosen
    /// it starts from outside the far edge, so right lands on the first lane and left on the last.
    private func acrossLanes(by step: Int) -> String? {
        let filled = laneContents.filter { !$0.isEmpty }
        guard !filled.isEmpty else { return nil }
        let origin = filled.firstIndex { lane in lane.contains { $0.id == current } }
            ?? (step > 0 ? -1 : filled.count)
        return filled[min(max(origin + step, 0), filled.count - 1)].first?.id
    }

    /// The neighbour above or below in the same lane; the pending lane when nothing is chosen.
    private func withinLane(by step: Int) -> String? {
        let chosen = current.flatMap { board.task(id: $0) }
        let lane = chosen.flatMap(KanbanPresentationGroup.group(for:)) ?? .pending
        let cards = lane.tasks(in: board)
        let origin = cards.firstIndex { $0.id == current } ?? (step > 0 ? -1 : cards.count)
        guard !cards.isEmpty else { return nil }
        return cards[min(max(origin + step, 0), cards.count - 1)].id
    }
}

/// What a dragged card carries: which gateway, which board and which task, so a card from
/// somewhere else can never be dropped here.
struct BoardDragPayload {
    let gateway: String
    let board: String

    private var stem: String { gateway + "/" + board + "/" }

    func encode(_ taskID: String) -> String { stem + taskID }

    func taskID(in payload: String) -> String? {
        payload.hasPrefix(stem) ? String(payload.dropFirst(stem.count)) : nil
    }
}

extension KanbanStore {
    /// The loop of a board that is on screen: read now, open the live socket, then read every
    /// `interval`. Off screen it only makes sure the socket is closed.
    func keepReading(whileVisible visible: Bool, every interval: Duration = .seconds(60)) async {
        guard visible else { return stopEvents() }
        await refresh()
        startEvents()
        await loadAssignees()
        repeat {
            try? await Task.sleep(for: interval)
            if !Task.isCancelled { await refresh() }
        } while !Task.isCancelled
    }
}
