#if os(macOS)
import Testing
@testable import Nollie

/// The Mac setup step lists only what a person can act on or watch finish.
struct MacSetupTrailTests {
    private func steps(prepared: NativeDependencyStep.State, service: NativeDependencyStep.State) -> [NativeDependencyStep] {
        NativeSetupPlan.steps.map { step in
            var shown = step
            shown.state = step.id == "service" ? service : prepared
            return shown
        }
    }

    @Test func thePlanHasNoRowForALaterVersion() {
        #expect(!NativeSetupPlan.steps.contains { $0.id == "computer" })
        #expect(!NativeSetupPlan.steps.contains { $0.optional })
        #expect(NativeSetupPlan.steps.map(\.id) == NativeSetupPlan.preparationSteps + ["service"])
    }

    @Test func theDirectDownloadShowsPreparationThenTheService() {
        let rows = SetupTrail.rows(steps(prepared: .ready, service: .needsInstall), showsService: true)
        #expect(rows.map(\.id) == ["prepare", "service"])
        #expect(rows[0].state == .ready)
    }

    @Test func aCopyWithoutTheServiceShowsNoRowForIt() {
        let rows = SetupTrail.rows(steps(prepared: .needsInstall, service: .blocked), showsService: false)
        #expect(rows.map(\.id) == ["prepare"])
    }

    @Test func onlyTheDirectDownloadWithItsServiceShowsTheServiceRow() {
        #expect(SetupTrail.showsService(direct: true, runtimeAvailable: true, state: .off))
        #expect(SetupTrail.showsService(direct: true, runtimeAvailable: true, state: .requiresApproval))
        #expect(SetupTrail.showsService(direct: true, runtimeAvailable: true, state: .failed))
        // A Direct build whose signed service is missing (unsigned or damaged copy).
        #expect(!SetupTrail.showsService(direct: true, runtimeAvailable: true, state: .unavailable))
        // The demo copy.
        #expect(!SetupTrail.showsService(direct: true, runtimeAvailable: false, state: .off))
        // The Mac App Store edition.
        #expect(!SetupTrail.showsService(direct: false, runtimeAvailable: false, state: .unavailable))
    }

    @Test func preparationRollsUpToItsMostTellingState() {
        #expect(SetupTrail.rollUp([.ready, .ready]) == .ready)
        #expect(SetupTrail.rollUp([.ready, .installing, .failed]) == .installing)
        #expect(SetupTrail.rollUp([.ready, .failed, .needsInstall]) == .failed)
        #expect(SetupTrail.rollUp([.ready, .needsInstall]) == .needsInstall)
        #expect(SetupTrail.rollUp([]) == .needsInstall)
    }

    @Test func serviceStatesMapToRows() {
        #expect(SetupTrail.serviceState(.ready) == .ready)
        #expect(SetupTrail.serviceState(.starting) == .installing)
        #expect(SetupTrail.serviceState(.requiresApproval) == .blocked)
        #expect(SetupTrail.serviceState(.failed) == .failed)
        for state in [ManagedRuntimeClient.State.off, .stopped, .needsVerification] {
            #expect(SetupTrail.serviceState(state) == .needsInstall)
        }
    }

    @Test func comingBackFromLoginItemsCarriesOnStarting() {
        for now in [ManagedRuntimeClient.State.off, .stopped, .needsVerification] {
            #expect(SetupTrail.resumesStart(after: .requiresApproval, now: now, requested: true))
        }
        // Nobody pressed Keep it running, or approval is still missing, or it moved on by itself.
        #expect(!SetupTrail.resumesStart(after: .requiresApproval, now: .off, requested: false))
        #expect(!SetupTrail.resumesStart(after: .requiresApproval, now: .requiresApproval, requested: true))
        #expect(!SetupTrail.resumesStart(after: .off, now: .stopped, requested: true))
        #expect(!SetupTrail.resumesStart(after: .requiresApproval, now: .ready, requested: true))
    }

    @Test func everyPreparationStepSaysWhatItIsDoing() {
        for id in NativeSetupPlan.preparationSteps {
            #expect(SetupTrail.partWords(id) != nil)
        }
        #expect(SetupTrail.partWords("hermes")?.contains("91 MB") == true)
        #expect(SetupTrail.partWords("service") == nil)
    }

    @Test func failuresReadPlainlyAndKeepTheExactReasonApart() {
        let technical = "A setup file is not regular or is too large."
        let words = SetupTrail.plainFailure(step: "hermes", reason: technical)
        #expect(!words.contains(technical))
        #expect(words.contains("Hermes"))
        #expect(words.contains("try again"))
        // Low space is already plain, and something the person can do.
        #expect(SetupTrail.plainFailure(step: "python", reason: NativeSetupPlan.lowDiskMessage) == NativeSetupPlan.lowDiskMessage)
    }

    @Test func theStepCountStaysSteadyOnceAPathIsChosen() {
        var progress = OnboardingProgress()
        #expect(progress.stepCount == nil)
        progress.step = .home
        #expect(progress.stepCount == nil)
        progress.choose(.new)
        #expect(progress.stepCount?.index == 1)
        let total = progress.stepCount?.total
        #expect(total == 6)
        while progress.step != .ready {
            #expect(progress.stepCount?.total == total)
            progress.advance()
        }
        #expect(progress.stepCount == nil)
        // Back to the first screen after choosing: no count there either.
        progress.step = .home
        #expect(progress.stepCount == nil)
        var existing = OnboardingProgress()
        existing.choose(.existing)
        #expect(existing.stepCount?.total == 5)
    }

    @Test func approvalSaysExactlyWhereToClick() {
        let words = SetupTrail.approvalSteps
        #expect(words.contains("System Settings"))
        #expect(words.contains("Login Items & Extensions"))
        #expect(words.contains("Allow in the Background"))
    }
}
#endif
