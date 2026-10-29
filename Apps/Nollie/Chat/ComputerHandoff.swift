import Foundation
import Observation
import NollieCore

/// Who holds a helper's computer, as the computer add-on reports it from the desktop lease.
enum ComputerHolder: String, Sendable, Equatable {
    /// The helper may use it (or Mac control is simply off; the helper's own computer is free).
    case helper
    /// This person took it over in Nollie: the helper is waiting.
    case you
    /// Another person holds it somewhere else. Nollie never takes it from them.
    case someone
}

/// What the Watch screen shows, worked out from the preview without any drawing.
enum WatchPolicy {
    /// The badge over the screen. Live only for a frame captured moments ago.
    enum Badge: Equatable {
        case live
        /// Updates stop arriving here because the app went to the background. The helper keeps going.
        case paused
        /// The live picture ended because the helper stopped using the computer, or it went away.
        case stopped
        /// The newest picture is older; nil when its time isn't known.
        case lastSeen(TimeInterval?)
        /// The add-on holds pictures back while a saved sign-in is typed.
        case signIn

        var text: String {
            switch self {
            case .live: String(localized: "Live", comment: "A badge on a computer's picture: it is live")
            case .paused: String(localized: "Paused", comment: "A badge on a computer's picture: updates are paused")
            case .stopped: String(localized: "Stopped", comment: "A badge on a computer's picture: the live picture ended")
            case .signIn: WatchPolicy.signInPausedLine
            case .lastSeen(let age): WatchPolicy.lastSeen(age)
            }
        }
    }

    /// What the badge needs from a live stream.
    struct LiveBadge: Equatable {
        /// A stream is open and has said hello.
        var open: Bool
        /// Its picture is the one on screen.
        var shown: Bool
        /// Its latest beat said the picture is current.
        var fresh: Bool
        var beatAt: Date?
        /// When the picture on screen was last known to be current.
        var currentAt: Date?
        /// Why the host ended the last stream, if it did, and when.
        var ended: LiveWire.EndReason?
        var endedAt: Date? = nil
    }

    /// A beat older than this no longer vouches for the picture.
    static let beatLimit: TimeInterval = 3

    static func badge(frame: ComputerPreviewFrame?, hasImage: Bool, interrupted: Bool,
                      updating: Bool, receivedAt: Date?, now: Date, live: LiveBadge? = nil, signInPaused: Bool = false) -> Badge? {
        // Said by a snapshot or by the live picture's beats: never Live, and nothing older shown.
        if signInPaused { return .signIn }
        guard hasImage || live?.shown == true else { return nil }
        if !updating { return .paused }
        let captured = frame?.capturedAt.flatMap { $0.isFinite ? Date(timeIntervalSince1970: $0) : nil } ?? receivedAt
        if let live {
            if live.open {
                if live.shown, live.fresh, let beat = live.beatAt, abs(now.timeIntervalSince(beat)) <= beatLimit { return .live }
            } else if live.ended == .stopped || live.ended == .gone {
                // Until a snapshot taken since then shows the computer in use again.
                let newer = (receivedAt ?? .distantPast) > (live.endedAt ?? .distantFuture)
                if !(newer && !interrupted && frame?.isFresh(at: now) == true) { return .stopped }
            }
            if live.open || live.shown {
                // Dated by the picture on screen: the stream's once it has shown one, else the still.
                let seen = live.shown ? live.currentAt ?? captured : captured
                return .lastSeen(seen.map { max(0, now.timeIntervalSince($0)) })
            }
        }
        if !interrupted, frame?.isFresh(at: now) == true { return .live }
        return .lastSeen(captured.map { max(0, now.timeIntervalSince($0)) })
    }

    static let signInPausedLine = String(localized: "Paused while a sign-in is typed", comment: "Safety: pictures of the screen pause while a saved sign-in is typed")
    /// The same, as a sentence.
    static let signInPausedSentence = String(localized: "Paused while a sign-in is typed.", comment: "Safety: pictures of the screen pause while a saved sign-in is typed")

    /// What VoiceOver says the picture is: live video only when the badge says Live, other video
    /// as the last picture, and a still by the time it was taken.
    static func pictureValue(showsVideo: Bool, badge: Badge?, capturedAt: Double?) -> String {
        if showsVideo { return badge == .live ? String(localized: "Live picture") : String(localized: "Last picture") }
        return capturedAt.map { Date(timeIntervalSince1970: $0).formatted(date: .omitted, time: .standard) } ?? String(localized: "Last screen")
    }

    /// Plain words under the badge while the connection can't keep up.
    static func linkLine(_ link: LiveWire.LinkState) -> String? {
        switch link {
        case .fine: nil
        case .behind: String(localized: "The connection is slow, so the picture is lighter.")
        case .stalled: String(localized: "Waiting for the picture to catch up.")
        }
    }

    /// Under the badge when the device got too warm for video and shows stills instead.
    static func coolingLine(_ device: String) -> String {
        String(localized: "Slowed down to keep your \(device) cool.", comment: "The device follows your: iPhone, iPad or Mac")
    }

    static func lastSeen(_ age: TimeInterval?) -> String {
        guard let age else { return String(localized: "Last screen") }
        let minutes = Int(age / 60)
        if minutes < 1 { return String(localized: "Last seen just now") }
        if minutes < 60 { return String(localized: "Last seen \(minutes) min ago") }
        let hours = minutes / 60
        return hours < 24 ? String(localized: "Last seen \(hours) hr ago") : String(localized: "Last seen over a day ago")
    }

    /// The pointer's place as a fraction of the picture, or nil when it can't be placed honestly.
    static func pointerSpot(_ pointer: ComputerPointer?, pixelSize: CGSize?) -> CGPoint? {
        guard let pointer, let size = pixelSize, size.width > 0, size.height > 0,
              pointer.x >= 0, pointer.y >= 0,
              Double(pointer.x) < size.width, Double(pointer.y) < size.height else { return nil }
        return CGPoint(x: (Double(pointer.x) + 0.5) / size.width, y: (Double(pointer.y) + 0.5) / size.height)
    }

    /// The header's Watch pill: while the helper is busy on a computer, or while you hold it.
    /// Never for a private bot: its computer is not watched from Nollie.
    static func showsWatch(active: Bool, held: Bool, isPrivate: Bool) -> Bool { !isPrivate && (active || held) }

    static func heldLine(_ name: String) -> String { String(localized: "You have the computer. \(name) is waiting.") }
    static let someoneLine = String(localized: "Someone else has the computer right now.")
    static let takeOverFailed = String(localized: "Couldn’t take over. Check the connection and try again.")
    static let handBackFailed = String(localized: "Couldn’t hand back. Check the connection and try again.")
    static func authReason(_ name: String) -> String {
        String(localized: "Take over \(name)’s computer", comment: "Safety: the reason shown with Face ID or Touch ID before taking over a bot's computer")
    }
}

/// The computers this device has taken over, so the chat keeps its Watch pill (and the way to
/// hand back) after the Watch screen closes. Every answer from the add-on corrects it.
@MainActor @Observable
final class ComputerHandoff {
    static let shared = ComputerHandoff()

    enum Outcome: Equatable { case done(ComputerHolder), refused, failed, cancelled }

    private(set) var held: Set<String> = []
    private(set) var busy: Set<String> = []

    static func key(_ runtime: GatewayRuntime, _ profile: String) -> String { "\(runtime.connection.id)/\(profile)" }

    func isHeld(_ runtime: GatewayRuntime, _ profile: String) -> Bool { held.contains(Self.key(runtime, profile)) }
    func isBusy(_ runtime: GatewayRuntime, _ profile: String) -> Bool { busy.contains(Self.key(runtime, profile)) }

    /// What the preview says now.
    func note(_ holder: ComputerHolder?, runtime: GatewayRuntime, profile: String) {
        note(holder, key: Self.key(runtime, profile))
    }

    func note(_ holder: ComputerHolder?, key: String) {
        guard let holder, !busy.contains(key) else { return }
        if holder == .you { held.insert(key) } else { held.remove(key) }
    }

    /// Starts with a Face ID, Touch ID or passcode check. If the reply is lost, the result
    /// stays unknown: the next preview reveals who holds the computer, and no request is repeated.
    func takeOver(profile: String, runtime: GatewayRuntime, api: HermesAPI? = nil, name: String,
                  authenticator: any DeviceOwnerAuthenticating) async -> Outcome {
        let key = Self.key(runtime, profile)
        guard !busy.contains(key) else { return .cancelled }
        guard await authenticator.authenticate(reason: WatchPolicy.authReason(name)) != nil else { return .cancelled }
        return await change("take-over", key: key, profile: profile, api: api ?? runtime.api)
    }

    func handBack(profile: String, runtime: GatewayRuntime, api: HermesAPI? = nil) async -> Outcome {
        let key = Self.key(runtime, profile)
        guard !busy.contains(key) else { return .cancelled }
        return await change("hand-back", key: key, profile: profile, api: api ?? runtime.api)
    }

    private struct Answer: Decodable { var control: String }

    private func change(_ action: String, key: String, profile: String, api: HermesAPI) async -> Outcome {
        busy.insert(key)
        defer { busy.remove(key) }
        do {
            let answer: Answer = try await api.send("POST", "/api/plugins/nollie-computer/\(action)",
                                                    profile: profile, json: .object([:]))
            guard let holder = ComputerHolder(rawValue: answer.control) else { return .failed }
            if holder == .you { held.insert(key) } else { held.remove(key) }
            return .done(holder)
        } catch HermesAPIError.http(let status, _) where status == 409 {
            return .refused
        } catch {
            return .failed
        }
    }
}
