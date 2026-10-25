import SwiftUI

struct WelcomeIdea: Equatable, Sendable {
    let title: String
    let symbol: String
}

enum WelcomeIdeas {
    static let interval: Duration = .seconds(10)

    static let pages: [[WelcomeIdea]] = [
        [
            .init(title: "Watch this price", symbol: "tag"),
            .init(title: "Find gigs this weekend", symbol: "music.note"),
            .init(title: "Research my next laptop", symbol: "magnifyingglass"),
        ],
        [
            .init(title: "Compare flights to Lisbon", symbol: "airplane"),
            .init(title: "Keep my project moving", symbol: "checkmark.circle"),
            .init(title: "Check back next week", symbol: "calendar"),
        ],
        [
            .init(title: "Find quiet cafés nearby", symbol: "cup.and.saucer"),
            .init(title: "Plan a rainy weekend", symbol: "cloud.rain"),
            .init(title: "Shortlist gifts under £30", symbol: "gift"),
        ],
    ]
}

struct WelcomeIdeasPlayback: Equatable {
    private(set) var page = 0
    private(set) var isPaused = false

    func shouldCycle(isActive: Bool, sceneIsActive: Bool, automatically: Bool,
                     reduceMotion: Bool, voiceOver: Bool, hovering: Bool, focused: Bool) -> Bool {
        isActive && sceneIsActive && automatically && !isPaused && !reduceMotion && !voiceOver && !hovering && !focused
    }

    mutating func advance(manually: Bool = false) {
        if manually { isPaused = true }
        page = (page + 1) % WelcomeIdeas.pages.count
    }

    mutating func togglePause() { isPaused.toggle() }
}

/// Suggestions only. Browsing these examples does not submit a prompt or schedule work.
struct WelcomeIdeasView: View {
    var isActive = true
    var cyclesAutomatically = true

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.scenePhase) private var scenePhase
    @State private var playback = WelcomeIdeasPlayback()
    @State private var hovering = false
    @FocusState private var focused: Bool
    @AccessibilityFocusState private var accessibilityFocused: Bool

    private var shouldCycle: Bool {
        playback.shouldCycle(isActive: isActive, sceneIsActive: scenePhase == .active,
                             automatically: cyclesAutomatically, reduceMotion: reduceMotion,
                             voiceOver: voiceOver, hovering: hovering,
                             focused: focused || accessibilityFocused)
    }

    var body: some View {
        // Every page participates in layout, so the repeating crossfade stays still.
        ZStack {
            ForEach(WelcomeIdeas.pages.indices, id: \.self) { index in
                page(WelcomeIdeas.pages[index])
                    .opacity(playback.page == index ? 1 : 0)
                    .allowsHitTesting(false)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 2)
        .contentShape(.rect)
        .focusable()
        .focused($focused)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Example requests")
        .accessibilityValue(WelcomeIdeas.pages[playback.page].map(\.title).joined(separator: ". "))
        .accessibilityHint("Use actions to browse or pause the examples.")
        .accessibilityFocused($accessibilityFocused)
        .accessibilityIdentifier("onboarding.ideas.examples")
        .accessibilityAction(named: Text("More ideas")) { advance(manually: true) }
        .accessibilityAction(named: Text(playback.isPaused ? "Resume idea rotation" : "Pause idea rotation")) {
            playback.togglePause()
        }
        .onKeyPress(.space) { playback.togglePause(); return .handled }
        .onKeyPress(.rightArrow) { advance(manually: true); return .handled }
        .onHover { hovering = $0 }
        .task(id: shouldCycle) {
            guard shouldCycle else { return }
            while !Task.isCancelled {
                do { try await Task.sleep(for: WelcomeIdeas.interval) }
                catch { return }
                guard !Task.isCancelled, shouldCycle else { return }
                advance()
            }
        }
    }

    private func page(_ ideas: [WelcomeIdea]) -> some View {
        VStack(spacing: 10) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) {
                    chip(ideas[0]).fixedSize(horizontal: true, vertical: false)
                    chip(ideas[1]).fixedSize(horizontal: true, vertical: false)
                }
                VStack(spacing: 10) {
                    chip(ideas[0])
                    chip(ideas[1])
                }
            }
            chip(ideas[2])
        }
    }

    private func chip(_ idea: WelcomeIdea) -> some View {
        HStack(spacing: 7) {
            Image(systemName: idea.symbol).accessibilityHidden(true)
            Text(idea.title)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.subheadline.weight(.medium))
        .foregroundStyle(.primary)
        .multilineTextAlignment(.center)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color.primary.opacity(contrast == .increased ? 0.10 : 0.045), in: .capsule)
        .accessibilityElement(children: .combine)
    }

    private func advance(manually: Bool = false) {
        withAnimation(reduceMotion || voiceOver ? nil : .easeInOut(duration: 0.6)) {
            playback.advance(manually: manually)
        }
    }
}
