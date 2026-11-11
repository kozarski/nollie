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

    @Test func aNewerPythonOrDownloadManagerIsPreparedAgainWithEverythingAfter() {
        var verified = ready
        verified["uv"] = false; verified["python"] = false; verified["dependencies"] = false
        #expect(EngineUpdate.stepsToRedo(verified: verified, hasReceipt: all) == ["uv", "python", "hermes", "dependencies", "addons"])
        verified = ready
        verified["python"] = false
        #expect(EngineUpdate.stepsToRedo(verified: verified, hasReceipt: all) == ["python", "hermes", "dependencies", "addons"])
    }

    @Test func aMissingDownloadManagerStaysWithTheSetupScreen() {
        var receipts = all
        receipts["uv"] = false
        var verified = ready
        verified["uv"] = false; verified["hermes"] = false
        #expect(EngineUpdate.stepsToRedo(verified: verified, hasReceipt: receipts).isEmpty)
    }

    @Test func anUpdateCutShortCarriesOnThoughItsReceiptsWereMovedAway() {
        var verified = ready, receipts = all
        verified["hermes"] = false; verified["dependencies"] = false; verified["addons"] = false
        receipts["hermes"] = false
        #expect(EngineUpdate.stepsToRedo(verified: verified, hasReceipt: receipts, unfinished: true) == ["hermes", "dependencies", "addons"])
        #expect(EngineUpdate.stepsToRedo(verified: ready, hasReceipt: all, unfinished: true).isEmpty)
    }

    @Test func hermesStartsAgainOnlyWhenTheServiceIsOnAndEverythingChecksOut() {
        #expect(EngineUpdate.shouldResume(serviceOn: true, hermesStopped: true, verified: ready))
        #expect(!EngineUpdate.shouldResume(serviceOn: false, hermesStopped: true, verified: ready))
        #expect(!EngineUpdate.shouldResume(serviceOn: true, hermesStopped: false, verified: ready))
        var verified = ready
        verified["addons"] = false
        #expect(!EngineUpdate.shouldResume(serviceOn: true, hermesStopped: true, verified: verified))
    }
}
#endif
