import Foundation
import Testing
@testable import NollieCore
#if os(macOS)
import IOKit.pwr_mgt
@testable import Nollie
#endif

// Keep Mac awake for my crew: when Nollie may hold the Mac out of idle sleep, and the assertion it holds.

private let kaNow = Date(timeIntervalSince1970: 1_792_540_800)

private func kaFacts(on: Bool = true, here: Bool = true, working: Bool = false, dueIn: [TimeInterval] = [],
                     power: KeepAwakePolicy.Power = .pluggedIn, lowPower: Bool = false) -> KeepAwakePolicy.Facts {
    KeepAwakePolicy.Facts(on: on, assistantHere: here, working: working, due: dueIn.map { kaNow.addingTimeInterval($0) },
                          power: power, lowPowerMode: lowPower, now: kaNow)
}

@Suite struct KeepAwakePolicyTests {
    @Test func offOrElsewhereNeverHolds() {
        #expect(KeepAwakePolicy.decide(kaFacts(on: false, working: true)) == .sleep(.off))
        #expect(KeepAwakePolicy.decide(kaFacts(here: false, working: true, dueIn: [60])) == .sleep(.elsewhere))
    }

    @Test func pluggedInStaysAwakeForWorkAndTonightsSchedules() {
        #expect(KeepAwakePolicy.decide(kaFacts(working: true)) == .awake(.working))
        // The nearest run decides, up to 12 hours ahead.
        #expect(KeepAwakePolicy.decide(kaFacts(dueIn: [8 * 3600, 3 * 3600])) == .awake(.due(kaNow.addingTimeInterval(3 * 3600))))
        #expect(KeepAwakePolicy.decide(kaFacts(dueIn: [13 * 3600])) == .sleep(.nothingDue))
        #expect(KeepAwakePolicy.decide(kaFacts()) == .sleep(.nothingDue))
    }

    @Test func aRunJustDueIsGivenTimeToStartButAnOldOneIsNot() {
        #expect(KeepAwakePolicy.decide(kaFacts(dueIn: [-120])) == .awake(.due(kaNow.addingTimeInterval(-120))))
        #expect(KeepAwakePolicy.decide(kaFacts(dueIn: [-3600])) == .sleep(.nothingDue))
    }

    @Test func onBatteryOnlyForWorkOrWhatIsAboutToRun() {
        let battery = KeepAwakePolicy.Power.battery(0.8)
        #expect(KeepAwakePolicy.decide(kaFacts(working: true, power: battery)) == .awake(.working))
        #expect(KeepAwakePolicy.decide(kaFacts(dueIn: [10 * 60], power: battery)) == .awake(.due(kaNow.addingTimeInterval(600))))
        #expect(KeepAwakePolicy.decide(kaFacts(dueIn: [2 * 3600], power: battery)) == .sleep(.nothingDue))
        #expect(KeepAwakePolicy.decide(kaFacts(dueIn: [10 * 60], power: .battery(nil))) == .awake(.due(kaNow.addingTimeInterval(600))))
    }

    @Test func aLowBatteryOrLowPowerModeAlwaysLetsItSleep() {
        #expect(KeepAwakePolicy.decide(kaFacts(working: true, power: .battery(0.19))) == .sleep(.lowBattery))
        #expect(KeepAwakePolicy.decide(kaFacts(working: true, power: .battery(0.9), lowPower: true)) == .sleep(.lowBattery))
        // Plugged in, Low Power Mode doesn't drain anything.
        #expect(KeepAwakePolicy.decide(kaFacts(working: true, lowPower: true)) == .awake(.working))
    }

    @Test func theAssertionNamesNollieAndTheReasonButNoBotOrTitle() {
        let clock: SleepNote.Clock = { _ in "2:00" }
        #expect(KeepAwakePolicy.assertionName(.working) == "Nollie is keeping your Mac awake while a helper works")
        #expect(KeepAwakePolicy.assertionName(.due(kaNow), clock: clock) == "Nollie is keeping your Mac awake for a schedule at 2:00")
    }
}

#if os(macOS)
@MainActor @Suite(.serialized) struct KeepAwakeMacTests {
    /// This process's own idle-sleep assertions, by name.
    private func held() -> [String] {
        var byProcess: Unmanaged<CFDictionary>?
        guard IOPMCopyAssertionsByProcess(&byProcess) == kIOReturnSuccess,
              let all = byProcess?.takeRetainedValue() as? [NSNumber: [[String: Any]]] else { return [] }
        let mine = all[NSNumber(value: ProcessInfo.processInfo.processIdentifier)] ?? []
        return mine.filter { $0[kIOPMAssertionTypeKey] as? String == kIOPMAssertPreventUserIdleSystemSleep }
            .compactMap { $0[kIOPMAssertionNameKey] as? String }
    }

    @Test func oneAssertionAtATimeRenamedInPlaceAndLetGo() {
        let name = "Nollie test \(UUID().uuidString)"
        let renamed = "Nollie test \(UUID().uuidString)"
        let hold = PowerAssertion()
        hold.hold(named: name)
        #expect(held().contains(name))
        hold.hold(named: renamed)
        #expect(held().contains(renamed) && !held().contains(name))
        hold.release()
        #expect(!held().contains(renamed))
        #expect(!hold.isHeld)
    }

    @Test func onlyAnAssistantOnThisMacCounts() throws {
        func connection(_ address: String, managed: Bool = false) throws -> GatewayConnection {
            GatewayConnection(name: "Test", gateway: try GatewayURL.normalize(address), authMode: .sessionToken,
                              managedInstallationID: managed ? UUID() : nil)
        }
        #expect(MacKeepAwake.isOnThisMac(try connection("http://127.0.0.1:9119")))
        #expect(MacKeepAwake.isOnThisMac(try connection("http://localhost:9119")))
        #expect(!MacKeepAwake.isOnThisMac(try connection("https://studio.tail1234.ts.net:8443")))
        #expect(MacKeepAwake.isOnThisMac(try connection("https://studio.tail1234.ts.net:8443", managed: true)))
    }

    @Test func thePageSaysWhatTheMacDoesNow() {
        let at = Date(timeIntervalSince1970: 0)
        #expect(KeepAwakeHero.State(on: false, decision: .sleep(.off)) == .off)
        #expect(KeepAwakeHero.State(on: true, decision: .awake(.due(at))).line(clock: { _ in "2:00" }) == "Next schedule at 2:00.")
        #expect(KeepAwakeHero.State(on: true, decision: .sleep(.lowBattery)).title == "Saving battery")
        #expect(KeepAwakeHero.State(on: true, decision: .sleep(.nothingDue)).line() == "Nothing due. It sleeps as usual.")
    }
}
#endif
