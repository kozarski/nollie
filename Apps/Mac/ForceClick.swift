import SwiftUI
import AppKit

/// Force click: the firmer, second-stage trackpad press.
///
/// SwiftUI never passes pressure events on, so one monitor for the whole app listens for them and
/// checks the pointer against the frames that views gave it through `onForceClick`.
@MainActor
final class ForceClickMonitor {
    static let shared = ForceClickMonitor()

    /// A rectangle in window coordinates, counted from the top, and what to do when pressed in it.
    struct Hotspot {
        let frame: CGRect
        let fire: () -> Void
    }

    private var eventMonitor: Any?
    private var hotspots = [UUID: Hotspot]()
    /// True from the moment a force click fires until its mouse-up has been swallowed.
    private var inFlight = false

    func track(_ spot: Hotspot, for key: UUID) {
        hotspots.updateValue(spot, forKey: key)
        guard eventMonitor == nil else { return }
        let handler: (NSEvent) -> NSEvent? = { [weak self] event in
            let swallowed = MainActor.assumeIsolated { self?.swallows(event) ?? false }
            return swallowed ? nil : event
        }
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.pressure, .leftMouseUp], handler: handler)
    }

    func forget(_ key: UUID) {
        hotspots.removeValue(forKey: key)
    }

    /// Reports whether the event ends here. Only the release that finishes a force click qualifies,
    /// which stops the row beneath the cursor from also opening.
    private func swallows(_ event: NSEvent) -> Bool {
        switch event.type {
        case .leftMouseUp:
            defer { inFlight = false }
            return inFlight
        case .pressure where event.stage == 2 && !inFlight:
            guard let point = event.pointInContentFromTop,
                  let spot = hotspots.values.first(where: { spot in spot.frame.contains(point) }) else { return false }
            spot.fire()
            inFlight = true
            return false
        default:
            return false
        }
    }
}

private extension NSEvent {
    /// Where the pointer is in the window's content, counted down from the top edge as SwiftUI does
    /// (AppKit's window points count up from the bottom).
    @MainActor var pointInContentFromTop: CGPoint? {
        guard let content = window?.contentView else { return nil }
        let inside = content.convert(locationInWindow, from: nil)
        let down = content.isFlipped ? inside.y : content.bounds.height - inside.y
        return CGPoint(x: inside.x, y: down)
    }
}

/// Sits behind a view, reports where that view is, and withdraws when the view goes.
private struct ForceClickSpot: View {
    let action: () -> Void
    @State private var key = UUID()

    var body: some View {
        GeometryReader { proxy in
            Color.clear.onChange(of: proxy.frame(in: .global), initial: true) { _, frame in
                ForceClickMonitor.shared.track(.init(frame: frame, fire: action), for: key)
            }
        }
        .onDisappear { ForceClickMonitor.shared.forget(key) }
    }
}

extension View {
    /// Runs `action` when the person force-clicks on this view.
    func onForceClick(_ action: @escaping () -> Void) -> some View {
        background(ForceClickSpot(action: action))
    }
}
