import Foundation
import Testing
@testable import Nollie

@MainActor
struct NewBotCreationTests {
    @Test func freshBotNeedsAnExplicitModelBeforeAnyRequest() async {
        let fixture = NewBotCreationFixture()
        var draft = fixture.draft
        draft.provider = nil; draft.model = nil
        #expect(await fixture.submit(draft) == false)
        #expect(fixture.created.isEmpty)
        #expect(fixture.state.request == nil)
    }

    @Test func createIncludesTheChosenRouteAndDescriptionAndReadsItBack() async throws {
        let fixture = NewBotCreationFixture()
        #expect(await fixture.submit() == true)
        #expect(fixture.created == [fixture.draft])
        #expect(fixture.writes.isEmpty)
        #expect(fixture.reads == ["research"])
        #expect(fixture.state.phase == .verified)
        let encoder = JSONEncoder(); encoder.keyEncodingStrategy = .convertToSnakeCase
        let body = try #require(JSONSerialization.jsonObject(with: encoder.encode(fixture.draft)) as? [String: String])
        #expect(body["model"] == "local-model")
        #expect(body["provider"] == "ollama")
        #expect(body["description"] == "Find useful sources")
    }

    @Test func partialCreateRetainsIdentityAndRetryOnlyRepairsThatProfile() async {
        let fixture = NewBotCreationFixture(); fixture.modelSet = false
        #expect(await fixture.submit() == false)
        #expect(fixture.state.phase == .created)
        #expect(fixture.state.request?.name == "research")
        var renamed = fixture.draft; renamed.name = "different"
        #expect(await fixture.submit(renamed) == true)
        #expect(fixture.created.count == 1)
        #expect(fixture.writes.map(\.0) == ["research"])
        #expect(fixture.reads == ["research"])
    }

    @Test func lostCreationResponseNeverRepeatsOrRepairsAnUnconfirmedProfile() async {
        let fixture = NewBotCreationFixture(); fixture.loseResponse = true
        #expect(await fixture.submit() == false)
        #expect(await fixture.submit() == false)
        #expect(fixture.created.count == 1)
        #expect(fixture.writes.isEmpty)
        #expect(fixture.reads == ["research"])
        #expect(fixture.state.phase == .unconfirmed)
    }

    @Test func successfulPostDoesNotHideWrongOrMissingSavedModel() async {
        for actual in [NewBotCreation.Selection(provider: "anthropic", model: "cloud-model"), .init(provider: "", model: "")] {
            let fixture = NewBotCreationFixture(); fixture.actual = actual
            #expect(await fixture.submit() == false)
            #expect(fixture.state.phase == .created)
            #expect(fixture.state.issue != nil)
        }
    }

    @Test func explicitCloneKeepsItsOwnInheritedRoute() async throws {
        let fixture = NewBotCreationFixture()
        var draft = fixture.draft
        draft.cloneFrom = "chosen-template"; draft.provider = nil; draft.model = nil
        fixture.actual = .init(provider: "anthropic", model: "chosen-cloud-model")
        fixture.modelSet = false
        #expect(await fixture.submit(draft) == true)
        #expect(fixture.created.first?.cloneFrom == "chosen-template")
        #expect(fixture.writes.isEmpty)
    }

    @Test func scopeChangeDuringCreateRetainsReceiptWithoutFurtherRequests() async {
        let fixture = NewBotCreationFixture(); fixture.changeScopeOnCreate = true
        #expect(await fixture.submit() == false)
        #expect(fixture.state.phase == .created)
        #expect(fixture.reads.isEmpty)
        #expect(fixture.writes.isEmpty)
        #expect(await fixture.submit() == false)
        #expect(fixture.created.count == 1)
    }

    @Test func aDifferentAcknowledgedNameNeverAuthorizesRepair() async {
        let fixture = NewBotCreationFixture(); fixture.responseName = "another-bot"
        #expect(await fixture.submit() == false)
        #expect(await fixture.submit() == false)
        #expect(fixture.state.phase == .unconfirmed)
        #expect(fixture.writes.isEmpty)
        #expect(fixture.created.count == 1)
    }
}

@MainActor
private final class NewBotCreationFixture {
    let state = NewBotCreation()
    let draft = NewBotCreation.Request(name: "research", description: "Find useful sources", cloneFrom: nil, provider: "ollama", model: "local-model")
    var actual = NewBotCreation.Selection(provider: "ollama", model: "local-model")
    var modelSet = true
    var loseResponse = false
    var changeScopeOnCreate = false
    var isCurrent = true
    var responseName: String?
    var created: [NewBotCreation.Request] = []
    var writes: [(String, NewBotCreation.Selection)] = []
    var reads: [String] = []

    func submit(_ request: NewBotCreation.Request? = nil) async -> Bool {
        await state.submit(request ?? draft, allowed: { self.isCurrent }, create: { value in
            self.created.append(value)
            if self.loseResponse { throw URLError(.networkConnectionLost) }
            if self.changeScopeOnCreate { self.isCurrent = false }
            return .init(ok: true, name: self.responseName ?? value.name, modelSet: self.modelSet)
        }, setModel: { name, selection in
            self.writes.append((name, selection))
        }, readModel: { name in
            self.reads.append(name)
            return self.actual
        })
    }
}
