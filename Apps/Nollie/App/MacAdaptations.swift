import SwiftUI

// Helpers that let a page be written once for the phone and the Mac. On the phone each one is the
// plain SwiftUI control. On the Mac it adds whatever a window needs.

/// A settings page's rows: a list on the phone, and on the Mac a grouped form held in a centred
/// column 700 points wide, like System Settings.
struct SettingsList<Content: View>: View {
    private let rows: Content

    init(@ViewBuilder content: () -> Content) {
        rows = content()
    }

    #if os(macOS)
    var body: some View {
        // The form fills the window so its scroll bar hugs the window edge; margins on the sides
        // would pinch the rows into a narrow column.
        GeometryReader { window in
            Form { rows }
                .formStyle(.grouped)
                .scrollContentBackground(.hidden)
                // A button in a row acts as the row, as on the phone, not as a push button.
                .buttonStyle(SettingsRowButtonStyle())
                .contentMargins(.horizontal, max(0, (window.size.width - 700) / 2), for: .scrollContent)
        }
    }
    #else
    var body: some View {
        List { rows }
            .listSectionSpacing(28)
            .environment(\.defaultMinListRowHeight, 54)
    }
    #endif
}

/// Opening size of a sheet on the Mac. Sheets there size to their content, and a list has no natural size.
enum SheetSize: Int {
    case form = 0     // a form or a list
    case compact      // a few controls
    case wide         // something to read

    private static let points: [(width: CGFloat, height: CGFloat)] = [(520, 600), (440, 340), (720, 680)]

    var ideal: CGSize {
        let size = Self.points[rawValue]
        return CGSize(width: size.width, height: size.height)
    }
}

#if os(macOS)

/// A button in a settings row: tinted text (red when destructive), the whole row as its target,
/// dimmed while pressed or disabled.
struct SettingsRowButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        let dim = configuration.isPressed ? 0.5 : (isEnabled ? 1 : 0.45)
        return configuration.label
            .frame(maxWidth: .infinity, alignment: .leading)
            .foregroundStyle(configuration.role == .destructive ? AnyShapeStyle(.red) : AnyShapeStyle(.tint))
            .contentShape(.rect)
            .opacity(dim)
    }
}

/// Escape closes the sheet, even one with no Cancel button of its own.
private struct EscapeCloses: ViewModifier {
    @Environment(\.dismiss) private var dismiss

    func body(content: Content) -> some View {
        content.background {
            Button("") { dismiss() }
                .keyboardShortcut(.cancelAction)
                .accessibilityHidden(true)
                .opacity(0)
        }
    }
}

/// A Refresh item for the toolbar, bound to command-R, in place of pull to refresh.
private struct RefreshButton: View {
    let reload: @MainActor () async -> Void
    @State private var isReloading = false

    var body: some View {
        Button("Refresh", systemImage: "arrow.clockwise", action: start)
            .help("Refresh (\u{2318}R)")
            .keyboardShortcut("r", modifiers: .command)
            .disabled(isReloading)
    }

    private func start() {
        guard !isReloading else { return }
        isReloading = true
        Task {
            await reload()
            isReloading = false
        }
    }
}

extension View {
    /// Sizes a sheet on the Mac and lets Escape close it.
    func sheetFrame(_ size: SheetSize = .form) -> some View {
        let ideal = size.ideal
        return frame(
            minWidth: ideal.width * 0.85, idealWidth: ideal.width, maxWidth: ideal.width * 1.5,
            minHeight: ideal.height * 0.7, idealHeight: ideal.height, maxHeight: ideal.height * 1.5)
            .modifier(EscapeCloses())
    }

    /// For pages whose own content already shows the name. The toolbar title is removed, since a blank
    /// one would show the window's name instead.
    func untitledPage() -> some View {
        navigationTitle("").toolbar(removing: .title)
    }

    /// Adds a Refresh button to the toolbar.
    func reloadable(_ action: @escaping @MainActor () async -> Void) -> some View {
        toolbar { ToolbarItem(placement: .automatic) { RefreshButton(reload: action) } }
    }
}

#else

extension View {
    /// Phone sheets are sized by their detents.
    func sheetFrame(_ size: SheetSize = .form) -> some View { self }

    /// For a page whose content already names it: an empty inline title.
    func untitledPage() -> some View {
        navigationTitle("").navigationBarTitleDisplayMode(.inline)
    }

    /// Pull to refresh.
    func reloadable(_ action: @escaping @MainActor () async -> Void) -> some View {
        refreshable { await action() }
    }
}

#endif

extension View {
    /// A row's actions: on a trailing swipe on the phone, in the context menu on the Mac.
    func rowActions<Actions: View>(allowsFullSwipe: Bool = true, @ViewBuilder _ actions: () -> Actions) -> some View {
        #if os(macOS)
        contextMenu(menuItems: actions)
        #else
        swipeActions(edge: .trailing, allowsFullSwipe: allowsFullSwipe, content: actions)
        #endif
    }
}
