#if os(macOS)
import Foundation
import Testing
@testable import Nollie

/// Preparation steps for one setup folder never overlap, whichever installer asks: the launch-time
/// add-on update and the setup screen once both ran the add-ons and threw the finished work away.
struct NativeInstallGateTests {
    /// Records how many bodies run at once, and the order they finish in.
    private actor Probe {
        var running = 0
        var most = 0
        var finished: [Int] = []
        func enter() { running += 1; most = max(most, running) }
        func leave(_ n: Int) { running -= 1; finished.append(n) }
    }

    @Test func oneFolderRunsOneStepAtATime() async throws {
        let gate = NativeInstallGate()
        let probe = Probe()
        let key = "/setups/" + UUID().uuidString
        try await withThrowingTaskGroup(of: Void.self) { group in
            for n in 0..<6 {
                group.addTask {
                    try await gate.serialized(key) {
                        await probe.enter()
                        try await Task.sleep(for: .milliseconds(20))
                        await probe.leave(n)
                    }
                }
            }
            try await group.waitForAll()
        }
        #expect(await probe.most == 1)
        #expect(await probe.finished.count == 6)
        #expect(await gate.isBusy(key) == false)
    }

    @Test func differentFoldersDoNotWaitForEachOther() async throws {
        let gate = NativeInstallGate()
        let probe = Probe()
        try await withThrowingTaskGroup(of: Void.self) { group in
            for n in 0..<3 {
                group.addTask {
                    try await gate.serialized("/setups/" + UUID().uuidString) {
                        await probe.enter()
                        try await Task.sleep(for: .milliseconds(80))
                        await probe.leave(n)
                    }
                }
            }
            try await group.waitForAll()
        }
        #expect(await probe.most > 1)
    }

    @Test func aFailedStepLetsTheNextCallerIn() async throws {
        struct Boom: Error {}
        let gate = NativeInstallGate()
        let key = "/setups/" + UUID().uuidString
        await #expect(throws: Boom.self) { try await gate.serialized(key) { throw Boom() } }
        #expect(await gate.isBusy(key) == false)
        let value = try await gate.serialized(key) { 7 }
        #expect(value == 7)
    }

    @Test func theSecondCallerSeesTheFirstCallersWork() async throws {
        // The shape of install(): check under the gate, do the work only when it isn't done.
        actor Folder { var receipt = false; var runs = 0; func work() { runs += 1; receipt = true } }
        let gate = NativeInstallGate()
        let folder = Folder()
        let key = "/setups/" + UUID().uuidString
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<2 {
                group.addTask {
                    try await gate.serialized(key) {
                        if await folder.receipt { return }
                        try await Task.sleep(for: .milliseconds(30))
                        await folder.work()
                    }
                }
            }
            try await group.waitForAll()
        }
        #expect(await folder.runs == 1)
    }

    #if NOLLIE_DIRECT
    @Test func aBusyAddOnInstallerIsAWaitNotAFailure() {
        #expect(NativeDependencyInstaller.isBusy(NativeSetupProcess.Failure(status: 3, diagnostic: "")))
        #expect(!NativeDependencyInstaller.isBusy(NativeSetupProcess.Failure(status: 1, diagnostic: "")))
        #expect(!NativeDependencyInstaller.isBusy(NativeSetupPlan.failure("other")))
    }
    #endif
}
#endif
