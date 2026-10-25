import SwiftUI

#if os(macOS)
/// Not needed on the Mac, where chats open in the detail pane of the split view.
struct InteractivePopEnabler: View {
    var body: some View { Color.clear }
}
#else
import UIKit

/// Swipe-back normally dies when a navigation stack hides its bar. This brings it back, and lets
/// the swipe start anywhere on screen instead of the left edge alone, which suits one-handed
/// use. It adds a pan recogniser to the navigation view that feeds the edge gesture's own
/// targets. Every tab root and every page with a hidden bar should carry one of these.
///
/// Exactly one per stack, and its delegate must outlive the stack. We learned this the hard way:
/// each chat that was pushed used to attach another pan and abandon it, delegate already gone.
/// A few chats later several pans were reacting to ANY drag, threads slid either way, and the
/// time reveal quit working.
struct InteractivePopEnabler: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> Controller { Controller() }
    func updateUIViewController(_ controller: Controller, context: Context) { controller.enable() }

    final class Controller: UIViewController {
        /// Nothing to draw; the controller only exists to find its navigation stack.
        override func loadView() { view = UIView() }

        override func didMove(toParent parent: UIViewController?) {
            super.didMove(toParent: parent)
            enable()
        }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            enable()
        }

        func enable() {
            guard let stack = navigationController ?? parent?.navigationController else { return }
            FullScreenPop.install(on: stack)
        }
    }
}

/// Owns the full-screen back pan for one navigation stack, and serves as delegate for it and for
/// the system edge gesture. The navigation controller itself keeps it alive.
final class FullScreenPop: NSObject, UIGestureRecognizerDelegate {
    private static var storeKey = 0
    private static let panName = "nollie.fullScreenPop"
    private weak var stack: UINavigationController?
    private weak var pan: UIPanGestureRecognizer?

    /// A drag must beat this speed (points per second) and be this much more sideways than up.
    private static let minimumSpeed: CGFloat = 250
    private static let sidewaysBias: CGFloat = 1.8

    static func install(on stack: UINavigationController) {
        guard let edge = stack.interactivePopGestureRecognizer else { return }
        edge.isEnabled = true
        if let owner = objc_getAssociatedObject(stack, &storeKey) as? FullScreenPop {
            edge.delegate = owner
            if owner.pan?.view == nil { owner.addPan(copyingTargetsFrom: edge) }
            return
        }
        let owner = FullScreenPop()
        owner.stack = stack
        objc_setAssociatedObject(stack, &storeKey, owner, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        edge.delegate = owner
        owner.addPan(copyingTargetsFrom: edge)
    }

    private func addPan(copyingTargetsFrom edge: UIGestureRecognizer) {
        guard let stack, let targets = edge.value(forKey: "targets") as? NSArray else { return }
        guard targets.count > 0 else { return }
        // Never two on one view, which can happen when a stack is rebuilt around a controller.
        for old in stack.view.gestureRecognizers ?? [] where old.name == Self.panName {
            stack.view.removeGestureRecognizer(old)
        }
        let wide = UIPanGestureRecognizer()
        wide.name = Self.panName
        wide.setValue(targets, forKey: "targets")
        wide.delegate = self
        wide.maximumNumberOfTouches = 1
        stack.view.addGestureRecognizer(wide)
        pan = wide
    }

    func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
        guard let stack, stack.viewControllers.count > 1 else { return false }
        guard let wide = recognizer as? UIPanGestureRecognizer, recognizer === pan else { return true }
        // List rows keep their own swipe actions. This pan was eating the leading swipes the Board uses
        // for Done and Unblock. Going back via the screen edge still works on those pages.
        if let touched = wide.view?.hitTest(wide.location(in: wide.view), with: nil), Self.isInListRow(touched) {
            return false
        }
        // Only a clearly rightward, mostly sideways drag. Vertical scrolling and the thread's
        // leftward time reveal are left alone.
        let v = wide.velocity(in: wide.view)
        return v.x > Self.minimumSpeed && abs(v.x) > abs(v.y) * Self.sidewaysBias
    }

    private static func isInListRow(_ view: UIView) -> Bool {
        var node: UIView? = view
        while let current = node {
            if current is UICollectionViewListCell || current is UITableViewCell { return true }
            node = current.superview
        }
        return false
    }

    func gestureRecognizer(_ recognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        false
    }
}
#endif
