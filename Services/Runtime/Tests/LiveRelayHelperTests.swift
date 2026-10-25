#if os(macOS)
import Foundation
import Testing

/// The helper's relay with a pretend app: an open the app answers too late never leaves a viewer
/// behind on the app's side.
@Suite(.timeLimit(.minutes(1)))
struct LiveRelayHelperTests {
    /// Behaves like Nollie.app: an open attaches a viewer, a close detaches it, and a close that
    /// comes first turns its open away. `attachLate` attaches only when the late answer goes.
    final class SlowApp: NSObject, NollieLiveHostIPC, @unchecked Sendable {
        private let lock = NSLock()
        private let answerAfter: TimeInterval
        private let attachLate: Bool
        private var viewers: Set<String> = []
        private var closed = NollieLiveRelayClosed()

        init(answerAfter: TimeInterval, attachLate: Bool = false) {
            self.answerAfter = answerAfter
            self.attachLate = attachLate
        }

        func open(request: Data, withReply: @escaping @Sendable (Data) -> Void) {
            guard let request = NollieLiveRelayOpen.decode(request) else { return withReply(NollieLiveRelayAnswer.ended("refused").encoded()) }
            if !attachLate { attach(request.stream) }
            DispatchQueue.global().asyncAfter(deadline: .now() + answerAfter) { [self] in
                let opened = attachLate ? attach(request.stream) : lock.withLock { viewers.contains(request.stream) }
                withReply((opened ? NollieLiveRelayAnswer.opened : .ended("unavailable")).encoded())
            }
        }

        func control(stream: String, message: Data) {}

        func close(stream: String) {
            lock.withLock {
                closed.insert(stream)
                viewers.remove(stream)
            }
        }

        @discardableResult private func attach(_ stream: String) -> Bool {
            lock.withLock { closed.contains(stream) ? false : viewers.insert(stream).inserted }
        }

        var viewerCount: Int { lock.withLock { viewers.count } }
        var closes: Int { lock.withLock { closed.streams.count } }
    }

    final class Sink: LiveRelaySink, @unchecked Sendable {
        private let lock = NSLock()
        private var reasons: [String] = []
        func send(_ data: Data, isText: Bool, isKeyframe: Bool) {}
        func end(reason: String) { lock.withLock { reasons.append(reason) } }
        var ended: [String] { lock.withLock { reasons } }
    }

    private let request = LinkDoorLiveRequest(profile: "work", sessionID: "chat-1", deviceID: UUID())

    private func settle(_ app: SlowApp, within seconds: Double = 3, until done: (SlowApp) -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if done(app) { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return done(app)
    }

    @Test func anOpenAnsweredTooLateIsClosedOnTheAppsSide() async {
        for attachLate in [false, true] {
            let relay = LiveRelay(openTimeout: 0.2)
            let app = SlowApp(answerAfter: 0.5, attachLate: attachLate)
            relay.register(LiveRelayApp(host: app))
            let feed = await relay.open(request, sink: Sink())
            #expect(feed == nil)
            #expect(await settle(app) { $0.closes == 1 }, "The helper tells the app to let go")
            // Past the late answer: the app has nobody left watching.
            try? await Task.sleep(for: .milliseconds(500))
            #expect(app.viewerCount == 0, "attachLate: \(attachLate)")
        }
    }

    @Test func anOpenAnsweredInTimeStaysOpenUntilTheDoorCloses() async {
        let relay = LiveRelay(openTimeout: 2)
        let app = SlowApp(answerAfter: 0.05)
        relay.register(LiveRelayApp(host: app))
        let sink = Sink()
        let feed = await relay.open(request, sink: sink)
        #expect(feed != nil)
        #expect(app.viewerCount == 1 && app.closes == 0 && sink.ended.isEmpty)
        feed?.close()
        #expect(await settle(app) { $0.viewerCount == 0 })
    }

    @Test func aNewerAppTakesOverAndAnEarlierOneIsAskedAgainWhenItGoes() async {
        let relay = LiveRelay(openTimeout: 2)
        let older = SlowApp(answerAfter: 0.01), newer = SlowApp(answerAfter: 0.01)
        let olderApp = LiveRelayApp(host: older), newerApp = LiveRelayApp(host: newer)
        relay.register(olderApp)
        let sink = Sink()
        let feed = await relay.open(request, sink: sink)
        #expect(feed != nil && older.viewerCount == 1)

        // A second copy registers: the stream ends on the phone and on the app that fed it.
        relay.register(newerApp)
        #expect(await settle(older) { $0.viewerCount == 0 }, "The older app lets go of its viewer")
        #expect(sink.ended == ["unavailable"])
        // The door's close after that still goes to the app that opened the stream.
        feed?.close()
        #expect(await settle(older) { $0.closes == 1 })
        let onNewer = await relay.open(request, sink: Sink())
        #expect(onNewer != nil && newer.viewerCount == 1 && older.viewerCount == 0)
        // Registering again changes nothing.
        relay.register(newerApp)
        #expect(await relay.open(request, sink: Sink()) != nil && newer.viewerCount == 2)

        // The newer copy quits: its streams end, and the older one, still connected, is asked again.
        relay.lost(newerApp)
        #expect(await settle(newer) { $0.viewerCount == 0 })
        #expect(await relay.open(request, sink: Sink()) != nil)
        #expect(older.viewerCount == 1)
        relay.lost(olderApp)
        #expect(await relay.open(request, sink: Sink()) == nil, "Nobody left to ask")
    }

    @Test func withNoAppTheresNoFeed() async {
        let feed = await LiveRelay(openTimeout: 0.2).open(request, sink: Sink())
        #expect(feed == nil)
    }
}
#endif
