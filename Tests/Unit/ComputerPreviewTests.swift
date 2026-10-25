import Foundation
import CoreGraphics
import ImageIO
import Testing
@testable import Nollie
import NollieCore

@MainActor
@Suite(.serialized) struct ComputerPreviewTests {
    private let now = Date(timeIntervalSince1970: 10_000)

    private func frame(state: String = "live", at: Double? = 10_000, image: String? = nil) -> ComputerPreviewFrame {
        ComputerPreviewFrame(state: state, computerName: "Work computer", kind: "space", imageDataUrl: image, capturedAt: at)
    }

    @Test func liveMeansARecentFrameWithBoundedClockSkew() {
        #expect(frame(at: 9_990.1).isFresh(at: now))
        #expect(frame(at: 10_005).isFresh(at: now))
        let timestamps: [Double?] = [nil, 9_990, 9_000, 10_005.1, .infinity, .nan]
        for timestamp in timestamps {
            #expect(!frame(at: timestamp).isFresh(at: now))
        }
        #expect(!frame(state: "idle").isFresh(at: now))
        #expect(!frame(state: "unavailable").isFresh(at: now))
    }

    @Test func payloadDecodesTheBridgeContract() throws {
        let data = Data(#"{"state":"live","computer_name":"Work computer","kind":"space","image_data_url":"data:image/png;base64,AQID","captured_at":10000}"#.utf8)
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let decoded = try decoder.decode(ComputerPreviewFrame.self, from: data)
        #expect(decoded.computerName == "Work computer")
        #expect(decoded.kind == "space")
        #expect(decoded.imageData == Data([1, 2, 3]))
        #expect(decoded.isFresh(at: now))
    }

    @Test func onlyBoundedEmbeddedPngOrJpegDataIsAccepted() {
        #expect(frame(image: "data:image/png;base64,AQID").imageData == Data([1, 2, 3]))
        #expect(frame(image: "data:image/jpeg;base64,AQID").imageData == Data([1, 2, 3]))
        for value in ["https://example.invalid/screen.png", "file:///tmp/screen.png",
                      "data:image/svg+xml;base64,AQID", "data:text/html;base64,AQID",
                      "data:image/png;base64,%%%", "data:image/png;base64"] {
            #expect(frame(image: value).imageData == nil)
        }
        #expect(frame(image: "data:image/png;base64," + String(repeating: "A", count: 12_000_000)).imageData == nil)
    }

    private func chat(_ profile: String = "work", id: String = "preview-session") throws -> ChatSession {
        let connection = GatewayConnection(name: "unit", gateway: try GatewayURL.normalize("https://preview.invalid/hermes"), authMode: .sessionToken)
        let runtime = GatewayRuntime(connection: connection, store: ConnectionStore())
        return ChatSession(runtime: runtime, storedID: id, title: nil, profile: profile)
    }

    private func api() throws -> HermesAPI {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ComputerPreviewStub.self]
        return HermesAPI(gateway: try GatewayURL.normalize("https://preview.invalid/hermes"),
                         signer: RequestSigner(authMode: .sessionToken, sessionToken: "preview-test-token"),
                         urlSession: URLSession(configuration: configuration))
    }

    private func imageURL() throws -> String {
        let context = try #require(CGContext(data: nil, width: 2, height: 2, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
        let image = try #require(context.makeImage())
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data as CFMutableData, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        return "data:image/png;base64," + (data as Data).base64EncodedString()
    }

    private func response(image: String?, state: String = "live", capturedAt: Double = Date().timeIntervalSince1970) throws -> Data {
        var object: [String: Any] = ["state": state, "computer_name": "Work computer", "kind": "space", "captured_at": capturedAt]
        if let image { object["image_data_url"] = image }
        return try JSONSerialization.data(withJSONObject: object)
    }

    @Test func modelFetchesAnAuthenticatedProfileAndSessionScopedFrame() async throws {
        let body = try response(image: imageURL())
        ComputerPreviewStub.handler = { request in
            #expect(request.httpMethod == "GET")
            #expect(request.url?.path == "/hermes/api/plugins/nollie-computer/preview")
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
            #expect(query.contains(URLQueryItem(name: "profile", value: "work")))
            #expect(query.contains(URLQueryItem(name: "session_id", value: "preview-session")))
            #expect(request.value(forHTTPHeaderField: "X-Hermes-Session-Token") == "preview-test-token")
            return (200, body)
        }
        defer { ComputerPreviewStub.reset() }
        let model = ComputerPreviewModel(api: try api())
        await model.refresh(try chat())
        #expect(model.image?.width == 2)
        #expect(model.computerName == "Work computer")
        #expect(model.isLive(at: Date()))
        #expect(!model.loading)
    }

    @Test func invalidAndStaleFramesNeverKeepTheLiveBadge() async throws {
        let currentChat = try chat()
        let model = ComputerPreviewModel(api: try api())
        let valid = try response(image: imageURL())
        ComputerPreviewStub.handler = { _ in (200, valid) }
        defer { ComputerPreviewStub.reset() }
        await model.refresh(currentChat)
        #expect(model.isLive(at: Date()))

        let malformed = try response(image: "data:image/png;base64,AQID")
        ComputerPreviewStub.handler = { _ in (200, malformed) }
        await model.refresh(currentChat)
        #expect(model.image != nil, "The last usable frame remains visible")
        #expect(model.interrupted)
        #expect(!model.isLive(at: Date()))

        let stale = try response(image: imageURL(), capturedAt: Date().timeIntervalSince1970 - 30)
        ComputerPreviewStub.handler = { _ in (200, stale) }
        await model.refresh(currentChat)
        #expect(!model.interrupted)
        #expect(!model.isLive(at: Date()))
    }

    @Test func anotherSessionCannotInheritThePreviousComputerImage() async throws {
        let model = ComputerPreviewModel(api: try api())
        let live = try response(image: imageURL())
        ComputerPreviewStub.handler = { _ in (200, live) }
        defer { ComputerPreviewStub.reset() }
        await model.refresh(try chat())
        #expect(model.image != nil)

        let unavailable = try response(image: nil, state: "unavailable")
        ComputerPreviewStub.handler = { _ in (200, unavailable) }
        await model.refresh(try chat("home", id: "another-session"))
        #expect(model.image == nil)
        #expect(model.computerName == "Work computer")
        #expect(model.unavailable)
        #expect(!model.isLive(at: Date()))
    }

    @Test func gatewayFailureKeepsOnlyTheLastScreen() async throws {
        let currentChat = try chat()
        let model = ComputerPreviewModel(api: try api())
        let live = try response(image: imageURL())
        ComputerPreviewStub.handler = { _ in (200, live) }
        defer { ComputerPreviewStub.reset() }
        await model.refresh(currentChat)
        ComputerPreviewStub.handler = { _ in (503, Data(#"{"detail":"Preview unavailable"}"#.utf8)) }
        await model.refresh(currentChat)
        #expect(model.image != nil)
        #expect(model.interrupted)
        #expect(!model.isLive(at: Date()))
    }

    @Test func switchingToMacNeverKeepsTheVirtualComputerScreen() async throws {
        let currentChat = try chat()
        let model = ComputerPreviewModel(api: try api())
        let live = try response(image: imageURL())
        ComputerPreviewStub.handler = { _ in (200, live) }
        defer { ComputerPreviewStub.reset() }
        await model.refresh(currentChat)
        #expect(model.image != nil)

        ComputerPreviewStub.handler = { _ in
            (200, Data(#"{"state":"unavailable","computer_name":"This Mac","kind":"mac"}"#.utf8))
        }
        await model.refresh(currentChat)
        #expect(model.image == nil)
        #expect(model.computerName == "This Mac")
        #expect(model.kind == "mac")
        #expect(!model.isLive(at: Date()))
    }

    /// While Nollie types a saved sign-in, the add-on answers "paused" with no picture: the held
    /// picture goes, nothing older from the chat stands in, and the next live frame resumes it.
    @Test func aSignInPauseDropsThePictureAndNeverFallsBack() async throws {
        let currentChat = try chat()
        currentChat.items = [TranscriptItem(id: "shot", kind: .tool(ToolActivity(id: "shot", name: "computer_use", argsText: #"{"action":"capture"}"#,
                                                                                  status: .done, resultText: #"{"screenshot_path":"/tmp/first.png"}"#)))]
        #expect(BotComputerActivity.latestScreen(in: currentChat) != nil)
        let paths = PathLog()
        let model = ComputerPreviewModel(api: try api())
        let live = try response(image: imageURL())
        let paused = Data(#"{"state":"paused","message":"Paused while Nollie types a saved sign-in."}"#.utf8)
        ComputerPreviewStub.handler = { paths.add($0); return (200, live) }
        defer { ComputerPreviewStub.reset() }
        await model.refresh(currentChat)
        #expect(model.image != nil && !model.signInPaused)

        ComputerPreviewStub.handler = { paths.add($0); return (200, paused) }
        await model.refresh(currentChat)
        #expect(model.signInPaused)
        #expect(model.image == nil && model.pointer == nil && model.receivedAt == nil)
        #expect(model.frame?.message == "Paused while Nollie types a saved sign-in.")
        #expect(model.kind == "space" && model.computerName == "Work computer", "still the same computer")
        #expect(!model.isLive(at: Date()) && !model.interrupted && !model.unavailable)
        #expect(WatchPolicy.badge(frame: model.frame, hasImage: false, interrupted: false, updating: true,
                                  receivedAt: nil, now: Date(), signInPaused: model.signInPaused)?.text == "Paused while a sign-in is typed")

        // A failed look while paused still shows nothing older.
        ComputerPreviewStub.handler = { paths.add($0); return (503, Data("{}".utf8)) }
        await model.refresh(currentChat)
        #expect(model.signInPaused && model.image == nil)
        #expect(paths.all.allSatisfy { $0.hasSuffix("/nollie-computer/preview") }, "never the chat's last screen: \(paths.all)")

        ComputerPreviewStub.handler = { paths.add($0); return (200, live) }
        await model.refresh(currentChat)
        #expect(!model.signInPaused && model.image != nil && model.isLive(at: Date()))

        // A new chat starts unpaused.
        ComputerPreviewStub.handler = { paths.add($0); return (200, paused) }
        await model.refresh(currentChat)
        #expect(model.signInPaused)
        ComputerPreviewStub.handler = { paths.add($0); return (503, Data("{}".utf8)) }
        await model.refresh(try chat("home", id: "another-session"))
        #expect(!model.signInPaused)
    }

    @Test(.timeLimit(.minutes(1))) func closingThePreviewCancelsItsInFlightRequest() async throws {
        let started = AsyncStream<Void>.makeStream()
        let stopped = AsyncStream<Void>.makeStream()
        ComputerPreviewStub.handler = { _ in
            started.continuation.yield(())
            return nil
        }
        ComputerPreviewStub.didStop = { stopped.continuation.yield(()) }
        defer { ComputerPreviewStub.reset(); started.continuation.finish(); stopped.continuation.finish() }
        let model = ComputerPreviewModel(api: try api())
        let currentChat = try chat()
        let watch = Task { await model.watch(currentChat) }
        var requests = started.stream.makeAsyncIterator()
        _ = await requests.next()
        watch.cancel()
        await watch.value
        var cancellations = stopped.stream.makeAsyncIterator()
        #expect(await cancellations.next() != nil)
        #expect(model.image == nil)
        #expect(!model.loading)
    }

    @Test func stoppingMacControlRequiresTheExactLeaseToAcknowledgeHumanOwnership() async throws {
        let fixture = MacControlFixture(mode: .confirmed)
        ComputerPreviewStub.handler = { fixture.respond($0) }
        defer { ComputerPreviewStub.reset() }
        let control = SystemControl()
        let stopped = await control.stopMacControl(profile: "work", home: MacControlFixture.home,
                                                    api: try api(), allowed: { true })
        #expect(stopped)
        #expect(control.states["work"] == false)
        #expect(control.states["other"] == nil)
        #expect(!control.busy.contains("work"))
        #expect(control.lastError == nil)
        #expect(fixture.snapshot.writes == 1)
        #expect(fixture.snapshot.reads == 2)
        #expect(fixture.snapshot.requests == ["GET /hermes/api/fs/read-text", "POST /hermes/api/files/upload", "GET /hermes/api/fs/read-text"])
    }

    @Test(arguments: [MacControlFixture.Mode.unchanged, .failedAcknowledgement, .failedUpload, .wrongUploadPath, .malformedAcknowledgement])
    func anUploadAloneNeverReportsMacControlStopped(_ mode: MacControlFixture.Mode) async throws {
        let fixture = MacControlFixture(mode: mode)
        ComputerPreviewStub.handler = { fixture.respond($0) }
        defer { ComputerPreviewStub.reset() }
        let control = SystemControl()
        #expect(!(await control.stopMacControl(profile: "work", home: MacControlFixture.home,
                                               api: try api(), allowed: { true })))
        #expect(control.states["work"] == nil)
        #expect(control.lastError != nil)
        #expect(fixture.snapshot.writes == 1)
    }

    @Test(arguments: [MacControlFixture.Mode.failedRead, .epochOverflow, .revokedDuringRead])
    func anUnreadableLeaseOrLostConsentStopsBeforeWriting(_ mode: MacControlFixture.Mode) async throws {
        let fixture = MacControlFixture(mode: mode)
        ComputerPreviewStub.handler = { fixture.respond($0) }
        defer { ComputerPreviewStub.reset() }
        let control = SystemControl()
        #expect(!(await control.stopMacControl(profile: "work", home: MacControlFixture.home,
                                               api: try api(), allowed: { fixture.snapshot.allowed })))
        #expect(fixture.snapshot.writes == 0)
        #expect(control.states["work"] == nil)
    }

    @Test(.timeLimit(.minutes(1))) func cancellingDuringAcknowledgementNeverClaimsTheMacStopped() async throws {
        let waiting = AsyncStream<Void>.makeStream()
        let fixture = MacControlFixture(mode: .waitingForAcknowledgement, waiting: { waiting.continuation.yield(()) })
        ComputerPreviewStub.handler = { fixture.respond($0) }
        defer { ComputerPreviewStub.reset(); waiting.continuation.finish() }
        let control = SystemControl()
        let api = try api()
        let stop = Task { await control.stopMacControl(profile: "work", home: MacControlFixture.home, api: api, allowed: { true }) }
        var events = waiting.stream.makeAsyncIterator()
        _ = await events.next()
        #expect(control.busy.contains("work"))
        #expect(control.states["work"] == nil)
        stop.cancel()
        #expect(!(await stop.value))
        #expect(control.states["work"] == nil)
        #expect(!control.busy.contains("work"))
        #expect(fixture.snapshot.writes == 1)
    }
}

private final class PathLog: @unchecked Sendable {
    private let lock = NSLock()
    private var paths: [String] = []
    func add(_ request: URLRequest) { lock.withLock { paths.append(request.url?.path ?? "") } }
    var all: [String] { lock.withLock { paths } }
}

final class MacControlFixture: @unchecked Sendable {
    enum Mode: Sendable {
        case confirmed, unchanged, failedRead, failedUpload, failedAcknowledgement, wrongUploadPath, malformedAcknowledgement
        case epochOverflow, revokedDuringRead, waitingForAcknowledgement
    }
    struct Snapshot {
        var reads = 0
        var writes = 0
        var requests: [String] = []
        var allowed = true
    }
    static let home = "/fixture/hermes/profiles/work"
    private let lock = NSLock()
    private var state = Snapshot()
    private let mode: Mode
    private let waiting: @Sendable () -> Void

    init(mode: Mode, waiting: @escaping @Sendable () -> Void = {}) {
        self.mode = mode
        self.waiting = waiting
    }

    var snapshot: Snapshot { lock.withLock { state } }

    func respond(_ request: URLRequest) -> (Int, Data)? {
        lock.withLock {
            let method = request.httpMethod ?? ""
            let path = request.url?.path ?? ""
            let leasePath = Self.home + "/bot-desktop/lease.json"
            state.requests.append(method + " " + path)
            #expect(request.value(forHTTPHeaderField: "X-Hermes-Session-Token") == "preview-test-token")
            if method == "GET", path == "/hermes/api/fs/read-text" {
                state.reads += 1
                let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems
                #expect(query == [URLQueryItem(name: "path", value: leasePath)])
                if state.reads == 1 {
                    if mode == .failedRead { return (503, Data("{}".utf8)) }
                    if mode == .revokedDuringRead { state.allowed = false }
                    let epoch = mode == .epochOverflow ? Int.max : 9
                    return lease(holder: "agent", epoch: epoch)
                }
                if mode == .failedAcknowledgement { return (503, Data("{}".utf8)) }
                if mode == .waitingForAcknowledgement { waiting(); return nil }
                if mode == .malformedAcknowledgement { return lease(holder: "unexpected", epoch: 10) }
                return lease(holder: mode == .unchanged ? "agent" : "human", epoch: mode == .unchanged ? 9 : 10)
            }
            if method == "POST", path == "/hermes/api/files/upload" {
                state.writes += 1
                let body = (try? JSONSerialization.jsonObject(with: Self.body(request))) as? [String: Any]
                #expect(body?["path"] as? String == leasePath)
                #expect(body?["overwrite"] as? Bool == true)
                let encoded = (body?["data_url"] as? String)?.split(separator: ",", maxSplits: 1).last.map(String.init)
                let data = encoded.flatMap { Data(base64Encoded: $0) }
                let written = data.flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] }
                #expect(written?["holder"] as? String == "human")
                #expect(written?["epoch"] as? Int == 10)
                if mode == .failedUpload { return (503, Data("{}".utf8)) }
                let responsePath = mode == .wrongUploadPath ? "/fixture/unrelated" : leasePath
                return (200, try! JSONSerialization.data(withJSONObject: ["ok": true, "path": responsePath]))
            }
            Issue.record("Unexpected computer control endpoint")
            return (404, Data("{}".utf8))
        }
    }

    private func lease(holder: String, epoch: Int) -> (Int, Data) {
        let text = String(data: try! JSONSerialization.data(withJSONObject: ["holder": holder, "epoch": epoch]), encoding: .utf8)!
        return (200, try! JSONSerialization.data(withJSONObject: ["text": text]))
    }

    private static func body(_ request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var result = Data()
        var bytes = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&bytes, maxLength: bytes.count)
            guard count > 0 else { break }
            result.append(contentsOf: bytes.prefix(count))
        }
        return result
    }
}

private final class ComputerPreviewStub: URLProtocol {
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) -> (Int, Data)?)?
    nonisolated(unsafe) static var didStop: (@Sendable () -> Void)?

    static func reset() { handler = nil; didStop = nil }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let (status, data) = Self.handler?(request) else { return }
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() { Self.didStop?() }
}
