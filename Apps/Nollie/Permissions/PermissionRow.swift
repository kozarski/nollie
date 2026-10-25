import SwiftUI

/// A single permission, drawn identically in setup, Settings and the Mac switch: a symbol that
/// turns into a tick when granted, the name, one line on why Nollie asks, and the next step.
struct PermissionRow: View {
    var title: String
    var reason: String
    var symbol: String
    var state: PermissionState
    var canAsk = true
    var busy = false
    var id: String
    var allow: () -> Void
    var openSettings: () -> Void
    @Environment(\.dynamicTypeSize) private var typeSize

    init(kind: PermissionKind, state: PermissionState, busy: Bool = false,
         allow: @escaping () -> Void, openSettings: @escaping () -> Void) {
        self.init(title: kind.title, reason: kind.reason, symbol: kind.symbol, state: state, canAsk: kind.canAsk,
                  busy: busy, id: kind.rawValue, allow: allow, openSettings: openSettings)
    }

    init(title: String, reason: String, symbol: String, state: PermissionState, canAsk: Bool = true,
         busy: Bool = false, id: String, allow: @escaping () -> Void, openSettings: @escaping () -> Void) {
        self.title = title
        self.reason = reason
        self.symbol = symbol
        self.state = state
        self.canAsk = canAsk
        self.busy = busy
        self.id = id
        self.allow = allow
        self.openSettings = openSettings
    }

    private var granted: Bool { state == .granted }

    var body: some View {
        let stacked = typeSize.isAccessibilitySize
        Group {
            if stacked {
                narrow(stacked: true)
            } else {
                // One line when the reason fits beside the name, the reason below it when not.
                ViewThatFits(in: .horizontal) {
                    wide
                    narrow(stacked: false)
                }
            }
        }
        .padding(.leading, 12).padding(.trailing, 12).padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .nollieGlass(.regular, in: stacked ? AnyShape(.rect(cornerRadius: 26, style: .continuous)) : AnyShape(Capsule()),
                     solid: Ink.card)
        .accessibilityElement(children: .contain)
        .testID("permission.\(id)")
    }

    private var wide: some View {
        HStack(spacing: 14) {
            mark
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline).foregroundStyle(Ink.text)
                Text(reason).font(.subheadline).foregroundStyle(Ink.text2).fixedSize(horizontal: true, vertical: false)
            }
            Spacer(minLength: 8)
            control
        }
    }

    /// The name and what to do on one line; the reason below, with the whole width.
    private func narrow(stacked: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if stacked {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 14) { mark; name }
                    control
                }
            } else {
                HStack(spacing: 14) {
                    mark
                    name
                    Spacer(minLength: 8)
                    control
                }
            }
            Text(reason).font(.subheadline).foregroundStyle(Ink.text2)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, stacked ? 0 : 50).padding(.trailing, 8)
        }
    }

    private var name: some View {
        Text(title).font(.headline).foregroundStyle(Ink.text)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var mark: some View {
        Image(systemName: granted ? "checkmark" : symbol)
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(granted ? Color.white : Ink.text2)
            .frame(width: 36, height: 36)
            .background(granted ? Ink.online : Ink.code, in: .circle)
            .contentTransition(.symbolEffect(.replace))
            .accessibilityHidden(true)
    }

    @ViewBuilder private var control: some View {
        switch state {
        case .granted:
            Text("On").font(.subheadline.weight(.medium)).foregroundStyle(Ink.text2)
                .padding(.horizontal, 10)
                .accessibilityLabel("\(title) is on")
        case .notAsked where canAsk:
            Button(action: allow) {
                Text(busy ? "Asking…" : "Allow").font(.subheadline.weight(.semibold)).padding(.horizontal, 6)
            }
            .buttonStyle(.nollieGlassProminent)
            .buttonBorderShape(.capsule)
            .disabled(busy)
            .accessibilityHint("Shows the system prompt for \(title). You answer it.")
            .testID("permission.\(id).allow")
        case .notAsked, .denied:
            Button(action: openSettings) {
                Text("Open Settings").font(.subheadline.weight(.semibold)).lineLimit(1).fixedSize().padding(.horizontal, 6)
            }
            .buttonStyle(.nollieGlass)
            .buttonBorderShape(.capsule)
            .testID("permission.\(id).settings")
        case .unavailable:
            Text("Not available").font(.subheadline.weight(.medium)).foregroundStyle(Ink.text3)
                .padding(.horizontal, 10)
        }
    }
}

/// The rows of a few permissions, each reading its state from the center and asking through it.
struct PermissionRows: View {
    var center: PermissionCenter
    var kinds: [PermissionKind]
    var spacing: CGFloat = 10
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        VStack(spacing: spacing) {
            ForEach(kinds.filter(center.isAvailable)) { kind in
                PermissionRow(kind: kind, state: center.state(kind), busy: center.asking.contains(kind),
                              allow: { Task { await center.ask(kind) } },
                              openSettings: { center.openSettings(kind) })
            }
        }
        .opacity(center.hasRead ? 1 : 0)
        .task {
            // Looks again whenever it appears or comes back from Settings; reading never prompts.
            await center.refresh()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await center.refresh() } }
        }
    }
}
