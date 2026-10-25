import Testing
@testable import NollieCore

/// The once-a-second judge: every move between fine, behind and stalled, the room it leaves before
/// changing its mind, the quality steps, the floors a viewer's device sets, and the keyframe after
/// a stall.
struct LiveJudgeTests {
    private static let clean = LiveJudge.Second(sent: 30, withheld: 0, bytesTaken: 400_000, bytesWaiting: 0, heard: true)
    private static let short = LiveJudge.Second(sent: 20, withheld: 6, bytesTaken: 200_000, bytesWaiting: 90_000, heard: true)
    private static let dead = LiveJudge.Second(sent: 0, withheld: 3, bytesTaken: 0, bytesWaiting: 50_000, heard: false)

    private func run(_ judge: inout LiveJudge, _ seconds: [LiveJudge.Second], limit: LiveWire.Limit = .none) -> [LiveJudge.Verdict] {
        seconds.map { judge.judge($0, limit: limit) }
    }

    @Test func secondsAreShortDeadOrClean() {
        func second(_ sent: Int, _ withheld: Int, taken: Int = 1, waiting: Int = 0, heard: Bool = true) -> LiveJudge.Second {
            .init(sent: sent, withheld: withheld, bytesTaken: taken, bytesWaiting: waiting, heard: heard)
        }
        #expect(!second(0, 1).isShort)
        #expect(second(0, 2).isShort)
        #expect(second(8, 2).isShort)
        #expect(!second(9, 2).isShort)
        #expect(second(40, 10).isShort)
        #expect(!second(41, 10).isShort)
        #expect(second(0, 0, taken: 0, waiting: 1, heard: false).isDead)
        #expect(!second(0, 0, taken: 0, waiting: 1, heard: true).isDead)
        #expect(!second(0, 0, taken: 0, waiting: 0, heard: false).isDead)
        #expect(!second(0, 0, taken: 1, waiting: 1, heard: false).isDead)
        #expect(Self.clean.isClean)
        #expect(!Self.short.isClean)
        #expect(!Self.dead.isClean)
    }

    @Test func fineFallsBehindAfterTwoShortSecondsInFour() {
        var judge = LiveJudge()
        let verdicts = run(&judge, [Self.short, Self.clean, Self.clean])
        #expect(verdicts.allSatisfy { $0.state == .fine && $0.level == 0 && !$0.levelChanged })
        let behind = judge.judge(Self.short)
        #expect(behind == .init(state: .behind, level: 1, levelChanged: true, needsKeyframe: false))

        // Two short seconds five apart are not two in four.
        var spaced = LiveJudge()
        #expect(run(&spaced, [Self.short, Self.clean, Self.clean, Self.clean, Self.short]).allSatisfy { $0.state == .fine })
    }

    @Test func behindCatchesUpAfterFourCleanSecondsInARow() {
        var judge = LiveJudge()
        _ = run(&judge, [Self.short, Self.short])
        #expect(judge.state == .behind)
        let three = run(&judge, [Self.clean, Self.clean, Self.clean])
        #expect(three.allSatisfy { $0.state == .behind && $0.level == 1 })
        #expect(judge.judge(Self.clean) == .init(state: .fine, level: 1, levelChanged: false, needsKeyframe: false))
    }

    @Test func oneRoughSecondStartsTheCleanCountAgain() {
        var judge = LiveJudge()
        _ = run(&judge, [Self.short, Self.short, Self.clean, Self.clean, Self.clean])
        #expect(judge.state == .behind)
        _ = judge.judge(Self.short)
        let after = run(&judge, [Self.clean, Self.clean, Self.clean])
        #expect(after.allSatisfy { $0.state == .behind })
        #expect(judge.judge(Self.clean).state == .fine)
    }

    @Test func stillBehindThreeSecondsAfterAStepStepsAgain() {
        var judge = LiveJudge()
        _ = run(&judge, [Self.short, Self.short])
        #expect(judge.level == 1)
        let next = run(&judge, [Self.short, Self.short, Self.short])
        #expect(next.map(\.level) == [1, 1, 2])
        #expect(next.map(\.levelChanged) == [false, false, true])
        let more = run(&judge, [Self.short, Self.short, Self.short, Self.short, Self.short, Self.short])
        #expect(more.map(\.level) == [2, 2, 3, 3, 3, 3])
        #expect(more.filter(\.levelChanged).count == 1)
    }

    @Test func catchingUpCleanlyIsNotAReasonToStepAgain() {
        var judge = LiveJudge()
        _ = run(&judge, [Self.short, Self.short])
        let catchingUp = run(&judge, [Self.clean, Self.clean, Self.clean, Self.clean])
        #expect(catchingUp.map(\.level) == [1, 1, 1, 1])
        #expect(catchingUp.last?.state == .fine)
    }

    @Test func twoDeadSecondsStallAndTheFirstLiveOneComesBackWithAKeyframe() {
        var judge = LiveJudge()
        #expect(judge.judge(Self.dead).state == .fine)
        #expect(judge.judge(Self.dead) == .init(state: .stalled, level: 1, levelChanged: true, needsKeyframe: false))
        let stillDead = run(&judge, [Self.dead, Self.dead, Self.dead])
        #expect(stillDead.allSatisfy { $0 == .init(state: .stalled, level: 1, levelChanged: false, needsKeyframe: false) })
        #expect(judge.judge(Self.short) == .init(state: .behind, level: 1, levelChanged: false, needsKeyframe: true))
        // Only once, and the normal rules follow.
        let back = run(&judge, [Self.clean, Self.clean, Self.clean, Self.clean])
        #expect(back.allSatisfy { !$0.needsKeyframe })
        #expect(back.last?.state == .fine)
    }

    @Test func behindStallsLikeFine() {
        var judge = LiveJudge()
        _ = run(&judge, [Self.short, Self.short])
        #expect(judge.judge(Self.dead).state == .behind)
        #expect(judge.judge(Self.dead) == .init(state: .stalled, level: 2, levelChanged: true, needsKeyframe: false))
        #expect(judge.judge(Self.clean) == .init(state: .behind, level: 2, levelChanged: false, needsKeyframe: true))
    }

    @Test func aHeardViewerIsNeverDead() {
        var judge = LiveJudge()
        let quiet = LiveJudge.Second(sent: 0, withheld: 0, bytesTaken: 0, bytesWaiting: 50_000, heard: true)
        #expect(run(&judge, [quiet, quiet, quiet]).allSatisfy { $0.state == .fine })
    }

    @Test func fifteenCleanSecondsStepTheQualityBackUp() {
        var judge = LiveJudge(level: 2)
        let fourteen = run(&judge, Array(repeating: Self.clean, count: 14))
        #expect(fourteen.allSatisfy { $0.level == 2 && !$0.levelChanged })
        #expect(judge.judge(Self.clean) == .init(state: .fine, level: 1, levelChanged: true, needsKeyframe: false))
        let next = run(&judge, Array(repeating: Self.clean, count: 15))
        #expect(next.map(\.level).last == 0)
        #expect(next.filter(\.levelChanged).count == 1)
        // Never better than the best.
        #expect(run(&judge, Array(repeating: Self.clean, count: 40)).allSatisfy { $0.level == 0 && !$0.levelChanged })
    }

    @Test func theCleanRunCountsFromTheLastChange() {
        var judge = LiveJudge()
        _ = run(&judge, [Self.short, Self.short])
        // Four clean seconds catch up, then eleven more make fifteen since the step.
        let verdicts = run(&judge, Array(repeating: Self.clean, count: 15))
        #expect(verdicts.last?.level == 0)
        #expect(verdicts.dropLast().allSatisfy { $0.level == 1 })
    }

    @Test func theViewersLimitSetsAFloor() {
        #expect(LiveJudge.floor(for: .none) == 0)
        #expect(LiveJudge.floor(for: .low) == 2)
        #expect(LiveJudge.floor(for: .lowest) == 3)

        var judge = LiveJudge()
        #expect(judge.judge(Self.clean, limit: .low) == .init(state: .fine, level: 2, levelChanged: true, needsKeyframe: false))
        #expect(run(&judge, Array(repeating: Self.clean, count: 30), limit: .low).allSatisfy { $0.level == 2 })
        #expect(judge.judge(Self.clean, limit: .lowest).level == 3)
        // At the floor, falling behind has nowhere lighter to go.
        let behind = run(&judge, [Self.short, Self.short], limit: .lowest)
        #expect(behind.last == .init(state: .behind, level: 3, levelChanged: false, needsKeyframe: false))
        // When the device cools down, the level climbs back a step per fifteen clean seconds.
        let cooled = run(&judge, Array(repeating: Self.clean, count: 19), limit: .none)
        #expect(cooled.last?.level == 2)
        #expect(run(&judge, Array(repeating: Self.clean, count: 30)).last?.level == 0)
    }

    @Test func theSameSecondsAlwaysGiveTheSameVerdicts() {
        let seconds = [Self.short, Self.dead, Self.dead, Self.clean, Self.short, Self.short, Self.clean]
            + Array(repeating: Self.clean, count: 20) + [Self.dead, Self.short]
        var first = LiveJudge(), second = LiveJudge()
        #expect(run(&first, seconds) == run(&second, seconds))
        #expect(first == second)
    }

    @Test func startingLevelsAreClamped() {
        #expect(LiveJudge(level: -4).level == 0)
        #expect(LiveJudge(level: 9).level == 3)
    }
}
