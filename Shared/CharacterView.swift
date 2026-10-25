import SwiftUI
import NollieCore

/// A Nollie character: the look's rendered body with its face drawn live as vectors on top, plus
/// the state's badge. The body image is chosen by size (tiers at 28, 52 and 124 pt, the 1024 px
/// master beyond that). While visible it animates at up to 30 fps, and a state change eases from
/// the previous pose. With Reduce Motion each state holds a still pose (blinks and gaze remain,
/// changes crossfade). Off screen, in a hidden window, with motion set to Still, or with
/// `animated` off, it draws the still pose and costs nothing.
public struct CharacterView: View {
    public var look: CharacterLookID
    public var state: CharacterState
    public var size: CGFloat
    /// Varies the blinks and glances, so characters side by side do not blink together.
    public var seed: UInt32
    /// False: always the still pose (stacks of small faces, pictures for notifications).
    public var animated: Bool
    /// On the Mac an idle character rests until something is working (#248); a short, authored
    /// moment such as the welcome intro opts out.
    public var restsWhenIdle: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.displayScale) private var displayScale
    @Environment(\.scenePhase) private var scenePhase
    /// Whether this window is somewhere a person can see it (Mac only; always true elsewhere).
    @Environment(\.botsLive) private var windowLive
    @AppStorage(CharacterView.styleKey) private var style = "lively"
    #if os(macOS)
    @AppStorage(BotAmbient.animateKey) private var animateSetting = true
    #endif

    @State private var onScreen = false
    /// The state `since` belongs to. It lags `state` by one update: the frame drawn before the
    /// change is handled still knows where the old state was.
    @State private var current: CharacterState
    @State private var since = Date()
    /// The state before, when it began and ended, and whether it was moving: the new state eases
    /// in from where the old one is, worked out again (poses are functions of time).
    @State private var previous: CharacterState?
    @State private var previousSince = Date.distantPast
    @State private var previousMoving = false
    @State private var changedAt = Date.distantPast
    /// A one-shot that has played while held: the still pose moves on to the next state.
    @State private var oneShotOver = false

    /// Settings › Bots: how much the characters move ("lively", "calm" or "still").
    public static let styleKey = "bots.motionStyle"
    /// How long a state change eases over.
    static let blendTime = 0.35

    public init(look: CharacterLookID, state: CharacterState = .idle, size: CGFloat, seed: UInt32 = 0,
                animated: Bool = true, restsWhenIdle: Bool = true) {
        self.look = look
        self.state = state
        self.size = size
        self.seed = seed
        self.animated = animated
        self.restsWhenIdle = restsWhenIdle
        _current = State(initialValue: state)
    }

    private var ambient: BotAmbient { BotAmbient.shared }

    /// Whether frames are drawn at all right now (Reduce Motion included: its blinks need them).
    private var moving: Bool {
        guard animated, onScreen, windowLive, style != "still", scenePhase != .background, !ambient.displayAsleep else { return false }
        #if os(macOS)
        // On the Mac an idle character holds still unless something is working somewhere (#248).
        return animateSetting && (state != .idle || ambient.anyWorking || !restsWhenIdle)
        #else
        return true
        #endif
    }

    public var body: some View {
        let moving = moving
        let crossfade = CharacterCatalog.shared.manifest.reducedMotion.crossfade
        Group {
            if moving && !reduceMotion {
                TimelineView(.animation(minimumInterval: 1 / 30)) { timeline in
                    canvas(pose: livePose(at: timeline.date))
                }
            } else if moving {
                // Held poses, but the eyes still blink and follow: a slower clock is plenty.
                TimelineView(.animation(minimumInterval: 1 / 15)) { timeline in
                    canvas(pose: heldPose(at: timeline.date))
                }
                .id(stillKey)
                .transition(.opacity)
            } else {
                stillCharacter
                    .id(stillKey)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: crossfade), value: moving && !reduceMotion ? "" : stillKey)
        .frame(width: size, height: size)
        .onAppear { onScreen = true }
        .onDisappear { onScreen = false }
        .onChange(of: state) { old, new in
            let now = Date()
            previous = old
            previousSince = since
            previousMoving = moving && !reduceMotion
            changedAt = now
            since = now
            current = new
            oneShotOver = false
        }
        // A one-shot (done) held still: its pose for its length, then the next state's.
        .task(id: "\(state.rawValue)-\(since.timeIntervalSinceReferenceDate)") {
            guard let length = CharacterCatalog.shared.state(state).oneShot else { return }
            try? await Task.sleep(for: .seconds(length))
            oneShotOver = true
        }
        .accessibilityHidden(true)
    }

    private var stillKey: String { "\(look.rawValue)-\(state.rawValue)-\(oneShotOver)" }

    private var stillPose: CharacterPose {
        let length = CharacterCatalog.shared.state(state).oneShot ?? 0
        return CharacterMotion.still(look: look, state: state, stateTime: oneShotOver ? length : 0)
    }

    @ViewBuilder private var stillCharacter: some View {
        #if os(macOS)
        if let image = stillImage {
            let side = size * (1 + CharacterDrawing.overdraw * 2)
            Image(decorative: image, scale: max(1, displayScale))
                .resizable()
                .frame(width: side, height: side)
                .allowsHitTesting(false)
        } else {
            canvas(pose: stillPose)
        }
        #else
        canvas(pose: stillPose)
        #endif
    }

    #if os(macOS)
    /// A still Canvas can leave a failed GPU surface in a sidebar row. Render the same drawing
    /// once to a bitmap; moving characters keep their live Canvas and never enter this cache.
    @MainActor private static let stillImages: NSCache<NSString, CGImage> = {
        let cache = NSCache<NSString, CGImage>()
        cache.countLimit = 128
        cache.totalCostLimit = 16 * 1024 * 1024
        return cache
    }()

    private var stillImage: CGImage? {
        let key = "\(stillKey)|\(size)|\(displayScale)|\(colorScheme == .dark ? "dark" : "light")" as NSString
        if let image = Self.stillImages.object(forKey: key) { return image }
        let renderer = ImageRenderer(content: canvas(pose: stillPose))
        let scale = max(1, displayScale)
        var bitmap: CGImage?
        // Drawing into a bitmap CGContext avoids the GPU surface used by renderer.cgImage,
        // which can fail in the same way as the displayed Canvas.
        renderer.render(rasterizationScale: scale) { bounds, draw in
            guard let context = CGContext(data: nil,
                                          width: Int(ceil(bounds.width * scale)),
                                          height: Int(ceil(bounds.height * scale)),
                                          bitsPerComponent: 8, bytesPerRow: 0,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
            context.scaleBy(x: scale, y: scale)
            draw(context)
            bitmap = context.makeImage()
        }
        guard let image = bitmap else { return nil }
        Self.stillImages.setObject(image, forKey: key, cost: image.bytesPerRow * image.height)
        return image
    }
    #endif

    private func heldPose(at date: Date) -> CharacterPose {
        let length = CharacterCatalog.shared.state(state).oneShot ?? 0
        return CharacterMotion.pose(look: look, state: state, time: date.timeIntervalSinceReferenceDate,
                                    stateTime: oneShotOver ? length : 0, seed: seed, reduceMotion: true, userGaze: userGaze)
    }

    private func motion(_ state: CharacterState, at date: Date, since: Date) -> CharacterPose {
        var pose = CharacterMotion.pose(look: look, state: state, time: date.timeIntervalSinceReferenceDate,
                                        stateTime: date.timeIntervalSince(since), seed: seed, userGaze: userGaze)
        if style == "calm" { pose = CharacterMotion.blend(CharacterMotion.still(look: look, state: state), pose, 0.5) }
        return pose
    }

    private func livePose(at date: Date) -> CharacterPose {
        // The change is not handled yet: the new state starts now, from the old one's pose.
        let pending = current != state
        var pose = motion(state, at: date, since: pending ? date : since)
        let from: (state: CharacterState, since: Date, moving: Bool, k: Double)?
        if pending {
            from = (current, since, true, 0)
        } else if let previous, date.timeIntervalSince(changedAt) < Self.blendTime {
            from = (previous, previousSince, previousMoving, date.timeIntervalSince(changedAt) / Self.blendTime)
        } else {
            from = nil
        }
        if let from {
            let old = from.moving ? motion(from.state, at: date, since: from.since) : CharacterMotion.still(look: look, state: from.state)
            pose = CharacterMotion.blend(old, pose, from.k)
        }
        // Settings › Bots › Tilt: a big enough character leans a little with the phone.
        if size >= 32 { pose.tilt += Double(ambient.tilt.x) * 4 }
        return pose
    }

    /// Where a listening or talking character looks: the phone's lean and the last scroll.
    private var userGaze: (x: Double, y: Double) {
        guard ambient.enabled else { return (0, 0) }
        return (max(-1, min(1, Double(ambient.tilt.x + ambient.gaze.x))), max(-1, min(1, Double(ambient.tilt.y + ambient.gaze.y))))
    }

    private func canvas(pose: CharacterPose) -> some View {
        // Hops rise a little above the frame: the canvas reaches past it so nothing is cut off.
        let pad = size * CharacterDrawing.overdraw
        let look = look, scheme = colorScheme, size = size, pixel = 1 / max(1, displayScale)
        return Canvas(opaque: false, rendersAsynchronously: false) { ctx, _ in
            CharacterDrawing.draw(in: &ctx, frame: CGRect(x: pad, y: pad, width: size, height: size),
                                  look: look, pose: pose, scheme: scheme, pixel: pixel)
        }
        .frame(width: size + pad * 2, height: size + pad * 2)
        .allowsHitTesting(false)
    }
}

/// The look's one-colour outline with eye holes, for the menu bar and tab bar (16 to 32 pt).
/// Tinted by the foreground style.
public struct CharacterGlyph: View {
    public var look: CharacterLookID
    public init(look: CharacterLookID = .main) { self.look = look }
    public var body: some View {
        Image(CharacterDrawing.glyphName(look))
            .renderingMode(.template)
            .resizable()
            .scaledToFit()
            .accessibilityHidden(true)
    }
}

/// Drawing a character into a GraphicsContext: the body image, the face, the front image and the
/// badge, in the package's draw order.
public enum CharacterDrawing {
    /// How far the canvas reaches past the frame on each side, as a fraction of the frame.
    static let overdraw: CGFloat = 0.1

    public static func bodyName(_ look: CharacterLookID, size: CGFloat, layer: String = "body") -> String {
        let tier = CharacterCatalog.shared.manifest.tiersPt.first { CGFloat($0) >= size * 0.98 }
        return "character-\(look.rawValue)-\(layer)-\(tier.map(String.init) ?? "master")"
    }

    /// The empty strip under a look's body at `size`: its frame's bottom minus its box's.
    public static func footGap(_ look: CharacterLookID, size: CGFloat) -> CGFloat {
        size * (1 - CharacterCatalog.shared.look(look).box[3])
    }

    public static func glyphName(_ look: CharacterLookID) -> String { "character-\(look.rawValue)-glyph" }

    /// Each body layer is decoded once and kept. On a busy Mac a layer looked up by name could
    /// miss its first frame (a blank still, or a magenta square on screen); a decoded image cannot,
    /// and the 30 fps loop stops looking the same image up on every frame.
    static func layer(_ name: String) -> Image { LayerCache.shared.image(name) }

    private final class LayerCache: @unchecked Sendable {
        static let shared = LayerCache()
        private let lock = NSLock()
        private var images: [String: Image] = [:]

        func image(_ name: String) -> Image {
            lock.lock(); defer { lock.unlock() }
            if let cached = images[name] { return cached }
            #if os(macOS)
            guard let decoded = NSImage(named: name) else { return Image(name) }
            let image = Image(nsImage: decoded)
            #else
            guard let decoded = UIImage(named: name) else { return Image(name) }
            let image = Image(uiImage: decoded)
            #endif
            images[name] = image
            return image
        }
    }
    /// The 512 px still on a soft tint of the coat (notifications); in every target, extensions too.
    public static func avatarName(_ look: CharacterLookID) -> String { "character-\(look.rawValue)-avatar" }

    public static func draw(in ctx: inout GraphicsContext, frame: CGRect, look id: CharacterLookID, pose: CharacterPose,
                            scheme: ColorScheme, pixel: CGFloat) {
        let catalog = CharacterCatalog.shared
        let look = catalog.look(id)
        let side = frame.width
        let height = look.height * side
        let palette = Palette(look: look, scheme: scheme)
        let pivot = CGPoint(x: frame.minX + look.pivot.x * side, y: frame.minY + look.pivot.y * side)

        var body = ctx
        body.translateBy(x: pivot.x + pose.shiftX * height, y: pivot.y - pose.lift * height)
        body.rotate(by: .degrees(pose.tilt))
        body.scaleBy(x: pose.scaleX, y: pose.scaleY)
        body.translateBy(x: -pivot.x, y: -pivot.y)
        body.draw(ctx.resolve(layer(bodyName(id, size: side))), in: frame)
        drawFace(in: &body, frame: frame, look: look, pose: pose, palette: palette, pixel: pixel)
        if look.hasFront { body.draw(ctx.resolve(layer(bodyName(id, size: side, layer: "front"))), in: frame) }

        guard let badge = pose.badge, let parts = catalog.face.badges[badge.kind],
              let anchor = look.badgeAnchors[badge.anchor], anchor.count == 2 else { return }
        let r = look.badgeRadius * side
        let whole = CharacterMotion.badgeMotion(badge.animate, time: pose.badgeTime, isStatic: pose.badgeStatic)
        var b = ctx
        // The badge follows the lift only: it does not tilt or squash.
        b.translateBy(x: frame.minX + anchor[0] * side + whole.dx * r, y: frame.minY + anchor[1] * side + whole.dy * r - pose.lift * height)
        b.rotate(by: .degrees(whole.rotation))
        b.scaleBy(x: whole.scale, y: whole.scale)
        b.opacity = whole.opacity * pose.badgeOpacity
        for (i, part) in parts.enumerated() {
            let m = CharacterMotion.badgePartMotion(badge.animate, part: part, index: i, time: pose.badgeTime, isStatic: pose.badgeStatic)
            var p = b
            p.opacity = m.opacity
            draw(part, in: &p, origin: CGPoint(x: 0, y: m.dy * r), sx: r, sy: r, palette: palette, pixel: pixel)
        }
    }

    static func drawFace(in ctx: inout GraphicsContext, frame: CGRect, look: CharacterLookSpec, pose: CharacterPose,
                         palette: Palette, pixel: CGFloat) {
        let face = CharacterCatalog.shared.face
        let side = frame.width
        let u = look.face.unit * side * pose.eyeScale
        let gx = pose.gazeX, gy = pose.gazeY
        if let eyes = face.eyes[pose.eyes] {
            let openY = eyes.closed ? 1 : pose.open
            let brows = face.brows[pose.brows]
            for (i, e) in look.face.eyes.prefix(2).enumerated() {
                let cx = frame.minX + e[0] * side + gx * 0.13 * u
                let cy = frame.minY + e[1] * side + gy * 0.09 * u
                // Blinks squash the eye toward a point a little above its centre.
                let origin = CGPoint(x: cx, y: cy - u * 0.08 * (1 - openY))
                for part in i == 0 ? eyes.left : eyes.right {
                    if part.isPupil, openY < 0.4 { continue }
                    let shift = part.isPupil ? CGPoint(x: gx * 0.12, y: gy * 0.1) : .zero
                    draw(part, in: &ctx, origin: origin, shift: shift, sx: u, sy: u * openY, palette: palette, pixel: pixel)
                }
                if let brows {
                    let parts = eyes.lidded ? (i == 0 ? brows.leftLidded : brows.rightLidded) : (i == 0 ? brows.left : brows.right)
                    let origin = CGPoint(x: cx, y: cy - pose.browRaise * 0.35 * u)
                    for part in parts { draw(part, in: &ctx, origin: origin, sx: u, sy: u, palette: palette, pixel: pixel) }
                }
            }
        }
        if let mouth = face.mouths[pose.mouth] {
            let fangs = pose.mouth == "fang" || pose.mouth == "fangs"
            let mu = look.face.unit * side * face.mouthScale * (fangs ? face.mouthScaleFangs : 1)
            let origin = CGPoint(x: frame.minX + look.face.mouth[0] * side + gx * 0.1 * u,
                                 y: frame.minY + look.face.mouth[1] * side + gy * 0.08 * u)
            for part in mouth { draw(part, in: &ctx, origin: origin, sx: mu, sy: mu, palette: palette, pixel: pixel) }
        }
    }

    /// One part at `origin`, its units scaled by (sx, sy); `shift` moves it first, in its own units.
    static func draw(_ part: FacePart, in ctx: inout GraphicsContext, origin: CGPoint, shift: CGPoint = .zero,
                     sx: CGFloat, sy: CGFloat, palette: Palette, pixel: CGFloat) {
        func point(_ p: [Double]) -> CGPoint {
            CGPoint(x: origin.x + (p[0] + shift.x) * sx, y: origin.y + (p[1] + shift.y) * sy)
        }
        func polyline(_ pts: [[Double]], closed: Bool) -> Path {
            var path = Path()
            path.addLines(pts.map(point))
            if closed { path.closeSubpath() }
            return path
        }
        // Strokes never go below one device pixel, or the thinnest lines vanish at 28 pt.
        func width(_ w: Double) -> CGFloat { max(pixel, w * sx) }
        let round = { (w: CGFloat) in StrokeStyle(lineWidth: w, lineCap: .round, lineJoin: .round) }
        switch part {
        case .ellipse(let c, let r, let fill, _):
            let centre = point(c)
            let rect = CGRect(x: centre.x - r[0] * sx, y: centre.y - r[1] * sy, width: r[0] * sx * 2, height: r[1] * sy * 2)
            ctx.fill(Path(ellipseIn: rect), with: .color(palette[fill]))
        case .poly(let pts, let fill, let outline, _):
            let path = polyline(pts, closed: true)
            ctx.fill(path, with: .color(palette[fill]))
            if let outline { ctx.stroke(path, with: .color(palette[outline.color]), style: round(width(outline.width))) }
        case .line(let pts, let w, let color):
            ctx.stroke(polyline(pts, closed: false), with: .color(palette[color]), style: round(width(w)))
        case .ring(let c, let r, let w, let color, let gap):
            var path = Path()
            if let gap, gap.count == 2 {
                // The gap runs clockwise on screen from a0 to a1; draw the rest.
                path.addArc(center: point(c), radius: r * sx, startAngle: .degrees(gap[1]), endAngle: .degrees(gap[0] + 360), clockwise: false)
            } else {
                path.addEllipse(in: CGRect(x: point(c).x - r * sx, y: point(c).y - r * sx, width: r * sx * 2, height: r * sx * 2))
            }
            ctx.stroke(path, with: .color(palette[color]), style: round(width(w)))
        case .rrect(let c, let size, let radius, let fill, _):
            let centre = point(c)
            let rect = CGRect(x: centre.x - size[0] / 2 * sx, y: centre.y - size[1] / 2 * sy, width: size[0] * sx, height: size[1] * sy)
            ctx.fill(Path(roundedRect: rect, cornerRadius: radius * sx), with: .color(palette[fill]))
        }
    }

    /// The package's colour tokens: fixed inks, the look's coat, and the theme's fg and bg.
    struct Palette {
        var coat: Color
        var fg: Color
        var bg: Color

        init(look: CharacterLookSpec, scheme: ColorScheme) {
            let theme = CharacterCatalog.shared.manifest.themes[scheme == .dark ? "dark" : "light"] ?? [:]
            coat = Color(botHex: look.colour) ?? .accentColor
            fg = theme["fg"].flatMap { Color(botHex: $0) } ?? .primary
            bg = theme["bg"].flatMap { Color(botHex: $0) } ?? .clear
        }

        subscript(token: String) -> Color {
            switch token {
            case "coat": return coat
            case "fg": return fg
            case "bg": return bg
            default:
                return Self.fixed[token] ?? .black
            }
        }

        private static let fixed: [String: Color] = CharacterCatalog.shared.manifest.colours.compactMapValues { Color(botHex: $0) }
    }
}
