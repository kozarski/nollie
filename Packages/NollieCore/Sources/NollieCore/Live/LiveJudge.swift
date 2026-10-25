/// Once a second, decides how the link to a viewer is doing and which quality level to send.
/// It reads the door's send gate (frames sent and held back, bytes the connection took and still
/// has waiting) and whether the viewer's report arrived. No clock inside: the same seconds always
/// give the same verdicts.
public struct LiveJudge: Sendable, Equatable {
    public struct Second: Sendable, Equatable {
        public var sent: Int
        public var withheld: Int
        public var bytesTaken: Int
        public var bytesWaiting: Int
        /// A report from the viewer arrived this second.
        public var heard: Bool

        public init(sent: Int, withheld: Int, bytesTaken: Int, bytesWaiting: Int, heard: Bool) {
            self.sent = sent; self.withheld = withheld; self.bytesTaken = bytesTaken; self.bytesWaiting = bytesWaiting
            self.heard = heard
        }

        /// At least a fifth of the frames offered were held back.
        public var isShort: Bool { withheld >= 2 && withheld * 5 >= sent + withheld }
        /// Nothing moved, something is waiting, and the viewer said nothing.
        public var isDead: Bool { bytesTaken == 0 && bytesWaiting > 0 && !heard }
        public var isClean: Bool { !isShort && !isDead }
    }

    public struct Verdict: Sendable, Equatable {
        public var state: LiveWire.LinkState
        public var level: Int
        public var levelChanged: Bool
        /// The link just came back from a stall: start the picture again from a keyframe.
        public var needsKeyframe: Bool

        public init(state: LiveWire.LinkState, level: Int, levelChanged: Bool, needsKeyframe: Bool) {
            self.state = state; self.level = level; self.levelChanged = levelChanged; self.needsKeyframe = needsKeyframe
        }
    }

    static let window = 4
    static let shortToFallBehind = 2
    static let deadToStall = 2
    static let cleanToCatchUp = 4
    static let secondsBetweenSteps = 3
    static let cleanToStepUp = 15

    public private(set) var state: LiveWire.LinkState = .fine
    public private(set) var level: Int
    private var recentShort: [Bool] = []
    private var deadRun = 0
    private var cleanRun = 0
    /// Clean seconds in a row since the level last changed.
    private var calmRun = 0
    private var sinceStep = 0
    private var roughSinceStep = false

    public init(level: Int = LiveQuality.best) {
        self.level = min(max(level, LiveQuality.best), LiveQuality.lightest)
    }

    /// The best level the viewer's device allows: Low Power Mode or a warm device keeps it light.
    public static func floor(for limit: LiveWire.Limit) -> Int {
        switch limit {
        case .none: LiveQuality.best
        case .low: 2
        case .lowest: LiveQuality.lightest
        }
    }

    public mutating func judge(_ second: Second, limit: LiveWire.Limit = .none) -> Verdict {
        let before = level
        recentShort.append(second.isShort)
        if recentShort.count > Self.window { recentShort.removeFirst() }
        deadRun = second.isDead ? deadRun + 1 : 0
        cleanRun = second.isClean ? cleanRun + 1 : 0
        calmRun = second.isClean ? calmRun + 1 : 0

        var needsKeyframe = false
        switch state {
        case .fine:
            if deadRun >= Self.deadToStall {
                stall()
            } else if recentShort.count(where: { $0 }) >= Self.shortToFallBehind {
                state = .behind
                step()
            }
        case .behind:
            if deadRun >= Self.deadToStall {
                stall()
            } else if cleanRun >= Self.cleanToCatchUp {
                state = .fine
            } else {
                // Still behind a while after the last step, and not because of the clean
                // seconds it takes to catch up: lighten again.
                sinceStep += 1
                if !second.isClean { roughSinceStep = true }
                if sinceStep >= Self.secondsBetweenSteps && roughSinceStep { step() }
            }
        case .stalled:
            if !second.isDead {
                state = .behind
                needsKeyframe = true
                sinceStep = 0
                roughSinceStep = false
            }
        }

        let floor = Self.floor(for: limit)
        if level < floor {
            level = floor
            calmRun = 0
        } else if calmRun >= Self.cleanToStepUp && level > floor {
            level -= 1
            calmRun = 0
        }
        return Verdict(state: state, level: level, levelChanged: level != before, needsKeyframe: needsKeyframe)
    }

    private mutating func stall() {
        state = .stalled
        step()
    }

    private mutating func step() {
        level = min(level + 1, LiveQuality.lightest)
        sinceStep = 0
        roughSinceStep = false
        calmRun = 0
    }
}
