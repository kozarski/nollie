import NollieCore
import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

extension Color {
    /// A green dark enough to read on white; the system green is washed out there.
    static let readableGreen: Color = {
        #if os(macOS)
        let deep = NSColor(red: 0.10, green: 0.50, blue: 0.22, alpha: 1)
        return Color(nsColor: NSColor(name: nil) { look in
            look.bestMatch(from: [.aqua, .darkAqua]) == .aqua ? deep : .systemGreen
        })
        #else
        let deep = UIColor(red: 0.10, green: 0.50, blue: 0.22, alpha: 1)
        return Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? .systemGreen : deep })
        #endif
    }()
}

/// How a bubble is coloured: the words, and the shape behind them.
struct BubblePalette {
    var words: Color = .primary
    var backdrop: Color = Color(.secondarySystemFill)

    /// Pale green with green words, for a finished step.
    static var finished: BubblePalette {
        BubblePalette(words: .readableGreen, backdrop: Color.green.mix(with: BubblePalette().backdrop, by: 0.75))
    }
}

/// How long the typing pauses after a letter.
private func typingPause(after letter: Character) -> Duration {
    .milliseconds(letter == " " ? 12 : 22)
}

/// A bubble that types its words out gradually each time `key` changes. It sizes itself to the
/// complete text straight away so the lines around it never shift as typing proceeds.
struct NollieTypedBubble: View {
    var text: String
    var key: AnyHashable
    var reduceMotion = false
    var palette = BubblePalette()
    /// Called with true when typing starts and false when it ends.
    var typing: (Bool) -> Void = { _ in }

    @State private var shown = ""

    var body: some View {
        // The full text, unseen, holds the size; what has been typed so far is laid over it.
        Text(text).hidden()
            .overlay(alignment: .top) { Text(shown) }
            .font(.subheadline.weight(.medium))
            .foregroundStyle(palette.words)
            .multilineTextAlignment(.center)
            .padding(EdgeInsets(top: 17, leading: 14, bottom: 9, trailing: 14))
            .background { SpeechBubbleShape(tailOnTop: true).fill(palette.backdrop) }
            .frame(maxWidth: 340)
            .task(id: key) { await typeOut() }
    }

    private func typeOut() async {
        if reduceMotion {
            shown = text
            typing(false)
            return
        }
        shown = ""
        typing(true)
        for letter in text {
            if Task.isCancelled { return }
            shown.append(letter)
            try? await Task.sleep(for: typingPause(after: letter))
        }
        typing(false)
    }
}

/// Nollie standing above a guided screen. While the bubble types it speaks, afterwards it
/// listens, during a running step it thinks (`thinking`), and when `turnKey` changes (new page,
/// step done) it gives a little hop.
struct NollieGuide: View {
    /// What the guide says, and when it says something new.
    private let words: String
    private let key: AnyHashable
    /// When this changes, the guide hops.
    private let turnKey: AnyHashable
    private let thinking: Bool
    private let done: Bool
    private let reduceMotion: Bool
    private let size: CGFloat

    init(says: String, key: AnyHashable, turnKey: AnyHashable, thinking: Bool = false, done: Bool = false,
         reduceMotion: Bool = false, size: CGFloat = 96) {
        (words, self.key, self.turnKey) = (says, key, turnKey)
        (self.thinking, self.done) = (thinking, done)
        (self.reduceMotion, self.size) = (reduceMotion, size)
    }

    @State private var talking = false
    @State private var hopCount = 0
    @State private var hopping = false

    /// Hopping beats thinking, which beats talking; with none of them it listens.
    private var pose: CharacterState {
        if hopping { return .done }
        if thinking { return .thinking }
        return talking ? .speaking : .listening
    }

    var body: some View {
        VStack(spacing: 8) {
            CharacterView(look: .main, state: pose, size: size)
            NollieTypedBubble(
                text: words, key: key, reduceMotion: reduceMotion,
                palette: done ? .finished : BubblePalette(),
                typing: { talking = $0 })
                .inset(h: 24)
        }
        .onChange(of: turnKey) { hopCount += 1 }
        .task(id: hopCount) { await hop() }
    }

    private func hop() async {
        guard hopCount > 0 else { return }
        hopping = true
        let length = CharacterCatalog.shared.state(.done).oneShot ?? 1.6
        if (try? await Task.sleep(for: .seconds(length))) != nil { hopping = false }
    }
}
