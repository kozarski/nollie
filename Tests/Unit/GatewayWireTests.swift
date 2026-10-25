import Foundation
import Testing
@testable import NollieCore

/// One generated wire type with a sample that sets every field and one that sets only required fields.
/// The list itself is generated (`Generated/GatewayWireSamples.swift`).
struct GatewayWireSample: Sendable {
    let name: String
    let type: any GatewayWireValue.Type
    let full: String
    let minimal: String
}

/// A call made while recording `Fixtures/GatewayRecordedFrames.swift`.
struct GatewayRecordedCall: Sendable {
    let id: Int
    let method: String
    let params: String
}

/// Reads `text` as `type`, writes it back, and returns both as plain JSON plus whether a second read matched.
private func roundTrip<Value: GatewayWireValue>(_ type: Value.Type, _ text: String) throws -> (GatewayJSON, GatewayJSON, Bool) {
    let value = try JSONDecoder().decode(Value.self, from: Data(text.utf8))
    let written = try JSONEncoder().encode(value)
    let again = try JSONDecoder().decode(Value.self, from: written)
    return (try GatewayJSON.parse(Data(text.utf8)), try GatewayJSON.parse(written), again == value)
}

/// The same JSON with null object fields left out: an optional field reads null and absent alike and writes
/// neither, so the two spellings mean the same thing.
private func withoutNullFields(_ json: GatewayJSON) -> GatewayJSON {
    switch json {
    case .object(let fields): .object(fields.filter { !$0.value.isNull }.mapValues(withoutNullFields))
    case .array(let items): .array(items.map(withoutNullFields))
    default: json
    }
}

private func decodes<Value: GatewayWireValue>(_ type: Value.Type, _ json: GatewayJSON) throws -> Value {
    try json.decode(Value.self)
}

@Suite struct GatewayWireTests {
    @Test func everyGeneratedTypeReadsAndWritesItsSamples() throws {
        #expect(gatewayWireSamples.count > 700)
        #expect(Set(gatewayWireSamples.map(\.name)).count == gatewayWireSamples.count)
        for sample in gatewayWireSamples {
            for text in [sample.full, sample.minimal] {
                do {
                    let (original, written, stable) = try roundTrip(sample.type, text)
                    #expect(withoutNullFields(original) == written, "\(sample.name) changed on the way through: \(text)")
                    #expect(stable, "\(sample.name) read back differently")
                } catch {
                    Issue.record("\(sample.name) failed to read \(text): \(error)")
                }
            }
        }
    }

    @Test func descriptorsCoverTheWholeContract() {
        #expect(GatewayWire.Calls.all.count == 257)
        #expect(Set(GatewayWire.Calls.all) == Set(GatewayWire.Calls.resultTypes.keys))
        #expect(GatewayWire.Questions.all.count == 16)
        #expect(Set(GatewayWire.Questions.all) == Set(GatewayWire.Questions.paramTypes.keys))
        #expect(GatewayWire.Events.all.count == 77)
        #expect(Set(GatewayWire.Events.all) == Set(GatewayWire.Events.payloadTypes.keys))
        #expect(GatewayWire.Calls.sessionEventsSince.name == "session.events.since")
        #expect(GatewayWire.Calls.ping.name == "ping")
        #expect(GatewayWire.Questions.approval.name == "approval")
        #expect(GatewayWire.Events.gatewayReady.name == "gateway.ready")
    }

    @Test func everyRecordedAnswerReadsAsItsMethodsResult() throws {
        let methods = Dictionary(uniqueKeysWithValues: gatewayRecordedCalls.map { ($0.id, $0.method) })
        var answers = 0, refusals = 0
        for text in gatewayRecordedFrames {
            let frame = try GatewayJSON.parse(Data(text.utf8))
            guard let id = frame["id"]?.intValue, let method = methods[id] else { continue }
            if let result = frame["result"] {
                let type = try #require(GatewayWire.Calls.resultTypes[method], "no result type for \(method)")
                do { _ = try decodes(type, result) } catch { Issue.record("\(method) answer did not read: \(error)") }
                answers += 1
            } else {
                #expect(frame["error"]?["code"]?.intValue != nil, "\(method) answer has neither result nor error")
                refusals += 1
            }
        }
        #expect(answers >= 15)
        #expect(refusals >= 3)
    }

    @Test func everyRecordedEventReadsAsItsPayload() throws {
        var events: [GatewayJSON] = []
        for text in gatewayRecordedFrames {
            let frame = try GatewayJSON.parse(Data(text.utf8))
            if frame["method"]?.stringValue == "event", let params = frame["params"] { events.append(params) }
            // Replayed events come back inside session.events.since answers, in the same shape.
            events += frame["result"]?["events"]?.arrayValue ?? []
        }
        #expect(events.count >= 10)
        for event in events {
            let name = try #require(event["type"]?.stringValue)
            let type = try #require(GatewayWire.Events.payloadTypes[name], "no payload type for \(name)")
            do { _ = try decodes(type, event["payload"] ?? [:]) } catch { Issue.record("\(name) payload did not read: \(error)") }
        }
    }

    @Test func gatewayReadyCarriesTheReplayEpoch() throws {
        let frame = try GatewayJSON.parse(Data(try #require(gatewayRecordedFrames.first).utf8))
        let ready = try decodes(GatewayWire.GatewayReadyPayload.self, try #require(frame["params"]?["payload"]))
        #expect(!ready.replayEpoch.isEmpty)
        #expect(ready.changeEvents)
    }

    @Test func enumsStayOpenToNewValues() throws {
        let known = try JSONDecoder().decode(GatewayWire.ApprovalChoice.self, from: Data(#""once""#.utf8))
        #expect(known == .once && known.isKnown)
        let newer = try JSONDecoder().decode(GatewayWire.ApprovalChoice.self, from: Data(#""next-year""#.utf8))
        #expect(newer.rawValue == "next-year" && !newer.isKnown)
        #expect(String(decoding: try JSONEncoder().encode(newer), as: UTF8.self) == #""next-year""#)
    }

    @Test func unionsKeepKindsTheyDoNotKnow() throws {
        let text = #"{"type": "robot", "serial": 9}"#
        let owner = try JSONDecoder().decode(GatewayWire.Owner.self, from: Data(text.utf8))
        guard case .unknown(let raw) = owner else { Issue.record("read as a known kind: \(owner)"); return }
        #expect(raw["serial"] == 9)
        #expect(try GatewayJSON(encoding: owner) == GatewayJSON.parse(Data(text.utf8)))
        let session = try JSONDecoder().decode(GatewayWire.Owner.self, from: Data(#"{"type": "session", "session_id": "a1"}"#.utf8))
        guard case .session(let known) = session else { Issue.record("not a session owner: \(session)"); return }
        #expect(known.sessionId == "a1")
    }

    @Test func paramsLeaveOutWhatIsNotSet() throws {
        let params = GatewayWire.SessionEventsSinceParams(sessionId: "s1", lastSeen: 4)
        #expect(try GatewayJSON(encoding: params) == ["session_id": "s1", "last_seen": 4])
        #expect(try GatewayJSON(encoding: GatewayWire.PingParams()) == [:])
    }

    @Test func plainJSONKeepsItsKinds() throws {
        let json = try GatewayJSON.parse(Data(#"{"a": true, "b": 1, "c": 1.5, "d": null, "e": ["x"], "f": {}}"#.utf8))
        #expect(json["a"] == .bool(true))
        #expect(json["b"] == .integer(1))
        #expect(json["c"] == .number(1.5))
        #expect(json["d"]?.isNull == true)
        #expect(json["e"]?[0]?.stringValue == "x")
        #expect(json["f"]?.objectValue?.isEmpty == true)
        #expect(json["missing"] == nil)
        #expect(String(decoding: try json.encoded(), as: UTF8.self) == #"{"a":true,"b":1,"c":1.5,"d":null,"e":["x"],"f":{}}"#)
    }
}
