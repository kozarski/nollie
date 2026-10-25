import Foundation

/// A character at one moment: what the view needs to draw a frame. Distances are fractions of H
/// (the look's box height), angles in degrees (positive leans clockwise), gaze in -1 to 1 (x right,
/// y down).
public struct CharacterPose: Equatable, Sendable {
    /// The body transform, applied to the body, face and front layers about the box's bottom centre.
    public var tilt = 0.0
    public var lift = 0.0
    public var shiftX = 0.0
    public var scaleX = 1.0
    public var scaleY = 1.0

    public var eyes: String
    public var brows: String
    public var mouth: String
    public var gazeX = 0.0
    public var gazeY = 0.0
    public var eyeScale = 1.0
    /// Openness after blinks: 1 open, down to 0.06 mid-blink.
    public var open = 1.0
    public var browRaise = 0.0

    public var badge: CharacterStateSpec.Badge?
    /// Seconds into the badge's animation; the badge holds still when `badgeStatic`.
    public var badgeTime = 0.0
    public var badgeStatic = false
    public var badgeOpacity = 1.0

    public init(eyes: String, brows: String, mouth: String) {
        self.eyes = eyes; self.brows = brows; self.mouth = mouth
    }
}

/// The states' motion from `manifest.json`, as plain functions of time: the same inputs always give
/// the same pose, so a paused view, a test and a live frame agree. Blinks, glances and talking are
/// drawn from a per-character seed instead of a random generator.
public enum CharacterMotion {
    /// The pose at absolute time `time` (seconds; breathing and bobbing run on it, so they never
    /// jump at a state change) and `stateTime` seconds into the state (hops, sweeps and one-shots).
    /// `reduceMotion` gives the state's held pose; `blinks` false keeps the eyes open (stills).
    public static func pose(look id: CharacterLookID, state: CharacterState, time: Double, stateTime: Double,
                            seed: UInt32 = 0, reduceMotion: Bool = false, blinks: Bool = true,
                            userGaze: (x: Double, y: Double)? = nil, catalog: CharacterCatalog = .shared) -> CharacterPose {
        var state = state
        var stateTime = stateTime
        // A one-shot hands over to its next state once it has played.
        let spec0 = catalog.state(state)
        if let length = spec0.oneShot, stateTime >= length, let next = spec0.then.flatMap(CharacterState.init(rawValue:)) {
            state = next
            stateTime -= length
        }
        let look = catalog.look(id)
        let spec = catalog.state(state)
        let hold = reduceMotion ? catalog.manifest.reducedMotion.states[state.rawValue] : nil
        let dropped = reduceMotion ? Set(catalog.manifest.reducedMotion.drop) : []
        let phase = time + Double(seed % 997) * 0.37

        let face = resolveFace(look: look, spec: spec.face, catalog: catalog)
        var pose = CharacterPose(eyes: face.eyes, brows: face.brows, mouth: face.mouth)
        let f = spec.face
        pose.eyeScale = f.eyeScale ?? 1
        pose.browRaise = f.browRaise ?? 0
        var open = f.open ?? 1

        // Gaze.
        var gaze: (x: Double, y: Double) = (0, 0)
        switch f.gaze ?? .wander {
        case .wander: gaze = reduceMotion ? (0, 0) : wander(time: phase, seed: seed)
        case .user: gaze = userGaze ?? (0, 0)
        case .fixed(let x, let y): gaze = (x, y)
        case .scan(let xs, let y, let period, let sweep):
            let p = positiveMod(stateTime, period) / period
            if p < sweep { gaze = (lerp(xs[0], xs[1], p / sweep), y) }
            else { gaze = (lerp(xs[1], xs[0], smooth((p - sweep) / max(0.001, 1 - sweep))), y) }
        case .jiggle(let xs, let y, let period):
            gaze = ((xs[0] + xs[1]) / 2 + (xs[1] - xs[0]) / 2 * sin(2 * .pi * stateTime / period), y)
        }
        if let held = hold?.gaze, held.count == 2 { gaze = (held[0], held[1]) }
        else if reduceMotion, case .scan(let xs, let y, _, _) = f.gaze ?? .wander { gaze = ((xs[0] + xs[1]) / 2, y) }
        else if reduceMotion, case .jiggle(let xs, let y, _) = f.gaze ?? .wander { gaze = ((xs[0] + xs[1]) / 2, y) }
        pose.gazeX = gaze.x; pose.gazeY = gaze.y

        // Mouth over time.
        var talking: String?
        if let cycle = f.mouthCycle, !reduceMotion, face.mouth != "none" {
            let local = positiveMod(stateTime, cycle.period)
            pose.mouth = cycle.frames.last { $0.time <= local }?.mouth ?? pose.mouth
        }
        if let talk = f.talk, !reduceMotion {
            talking = talkShape(talk, stateTime: stateTime, seed: seed)
            pose.mouth = talking ?? (face.mouth == "none" ? "v_m" : face.mouth)
        }
        if let held = hold?.mouth { pose.mouth = held }

        // Blinks, unless the state or the eyes rule them out.
        let style = catalog.face.eyes[pose.eyes]
        if style?.closed == true { open = 1 }
        else if blinks, f.blink ?? true { open *= 1 - blinkAmount(time: phase, seed: seed) * 0.94 }
        pose.open = max(0.06, open)

        // Body.
        let b = spec.body
        pose.tilt = hold?.tilt ?? b.tilt ?? 0
        pose.lift = b.lift ?? 0
        let grow = b.grow ?? 1
        var sx = grow, sy = grow
        if let bob = b.bob, !dropped.contains("bob") { pose.lift += bob[0] * sin(2 * .pi * phase / bob[1]) }
        if let breath = b.breath, !dropped.contains("breath") {
            let v = breath[0] * sin(2 * .pi * phase / breath[1])
            sx *= 1 - v * 0.5; sy *= 1 + v
        }
        if let rock = b.rock, !dropped.contains("rock"), hold?.tilt == nil { pose.tilt += rock[0] * sin(2 * .pi * stateTime / rock[1]) }
        if let sway = b.swayX, !dropped.contains("sway_x") { pose.shiftX += sway[0] * sin(2 * .pi * stateTime / sway[1]) }
        if let nod = b.nod, !dropped.contains("nod") { pose.lift -= nod[0] * pow(max(0, sin(2 * .pi * stateTime / nod[1])), 6) }
        if let on = b.nodOn, talking == on, !dropped.contains("nod") { pose.lift -= 0.0075 }
        if let taps = b.taps, !dropped.contains("taps") {
            let p = positiveMod(stateTime, taps.period) / taps.period
            let k = p < 0.35 ? sin(.pi * p / 0.35) : 0
            sx *= 1 + (taps.squash[0] - 1) * k; sy *= 1 + (taps.squash[1] - 1) * k
        }
        if let hops = b.hops, !dropped.contains("hops") {
            let local = hops.period.map { positiveMod(stateTime, $0) } ?? stateTime
            for hop in hops.at where hop.count == 3 {
                let h = catalog.manifest.hopCurve.sample((local - hop[0]) / hop[1])
                pose.lift += h.lift * hop[2]; sx *= h.sx; sy *= h.sy
            }
        }
        if let shake = b.shake, !dropped.contains("shake") {
            let p = positiveMod(stateTime, shake.period)
            if p < shake.length { pose.shiftX += sin(2 * .pi * shake.freq * p) * shake.amp * (1 - p / shake.length) }
        }
        pose.scaleX = sx; pose.scaleY = sy

        pose.badge = spec.badge
        pose.badgeTime = stateTime
        pose.badgeStatic = reduceMotion && catalog.manifest.reducedMotion.badgesStatic
        return pose
    }

    /// The state's held pose with open eyes: for a paused view, a still render or Reduce Motion.
    public static func still(look: CharacterLookID, state: CharacterState, stateTime: Double = 0,
                             catalog: CharacterCatalog = .shared) -> CharacterPose {
        pose(look: look, state: state, time: 0, stateTime: stateTime, reduceMotion: true, blinks: false, catalog: catalog)
    }

    /// Part way from `a` to `b` (k 0 to 1): numbers ease, the face's shapes switch half way and a
    /// new badge fades in.
    public static func blend(_ a: CharacterPose, _ b: CharacterPose, _ k: Double) -> CharacterPose {
        let k = smooth(k)
        guard k < 1 else { return b }
        var p = k < 0.5 ? a : b
        p.tilt = lerp(a.tilt, b.tilt, k); p.lift = lerp(a.lift, b.lift, k); p.shiftX = lerp(a.shiftX, b.shiftX, k)
        p.scaleX = lerp(a.scaleX, b.scaleX, k); p.scaleY = lerp(a.scaleY, b.scaleY, k)
        p.gazeX = lerp(a.gazeX, b.gazeX, k); p.gazeY = lerp(a.gazeY, b.gazeY, k)
        p.eyeScale = lerp(a.eyeScale, b.eyeScale, k); p.open = lerp(a.open, b.open, k)
        p.browRaise = lerp(a.browRaise, b.browRaise, k)
        p.badge = b.badge; p.badgeTime = b.badgeTime; p.badgeStatic = b.badgeStatic
        p.badgeOpacity = a.badge == b.badge ? b.badgeOpacity : k * b.badgeOpacity
        return p
    }

    /// The look's eyes, brows and mouth in a state, in the README's order.
    public static func resolveFace(look: CharacterLookSpec, spec f: CharacterStateSpec.Face,
                                   catalog: CharacterCatalog = .shared) -> (eyes: String, brows: String, mouth: String) {
        var eyes = look.eyes, brows = look.brows, mouth = look.mouth
        if let e = f.eyes { eyes = e }
        if let e = f.eyesIfLidded, catalog.face.eyes[eyes]?.lidded == true { eyes = e }
        if let m = f.mouth, mouth != "none" { mouth = m }
        if let map = f.mouthMap { mouth = map[mouth] ?? mouth }
        if let cycle = f.mouthCycle, mouth != "none", let first = cycle.frames.first { mouth = first.mouth }
        if let b = f.brows { brows = b }
        if let b = f.browsIfNone, brows == "none" { brows = b }
        if let map = f.browsMap { brows = map[brows] ?? brows }
        return (eyes, brows, mouth)
    }

    // MARK: Badges

    /// The whole badge's motion at `time` seconds into it: an offset in badge units, a scale, a
    /// rotation in degrees and an opacity.
    public static func badgeMotion(_ animate: String, time t: Double, isStatic: Bool) -> (dx: Double, dy: Double, scale: Double, rotation: Double, opacity: Double) {
        switch animate {
        case "pulse_ring": return (0, 0, isStatic ? 1 : 1 + 0.06 * sin(t * 4), 0, 1)
        case "wiggle": return (0, 0, 1, isStatic ? 0 : 12 * sin(2 * .pi * t / 0.9), 1)
        case "drift":
            let p = isStatic ? 0.4 : positiveMod(t, 2.6) / 2.6
            return (p * 0.8 + sin(p * 6) * 0.1, -p * 1.4, 0.8 + p * 0.6, 0, isStatic ? 0.85 : sin(p * .pi) * 0.9)
        default: return (0, 0, 1, 0, 1)
        }
    }

    /// One part's own motion inside the badge: the dots fade in turn, the ticks hop in turn.
    public static func badgePartMotion(_ animate: String, part: FacePart, index: Int, time t: Double, isStatic: Bool) -> (dy: Double, opacity: Double) {
        guard !isStatic else { return (0, 1) }
        switch animate {
        case "pulse":
            let i = Double(index / 2)
            return (0, 0.25 + 0.75 * min(1, max(0, sin(t * 2.6 - i * 0.9) * 1.4)))
        case "hop":
            guard case .rrect(_, _, _, _, let hop?) = part else { return (0, 1) }
            return (-max(0, sin(t * 9 - Double(hop) * 0.9)) * 0.36, 1)
        default: return (0, 1)
        }
    }

    // MARK: Seeded life

    /// 0 open to 1 shut. One blink every 3 to 5 s (a slot of 4 s, placed anywhere in its middle
    /// second), some of them doubled: close in 70 ms, hold 40 ms, open in 120 ms.
    public static func blinkAmount(time t: Double, seed: UInt32) -> Double {
        let slot = 4.0
        let k = Int(floor(t / slot))
        var amount = 0.0
        for s in [k - 1, k] {
            let start = Double(s) * slot + 1.5 + random(seed, s, 1) * 1.0
            amount = max(amount, blinkCurve(t - start))
            if random(seed, s, 2) < 0.22 { amount = max(amount, blinkCurve(t - start - 0.31)) }
        }
        return amount
    }

    static func blinkCurve(_ e: Double) -> Double {
        if e < 0 { return 0 }
        if e < 0.07 { return e / 0.07 }
        if e < 0.11 { return 1 }
        if e < 0.23 { return 1 - (e - 0.11) / 0.12 }
        return 0
    }

    /// Idle glances: a new target every 1 to 3.5 s, often somewhere else, sometimes back to
    /// the middle, eased over 0.3 s.
    public static func wander(time t: Double, seed: UInt32) -> (x: Double, y: Double) {
        let slot = 2.25
        func change(_ k: Int) -> Double { Double(k) * slot + (random(seed, k, 3) - 0.5) * 1.2 }
        func target(_ k: Int) -> (x: Double, y: Double) {
            if random(seed, k, 4) < 0.55 {
                return (lerp(-0.85, 0.85, random(seed, k, 5)), lerp(-0.5, 0.45, random(seed, k, 6)))
            }
            return (lerp(-0.15, 0.15, random(seed, k, 5)), lerp(-0.1, 0.1, random(seed, k, 6)))
        }
        var k = Int(floor(t / slot))
        if t < change(k) { k -= 1 }
        let a = target(k - 1), b = target(k)
        let e = smooth((t - change(k)) / 0.3)
        return (lerp(a.x, b.x, e), lerp(a.y, b.y, e))
    }

    /// The talking mouth: bursts of quick shapes with pauses between them; nil while paused.
    static func talkShape(_ talk: CharacterStateSpec.Talk, stateTime: Double, seed: UInt32) -> String? {
        guard !talk.shapes.isEmpty, talk.burst.count == 2, talk.pause.count == 2, talk.step.count == 2 else { return nil }
        let cycle = (talk.burst[0] + talk.burst[1]) / 2 + (talk.pause[0] + talk.pause[1]) / 2
        let k = Int(floor(stateTime / cycle))
        let within = stateTime - Double(k) * cycle
        let burst = min(lerp(talk.burst[0], talk.burst[1], random(seed, k, 7)), cycle - talk.pause[0])
        guard within < burst else { return nil }
        let step = (talk.step[0] + talk.step[1]) / 2
        let j = Int(floor(within / step))
        let n = talk.shapes.count
        var index = Int(random(seed, k, 8) * Double(n)) % n
        if n > 1 { for i in 0..<j { index = (index + 1 + Int(random(seed, k * 64 + i, 9) * Double(n - 1)) % (n - 1)) % n } }
        return talk.shapes[index]
    }

    /// A stable number in 0..<1 for (seed, slot, salt).
    static func random(_ seed: UInt32, _ slot: Int, _ salt: UInt64) -> Double {
        var z = UInt64(seed) &* 0x9E37_79B9_7F4A_7C15 &+ UInt64(bitPattern: Int64(slot)) &* 0xBF58_476D_1CE4_E5B9 &+ salt &* 0x94D0_49BB_1331_11EB
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        z ^= z >> 31
        return Double(z >> 11) / Double(1 << 53)
    }

    static func lerp(_ a: Double, _ b: Double, _ k: Double) -> Double { a + (b - a) * k }
    static func smooth(_ x: Double) -> Double {
        let clamped = min(1, max(0, x))
        return clamped * clamped * (3 - 2 * clamped)
    }

    static func positiveMod(_ a: Double, _ m: Double) -> Double {
        let remainder = a.truncatingRemainder(dividingBy: m)
        return remainder >= 0 ? remainder : remainder + m
    }
}

extension CharacterLookID {
    /// A stable seed for a character's blinks and glances, so bots side by side do not blink together.
    public static func seed(_ text: String) -> UInt32 {
        var hash: UInt32 = 2_166_136_261
        for byte in text.utf8 { hash = (hash ^ UInt32(byte)) &* 16_777_619 }
        return hash
    }
}
