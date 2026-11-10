#if os(macOS)
import Testing
@testable import Nollie

struct EngineUpdateTests {
    private let ready = ["uv": true, "python": true, "hermes": true, "dependencies": true, "addons": true]
    private let all = ["uv": true, "python": true, "hermes": true, "dependencies": true, "addons": true]

    @Test func aCurrentSetupIsLeftAlone() {
        #expect(EngineUpdate.stepsToRedo(verified: ready, hasReceipt: all).isEmpty)
    }

    @Test func anOlderEngineIsPreparedAgainWithItsLibrariesAndAddOns() {
        var verified = ready
        verified["hermes"] = false; verified["dependencies"] = false
        #expect(EngineUpdate.stepsToRedo(verified: verified, hasReceipt: all) == ["hermes", "dependencies", "addons"])
    }

    @Test func onlyTheLibrariesWhenTheEngineIsCurrent() {
        var verified = ready
        verified["dependencies"] = false
        #expect(EngineUpdate.stepsToRedo(verified: verified, hasReceipt: all) == ["dependencies", "addons"])
    }

    @Test func aSetupNeverFinishedStaysWithTheSetupScreen() {
        var verified = ready, receipts = all
        verified["hermes"] = false; verified["dependencies"] = false; verified["addons"] = false
        receipts["hermes"] = false; receipts["dependencies"] = false; receipts["addons"] = false
        #expect(EngineUpdate.stepsToRedo(verified: verified, hasReceipt: receipts).isEmpty)
    }

    @Test func pythonOrTheDownloadManagerNotReadyStaysWithTheSetupScreen() {
        for missing in ["uv", "python"] {
            var verified = ready
            verified[missing] = false; verified["hermes"] = false
            #expect(EngineUpdate.stepsToRedo(verified: verified, hasReceipt: all).isEmpty)
        }
    }
}
#endif
