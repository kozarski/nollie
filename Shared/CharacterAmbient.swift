import SwiftUI

/// Shared mood for every bot shown. Scrolling turns their eyes, tilting the device leans them, and
/// finishing a turn or a tap gives one bot a little flourish. The app drives it; extensions keep it still.
@MainActor @Observable
public final class BotAmbient {
    public static let shared = BotAmbient()

    /// UserDefaults key behind Settings, Appearance, Animate bots (Mac).
    public static let animateKey = "bots.animate"

    // MARK: Looking and leaning

    /// Where the eyes look, each axis from -1 to 1. Eases back to centre once scrolling stops.
    public var gaze: CGPoint = .zero
    /// How the device is held, each axis from -1 to 1: roll on x, pitch on y.
    public var tilt: CGPoint = .zero
    /// True while a list is moving, and for a moment after.
    public var scrolling = false
    /// Settings, Bots: whether bots follow scrolling at all.
    public var enabled = true

    // MARK: Whether to move

    /// The Mac's screen is asleep or locked. Drawing then only makes the render server wait.
    public var displayAsleep = false
    /// Something is running or waiting somewhere (the Mac's menu bar knows). Idle bots only blink
    /// and glance while that is true, so a quiet app costs nothing.
    public var anyWorking = false
    /// Whether a bot that is only decoration (in the sidebar or Home) should do its working moves:
    /// on the Mac only while there is real work (#248), always on the phone.
    public var decorativeActive: Bool {
        #if os(macOS)
        anyWorking
        #else
        true
        #endif
    }

    // MARK: Moments, keyed by profile name

    /// The time each bot last completed a turn, which makes it spin once.
    public var finished = [String: Date]()
    /// The time each bot was last tapped, which makes it turn and blink.
    public var tapped = [String: Date]()

    public func turnFinished(profile: String) { finished.updateValue(.now, forKey: profile) }
    public func tap(profile: String) { tapped.updateValue(.now, forKey: profile) }

    // MARK: Scrolling

    private var settle: Task<Void, Never>?
    private var lastGazeUpdate = Date.distantPast

    public init() {}

    /// Feeds in a scrolled distance `dy` (positive when the content travels upward). The eyes follow
    /// at roughly sixteen updates a second at most, and only for movement big enough to see.
    public func scrolled(dy: CGFloat) {
        guard dy.magnitude > 0.5 else { return }
        if enabled { followScroll(dy) }
        if !scrolling { scrolling = true }
        settle?.cancel()
        settle = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(450)) } catch { return }
            self?.gaze = .zero
            self?.scrolling = false
        }
    }

    private func followScroll(_ dy: CGFloat) {
        let elapsed = -lastGazeUpdate.timeIntervalSinceNow
        guard elapsed > 0.06 else { return }
        lastGazeUpdate = .now
        let eased = gaze.y * 0.6 - dy / 40
        let clamped = max(-1, min(1, eased))
        if (clamped - gaze.y).magnitude > 0.03 { gaze.y = clamped }
    }
}

extension EnvironmentValues {
    /// Decides whether bots in this window may animate. It is off when the window is hidden, collapsed
    /// into the Dock, covered, or behind other apps. Only the Mac sets it, window by window.
    @Entry public var botsLive = true
}

extension Color {
    /// A colour from "#RRGGBB" (the hash is optional); nil for anything else.
    public init?(botHex: String) {
        var digits = Substring(botHex.trimmingCharacters(in: .whitespaces))
        if digits.first == "#" { digits.removeFirst() }
        guard digits.count == 6, let packed = Int(digits, radix: 16) else { return nil }
        let shares = [16, 8, 0].map { Double(packed >> $0 & 0xFF) / 255 }
        self.init(red: shares[0], green: shares[1], blue: shares[2])
    }
}
