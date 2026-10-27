import SwiftUI

extension LocalizedStringResource {
    /// Words already worked out in code (a name, a sentence built with `String(localized:)`), shown as they are.
    /// Our views take `LocalizedStringResource`, so a literal is looked up in the catalog and this passes the rest.
    static func verbatim(_ text: String) -> LocalizedStringResource {
        // A table that does not exist: the lookup misses and the text itself is shown.
        LocalizedStringResource(String.LocalizationValue(text), table: "Verbatim")
    }

    static func verbatim(_ text: String?) -> LocalizedStringResource? { text.map { verbatim($0) } }
}

/// Runs `work` again and again, `seconds` apart, until the surrounding task is cancelled. The
/// first run comes after the first pause, so call it after an initial read.
@MainActor
func repeatEvery(_ seconds: Double, _ work: () async -> Void) async {
    while !Task.isCancelled {
        try? await Task.sleep(for: .seconds(seconds))
        guard !Task.isCancelled else { return }
        await work()
    }
}

/// A centred message for a page with nothing to show, with an optional second line.
struct Placeholder: View {
    let title: String
    let symbol: String
    var detail: String?

    init(_ title: LocalizedStringResource, symbol: String, detail: LocalizedStringResource? = nil) {
        self.init(verbatim: String(localized: title), symbol: symbol, detail: detail.map { String(localized: $0) })
    }

    fileprivate init(verbatim title: String, symbol: String, detail: String? = nil) {
        self.title = title
        self.symbol = symbol
        self.detail = detail
    }

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: symbol)
        } description: {
            if let detail { Text(detail) }
        }
    }
}

extension View {
    /// The identifier UI tests find this view by.
    func testID(_ identifier: String) -> some View {
        accessibilityIdentifier(identifier)
    }

    /// A small centred title in the navigation bar.
    func inlineTitle(_ title: LocalizedStringResource) -> some View {
        inlineTitle(verbatim: String(localized: title))
    }

    fileprivate func inlineTitle(verbatim title: String) -> some View {
        navigationTitle(title).navigationBarTitleDisplayMode(.inline)
    }
}

extension View {
    /// A one-button alert that shows `message` while it is set, and clears it on OK. `showing`
    /// lets a page hold the alert back for a moment.
    func noticeAlert(_ title: LocalizedStringResource, _ message: Binding<String?>, showing: Bool = true) -> some View {
        noticeAlert(verbatim: String(localized: title), message, showing: showing)
    }

    fileprivate func noticeAlert(verbatim title: String, _ message: Binding<String?>, showing: Bool = true) -> some View {
        alert(
            title,
            isPresented: Binding(
                get: { showing && message.wrappedValue != nil },
                set: { if !$0 { message.wrappedValue = nil } })
        ) {
            Button("OK") { message.wrappedValue = nil }
        } message: {
            Text(message.wrappedValue ?? "")
        }
    }
}

/// Turns an async method into a button action that runs it in a task.
func asTask(_ work: @escaping @MainActor () async -> Void) -> () -> Void {
    { Task { await work() } }
}

extension Binding where Value == Bool {
    /// A switch that is on while `item` holds a value. Turning it off clears the value.
    static func present<Wrapped>(_ item: Binding<Wrapped?>) -> Binding<Bool> {
        Binding(get: { item.wrappedValue != nil }, set: { if !$0 { item.wrappedValue = nil } })
    }
}

extension View {
    /// The column a small card sheet lays its content in: padded at the sides and bottom, 420
    /// wide on the Mac and up to 440 on the phone.
    func sheetColumn() -> some View {
        padding(EdgeInsets(top: 0, leading: 28, bottom: 24, trailing: 28))
            .modifier(SheetColumnWidth())
    }
}

private struct SheetColumnWidth: ViewModifier {
    func body(content: Content) -> some View {
        #if os(macOS)
        content.frame(width: 420)
        #else
        content.frame(maxWidth: 440)
        #endif
    }
}

extension View {
    /// Limits a page to a comfortable column centred in a wide Mac window. No effect on the phone.
    func readingColumn(_ width: CGFloat = 720) -> some View {
        #if os(macOS)
        frame(maxWidth: width).frame(maxWidth: .infinity)
        #else
        self
        #endif
    }
}
