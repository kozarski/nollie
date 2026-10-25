#if os(macOS) && NOLLIE_DIRECT
import Foundation
import Testing
@testable import Nollie

/// The care taken before an update installs: a bot using the Mac is stopped, running turns get time to
/// finish, and the ones still going are paused. A fake Mac and a fake clock stand in for the real ones.
@MainActor
final class FakeUpdateMac: UpdateInstallEnvironment {
    var computerActive: Bool
    var turns: [UpdateTurn]
    private(set) var events: [String] = []
    private(set) var paused: [UpdateTurn] = []
    /// Seconds on the fake clock; turns listed here finish when it reaches their time.
    private(set) var clock = Duration.zero
    var finishAt: [String: Duration] = [:]

    init(computerActive: Bool = false, turns: [UpdateTurn] = []) {
        self.computerActive = computerActive
        self.turns = turns
    }

    func runningTurns() -> [UpdateTurn] {
        turns.filter { turn in finishAt[turn.id].map { clock < $0 } ?? true }
    }

    func stopComputer() -> Bool {
        defer { computerActive = false }
        if computerActive { events.append("computer stopped") }
        return computerActive
    }

    func pause(_ turn: UpdateTurn) async {
        events.append("paused \(turn.id)")
        paused.append(turn)
        turns.removeAll { $0 == turn }
    }

    func tick(_ step: Duration) { clock += step }
}

@MainActor
struct UpdateInstallGateTests {
    private let scout = UpdateTurn(id: "chat-1", bot: "scout")
    private let mason = UpdateTurn(id: "chat-2", bot: "mason")

    private func gate(_ mac: FakeUpdateMac, patience: Duration = .seconds(60)) -> (UpdateInstallGate, Counter) {
        let counter = Counter()
        let gate = UpdateInstallGate(environment: mac,
                                     timing: .init(patience: patience, poll: .seconds(1), settle: .seconds(3)),
                                     sleep: { step in mac.tick(step); counter.slept += step; await Task.yield() })
        return (gate, counter)
    }

    @MainActor final class Counter { var slept = Duration.zero }

    @Test func aQuietMacIsReadyAtOnceWithoutWaiting() async {
        let mac = FakeUpdateMac()
        let (gate, counter) = gate(mac)
        let report = await gate.prepare()
        #expect(report == UpdateInstallReport())
        #expect(counter.slept == .zero)
        #expect(mac.events.isEmpty)
    }

    @Test func aBotUsingTheMacIsStoppedBeforeAnythingElse() async {
        let mac = FakeUpdateMac(computerActive: true, turns: [scout])
        mac.finishAt[scout.id] = .seconds(2)
        let (gate, _) = gate(mac)
        let report = await gate.prepare()
        #expect(report.computerStopped)
        #expect(mac.events == ["computer stopped"])
        #expect(!mac.computerActive)
    }

    @Test func turnsThatFinishInTimeAreLeftAlone() async {
        let mac = FakeUpdateMac(turns: [scout, mason])
        mac.finishAt[scout.id] = .seconds(5)
        mac.finishAt[mason.id] = .seconds(20)
        let (gate, counter) = gate(mac)
        let report = await gate.prepare()
        #expect(report.finishedOnTheirOwn == 2)
        #expect(report.paused.isEmpty)
        #expect(mac.paused.isEmpty)
        #expect(counter.slept == .seconds(20))
    }

    @Test func aTurnStillGoingWhenPatienceRunsOutIsPausedOnce() async {
        let mac = FakeUpdateMac(turns: [scout, mason])
        mac.finishAt[scout.id] = .seconds(10)
        let (gate, counter) = gate(mac, patience: .seconds(30))
        let report = await gate.prepare()
        #expect(report.finishedOnTheirOwn == 1)
        #expect(report.paused == [mason])
        #expect(mac.events == ["paused chat-2"])
        // The whole patience, then the short settle so the gateway has the interrupt.
        #expect(counter.slept == .seconds(33))
    }

    @Test func everyTurnIsPausedWhenNoneFinish() async {
        let mac = FakeUpdateMac(computerActive: true, turns: [scout, mason])
        let (gate, _) = gate(mac, patience: .seconds(5))
        let report = await gate.prepare()
        #expect(report.computerStopped)
        #expect(Set(report.paused) == [scout, mason])
        #expect(mac.runningTurns().isEmpty)
    }

    @Test func askingAgainWhilePreparingJoinsTheSameRun() async {
        let mac = FakeUpdateMac(turns: [scout])
        let (gate, _) = gate(mac, patience: .seconds(5))
        async let first = gate.prepare()
        async let second = gate.prepare()
        let (one, two) = await (first, second)
        #expect(one == two)
        #expect(mac.paused == [scout])
        #expect(!gate.isPreparing)
    }

    @Test func aLaterRunStartsFresh() async {
        let mac = FakeUpdateMac(turns: [scout])
        let (gate, _) = gate(mac, patience: .seconds(2))
        _ = await gate.prepare()
        mac.turns = [mason]
        let report = await gate.prepare()
        #expect(report.paused == [mason])
    }
}

struct SparkleConfigurationTests {
    private let key = Data(repeating: 7, count: 32).base64EncodedString()
    private let feed = "https://github.com/kozarski/nollie/releases/latest/download/appcast.xml"

    @Test func aRealKeyAndAnHttpsFeedAreEnough() throws {
        let configuration = try #require(SparkleConfiguration(info: ["SUFeedURL": feed, "SUPublicEDKey": key]))
        #expect(configuration.feedURL.absoluteString == feed)
        #expect(configuration.publicKey == key)
    }

    @Test func thePlaceholderAndOtherWrongKeysKeepTheUpdaterOff() {
        let wrong = ["PLACEHOLDER_RUN_TOOLS_RELEASE_SPARKLE_KEYS_SH", "", "###", Data(repeating: 1, count: 16).base64EncodedString(),
                     Data(repeating: 1, count: 64).base64EncodedString()]
        for bad in wrong {
            #expect(SparkleConfiguration(info: ["SUFeedURL": feed, "SUPublicEDKey": bad]) == nil)
        }
    }

    @Test func aMissingOrInsecureFeedKeepsTheUpdaterOff() {
        #expect(SparkleConfiguration(info: nil) == nil)
        #expect(SparkleConfiguration(info: ["SUPublicEDKey": key]) == nil)
        #expect(SparkleConfiguration(info: ["SUFeedURL": "http://example.com/appcast.xml", "SUPublicEDKey": key]) == nil)
        #expect(SparkleConfiguration(info: ["SUFeedURL": "not a url", "SUPublicEDKey": key]) == nil)
    }
}
#endif
