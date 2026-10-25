import Testing
@testable import Nollie
import NollieCore

@Suite struct BoardReviewSummaryTests {
    @Test func routineReviewsDoNotAskForTheUsersAttention() {
        var archived = KanbanBoardMeta(slug: "archive", counts: ["review": 40, "blocked": 30])
        archived.archived = true
        let summary = BoardReviewSummary(boards: [
            .init(slug: "first", counts: ["review": 2, "running": 8, "blocked": 3]),
            .init(slug: "second", counts: ["review": 1, "ready": 12]),
            .init(slug: "first", counts: ["review": 2]),
            .init(slug: "unknown"), archived,
        ], selectedBoard: "first", loadedBoard: nil)
        #expect(summary.count == 3)
        #expect(summary.boardToOpen(current: "first") == "first")
        #expect(summary.boardToOpen(current: "unknown") == "first")
    }

    @Test func newerCardsReplaceTheirBoardsMetadataWithoutCountingTwice() {
        let review = KanbanTask(id: "review", title: "Ready to check", status: "review")
        let board = KanbanBoard(columns: [
            .init(name: "review", tasks: [review, review]),
            .init(name: "blocked", tasks: [.init(id: "blocked", title: "Blocked", status: "blocked")]),
            .init(name: "running", tasks: [.init(id: "running", title: "Working", status: "running")]),
        ])
        let summary = BoardReviewSummary(boards: [
            .init(slug: "first", counts: ["review": 8]),
            .init(slug: "second", counts: ["review": 2]),
        ], selectedBoard: "first", loadedBoard: board)
        #expect(summary.count == 1)
    }

    @Test func resolvingTheLastTaskLeadsToTheNextBoardNeedingHelp() {
        let summary = BoardReviewSummary(boards: [
            .init(slug: "first", counts: ["review": 1]),
            .init(slug: "second", counts: ["blocked": 2]),
        ], selectedBoard: "first", loadedBoard: KanbanBoard(columns: []))
        #expect(summary.count == 2)
        #expect(summary.boardToOpen(current: "first") == "second")
    }

    @Test func emptyOrUnavailableCountsStayQuiet() {
        let summary = BoardReviewSummary(boards: [.init(slug: "first", counts: ["review": -1, "blocked": -2])], selectedBoard: "first", loadedBoard: nil)
        #expect(summary.count == 0)
        #expect(summary.boardToOpen(current: "first") == "first")
        let empty = BoardReviewSummary(boards: [], selectedBoard: nil, loadedBoard: nil)
        #expect(empty.count == 0)
        #expect(empty.boardToOpen(current: nil) == nil)
    }

    @Test func archivedSelectedBoardsDoNotAddLoadedReviews() {
        var archived = KanbanBoardMeta(slug: "archive", counts: ["review": 4])
        archived.archived = true
        let board = KanbanBoard(columns: [.init(name: "review", tasks: [.init(id: "old", title: "Old review", status: "review")])])
        let summary = BoardReviewSummary(boards: [archived], selectedBoard: "archive", loadedBoard: board)
        #expect(summary.count == 0)
    }

    @Test func aTaskRepeatedAcrossAttentionColumnsOnlyCountsOnce() {
        let review = KanbanTask(id: "same", title: "Check it", status: "review")
        let blocked = KanbanTask(id: "same", title: "Check it", status: "blocked")
        let board = KanbanBoard(columns: [
            .init(name: "review", tasks: [review]),
            .init(name: "blocked", tasks: [blocked, .init(id: "other", title: "Choose a format", status: "blocked")]),
        ])
        let summary = BoardReviewSummary(boards: [], selectedBoard: "first", loadedBoard: board)
        #expect(summary.count == 2)
        #expect(summary.count == KanbanPresentationGroup.blocked.tasks(in: board).count)
    }

    @Test func preciseCompanionCountsExcludeRecoveryOnUnopenedBoards() {
        let summary = BoardReviewSummary(boards: [
            .init(slug: "first", counts: ["blocked": 5, "review": 3]),
            .init(slug: "second", counts: ["blocked": 7]),
        ], selectedBoard: nil, loadedBoard: nil, attentionCounts: ["first": 0, "second": 2])
        #expect(summary.count == 2)
        #expect(summary.boardToOpen(current: "first") == "second")
    }

    @Test func loadedCardsKeepTransientFailuresWithTheAgents() {
        var waiting = KanbanTask(id: "retry", title: "Retry a connection", status: "blocked")
        waiting.blockKind = "transient"
        var question = KanbanTask(id: "question", title: "Choose a date", status: "blocked")
        question.blockKind = "needs_input"
        let summary = BoardReviewSummary(boards: [], selectedBoard: "first",
            loadedBoard: KanbanBoard(columns: [.init(name: "blocked", tasks: [waiting, question])]))
        #expect(summary.count == 1)
    }
}
