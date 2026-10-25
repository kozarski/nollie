import SwiftUI
import NollieCore

struct WelcomeHeroAnchorKey: PreferenceKey {
    static var defaultValue: Anchor<CGRect>? { nil }
    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
        value = nextValue() ?? value
    }
}

struct WelcomeIntroView: View {
    var startedAt: Date
    var heroFrame: CGRect
    var size: CGSize
    var fixedTime: Double?
    var skip: () -> Void

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 60, paused: fixedTime != nil)) { context in
            let frame = WelcomeIntroTimeline.frame(at: fixedTime ?? context.date.timeIntervalSince(startedAt))
            let camera = WelcomeIntroTimeline.camera(frame: frame, viewport: size, hero: heroFrame)
            // Drawn at the camera's size rather than scaled up, so the close-up stays sharp.
            CharacterView(look: .main, state: frame.state, size: max(1, heroFrame.width * camera.scale),
                          animated: fixedTime == nil, restsWhenIdle: false)
                .position(camera.center)
                .allowsHitTesting(false)
        }
        .frame(width: size.width, height: size.height)
        .background {
            #if os(iOS)
            Color(.systemGroupedBackground)
            #endif
        }
        .clipped()
        #if os(macOS)
        .contentShape(.rect)
        .gesture(WindowDragGesture())
        .allowsWindowActivationEvents()
        #endif
        .overlay(alignment: .topTrailing) {
            Button(action: skip) {
                Text("Skip intro")
                    .font(.subheadline.weight(.medium))
                    .frame(minWidth: 80, minHeight: 44)
                    .contentShape(.rect)
            }
                .buttonStyle(.nollieGlass)
                .padding(24)
                .accessibilityIdentifier("onboarding.intro.skip")
        }
        .overlay(alignment: .bottomLeading) {
            if fixedTime != nil {
                Text("Animation preview")
                    .font(.caption).foregroundStyle(Color.secondary).padding(24)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Nollie is waking up")
        .accessibilityIdentifier("onboarding.intro")
    }
}
