import SwiftUI

// Small views that sit behind a tab's pages and tell the model what the page is doing, so the tab
// bar and the reselect gesture can react: is the page at the root, and does it want the bar gone.

/// Keeps the tab bar hidden while the page shows. Chats skips this, because its list's navigation
/// path hides the bar as a push starts, so only the other tabs are counted. Asks stack, so a
/// second page does not undo a first.
private struct BarHold: View {
    @Environment(AppModel.self) private var model
    @State private var heldOn: AppModel.AppTab?

    var body: some View {
        Color.clear
            .onAppear {
                let tab = model.selectedTab
                guard heldOn == nil, tab != .chats else { return }
                heldOn = tab
                shiftHolds(on: tab, by: 1)
            }
            .onDisappear {
                guard let tab = heldOn else { return }
                heldOn = nil
                shiftHolds(on: tab, by: -1)
            }
    }

    private func shiftHolds(on tab: AppModel.AppTab, by step: Int) {
        let now = model.tabBarHiders[tab] ?? 0
        model.tabBarHiders[tab] = max(0, now + step)
    }
}

/// Tags a tab's root page so the tab counts as at-root while the page shows. (Chats instead
/// reports through its navigation path, as an open chat leaves the list alive beneath it.) Also
/// carries the probe that pops the stack when the tab is selected again.
private struct RootMarker: View {
    @Environment(AppModel.self) private var model
    let tab: AppModel.AppTab

    var body: some View {
        PopToRootProbe(tab: tab)
            .onAppear { model.tabAtRoot[tab] = true }
            .onDisappear { model.tabAtRoot[tab] = false }
    }
}

/// An invisible view in a tab's root page. When `popToRoot` for its tab goes up, it finds the
/// navigation controller around itself and pops it back to the root.
private struct PopToRootProbe: UIViewRepresentable {
    @Environment(AppModel.self) private var model
    var tab: AppModel.AppTab

    /// The last request already acted on, so each one pops once.
    final class Handled {
        var number = 0
    }

    func makeCoordinator() -> Handled { Handled() }

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ view: UIView, context: Context) {
        let wanted = model.popToRoot[tab] ?? 0
        guard wanted > 0, wanted != context.coordinator.number else { return }
        context.coordinator.number = wanted
        DispatchQueue.main.async {
            let chain = sequence(first: view as UIResponder, next: { $0.next })
            let stack = chain.lazy.compactMap { link in
                (link as? UINavigationController) ?? (link as? UIViewController)?.navigationController
            }.first
            stack?.popToRootViewController(animated: true)
        }
    }
}

extension View {
    func hidesTabBar() -> some View { background(BarHold()) }
    func tabRoot(_ tab: AppModel.AppTab) -> some View { background(RootMarker(tab: tab)) }
}
