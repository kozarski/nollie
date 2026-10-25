import Foundation
import CoreGraphics
import NollieCore

enum WelcomeIntroTimeline {
    static let seenKey = "nollie.onboarding.welcomeIntroSeen"
    static let duration = 4.55

    static func shouldPlay(hasConnections: Bool, hasSavedProgress: Bool, hasSeenIntro: Bool,
                           reduceMotion: Bool, isFixture: Bool, demoRequested: Bool) -> Bool {
        guard !reduceMotion, !isFixture else { return false }
        return demoRequested || (!hasConnections && !hasSavedProgress && !hasSeenIntro)
    }

    struct Frame: Equatable {
        let approach: Double
        let reveal: Double
        let settle: Double
        let state: CharacterState
    }

    /// Asleep up close, waking, noticing the viewer, hello, then a happy hop on the way back that
    /// lands as idle just before the intro ends.
    static let beats: [(start: Double, state: CharacterState)] = [
        (0, .asleep), (1.10, .idle), (2.08, .listening), (2.63, .speaking), (2.94, .done),
    ]

    static func frame(at elapsed: Double) -> Frame {
        let t = elapsed.isFinite ? max(0, elapsed) : 0
        // Arrive at the near eye, linger, take in the whole face, then step back.
        return Frame(approach: smooth((t - 0.08) / 0.44),
                     reveal: smooth((t - 1.45) / 0.62),
                     settle: smooth((t - 2.96) / 1.20),
                     state: beats.last { $0.start <= t }?.state ?? .asleep)
    }

    struct Camera: Equatable {
        let scale: CGFloat
        let center: CGPoint
    }

    /// Where Nollie's eyes sit in its frame (screen-left first) and how wide one is, as fractions.
    static var eyeAnchors: (near: CGPoint, far: CGPoint, unit: CGFloat) {
        let face = CharacterCatalog.shared.look(.main).face
        func point(_ i: Int) -> CGPoint {
            guard face.eyes.indices.contains(i), face.eyes[i].count == 2 else { return CGPoint(x: 0.34 + 0.27 * Double(i), y: 0.55) }
            return CGPoint(x: face.eyes[i][0], y: face.eyes[i][1])
        }
        return (point(0), point(1), CGFloat(max(0.01, face.unit)))
    }

    /// Frame the near eye first, then let the far eye cross into view before stepping back.
    static func camera(frame: Frame, viewport: CGSize, hero: CGRect) -> Camera {
        let side = max(1, hero.width)
        let eyes = eyeAnchors
        let gap = max(1, (eyes.far.x - eyes.near.x) * side)
        // Close enough that the far eye waits off screen to the right.
        let closeScale = max(1, min(viewport.width, viewport.height) * 0.22 / (eyes.unit * side),
                             viewport.width * 0.58 / gap)
        let openingScale = closeScale * 1.6
        let pairScale = min(closeScale, max(1, min(viewport.width * 0.42, viewport.height * 0.5) / gap))
        let approachScale = logMix(openingScale, closeScale, frame.approach)
        let revealScale = logMix(approachScale, pairScale, frame.reveal)
        let scale = logMix(revealScale, 1, frame.settle)
        let middle = CGPoint(x: (eyes.near.x + eyes.far.x) / 2, y: (eyes.near.y + eyes.far.y) / 2)
        let focus = CGPoint(x: mix(eyes.near.x, middle.x, frame.reveal), y: mix(eyes.near.y, middle.y, frame.reveal))
        let offset = CGPoint(x: (focus.x - 0.5) * side, y: (focus.y - 0.5) * side)
        let staged = CGPoint(x: viewport.width * 0.5, y: viewport.height * 0.45)
        let target = CGPoint(x: mix(staged.x, hero.midX + offset.x, frame.settle),
                             y: mix(staged.y, hero.midY + offset.y, frame.settle))
        return Camera(scale: scale,
                      center: CGPoint(x: target.x - scale * offset.x,
                                      y: target.y - scale * offset.y))
    }

    private static func mix(_ a: Double, _ b: Double, _ amount: Double) -> Double { a + (b - a) * amount }
    private static func logMix(_ a: Double, _ b: Double, _ amount: Double) -> Double {
        exp(mix(log(a), log(b), amount))
    }
    private static func smooth(_ value: Double) -> Double {
        let x = min(1, max(0, value))
        return x * x * x * (x * (x * 6 - 15) + 10)
    }
}
