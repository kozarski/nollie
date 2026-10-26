import SwiftUI
import QuickLook

/// On a wide screen, the extras a chat opens (Watch, a card full size, a file, Papertrail) take the
/// right half beside the chat instead of covering it. The wide layout owns one of these and puts
/// it in the environment; on the phone's single stack and on the Mac there is none, and the same
/// things open as sheets the way they always have.
@MainActor @Observable
final class SidePanelHost {
    struct Page: Identifiable {
        let id: String
        let view: AnyView
    }

    private(set) var page: Page?
    /// The panel spreads over the chat too.
    private(set) var expanded = false
    /// Off while a fold is in use: spread out, the panel would sit across the crease.
    var canExpand = true {
        didSet { if !canExpand { expanded = false } }
    }

    var isOpen: Bool { page != nil }

    func show(_ id: String, @ViewBuilder content: () -> some View) {
        page = Page(id: id, view: AnyView(content()))
        expanded = false
    }

    func close() {
        page = nil
        expanded = false
    }

    func toggleExpanded() {
        guard canExpand else { return }
        expanded.toggle()
    }
}

extension EnvironmentValues {
    /// True when chats open beside the list (a wide iPad or iPhone Duo window) rather than over it.
    /// Opening then replaces the chat on show, and the chat has no Back.
    @Entry var chatOpensBeside = false
    /// The wide layout's panel. Nil where extras open as sheets.
    @Entry var sidePanel: SidePanelHost? = nil
    /// True for views drawn inside the panel, which brings its own close and expand.
    @Entry var inSidePanel = false
}

extension View {
    /// A sheet, or on a wide screen the panel beside the chat. `panel` is what the panel shows; it
    /// brings no Done button of its own, since the panel has close and expand.
    func sheetOrSidePanel<Sheet: View, Panel: View>(
        isPresented: Binding<Bool>, id: String,
        @ViewBuilder sheet: @escaping () -> Sheet,
        @ViewBuilder panel: @escaping () -> Panel
    ) -> some View {
        modifier(SheetOrSidePanel(isPresented: isPresented, id: id, sheet: sheet, panel: panel))
    }

    /// Quick Look over the screen, or on a wide screen in the panel beside the chat.
    func filePreview(_ url: Binding<URL?>) -> some View {
        modifier(FilePreviewPresenter(url: url))
    }
}

private struct SheetOrSidePanel<Sheet: View, Panel: View>: ViewModifier {
    @Environment(\.sidePanel) private var host
    @Binding var isPresented: Bool
    var id: String
    var sheet: () -> Sheet
    var panel: () -> Panel

    /// The sheet only shows where there is no panel to take it.
    private var asSheet: Binding<Bool> {
        Binding(get: { isPresented && host == nil }, set: { isPresented = $0 })
    }

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: asSheet) { sheet().withAppModel() }
            .onChange(of: isPresented) { _, shown in
                guard shown, let host else { return }
                host.show(id, content: panel)
                isPresented = false
            }
    }
}

private struct FilePreviewPresenter: ViewModifier {
    @Environment(\.sidePanel) private var host
    @Binding var url: URL?

    private var overScreen: Binding<URL?> {
        Binding(get: { host == nil ? url : nil }, set: { url = $0 })
    }

    func body(content: Content) -> some View {
        content
            .quickLookPreview(overScreen)
            .onChange(of: url) { _, picked in
                guard let picked, let host else { return }
                host.show("file|" + picked.path) { SidePanelPage(title: picked.lastPathComponent) { FilePreviewPanel(url: picked) } }
                url = nil
            }
    }
}

/// A page in the panel with a title bar of its own: the page's name, expand and close.
struct SidePanelPage<Content: View>: View {
    var title: String
    @ViewBuilder var content: Content
    @Environment(\.sidePanel) private var host

    var body: some View {
        NavigationStack {
            content
                .navigationTitle(title)
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
                .toolbar { if let host { SidePanelControls(host: host) } }
        }
    }
}

/// Expand and close, for a panel page's bar.
struct SidePanelControls: ToolbarContent {
    var host: SidePanelHost

    var body: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            if host.canExpand { SidePanelExpandButton(host: host) }
        }
        ToolbarItem(placement: .confirmationAction) { SidePanelCloseButton(host: host) }
    }
}

struct SidePanelCloseButton: View {
    var host: SidePanelHost

    var body: some View {
        Button { withAnimation(.snappy) { host.close() } } label: { Label("Close", systemImage: "xmark") }
            .labelStyle(.iconOnly)
            .accessibilityIdentifier("panel.close")
    }
}

struct SidePanelExpandButton: View {
    var host: SidePanelHost

    var body: some View {
        Button { withAnimation(.snappy) { host.toggleExpanded() } } label: {
            Label(host.expanded ? "Make smaller" : "Expand",
                  systemImage: host.expanded ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
        }
        .labelStyle(.iconOnly)
        .accessibilityIdentifier("panel.expand")
    }
}

#if os(iOS)
/// A file in Quick Look, drawn inside the panel rather than over the screen.
struct FilePreviewPanel: UIViewControllerRepresentable {
    var url: URL

    func makeCoordinator() -> Source { Source(url: url) }

    func makeUIViewController(context: Context) -> QLPreviewController {
        let preview = QLPreviewController()
        preview.dataSource = context.coordinator
        return preview
    }

    func updateUIViewController(_ preview: QLPreviewController, context: Context) {
        guard context.coordinator.url != url else { return }
        context.coordinator.url = url
        preview.reloadData()
    }

    final class Source: NSObject, QLPreviewControllerDataSource {
        var url: URL
        init(url: URL) { self.url = url }
        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }
        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem { url as NSURL }
    }
}
#else
struct FilePreviewPanel: View {
    var url: URL
    var body: some View { Text(url.lastPathComponent) }
}
#endif
