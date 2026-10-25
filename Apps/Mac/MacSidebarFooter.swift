import AppKit
import NollieCore
import SwiftUI

/// The Mac account's name in the two forms the footer shows.
struct MacAccountName {
    let first: String
    let initials: String

    /// "Corey Kozarski" gives "Corey" and "CK"; an empty name gives "?" for initials.
    init(full: String) {
        let words = full.split(separator: " ")
        first = words.first.map(String.init) ?? full
        initials = words.isEmpty ? "?" : String(words.prefix(2).compactMap(\.first)).uppercased()
    }

    static let current = MacAccountName(full: NSFullUserName())
}

/// The strip at the bottom of the sidebar: who this Mac belongs to, which gateway is connected,
/// and the way into Settings.
struct MacSidebarFooter: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 10) {
            FooterAccount(name: MacAccountName.current)
            Spacer(minLength: 6)
            FooterGateway(name: gatewayName, note: connectionNote, dot: dotColour)
            FooterGear(updateWaiting: model.companionUpdateAvailable, toggle: toggleSettings)
        }
        .inset(h: 16)
        .frame(height: 64)
    }

    private var gatewayName: String {
        model.runtime?.connection.name ?? model.store.active?.name ?? "No gateway"
    }

    private var connectionNote: String {
        guard let runtime = model.runtime else { return model.activationError ?? "Connecting…" }
        return runtime.socketState.label
    }

    private var dotColour: Color {
        switch model.runtime?.socketState {
        case .open: Ink.online
        case .connecting, .reconnecting, .idle: .orange
        case .authRejected, .failed: .red
        case nil: Ink.text3
        }
    }

    private func toggleSettings() {
        model.selectedTab = model.selectedTab == .settings ? .chats : .settings
    }
}

private struct FooterAccount: View {
    let name: MacAccountName

    var body: some View {
        HStack(spacing: 10) {
            Text(name.initials)
                .font(Ink.initials)
                .foregroundStyle(Ink.meText)
                .frame(square: 32)
                .background(Ink.me, in: .circle)
            Text(name.first).font(Ink.footName).foregroundStyle(Ink.text).lineLimit(1)
        }
        .fixedSize()
        .contentShape(.rect)
    }
}

private struct FooterGateway: View {
    let name: String
    let note: String
    let dot: Color

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(dot).frame(square: 7)
            Text(name).font(Ink.footDetail).foregroundStyle(Ink.text2).lineLimit(1)
        }
        .contentShape(.rect)
        .help("\(name) · \(note)")
        .accessibilityLabel("Gateway \(name), \(note)")
        .accessibilityIdentifier("sidebar.gateway")
    }
}

/// The Settings gear. It turns once when the pointer arrives, and wears a red dot while the
/// Companion has an update waiting.
private struct FooterGear: View {
    let updateWaiting: Bool
    let toggle: () -> Void

    @Environment(\.accessibilityReduceMotion) private var calm
    @State private var hovering = false
    @State private var spins = 0

    var body: some View {
        Button(action: toggle) {
            Image(systemName: "gearshape")
                .font(.system(size: 15, weight: hovering ? .semibold : .regular))
                .foregroundStyle(hovering ? Ink.text : Ink.text3)
                .symbolEffect(.rotate.clockwise, options: .nonRepeating.speed(1.5), value: spins)
                .overlay(alignment: .topTrailing) { if updateWaiting { badge } }
                .frame(square: 24)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .padding(.leading, 2)
        .help("Settings (⌘,)")
        .accessibilityLabel("Settings")
        .accessibilityIdentifier("sidebar.settings")
        .onHover(perform: pointerMoved)
    }

    private var badge: some View {
        Circle().fill(.red).frame(square: 6).offset(x: 3, y: -2)
    }

    private func pointerMoved(_ inside: Bool) {
        guard inside != hovering else { return }
        hovering = inside
        if inside && !calm { spins += 1 }
    }
}
