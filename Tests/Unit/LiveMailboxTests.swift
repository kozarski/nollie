import Foundation
import Testing
@testable import NollieCore

/// One frame in the encoder at a time, the newest waiting, and a keyframe request that rides
/// with the next frame handed over.
struct LiveMailboxTests {
    private func handed(_ admission: LiveMailbox<Int>.Admission) -> LiveMailbox<Int>.Handoff? {
        if case .encodeNow(let handoff) = admission { return handoff }
        return nil
    }

    private func waited(_ admission: LiveMailbox<Int>.Admission) -> Bool? {
        if case .waiting(let replaced) = admission { return replaced }
        return nil
    }

    @Test func theNewestFrameWins() {
        var box = LiveMailbox<Int>()
        #expect(!box.inFlight)
        #expect(handed(box.admit(1))?.frame == 1)
        #expect(box.inFlight)
        #expect(waited(box.admit(2)) == false)
        #expect(waited(box.admit(3)) == true)
        #expect(waited(box.admit(4)) == true)
        #expect(box.dropped == 2)
        #expect(box.hasWaiting)
        #expect(box.latest == 4)
        #expect(box.encoderReturned()?.frame == 4)
        #expect(box.inFlight)
        #expect(!box.hasWaiting)
        #expect(box.encoderReturned() == nil)
        #expect(!box.inFlight)
        #expect(handed(box.admit(5))?.frame == 5)
        #expect(box.dropped == 2)
    }

    @Test func onlyOneFrameIsEverInTheEncoder() {
        var box = LiveMailbox<Int>()
        var inEncoder = 0
        var handedOver = 0
        for frame in 0..<1000 {
            if handed(box.admit(frame)) != nil { inEncoder += 1; handedOver += 1 }
            #expect(inEncoder <= 1)
            if frame % 3 == 2 {
                inEncoder -= 1
                if box.encoderReturned() != nil { inEncoder += 1; handedOver += 1 }
            }
        }
        #expect(handedOver + box.dropped + (box.hasWaiting ? 1 : 0) == 1000)
    }

    @Test func aKeyframeRequestRidesWithTheNextFrameHandedOver() {
        var box = LiveMailbox<Int>()
        box.requestKeyframe()
        #expect(handed(box.admit(1)) == .some(.init(frame: 1, keyframe: true)))
        #expect(!box.keyframeRequested)

        // Asked for while a frame is in the encoder: the frame waiting then carries it, once.
        _ = box.admit(2)
        box.requestKeyframe()
        _ = box.admit(3)
        #expect(box.encoderReturned() == .some(.init(frame: 3, keyframe: true)))
        _ = box.admit(4)
        #expect(box.encoderReturned() == .some(.init(frame: 4, keyframe: false)))
        #expect(box.encoderReturned() == nil)

        // Asked for with nothing waiting: the flag stays until a frame is handed over.
        _ = box.admit(5)
        box.requestKeyframe()
        #expect(box.encoderReturned() == nil)
        #expect(box.keyframeRequested)
        #expect(handed(box.admit(6))?.keyframe == true)
        #expect(handed(box.admit(7)) == nil)
    }

    @Test func takingTheRequestConsumesIt() {
        var box = LiveMailbox<Int>()
        let before = box.takeKeyframeRequest()
        box.requestKeyframe()
        box.requestKeyframe()
        let first = box.takeKeyframeRequest(), second = box.takeKeyframeRequest()
        #expect(!before)
        #expect(first)
        #expect(!second)
    }

    @Test func aStillScreenRepeatsItsLatestPictureAsTheKeyframe() {
        var box = LiveMailbox<Int>()
        #expect(box.repeatLatest() == nil)
        _ = box.admit(1)
        #expect(box.encoderReturned() == nil)
        #expect(box.repeatLatest() == nil)
        box.requestKeyframe()
        #expect(box.repeatLatest() == .some(.init(frame: 1, keyframe: true)))
        #expect(box.inFlight)
        #expect(!box.keyframeRequested)
        // Never while a frame is in the encoder or a newer one waits.
        box.requestKeyframe()
        #expect(box.repeatLatest() == nil)
        _ = box.admit(2)
        #expect(box.repeatLatest() == nil)
        #expect(box.encoderReturned() == .some(.init(frame: 2, keyframe: true)))
    }

    @Test func closingDropsTheWaitingFrameAndRefusesMore() {
        var box = LiveMailbox<Int>()
        _ = box.admit(1)
        _ = box.admit(2)
        box.requestKeyframe()
        box.close()
        #expect(box.closed)
        #expect(!box.hasWaiting)
        #expect(box.latest == nil)
        #expect(!box.keyframeRequested)
        guard case .refused = box.admit(3) else { Issue.record("a closed mailbox took a frame"); return }
        // The frame in the encoder finishes; nothing follows it.
        #expect(box.encoderReturned() == nil)
        #expect(!box.inFlight)
        box.requestKeyframe()
        #expect(!box.keyframeRequested)
        #expect(box.repeatLatest() == nil)
    }

    @Test func theLockedMailboxKeepsCountUnderContention() async {
        let box = LockedLiveMailbox<Int>()
        let handedOver = await withTaskGroup(of: Int.self) { group in
            for producer in 0..<8 {
                group.addTask {
                    var handed = 0
                    for frame in 0..<500 {
                        if case .encodeNow = box.admit(producer * 1000 + frame) { handed += 1 }
                        if frame % 2 == 0 {
                            // Act as the encoder finishing whatever is in flight.
                            if box.inFlight, box.encoderReturned() != nil { handed += 1 }
                        }
                    }
                    return handed
                }
            }
            return await group.reduce(0, +)
        }
        let waiting = box.withLock { $0.hasWaiting } ? 1 : 0
        #expect(handedOver + box.dropped + waiting == 4000)
    }
}
