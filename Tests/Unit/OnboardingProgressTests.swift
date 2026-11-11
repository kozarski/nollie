import Foundation
import Testing
@testable import Nollie
import NollieCore

@MainActor
struct OnboardingProgressTests {
    @Test func theComputerStepHasOneWayOnAndItAlwaysWorks() {
        #expect(OnboardingProgress.Step.computer.continueAlwaysWorks, "Off means go on without it")
        #expect(!OnboardingProgress.Step.computer.hasLaterPill, "Set up later meant the same as Continue")
        #expect(!OnboardingProgress.Step.computer.hasSkipPill, "Continue is the one button")
        #expect(OnboardingProgress.Step.model.hasLaterPill, "The model's Continue waits for one that answers")
        #expect(!OnboardingProgress.Step.model.continueAlwaysWorks)
        #expect(OnboardingProgress.Step.permissions.hasLaterPill && OnboardingProgress.Step.permissions.continueAlwaysWorks)
        #expect(OnboardingProgress.Step.welcome.hasSkipPill && OnboardingProgress.Step.connection.hasSkipPill)
        // Continue with the switch off goes on, and the step is not marked as put off.
        var progress = OnboardingProgress(step: .computer, route: .new)
        progress.advance()
        #expect(progress.step == .permissions)
        #expect(!progress.deferred.contains(.computer))
    }

    @Test func existingUsersAreNotSentThroughFirstRunAgain() {
        #expect(!OnboardingProgress.shouldPresent(hasConnections: true, raw: ""))
        #expect(OnboardingProgress.shouldPresent(hasConnections: false, raw: ""))
        #expect(!OnboardingProgress.shouldPresent(hasConnections: true, raw: "broken"))
    }

    @Test func savingTheFirstConnectionDoesNotDismissUnfinishedSetup() {
        var progress = OnboardingProgress()
        progress.choose(.existing)
        let connectionID = UUID()
        progress.connected(connectionID)
        let restored = OnboardingProgress.parse(progress.encoded)
        #expect(restored.connectionID == connectionID)
        #expect(restored.step == .model)
        #expect(OnboardingProgress.shouldPresent(hasConnections: true, raw: restored.encoded))
    }

    @Test func phonePairingSkipsMacSetupAndStillRequiresALiveConnectionToFinish() {
        var progress = OnboardingProgress()
        let id = UUID()
        progress.paired(id)
        #expect(progress.connectionID == id)
        #expect(progress.step == .ready)
        #expect(progress.completion == .inProgress)
        progress.finish(connected: false)
        #expect(progress.completion == .inProgress)
        progress.finish(connected: true)
        #expect(progress.completion == .completed)
    }

    @Test func phoneResumesOnlyWelcomePairingOrItsConnectionCheck() {
        var progress = OnboardingProgress()
        progress.resumeOnPhone(hasConnection: false)
        #expect(progress.step == .welcome)
        progress.choose(.new)
        progress.step = .team
        progress.resumeOnPhone(hasConnection: false)
        #expect(progress.step == .home)
        progress.connected(UUID())
        progress.resumeOnPhone(hasConnection: true)
        #expect(progress.step == .ready)
        progress.finish(connected: true)
        let completed = progress
        progress.resumeOnPhone(hasConnection: false)
        #expect(progress == completed)
    }

    @Test func manualSetupIsAnExplicitWayOutWithoutAConnection() {
        var progress = OnboardingProgress()
        progress.skip()
        #expect(progress.completion == .skipped)
        #expect(!OnboardingProgress.shouldPresent(hasConnections: false, raw: progress.encoded))
    }

    @Test func missingConnectionReturnsToConnectionInsteadOfClaimingReady() {
        var progress = OnboardingProgress()
        progress.choose(.new)
        progress.connected(UUID())
        progress.step = .ready
        progress.resume(hasConnection: false)
        #expect(progress.step == .connection)
        #expect(progress.connectionID == nil)
        #expect(progress.route == .new)
    }

    @Test func finishingRequiresARealConnectionButAllowsDeferredExtras() {
        var progress = OnboardingProgress()
        progress.connected(UUID())
        progress.advance(deferStep: true)
        progress.advance(deferStep: true)
        progress.advance(deferStep: true)
        #expect(progress.step == .ready)
        #expect(progress.deferred == [.model, .computer, .permissions])
        progress.finish(connected: false)
        #expect(progress.completion == .inProgress)
        progress.finish(connected: true)
        #expect(progress.completion == .completed)
        #expect(!OnboardingProgress.shouldPresent(hasConnections: true, raw: progress.encoded))
    }

    @Test func connectingExistingDoesNotIncludeNewAssistantPersonalization() {
        var progress = OnboardingProgress()
        progress.choose(.existing)
        #expect(progress.step == .howItWorks)
        progress.advance()
        #expect(progress.step == .connection)
        #expect(!progress.steps.contains(.team))
        progress.choose(.new)
        #expect(progress.step == .howItWorks)
        progress.advance()
        #expect(progress.step == .team)
        #expect(progress.previous == .howItWorks)
    }

    @Test(arguments: [OnboardingProgress.Route.new, .existing, .importCopy])
    func everyRouteExplainsTheSetupBeforeItsFirstAction(_ route: OnboardingProgress.Route) {
        var progress = OnboardingProgress()
        progress.choose(route)
        #expect(progress.step == .howItWorks)
        #expect(progress.previous == .home)
        #expect(progress.connectionID == nil)
        #expect(progress.completion == .inProgress)
        let explanation = progress.steps.firstIndex(of: .howItWorks)!
        #expect(explanation < progress.steps.firstIndex(of: .connection)!)
        progress.advance()
        #expect(progress.step == (route == .new ? .team : .connection))
        #expect(progress.previous == .howItWorks)
        progress.step = progress.previous!
        #expect(progress.step == .howItWorks)
        progress.step = progress.previous!
        #expect(progress.step == .home)
    }

    @Test func explanationResumesWithoutLosingChoicesOrInventingReadiness() {
        var progress = OnboardingProgress()
        progress.choose(.new)
        progress.preferences.assistantName = "Juniper"
        progress.preferences.includeHelpers = true
        var restored = OnboardingProgress.parse(progress.encoded)
        restored.resume(hasConnection: false)
        #expect(restored == progress)
        restored.advance()
        #expect(restored.step == .team)
        #expect(restored.preferences == progress.preferences)
        #expect(restored.connectionID == nil)
        #expect(restored.deferred.isEmpty)
    }

    @Test func olderInProgressAndCompletedSetupsKeepTheirSavedPosition() {
        let old = #"{"step":"connection","route":"new","preferences":{"assistantName":"Juniper","includeHelpers":false},"deferred":[],"completion":"inProgress"}"#
        var restored = OnboardingProgress.parse(old)
        restored.resume(hasConnection: false)
        #expect(restored.step == .connection)
        #expect(restored.preferences.resolvedAssistantName == "Juniper")
        #expect(restored.previous == .team)
        let completed = #"{"step":"ready","route":"existing","preferences":{"assistantName":"Nollie","includeHelpers":false},"deferred":[],"completion":"completed"}"#
        var finished = OnboardingProgress.parse(completed)
        finished.resume(hasConnection: true)
        #expect(finished.step == .ready)
        #expect(finished.completion == .completed)
        #expect(!OnboardingProgress.shouldPresent(hasConnections: true, raw: finished.encoded))
    }

    @Test func namesAndOptionalHelpersResumeWithoutStoringReadiness() {
        var progress = OnboardingProgress()
        progress.choose(.new)
        progress.preferences.assistantName = "  Juniper\n  Lane  "
        progress.preferences.includeHelpers = true
        let restored = OnboardingProgress.parse(progress.encoded)
        #expect(restored.preferences.resolvedAssistantName == "Juniper Lane")
        #expect(restored.preferences.includeHelpers)
        #expect(restored.connectionID == nil)
        #expect(!progress.encoded.contains("token"))
    }

    @Test func emptyNameUsesNollieAndLongNameIsBounded() {
        #expect(OnboardingPreferences(assistantName: " \n ").resolvedAssistantName == "Nollie")
        #expect(OnboardingPreferences(assistantName: String(repeating: "a", count: 80)).resolvedAssistantName.count == 32)
    }

    @Test func selectedModelDoesNotImplyAuthenticatedProvider() {
        let unavailable = ModelOptionsResult(providers: [.init(slug: "example", name: "Example", authenticated: false)], model: "example/model", provider: "example")
        #expect(OnboardingModelStatus.read(unavailable) == .needsSignIn(model: "example/model"))
        let unknown = ModelOptionsResult(providers: [], model: "example/model", provider: "example")
        #expect(OnboardingModelStatus.read(unknown) == .unverified(model: "example/model"))
        #expect(!OnboardingModelStatus.read(unknown).isReady)
    }

    @Test func providerAccountAndModelMustBothBePresent() {
        let provider = ModelProvider(slug: "example", name: "Example", authenticated: true)
        #expect(OnboardingModelStatus.read(ModelOptionsResult(providers: [provider], provider: "example")) == .notConfigured)
        let ready = ModelOptionsResult(providers: [provider], model: "example/model", provider: "example")
        #expect(OnboardingModelStatus.read(ready).isReady)
        let anotherProvider = ModelOptionsResult(providers: [provider], model: "other/model", provider: "other")
        #expect(!OnboardingModelStatus.read(anotherProvider).isReady)
    }

    @Test func unrelatedCurrentProviderCannotVerifyExplicitSelection() {
        let other = ModelProvider(slug: "other", name: "Other", isCurrent: true, authenticated: true)
        let options = ModelOptionsResult(providers: [other], model: "example/model", provider: "example")
        #expect(OnboardingModelStatus.read(options) == .unverified(model: "example/model"))
        let unspecified = ModelOptionsResult(providers: [other], model: "other/model")
        #expect(OnboardingModelStatus.read(unspecified).isReady)
    }


    @Test func modelPreferenceResumesAndOlderChoicesRemainReadable() throws {
        let preferences = OnboardingPreferences(assistantName: "Juniper", modelMode: .both)
        let restored = try JSONDecoder().decode(OnboardingPreferences.self, from: JSONEncoder().encode(preferences))
        #expect(restored.modelMode == .both)
        let older = Data(#"{"assistantName":"Juniper","includeHelpers":true}"#.utf8)
        let migrated = try JSONDecoder().decode(OnboardingPreferences.self, from: older)
        #expect(migrated.assistantName == "Juniper")
        #expect(migrated.includeHelpers)
        #expect(migrated.modelMode == .local)
    }

    @Test func importCopyRemainsDistinctFromConnectingAndPreservesPersonalization() {
        var progress = OnboardingProgress()
        progress.preferences.assistantName = "Juniper"
        progress.choose(.importCopy)
        #expect(progress.step == .howItWorks)
        progress.advance()
        #expect(progress.step == .connection)
        #expect(!progress.steps.contains(.team))
        let restored = OnboardingProgress.parse(progress.encoded)
        #expect(restored.route == .importCopy)
        #expect(restored.preferences.assistantName == "Juniper")
        #expect(restored.connectionID == nil)
        progress.choose(.existing)
        #expect(progress.route == .existing)
        #expect(progress.connectionID == nil)
    }

    @Test func progressTrailStopsAtTheFirstUnverifiedStep() {
        #expect(SetupTrailProgress.completedPrefix([]) == 0)
        #expect(SetupTrailProgress.completedPrefix([.ready, .needed, .ready]) == 1)
        #expect(SetupTrailProgress.completedPrefix([.notChecked, .ready]) == 0)
        #expect(SetupTrailProgress.completedPrefix([.ready, .ready, .working]) == 2)
    }

    @Test func setupCelebratesVerifiedCompletionOnlyOnceAfterWork() {
        #expect(!SetupTrailProgress.shouldCelebrate(wasReady: false, isReady: false, observedWork: true))
        #expect(!SetupTrailProgress.shouldCelebrate(wasReady: false, isReady: true, observedWork: false))
        #expect(SetupTrailProgress.shouldCelebrate(wasReady: false, isReady: true, observedWork: true))
        #expect(!SetupTrailProgress.shouldCelebrate(wasReady: true, isReady: true, observedWork: true))
    }


    @Test func aMacUnder16GBStartsOnAPlanUntilThePersonChooses() throws {
        let gib: UInt64 = 1 << 30
        var small = OnboardingPreferences()
        let changed = small.suggestModelMode(memoryBytes: 8 * gib)
        #expect(changed)
        #expect(small.modelMode == .cloud)
        let again = small.suggestModelMode(memoryBytes: 8 * gib)
        #expect(!again, "suggesting twice changes nothing")

        var roomy = OnboardingPreferences()
        let roomyChanged = roomy.suggestModelMode(memoryBytes: 16 * gib)
        #expect(!roomyChanged)
        #expect(roomy.modelMode == .local)

        // Memory unknown: nothing is assumed.
        var unknown = OnboardingPreferences()
        let unknownChanged = unknown.suggestModelMode(memoryBytes: nil)
        #expect(!unknownChanged)
        #expect(unknown.modelMode == .local)

        // Chosen on the model step or in Settings: setup leaves it, on any Mac.
        var chosen = OnboardingPreferences(modelMode: .local, modelModeChosen: true)
        let chosenChanged = chosen.suggestModelMode(memoryBytes: 8 * gib)
        #expect(!chosenChanged)
        #expect(chosen.modelMode == .local)

        // The choice survives a relaunch; setup progress saved before this reads as not chosen.
        let restored = try JSONDecoder().decode(OnboardingPreferences.self, from: JSONEncoder().encode(chosen))
        #expect(restored.modelModeChosen)
        let older = Data(#"{"assistantName":"Juniper","modelMode":"local"}"#.utf8)
        #expect(try JSONDecoder().decode(OnboardingPreferences.self, from: older).modelModeChosen == false)
    }

    @Test func setupReopenedWithoutAPathTakesTheOneItsConnectionBelongsTo() {
        // Settings' Review setup on a Mac whose saved progress was empty: Back reached the connection step
        // with no path, showing Start new's card under another heading, and Connect did nothing.
        var managed = OnboardingProgress(step: .model)
        managed.settleRoute(managed: true)
        #expect(managed.route == .new)
        #expect(managed.previous == .connection)
        var other = OnboardingProgress(step: .model)
        other.settleRoute(managed: false)
        #expect(other.route == .existing)
        // A path already chosen stays, and before the choice there is nothing to settle.
        var chosen = OnboardingProgress(step: .connection, route: .importCopy)
        chosen.settleRoute(managed: true)
        #expect(chosen.route == .importCopy)
        var home = OnboardingProgress(step: .home)
        home.settleRoute(managed: true)
        #expect(home.route == nil)
    }

    @Test func settingUpAgainGoesToStartNewsSetupStepAndKeepsTheName() {
        var progress = OnboardingProgress(step: .ready, route: .existing,
                                          preferences: OnboardingPreferences(assistantName: "Juniper"),
                                          connectionID: UUID(), deferred: [.model], completion: .completed)
        progress.setUpAgain()
        #expect(progress.route == .new && progress.step == .connection)
        #expect(progress.connectionID == nil && progress.deferred.isEmpty)
        #expect(progress.completion == .inProgress)
        #expect(progress.preferences.assistantName == "Juniper")
        let raw = OnboardingProgress.settingUpAgain("")
        #expect(OnboardingProgress.parse(raw).step == .connection)
        #expect(OnboardingProgress.shouldPresent(hasConnections: true, raw: raw))
    }
}
