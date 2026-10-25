import Foundation
import Testing
@testable import Nollie

@MainActor
struct InterruptedRuntimeRecoveryTests {
    @MainActor private final class Runtime {
        var running = true
        var starts = 0
        var startedCancelled = false
        func stop() async { await Task.yield(); running = false }
        func start() async {
            startedCancelled = Task.isCancelled
            starts += 1
            running = true
        }
    }

    @Test func cancelledSwitchRestoresThePreviousRuntimeInAnUncancelledTask() async {
        let previous = Runtime(), id = UUID()
        let cancelledSwitch = Task { @MainActor in
            await previous.stop()
            withUnsafeCurrentTask { $0?.cancel() }
            return InterruptedRuntimeRecovery.schedule(previous, connectionID: id,
                currentRuntime: { previous }, activeConnectionID: { id }, isCurrent: { true },
                start: { await $0.start() })
        }
        let recovery = await cancelledSwitch.value
        await recovery.value
        #expect(previous.running && previous.starts == 1 && !previous.startedCancelled)
    }

    @Test func staleSwitchCanRestoreItsOldConnectionWithoutStartingItsAbandonedDestination() async {
        let previous = Runtime(), abandoned = Runtime(), id = UUID()
        await previous.stop()
        abandoned.running = false
        let recovery = InterruptedRuntimeRecovery.schedule(previous, connectionID: id,
            currentRuntime: { previous }, activeConnectionID: { id }, isCurrent: { true },
            start: { await $0.start() })
        await recovery.value
        #expect(previous.running && previous.starts == 1)
        #expect(!abandoned.running && abandoned.starts == 0)
    }

    @Test(arguments: ["runtime", "connection", "generation"])
    func newerIntentPreventsRecoveryOfTheOldRuntime(_ changed: String) async {
        let previous = Runtime(), replacement = Runtime(), id = UUID()
        await previous.stop()
        var current = previous
        var activeID = id
        var currentGeneration = true
        let recovery = InterruptedRuntimeRecovery.schedule(previous, connectionID: id,
            currentRuntime: { current }, activeConnectionID: { activeID }, isCurrent: { currentGeneration },
            start: { await $0.start() })
        switch changed {
        case "runtime": current = replacement
        case "connection": activeID = UUID()
        default: currentGeneration = false
        }
        await recovery.value
        #expect(previous.starts == 0 && !previous.running)
        #expect(replacement.starts == 0)
    }

    @Test func explicitDisconnectCancelsPendingRecovery() async {
        let previous = Runtime(), id = UUID()
        await previous.stop()
        let recovery = InterruptedRuntimeRecovery.schedule(previous, connectionID: id,
            currentRuntime: { previous }, activeConnectionID: { id }, isCurrent: { true },
            start: { await $0.start() })
        recovery.cancel()
        await recovery.value
        #expect(!previous.running && previous.starts == 0)
    }
}
