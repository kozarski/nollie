import AppKit
import SwiftUI

/// The raised frosted card the bot list sits on. It looks the same whether or not the window has focus.
struct MacSidebarCard: View {
    let policy: GlassAppearance.Policy

    var body: some View {
        let outline = RoundedRectangle(cornerRadius: 24, style: .continuous)
        ZStack {
            if policy.usesGlass { outline.fill(.regularMaterial) }
            outline.fill(Ink.sidebar.opacity(policy.usesGlass ? policy.backingOpacity : 1))
        }
        .clipShape(outline)
        .overlay { outline.strokeBorder(Ink.text.opacity(0.08), lineWidth: 0.5) }
        .shadow(color: .black.opacity(0.06), radius: 4, y: 2)
        .allowsHitTesting(false)
    }
}

/// One surface behind the whole window, so it carries across page changes and keeps text readable.
struct MacFrostedBackdrop: View {
    let policy: GlassAppearance.Policy

    var body: some View {
        ZStack {
            if policy.usesGlass { MacWindowMaterial() }
            // The material already gives a neutral base. This wash is lighter than the one on the
            // raised cards, so the window stays see-through without hurting contrast.
            Ink.canvas.opacity(policy.usesGlass ? policy.backingOpacity / 2 : 1)
        }
        .allowsHitTesting(false)
    }
}

private struct MacWindowMaterial: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let effect = NSVisualEffectView()
        effect.material = .underWindowBackground
        effect.blendingMode = .behindWindow
        effect.state = .active
        return effect
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}
