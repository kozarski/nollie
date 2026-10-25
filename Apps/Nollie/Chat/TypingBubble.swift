import SwiftUI

/// Hands `content` the current time as a number so it can animate itself. When motion is off
/// (Reduce Motion, or a Mac whose bots are not on screen) it gets nil once and nothing ticks.
private struct Ticking<Content: View>: View {
    @ViewBuilder var content: (Double?) -> Content

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    #if os(macOS)
    @Environment(\.botsLive) private var botsLive
    #endif

    private var moves: Bool {
        #if os(macOS)
        return botsLive && !reduceMotion
        #else
        return !reduceMotion
        #endif
    }

    var body: some View {
        if moves {
            TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { content($0.date.timeIntervalSinceReferenceDate) }
        } else {
            content(nil)
        }
    }
}

/// Looks like the typing bubble in Messages: grey, three hopping dots, and two little circles
/// trailing off the corner like a thought. Passing `tool` makes it dark and adds a badge, because
/// the bot is then running something rather than writing.
struct TypingBubble: View {
    var tool: String? = nil

    private var running: Bool { tool != nil }
    private var paint: Color { running ? Color(white: 0.12) : Color(.systemGray5) }

    /// One circle of the thought trail, shifted away from the corner.
    private func bead(_ width: CGFloat, nudge: CGSize) -> some View {
        Circle().fill(paint).frame(square: width).offset(nudge)
    }

    var body: some View {
        HStack(spacing: 10) {
            if running { ToolBadge() }
            TypingDots(color: running ? .white.opacity(0.75) : Color(.systemGray))
        }
        .padding(EdgeInsets(top: 13, leading: 18, bottom: 13, trailing: 18))
        .background(paint, in: .rect(cornerRadius: 22))
        // Trail: a larger circle at the corner, then a tiny one further out.
        .overlay(alignment: .bottomLeading) { bead(12, nudge: CGSize(width: -2, height: 2)) }
        .overlay(alignment: .bottomLeading) { bead(5, nudge: CGSize(width: -10, height: 9)) }
        .padding(EdgeInsets(top: 0, leading: 6, bottom: 6, trailing: 0))
        .accessibilityLabel(tool.map { "Running \($0)" } ?? "Typing")
    }
}

/// Dots that lift and glow one after another, then pause, at the pace Messages uses.
struct TypingDots: View {
    var color: Color

    var body: some View {
        Ticking { clock in
            HStack(spacing: 6) {
                ForEach(0..<3, id: \.self) { index in
                    let rise = Self.rise(of: index, at: clock ?? 0.3)
                    Circle().fill(color).frame(square: 8).opacity(0.45 + 0.55 * rise).offset(y: -3 * rise)
                }
            }
        }
    }

    /// Lift of one dot at time `t`: 0 resting, 1 at the top of its hop.
    private static func rise(of index: Int, at t: Double) -> Double {
        let phase = (t * 1.05 - Double(index) * 0.16).truncatingRemainder(dividingBy: 1)
        return phase < 0.55 ? sin(phase / 0.55 * .pi) : 0
    }
}

/// A small mint tile holding a blue target: marks that the bot is running a tool.
struct ToolBadge: View {
    private static let mint = Color(red: 0.70, green: 0.95, blue: 0.66)
    private static let ring = Color(red: 0.16, green: 0.45, blue: 0.95)
    private static let core = Color(red: 0.30, green: 0.80, blue: 0.72)

    var body: some View {
        Image(systemName: "circle.circle.fill")
            .font(Font.system(size: 15).weight(.semibold))
            .foregroundStyle(Self.ring, Self.core)
            .frame(width: 34, height: 26)
            .background(Self.mint, in: .rect(cornerRadius: 9))
    }
}

/// The line at the foot of the thread while a bot works: dots in the bot's colour, with a quiet
/// note on what it is up to ("Checking the board").
struct WorkingLine: View {
    var profile: String?
    var text: String?

    var body: some View {
        HStack(spacing: 10) {
            WorkingDots(color: profile.map { BotColors.color(for: $0) } ?? Ink.text3)
            if let text, !text.isEmpty {
                Text(text)
                    .quiet(Ink.working, Ink.text3)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .contentTransition(.opacity)
                    .animation(.snappy, value: text)
            }
        }
        .padding(EdgeInsets(top: 6, leading: 4, bottom: 6, trailing: 0))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(text ?? "Working")
    }
}

/// Three dots whose glow travels along the row, the lead dot brightest.
struct WorkingDots: View {
    var color: Color

    /// How bright each dot is when nothing moves, matching the design drawing.
    private static let resting = [1.0, 0.36, 0.0]

    var body: some View {
        Ticking { clock in
            HStack(spacing: 3) {
                ForEach(Self.resting.indices, id: \.self) { index in
                    Circle().fill(color).frame(square: 9).opacity(0.3 + 0.7 * Self.glow(of: index, at: clock))
                }
            }
            .accessibilityHidden(true)
        }
    }

    private static func glow(of index: Int, at clock: Double?) -> Double {
        guard let clock else { return resting[index] }
        let phase = (clock * 0.9 + Double(3 - index) / 3).truncatingRemainder(dividingBy: 1)
        return 0.5 + 0.5 * cos(phase * 2 * .pi)
    }
}
