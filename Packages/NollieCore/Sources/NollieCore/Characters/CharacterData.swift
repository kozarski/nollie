import Foundation

/// The character package's two data files, decoded: `manifest.json` (looks, states, motion) and
/// `face.json` (the vector face parts). Both ship in this package's resources; the images are in
/// the apps' asset catalogs. Coordinates are fractions of a look's square frame (0 to 1, y down).
public final class CharacterCatalog: Sendable {
    public static let shared = CharacterCatalog()

    public let manifest: CharacterManifest
    public let face: FaceCatalogue
    private let looks: [CharacterLookID: CharacterLookSpec]

    public init(manifest: CharacterManifest, face: FaceCatalogue) {
        self.manifest = manifest
        self.face = face
        var looks: [CharacterLookID: CharacterLookSpec] = [:]
        for spec in manifest.looks { if let id = CharacterLookID(rawValue: spec.id) { looks[id] = spec } }
        self.looks = looks
    }

    private convenience init() {
        do {
            try self.init(manifestData: Self.resource("manifest"), faceData: Self.resource("face"))
        } catch {
            fatalError("The character package is missing or unreadable: \(error)")
        }
    }

    public convenience init(manifestData: Data, faceData: Data) throws {
        // Plain keys: a snake-case strategy would also rewrite dictionary keys such as "v_m".
        let decoder = JSONDecoder()
        let manifest = try decoder.decode(CharacterManifest.self, from: manifestData)
        let face = try decoder.decode(FaceFile.self, from: faceData).catalogue
        self.init(manifest: manifest, face: face)
    }

    static func resource(_ name: String) throws -> Data {
        guard let url = Bundle.module.url(forResource: name, withExtension: "json") else {
            throw CocoaError(.fileNoSuchFile)
        }
        return try Data(contentsOf: url)
    }

    /// Every look id the app knows is in the package (checked by a test).
    public func look(_ id: CharacterLookID) -> CharacterLookSpec {
        looks[id] ?? manifest.looks[0]
    }

    public func state(_ state: CharacterState) -> CharacterStateSpec {
        manifest.states[state.rawValue] ?? manifest.states["idle"]!
    }

    /// A colour token's hex ("ink", "glint"…); `coat`, `fg` and `bg` are resolved by the caller.
    public func colour(_ token: String) -> String? { manifest.colours[token] }

    private struct FaceFile: Decodable { var catalogue: FaceCatalogue }
}

// MARK: - manifest.json

public struct CharacterManifest: Decodable, Sendable {
    public var format: String
    public var version: Int
    public var defaultLook: String
    public var tiersPt: [Int]
    public var scales: [Int]
    public var masterPx: Int
    public var colours: [String: String]
    /// `light` and `dark`, each with `bg`, `fg` and `muted`.
    public var themes: [String: [String: String]]
    public var states: [String: CharacterStateSpec]
    public var hopCurve: HopCurve
    public var reducedMotion: ReducedMotion
    public var looks: [CharacterLookSpec]

    private enum CodingKeys: String, CodingKey {
        case format, version, scales, colours, themes, states, looks
        case defaultLook = "default_look", tiersPt = "tiers_pt", masterPx = "master_px"
        case hopCurve = "hop_curve", reducedMotion = "reduced_motion"
    }
}

public struct CharacterLookSpec: Decodable, Sendable {
    public var id: String
    public var name: String
    public var shape: String
    /// The coat, "#RRGGBB".
    public var colour: String
    public var eyes: String
    public var brows: String
    public var mouth: String
    public var extras: [String]
    public var main: Bool
    public var face: FaceAnchors
    /// The character's bounding box in the frame: [x0, y0, x1, y1].
    public var box: [Double]
    public var badgeRadius: Double
    /// `corner`, `thought` and `side`, each [x, y].
    public var badgeAnchors: [String: [Double]]
    public var files: Files

    private enum CodingKeys: String, CodingKey {
        case id, name, shape, colour, eyes, brows, mouth, extras, main, face, box, files
        case badgeRadius = "badge_radius", badgeAnchors = "badge_anchors"
    }

    public struct FaceAnchors: Decodable, Sendable {
        /// Screen-left eye first.
        public var eyes: [[Double]]
        public var unit: Double
        public var mouth: [Double]
    }

    public struct Files: Decodable, Sendable {
        /// `body`, and `front` when the look has pieces over the face.
        public var master: [String: String]
        public var tiers: [String: Tier]
        public var glyph: String
        public var avatar512: String

        private enum CodingKeys: String, CodingKey { case master, tiers, glyph, avatar512 = "avatar_512" }

        public struct Tier: Decodable, Sendable {
            public var px: Int
            public var body: String
            public var front: String?
        }
    }

    /// The box's height as a fraction of the frame (H in the README).
    public var height: Double { box[3] - box[1] }
    /// The bottom centre of the box, the pivot for the body's transforms.
    public var pivot: (x: Double, y: Double) { ((box[0] + box[2]) / 2, box[3]) }
    /// Whether any tier has a front layer (none of the starter looks do yet).
    public var hasFront: Bool { files.master["front"] != nil }
}

public struct CharacterStateSpec: Decodable, Sendable {
    public var label: String
    public var caption: String
    /// Seconds a one-shot plays before `then` takes over.
    public var oneShot: Double?
    public var then: String?
    public var face: Face
    public var body: Body
    public var badge: Badge?

    private enum CodingKeys: String, CodingKey { case label, caption, then, face, body, badge, oneShot = "one_shot" }

    public struct Face: Decodable, Sendable {
        public var gaze: Gaze?
        public var eyeScale: Double?
        public var open: Double?
        public var browRaise: Double?
        public var blink: Bool?
        public var eyes: String?
        public var eyesIfLidded: String?
        public var mouth: String?
        public var mouthMap: [String: String]?
        public var mouthCycle: MouthCycle?
        public var talk: Talk?
        public var brows: String?
        public var browsIfNone: String?
        public var browsMap: [String: String]?

        private enum CodingKeys: String, CodingKey {
            case gaze, open, blink, eyes, mouth, talk, brows
            case eyeScale = "eye_scale", browRaise = "brow_raise", eyesIfLidded = "eyes_if_lidded", mouthMap = "mouth_map"
            case mouthCycle = "mouth_cycle", browsIfNone = "brows_if_none", browsMap = "brows_map"
        }
    }

    public enum Gaze: Decodable, Sendable, Equatable {
        case wander
        case user
        case fixed(x: Double, y: Double)
        case scan(x: [Double], y: Double, period: Double, sweep: Double)
        case jiggle(x: [Double], y: Double, period: Double)

        private struct Sweep: Decodable { var x: [Double]; var y: Double; var period: Double; var sweep: Double? }
        private struct Moves: Decodable { var scan: Sweep?; var jiggle: Sweep? }

        public init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if let word = try? c.decode(String.self) {
                self = word == "user" ? .user : .wander
            } else if let xy = try? c.decode([Double].self), xy.count == 2 {
                self = .fixed(x: xy[0], y: xy[1])
            } else {
                let m = try c.decode(Moves.self)
                if let s = m.scan { self = .scan(x: s.x, y: s.y, period: s.period, sweep: s.sweep ?? 1) }
                else if let j = m.jiggle { self = .jiggle(x: j.x, y: j.y, period: j.period) }
                else { self = .wander }
            }
        }
    }

    public struct MouthCycle: Decodable, Sendable {
        public var period: Double
        /// (start time, mouth), in order.
        public var frames: [(time: Double, mouth: String)]

        private enum Keys: String, CodingKey { case period, frames }
        private struct Frame: Decodable {
            var time: Double, mouth: String
            init(from decoder: Decoder) throws {
                var c = try decoder.unkeyedContainer()
                time = try c.decode(Double.self); mouth = try c.decode(String.self)
            }
        }
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Keys.self)
            period = try c.decode(Double.self, forKey: .period)
            frames = try c.decode([Frame].self, forKey: .frames).map { ($0.time, $0.mouth) }
        }
    }

    public struct Talk: Decodable, Sendable {
        public var shapes: [String]
        public var step: [Double]
        public var burst: [Double]
        public var pause: [Double]
    }

    public struct Body: Decodable, Sendable {
        public var bob: [Double]?
        public var breath: [Double]?
        public var tilt: Double?
        public var lift: Double?
        public var grow: Double?
        public var rock: [Double]?
        public var swayX: [Double]?
        public var nod: [Double]?
        public var nodOn: String?
        public var taps: Taps?
        public var hops: Hops?
        public var shake: Shake?

        private enum CodingKeys: String, CodingKey {
            case bob, breath, tilt, lift, grow, rock, nod, taps, hops, shake
            case swayX = "sway_x", nodOn = "nod_on"
        }

        public struct Taps: Decodable, Sendable { public var period: Double; public var squash: [Double] }
        public struct Hops: Decodable, Sendable {
            /// Nil: plays once.
            public var period: Double?
            /// [start, length, height] each.
            public var at: [[Double]]
        }
        public struct Shake: Decodable, Sendable { public var period: Double; public var length: Double; public var amp: Double; public var freq: Double }
    }

    public struct Badge: Decodable, Sendable, Equatable {
        public var kind: String
        public var anchor: String
        public var animate: String
    }
}

public struct HopCurve: Decodable, Sendable {
    /// [phase, lift, sx, sy] rows, phase rising from 0 to 1.
    public var rows: [[Double]]

    /// The hop at phase p (0 to 1): lift as a fraction of the hop height and the squash.
    public func sample(_ p: Double) -> (lift: Double, sx: Double, sy: Double) {
        guard p >= 0, p < 1, rows.count > 1 else { return (0, 1, 1) }
        var i = 0
        while i < rows.count - 2, rows[i + 1][0] <= p { i += 1 }
        let a = rows[i], b = rows[i + 1]
        let k = b[0] > a[0] ? (p - a[0]) / (b[0] - a[0]) : 0
        func mix(_ j: Int) -> Double { a[j] + (b[j] - a[j]) * k }
        return (mix(1), mix(2), mix(3))
    }
}

public struct ReducedMotion: Decodable, Sendable {
    public var crossfade: Double
    public var drop: [String]
    public var badgesStatic: Bool
    public var states: [String: Hold]

    private enum CodingKeys: String, CodingKey { case crossfade, drop, states, badgesStatic = "badges_static" }

    /// A state's held pose under Reduce Motion.
    public struct Hold: Decodable, Sendable {
        public var gaze: [Double]?
        public var mouth: String?
        public var tilt: Double?
    }
}

// MARK: - face.json

public struct FaceCatalogue: Decodable, Sendable {
    public var mouthScale: Double
    public var mouthScaleFangs: Double
    public var eyes: [String: EyeStyle]
    public var brows: [String: BrowStyle]
    public var mouths: [String: [FacePart]]
    public var badges: [String: [FacePart]]

    private enum CodingKeys: String, CodingKey {
        case eyes, brows, mouths, badges, mouthScale = "mouth_scale", mouthScaleFangs = "mouth_scale_fangs"
    }

    public struct EyeStyle: Decodable, Sendable {
        public var left: [FacePart]
        public var right: [FacePart]
        /// Shut eyes (happy, sleepy): no blinks, no openness.
        public var closed: Bool
        /// A flat lid line on top: brows sit higher, and some states open these eyes.
        public var lidded: Bool
    }

    public struct BrowStyle: Decodable, Sendable {
        public var left: [FacePart]
        public var right: [FacePart]
        public var leftLidded: [FacePart]
        public var rightLidded: [FacePart]

        private enum CodingKeys: String, CodingKey { case left, right, leftLidded = "left_lidded", rightLidded = "right_lidded" }
    }
}

/// One plain shape of a face or badge, in that layer's units (see the package README).
public enum FacePart: Decodable, Sendable {
    case ellipse(center: [Double], radii: [Double], fill: String, pupil: Bool)
    case poly(points: [[Double]], fill: String, outline: (width: Double, color: String)?, pupil: Bool)
    case line(points: [[Double]], width: Double, color: String)
    /// `gap`: the arc left out, in degrees from +x toward screen-down.
    case ring(center: [Double], radius: Double, width: Double, color: String, gap: [Double]?)
    case rrect(center: [Double], size: [Double], radius: Double, fill: String, hop: Int?)

    private enum Keys: String, CodingKey { case t, c, r, fill, pupil, pts, outline, w, color, gap, size, radius, hop }
    private struct Outline: Decodable { var w: Double; var color: String }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        let pupil = try c.decodeIfPresent(Bool.self, forKey: .pupil) ?? false
        switch try c.decode(String.self, forKey: .t) {
        case "ellipse":
            self = .ellipse(center: try c.decode([Double].self, forKey: .c), radii: try c.decode([Double].self, forKey: .r),
                            fill: try c.decode(String.self, forKey: .fill), pupil: pupil)
        case "poly":
            let o = try c.decodeIfPresent(Outline.self, forKey: .outline)
            self = .poly(points: try c.decode([[Double]].self, forKey: .pts), fill: try c.decode(String.self, forKey: .fill),
                         outline: o.map { ($0.w, $0.color) }, pupil: pupil)
        case "line":
            self = .line(points: try c.decode([[Double]].self, forKey: .pts), width: try c.decode(Double.self, forKey: .w),
                         color: try c.decode(String.self, forKey: .color))
        case "ring":
            self = .ring(center: try c.decode([Double].self, forKey: .c), radius: try c.decode(Double.self, forKey: .r),
                         width: try c.decode(Double.self, forKey: .w), color: try c.decode(String.self, forKey: .color),
                         gap: try c.decodeIfPresent([Double].self, forKey: .gap))
        case "rrect":
            self = .rrect(center: try c.decode([Double].self, forKey: .c), size: try c.decode([Double].self, forKey: .size),
                          radius: try c.decode(Double.self, forKey: .radius), fill: try c.decode(String.self, forKey: .fill),
                          hop: try c.decodeIfPresent(Int.self, forKey: .hop))
        case let other:
            throw DecodingError.dataCorruptedError(forKey: .t, in: c, debugDescription: "Unknown face part \(other)")
        }
    }

    public var isPupil: Bool {
        switch self {
        case .ellipse(_, _, _, let p), .poly(_, _, _, let p): return p
        default: return false
        }
    }
}
