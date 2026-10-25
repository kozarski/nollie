import Foundation
import ImageIO
import Observation
import NollieCore

/// Frames travel through the gateway's existing authenticated connection. Opening a preview
/// never grants control, starts a computer, or changes its active window.
struct ComputerPreviewFrame: Decodable, Sendable {
    var state: String
    var computerName: String?
    var kind: String?
    var imageDataUrl: String?
    var capturedAt: Double?
    /// Where the helper last acted, in the frame's pixels, from its own click (add-on 0.2).
    var pointer: ComputerPointer? = nil
    /// Who holds the computer: "helper", "you" or "someone" (add-on 0.2; absent before).
    var control: String? = nil
    /// The add-on's own words for a state, like why pictures are paused.
    var message: String? = nil

    func isFresh(at now: Date) -> Bool {
        guard state == "live", let capturedAt, capturedAt.isFinite else { return false }
        let age = now.timeIntervalSince1970 - capturedAt
        return age >= -5 && age < 10
    }

    var imageData: Data? {
        guard let url = imageDataUrl, url.utf8.count <= 12_000_000,
              url.hasPrefix("data:image/png;base64,") || url.hasPrefix("data:image/jpeg;base64,"),
              let comma = url.firstIndex(of: ",") else { return nil }
        return Data(base64Encoded: String(url[url.index(after: comma)...]))
    }
}

/// A spot the helper's computer tool acted on, as the add-on read it from the tool call.
struct ComputerPointer: Decodable, Sendable, Equatable {
    var x: Int
    var y: Int
    var at: Double?
}

@MainActor @Observable
final class ComputerPreviewModel {
    /// The latest snapshot's picture; `image` is what may be shown of it.
    private var stillImage: CGImage?
    private(set) var frame: ComputerPreviewFrame?
    private(set) var computerName: String?
    private(set) var kind: String?
    private(set) var receivedAt: Date?
    private(set) var loading = true
    private(set) var unavailable = false
    private(set) var interrupted = false
    /// The helper's last spot on this computer, only while a live frame came with it.
    private var stillPointer: ComputerPointer?
    /// Who holds the computer, when the add-on can say. Nil means Take over isn't offered.
    private var stillHolder: ComputerHolder?
    /// The frame's own size in pixels, which the pointer's numbers are measured in.
    private var stillPixelSize: CGSize?
    /// The latest snapshot said pictures are paused while Nollie types a saved sign-in.
    private var stillSignInPaused = false
    private var fallbackID: String?
    private var bridgeMissing = false
    private var lastProbe = Date.distantPast
    private var sessionKey: String?
    private let apiOverride: HermesAPI?
    /// The live picture, for the Watch screen only. Its numbers lead while a stream is open.
    let live: LiveWatch
    /// When a stream may be tried again after one failed or closed.
    private var liveAgainAt = Date.distantPast
    private let openFeed: (ChatSession) async -> any LiveFeed
    private let now: () -> Date
    private let pause: (Duration) async throws -> Void
    /// How often a snapshot is taken while a stream hasn't said hello yet.
    private let beforeHelloEvery: Duration

    static let liveRetry: TimeInterval = 30

    init(api: HermesAPI? = nil, live: LiveWatch = LiveWatch(),
         openFeed: @escaping (ChatSession) async -> any LiveFeed = { await LiveFeedRouter.open(for: $0) },
         now: @escaping () -> Date = Date.init,
         pause: @escaping (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
         beforeHelloEvery: Duration = .seconds(2)) {
        apiOverride = api
        self.live = live
        self.openFeed = openFeed
        self.now = now
        self.pause = pause
        self.beforeHelloEvery = beforeHelloEvery
    }

    var needsCompanion: Bool { bridgeMissing }

    /// A stream that has said hello speaks for the computer; otherwise the latest snapshot does.
    /// Who holds it comes with the stream's beats, so the snapshot's word stands until the first.
    private var liveLeads: Bool { live.running && live.greeted }
    var holder: ComputerHolder? { liveLeads && live.beatAt != nil ? live.holder : stillHolder }
    var pointer: ComputerPointer? { liveLeads ? live.pointer : stillPointer }
    /// The size the pointer's numbers are measured in.
    var pixelSize: CGSize? { liveLeads ? live.sourceSize : stillPixelSize }

    /// Pictures of this computer are paused while Nollie types a saved sign-in into it, as the
    /// latest snapshot or the live picture's beats say. Nothing older stands in for them, and the
    /// next answer that isn't paused ends it.
    var signInPaused: Bool { liveLeads ? live.hold == .signIn : stillSignInPaused }

    /// The snapshot to show: none while paused, and none taken before the live picture last paused.
    var image: CGImage? {
        guard !signInPaused, let stillImage else { return nil }
        if let heldAt = live.heldAt, (receivedAt ?? .distantPast) <= heldAt { return nil }
        return stillImage
    }

    /// The live picture is on screen: while a stream runs, once it has shown a frame of its own;
    /// after that, until a newer snapshot comes.
    var showsVideo: Bool {
        guard live.hasShownFrame, !signInPaused else { return false }
        if live.running { return live.shownThisRun }
        return (receivedAt ?? .distantPast) <= (live.lastFrameAt ?? .distantPast)
    }

    /// The video surface is placed (under the last still until its first frame, so nothing flashes).
    var placesVideo: Bool { !signInPaused && (showsVideo || liveLeads) }

    /// What the badge needs to know about the live picture, once there has been one.
    var liveBadge: WatchPolicy.LiveBadge? {
        guard live.running || live.hasShownFrame || live.ended != nil else { return nil }
        return WatchPolicy.LiveBadge(open: liveLeads, shown: showsVideo, fresh: live.fresh, beatAt: live.beatAt,
                                     currentAt: live.currentAt, ended: live.ended, endedAt: live.endedAt)
    }

    func isLive(at now: Date) -> Bool {
        !interrupted && !unavailable && frame?.isFresh(at: now) == true && image != nil
    }

    /// Snapshots every 2 seconds. With `live` (the Watch screen), one snapshot first for a quick
    /// picture, then the live stream; once it has said hello nothing is polled. When it fails or
    /// closes, snapshots again, and the stream is tried again 30 seconds later.
    func watch(_ chat: ChatSession, live wantsLive: Bool = false) async {
        defer { loading = false }
        while !Task.isCancelled {
            await refresh(chat)
            if wantsLive, !PrivateBots.isPrivate(chat.profileName), now() >= liveAgainAt {
                await playLive(chat)
                guard !Task.isCancelled else { return }
                continue
            }
            do { try await pause(.seconds(interrupted ? 5 : 2)) }
            catch { return }
        }
    }

    private func playLive(_ chat: ChatSession) async {
        let key = sessionKey
        let feed = await openFeed(chat)
        guard !Task.isCancelled, sessionKey == key else { feed.cancel(); return }
        // Until the stream says hello it speaks for nothing, so snapshots carry on: a sign-in
        // that begins meanwhile still clears the picture and shows the pause.
        let live = live, every = beforeHelloEvery
        let snapshots = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: every) } catch { return }
                guard let self, live.running, !live.greeted, self.sessionKey == key else { return }
                await self.refresh(chat)
            }
        }
        let outcome = await live.run(feed)
        snapshots.cancel()
        guard !Task.isCancelled else { return }
        liveAgainAt = now().addingTimeInterval(Self.liveRetry)
        cooling = outcome == .cooling
        // Keep what this run knew until the next snapshot says otherwise.
        if live.sourceSize != nil {
            stillPointer = live.pointer
            stillPixelSize = live.sourceSize
        }
        if live.beatAt != nil { stillHolder = live.holder }
        // Paused when it ended: still paused until a snapshot says otherwise.
        if live.hold == .signIn { stillSignInPaused = true }
    }

    /// Video stopped because the device got too warm.
    private(set) var cooling = false

    func refresh(_ chat: ChatSession) async {
        let key = "\(chat.runtime.connection.id)/\(chat.profileName)/\(chat.storedID)"
        if sessionKey != key {
            stillImage = nil; frame = nil; computerName = nil; kind = nil; receivedAt = nil
            stillPointer = nil; stillHolder = nil; stillPixelSize = nil; stillSignInPaused = false
            loading = true; unavailable = false; interrupted = false
            fallbackID = nil; bridgeMissing = false; lastProbe = .distantPast
            live.reset(); liveAgainAt = .distantPast; cooling = false
            sessionKey = key
        }
        let api = apiOverride ?? chat.runtime.api
        if !bridgeMissing || Date().timeIntervalSince(lastProbe) >= 30 {
            lastProbe = Date()
            do {
                let next: ComputerPreviewFrame = try await api.get(
                    "/api/plugins/nollie-computer/preview",
                    query: [URLQueryItem(name: "session_id", value: chat.storedID)], profile: chat.profileName)
                try Task.checkCancellation()
                guard sessionKey == key else { return }
                bridgeMissing = false
                let data = next.imageData
                let decoded = data.flatMap(Self.decode)
                let paused = next.state == "paused"
                // A paused answer may leave out which computer it is: still the same one.
                let nextName = paused ? next.computerName ?? computerName : next.computerName
                let nextKind = paused ? next.kind ?? kind : next.kind
                let targetChanged = computerName != nextName || kind != nextKind
                if targetChanged || paused {
                    stillImage = nil; receivedAt = nil; fallbackID = nil; stillPixelSize = nil
                    // The last live picture was of the other computer too, or older than the pause.
                    live.forgetPicture()
                }
                stillSignInPaused = paused
                stillHolder = next.control.flatMap(ComputerHolder.init(rawValue:))
                computerName = nextName
                kind = nextKind
                frame = next
                unavailable = next.state == "unavailable"
                interrupted = next.state == "live" && decoded == nil
                if let decoded {
                    stillImage = decoded; receivedAt = Date(); fallbackID = nil
                    stillPixelSize = data.flatMap(Self.pixelSize)
                    stillPointer = next.pointer
                } else if next.state != "live" {
                    stillPointer = nil
                }
                else if next.kind == nil && next.state != "live" { await fallback(chat, key: key) }
                loading = false
                return
            } catch is CancellationError { return }
            catch {
                guard !Task.isCancelled, sessionKey == key else { return }
                if case HermesAPIError.http(let status, _) = error, status == 404 {
                    bridgeMissing = true
                    stillHolder = nil; stillPointer = nil
                    unavailable = true
                } else { interrupted = true }
            }
        }
        await fallback(chat, key: key)
        loading = false
    }

    private func fallback(_ chat: ChatSession, key: String) async {
        // While a sign-in is typed, no older picture stands in for the paused one.
        guard !signInPaused, let ref = BotComputerActivity.latestScreen(in: chat), ref.id != fallbackID else { return }
        do {
            let (data, _) = try await GatewayMediaAPI(api: apiOverride ?? chat.runtime.api, profile: chat.profileName).fetch(ref)
            try Task.checkCancellation()
            guard sessionKey == key, !signInPaused else { return }
            guard let decoded = Self.decode(data) else { return }
            stillImage = decoded
            frame = nil
            receivedAt = nil
            stillPointer = nil
            stillHolder = nil
            stillPixelSize = nil
            computerName = nil
            kind = nil
            fallbackID = ref.id
        } catch { }
    }

    /// The image's own width and height, before any thumbnail is made for the screen.
    static func pixelSize(_ data: Data) -> CGSize? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue,
              width > 0, height > 0 else { return nil }
        return CGSize(width: width, height: height)
    }

    private static func decode(_ data: Data) -> CGImage? {
        guard data.count <= 9_000_000,
              let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                      kCGImageSourceThumbnailMaxPixelSize: 1600,
                                      kCGImageSourceCreateThumbnailWithTransform: true]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}
