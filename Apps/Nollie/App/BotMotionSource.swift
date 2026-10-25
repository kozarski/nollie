import UIKit
import CoreMotion
import NollieCore

/// Passes device tilt to the bots' lean (`BotAmbient.shared.tilt`) while Nollie is frontmost and
/// bot motion is switched on.
@MainActor
final class BotMotionSource {
    /// Setting for how much bots move: lively, calm or still. `CharacterView` reads the same key.
    static let styleKey = CharacterView.styleKey
    /// Leaning with the gyroscope is its own opt-in switch, since it can feel twitchy.
    static let tiltKey = "bots.tilt"
    static let enabledKey = "bots.motion"
    static let shared = BotMotionSource()

    /// One direction of lean, from -1 to 1. The first angle seen counts as level, and that level
    /// drifts slowly after the hand, so a bot stands upright however the phone rests.
    private struct LeanAxis {
        private var level: Double?
        private var smoothed = 0.0

        /// A few degrees around level do nothing; full lean comes at about 40 degrees.
        private static func curve(_ delta: Double) -> Double {
            let eased = min(1, max(0, abs(delta) - 0.09) / 0.61)
            return delta < 0 ? -eased : eased
        }

        mutating func feed(_ angle: Double) -> Double {
            let anchor = level ?? angle
            let drifted = anchor + (angle - anchor) * 0.01
            level = drifted
            smoothed += (Self.curve(angle - drifted) - smoothed) * 0.12
            return smoothed
        }
    }

    private let manager = CMMotionManager()
    private var roll = LeanAxis()
    private var pitch = LeanAxis()

    var enabled: Bool {
        UserDefaults.standard.object(forKey: Self.enabledKey) as? Bool ?? true
    }

    var tiltEnabled: Bool {
        UserDefaults.standard.object(forKey: Self.tiltKey) as? Bool == true
    }

    /// Starts or stops motion updates so they match the settings and whether the app is active.
    func apply(active: Bool = true) {
        BotAmbient.shared.enabled = enabled
        let wanted = enabled && tiltEnabled && active
            && manager.isDeviceMotionAvailable && !UIAccessibility.isReduceMotionEnabled
        if wanted { startUpdates() } else { stopUpdates() }
    }

    private func stopUpdates() {
        manager.stopDeviceMotionUpdates()
        BotAmbient.shared.tilt = .zero
        (roll, pitch) = (LeanAxis(), LeanAxis())
    }

    private func startUpdates() {
        if manager.isDeviceMotionActive { return }
        manager.deviceMotionUpdateInterval = 1.0 / 30
        manager.startDeviceMotionUpdates(to: .main) { [weak self] sample, _ in
            guard let self, let attitude = sample?.attitude else { return }
            BotAmbient.shared.tilt = CGPoint(x: roll.feed(attitude.roll), y: pitch.feed(attitude.pitch))
        }
    }
}
