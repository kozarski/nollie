import Foundation
import Synchronization
import Testing
@testable import Nollie
@testable import NollieCore

@MainActor
@Suite(.serialized, .timeLimit(.minutes(1))) struct AskFirstSettingsTests {
    private func setup(isPrivate: @escaping (String) -> Bool = { _ in false }) throws -> (AskFirstModel, GatewayRuntime) {
        let gateway = try GatewayURL.normalize("https://ask-first.invalid/hermes")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AskFirstSettingsStub.self]
        let api = HermesAPI(gateway: gateway, signer: .init(authMode: .sessionToken, sessionToken: "ask-first-fixture"),
                            urlSession: URLSession(configuration: configuration))
        let runtime = GatewayRuntime(connection: .init(name: "Fixture", gateway: gateway, authMode: .sessionToken),
                                     store: ConnectionStore())
        return (AskFirstModel(api: api, isPrivate: isPrivate), runtime)
    }

    @Test func readsTheChosenBotAndKeepsOffVisible() async throws {
        let (model, runtime) = try setup()
        AskFirstSettingsStub.handler = { request in
            #expect(request.httpMethod == "GET")
            #expect(request.url?.path == "/hermes/api/plugins/nollie-computer/ask-first")
            #expect(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems
                    == [URLQueryItem(name: "profile", value: "work")])
            #expect(request.value(forHTTPHeaderField: "X-Hermes-Session-Token") == "ask-first-fixture")
            return (200, Data(#"{"profile":"work","enabled":false}"#.utf8))
        }
        defer { AskFirstSettingsStub.reset() }
        #expect(model.enabled == nil)
        await model.load(bot: "work", runtime: runtime)
        #expect(model.enabled == false)
        #expect(model.matches(bot: "work", runtime: runtime))
        #expect(!model.busy && model.error == nil)
    }

    @Test func turningOffWaitsForOneConfirmationAndCancelDoesNothing() async throws {
        let (model, runtime) = try setup()
        let writes = Mutex(0)
        AskFirstSettingsStub.handler = { request in
            if request.httpMethod == "PUT" {
                writes.withLock { $0 += 1 }
                #expect((try? JSONDecoder().decode(JSONValue.self, from: AskFirstSettingsStub.body(request))) == ["enabled": false])
                return (200, Data(#"{"profile":"work","enabled":false}"#.utf8))
            }
            return (200, Data(#"{"profile":"work","enabled":true}"#.utf8))
        }
        defer { AskFirstSettingsStub.reset() }
        await model.load(bot: "work", runtime: runtime)
        await model.requestChange(false, bot: "work", runtime: runtime)
        #expect(model.needsTurnOffConfirmation && model.enabled == true)
        #expect(writes.withLock { $0 } == 0)
        model.cancelTurnOff()
        await model.confirmTurnOff(bot: "work", runtime: runtime)?.value
        #expect(writes.withLock { $0 } == 0 && model.enabled == true)
        await model.requestChange(false, bot: "work", runtime: runtime)
        let saving = model.confirmTurnOff(bot: "work", runtime: runtime)
        model.cancelTurnOff()
        await saving?.value
        await model.confirmTurnOff(bot: "work", runtime: runtime)?.value
        #expect(writes.withLock { $0 } == 1)
        #expect(model.enabled == false && !model.needsTurnOffConfirmation)
    }

    @Test func turningOnNeedsNoConfirmation() async throws {
        let (model, runtime) = try setup()
        let writes = Mutex(0)
        AskFirstSettingsStub.handler = { request in
            if request.httpMethod == "PUT" {
                writes.withLock { $0 += 1 }
                #expect((try? JSONDecoder().decode(JSONValue.self, from: AskFirstSettingsStub.body(request))) == ["enabled": true])
                return (200, Data(#"{"profile":"work","enabled":true}"#.utf8))
            }
            return (200, Data(#"{"profile":"work","enabled":false}"#.utf8))
        }
        defer { AskFirstSettingsStub.reset() }
        await model.load(bot: "work", runtime: runtime)
        await model.requestChange(true, bot: "work", runtime: runtime)
        await model.requestChange(true, bot: "work", runtime: runtime)
        #expect(model.enabled == true && !model.needsTurnOffConfirmation)
        #expect(writes.withLock { $0 } == 1)
    }

    @Test func aLostWriteAnswerIsUnknownAndNeverRetried() async throws {
        let (model, runtime) = try setup()
        let writes = Mutex(0)
        AskFirstSettingsStub.handler = { request in
            if request.httpMethod == "PUT" {
                writes.withLock { $0 += 1 }
                throw URLError(.networkConnectionLost)
            }
            return (200, Data(#"{"profile":"work","enabled":true}"#.utf8))
        }
        defer { AskFirstSettingsStub.reset() }
        await model.load(bot: "work", runtime: runtime)
        await model.requestChange(false, bot: "work", runtime: runtime)
        await model.confirmTurnOff(bot: "work", runtime: runtime)?.value
        #expect(model.enabled == nil && model.error != nil && !model.busy)
        await model.requestChange(false, bot: "work", runtime: runtime)
        await model.confirmTurnOff(bot: "work", runtime: runtime)?.value
        #expect(writes.withLock { $0 } == 1)
        AskFirstSettingsStub.handler = { _ in (200, Data(#"{"profile":"work","enabled":false}"#.utf8)) }
        await model.load(bot: "work", runtime: runtime)
        #expect(model.enabled == false && model.error == nil)
    }

    @Test func privateBotsAreNeverRequestedAndClearThePreviousBot() async throws {
        let (model, runtime) = try setup(isPrivate: { $0 == "quiet" })
        let requests = Mutex(0)
        AskFirstSettingsStub.handler = { _ in
            requests.withLock { $0 += 1 }
            return (200, Data(#"{"profile":"work","enabled":true}"#.utf8))
        }
        defer { AskFirstSettingsStub.reset() }
        await model.load(bot: "work", runtime: runtime)
        await model.requestChange(false, bot: "work", runtime: runtime)
        await model.load(bot: "quiet", runtime: runtime)
        await model.requestChange(true, bot: "quiet", runtime: runtime)
        await model.confirmTurnOff(bot: "quiet", runtime: runtime)?.value
        #expect(requests.withLock { $0 } == 1)
        #expect(model.enabled == nil && !model.needsTurnOffConfirmation)
        #expect(!model.matches(bot: "quiet", runtime: runtime))
    }

    @Test func aLocalCrewBotStillHasAnAskFirstSwitch() async throws {
        let (model, runtime) = try setup()
        runtime.profiles = [ProfileInfo(name: "work", provider: "ollama")]
        let requests = Mutex(0)
        AskFirstSettingsStub.handler = { _ in
            requests.withLock { $0 += 1 }
            return (200, Data(#"{"profile":"work","enabled":true}"#.utf8))
        }
        defer { AskFirstSettingsStub.reset() }
        await model.load(bot: "work", runtime: runtime)
        #expect(requests.withLock { $0 } == 1)
        #expect(model.enabled == true && model.matches(bot: "work", runtime: runtime))
    }

    @Test(arguments: ["private", "moss", "private-notes", "moss_notes", "quiet", "quiet-notes", "quiet_notes"])
    func privateNamesAndTheirAliasesAreNeverRequested(_ bot: String) async throws {
        let (model, runtime) = try setup(isPrivate: { $0 == "quiet" })
        let requests = Mutex(0)
        AskFirstSettingsStub.handler = { _ in
            requests.withLock { $0 += 1 }
            return (500, Data())
        }
        defer { AskFirstSettingsStub.reset() }
        await model.load(bot: bot, runtime: runtime)
        await model.requestChange(true, bot: bot, runtime: runtime)
        await model.confirmTurnOff(bot: bot, runtime: runtime)?.value
        #expect(requests.withLock { $0 } == 0)
        #expect(model.enabled == nil && !model.matches(bot: bot, runtime: runtime))
    }

    @Test(arguments: [#"{"profile":"other","enabled":true}"#, #"{"profile":"work"}"#, "{}"])
    func unreadableRepliesNeverBecomeAnOffSwitch(_ body: String) async throws {
        let (model, runtime) = try setup()
        AskFirstSettingsStub.handler = { _ in (200, Data(body.utf8)) }
        defer { AskFirstSettingsStub.reset() }
        await model.load(bot: "work", runtime: runtime)
        #expect(model.enabled == nil && model.error != nil)
    }

    @Test func aConfirmationCannotMoveToAnotherGateway() async throws {
        let (model, runtime) = try setup()
        let (_, otherRuntime) = try setup()
        let requests = Mutex(0)
        AskFirstSettingsStub.handler = { _ in
            requests.withLock { $0 += 1 }
            return (200, Data(#"{"profile":"work","enabled":true}"#.utf8))
        }
        defer { AskFirstSettingsStub.reset() }
        await model.load(bot: "work", runtime: runtime)
        await model.requestChange(false, bot: "work", runtime: runtime)
        #expect(!model.matches(bot: "work", runtime: otherRuntime))
        await model.confirmTurnOff(bot: "work", runtime: otherRuntime)?.value
        #expect(requests.withLock { $0 } == 1)
        #expect(!model.needsTurnOffConfirmation)
    }

    @Test func anOldReadCannotOverwriteTheNewBot() async throws {
        let (model, runtime) = try setup()
        let gate = AskFirstSettingsGate()
        AskFirstSettingsStub.handler = { request in
            if request.url?.query == "profile=work" {
                await gate.hold()
                return (200, Data(#"{"profile":"work","enabled":true}"#.utf8))
            }
            return (200, Data(#"{"profile":"home","enabled":false}"#.utf8))
        }
        defer { AskFirstSettingsStub.reset() }
        let oldRead = Task { await model.load(bot: "work", runtime: runtime) }
        await gate.waitUntilHeld()
        await model.load(bot: "home", runtime: runtime)
        await gate.release()
        await oldRead.value
        #expect(model.enabled == false && model.matches(bot: "home", runtime: runtime))
        #expect(!model.busy && model.error == nil)
    }

    @Test func anOldWriteCannotOverwriteTheNewBot() async throws {
        let (model, runtime) = try setup()
        let gate = AskFirstSettingsGate()
        AskFirstSettingsStub.handler = { request in
            if request.httpMethod == "PUT" {
                await gate.hold()
                return (200, Data(#"{"profile":"work","enabled":true}"#.utf8))
            }
            let bot = request.url?.query == "profile=work" ? "work" : "home"
            return (200, Data("{\"profile\":\"\(bot)\",\"enabled\":false}".utf8))
        }
        defer { AskFirstSettingsStub.reset() }
        await model.load(bot: "work", runtime: runtime)
        let oldWrite = Task { await model.requestChange(true, bot: "work", runtime: runtime) }
        await gate.waitUntilHeld()
        await model.load(bot: "home", runtime: runtime)
        await gate.release()
        await oldWrite.value
        #expect(model.enabled == false && model.matches(bot: "home", runtime: runtime))
        #expect(!model.busy && model.error == nil)
    }
}

private actor AskFirstSettingsGate {
    private var held: CheckedContinuation<Void, Never>?
    private var waiting: CheckedContinuation<Void, Never>?

    func hold() async {
        await withCheckedContinuation { continuation in
            held = continuation
            waiting?.resume()
            waiting = nil
        }
    }

    func waitUntilHeld() async {
        if held != nil { return }
        await withCheckedContinuation { waiting = $0 }
    }

    func release() { held?.resume(); held = nil }
}

private final class AskFirstSettingsStub: URLProtocol, @unchecked Sendable {
    typealias Handler = @Sendable (URLRequest) async throws -> (Int, Data)
    private static let storage = Mutex<Handler?>(nil)
    static var handler: Handler? {
        get { storage.withLock { $0 } }
        set { storage.withLock { $0 = newValue } }
    }
    private var work: Task<Void, Never>?

    static func reset() { handler = nil }
    private static let takesEveryRequest = true
    override class func canInit(with request: URLRequest) -> Bool { takesEveryRequest }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler else { return }
        work = Task {
            do {
                let (status, data) = try await handler(request)
                guard !Task.isCancelled else { return }
                let jsonHeaders = ["Content-Type": "application/json"]
                let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: jsonHeaders)!
                guard let client else { return }
                client.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client.urlProtocol(self, didLoad: data)
                client.urlProtocolDidFinishLoading(self)
            } catch { client?.urlProtocol(self, didFailWithError: error) }
        }
    }

    override func stopLoading() { work?.cancel() }

    static func body(_ request: URLRequest) -> Data {
        if let data = request.httpBody { return data }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open(); defer { stream.close() }
        var data = Data(), buffer = [UInt8](repeating: 0, count: 1024)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            data.append(buffer, count: count)
        }
        return data
    }
}
