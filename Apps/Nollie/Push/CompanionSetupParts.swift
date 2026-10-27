import SwiftUI

/// Section titles sit slightly further above their cards than the system default.
func sectionHeader(_ title: String) -> some View {
    Text(title).padding(EdgeInsets(top: 0, leading: 0, bottom: 6, trailing: 0))
}

// MARK: - Small text styles shared by the setup screens

/// How loud a footnote is.
enum Tone {
    case quiet, warning, problem, good

    var colour: Color {
        switch self {
        case .quiet: .secondary
        case .warning: .orange
        case .problem: .red
        case .good: .green
        }
    }
}

extension View {
    /// Footnote-sized text in a tone.
    func note(_ tone: Tone = .quiet) -> some View {
        font(.footnote).foregroundStyle(tone.colour)
    }

    /// The dark, slightly see-through well the install log and the update console sit in.
    func darkWell() -> some View {
        background(.black.opacity(0.35), in: .rect(cornerRadius: 10))
    }
}

/// A footnote with an icon, for a result or a warning inside a form.
struct StatusNote: View {
    let text: String
    let symbol: String
    let tone: Tone

    init(_ text: String, symbol: String, tone: Tone = .quiet) {
        self.text = text
        self.symbol = symbol
        self.tone = tone
    }

    var body: some View {
        Label(text, systemImage: symbol).note(tone)
    }
}

/// A label that shows a spinner where its icon would be.
struct SpinnerLabel: View {
    let title: String

    init(_ title: String) { self.title = title }

    var body: some View {
        Label(title: { Text(title) }, icon: { ProgressView() })
    }
}

/// A button with a spinner in place of its icon while `busy`.
struct BusyButton: View {
    let title: String
    let busyTitle: String
    let symbol: String
    let busy: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            if busy { SpinnerLabel(busyTitle) } else { Label(title, systemImage: symbol) }
        }
        .disabled(busy)
    }
}

// MARK: - Form building blocks

/// A form section with an optional title above and note below.
struct FormCard<Rows: View>: View {
    let title: String?
    let note: String?
    let rows: () -> Rows

    init(_ title: String? = nil, note: String? = nil, @ViewBuilder rows: @escaping () -> Rows) {
        self.title = title
        self.note = note
        self.rows = rows
    }

    var body: some View {
        Section(content: rows, header: { title.map(sectionHeader) }, footer: { note.map { Text($0) } })
    }
}

/// A tappable row with an icon.
struct ActionRow: View {
    let title: String
    let symbol: String
    let role: ButtonRole?
    let action: () -> Void

    init(_ title: String, symbol: String, role: ButtonRole? = nil, action: @escaping () -> Void) {
        self.title = title
        self.symbol = symbol
        self.role = role
        self.action = action
    }

    var body: some View {
        Button(role: role, action: action) { Label(title, systemImage: symbol) }
    }
}

// MARK: - Step page

/// One wizard step: a floating card (the bot's line and the step's title) over a form that scrolls under it.
struct StepPage<Content: View, Header: View>: View {
    let step: PushSetupView.SetupStep
    let done: Bool
    private var heading: String { step.title }
    @Binding var headerHeight: CGFloat
    @ViewBuilder var content: () -> Content
    @ViewBuilder var header: () -> Header

    var body: some View {
        let mast = StepMast(title: heading, height: $headerHeight, art: header)
        Form { content() }
            .contentMargins(.bottom, 120, for: .scrollContent)
            .overlay(alignment: .top) { mast }
            .contentMargins(.top, headerHeight + 10, for: .scrollContent)
            .listSectionSpacing(24)
            .scrollContentBackground(.hidden)
            .modifier(RoomyOnMac())
    }
}

/// On the Mac the form is a grouped column, capped in width and centred.
private struct RoomyOnMac: ViewModifier {
    func body(content: Content) -> some View {
        #if os(macOS)
        content
            .formStyle(.grouped)
            .frame(maxWidth: 700)
            .frame(maxWidth: .infinity)
        #else
        content
        #endif
    }
}

/// The card floating over the top of a step: the bot, then the step's name, fading into the page.
private struct StepMast<Art: View>: View {
    let title: String
    @Binding var height: CGFloat
    @ViewBuilder var art: () -> Art

    var body: some View {
        VStack(spacing: 10) {
            art()
            Text(title)
                .contentTransition(.numericText())
                .font(.title2.bold())
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(EdgeInsets(top: 14, leading: 0, bottom: 12, trailing: 0))
        .background { fade.ignoresSafeArea() }
        .onGeometryChange(for: CGFloat.self, of: \.size.height) { height = $0 }
    }

    private var fade: some View {
        let page = Color(.systemGroupedBackground)
        return LinearGradient(colors: [page, page, .clear], startPoint: .top, endPoint: .bottom)
    }
}

// MARK: - Values and files

/// A value that may be too long: cut off with an ellipsis, and a tap shows all of it for a few seconds.
struct PeekableValue: View {
    let text: String
    let full: String?
    @State private var closing: Task<Void, Never>?

    private var isOpen: Binding<Bool> {
        Binding(get: { closing != nil }, set: { open in if !open { closing = nil } })
    }

    var body: some View {
        Text(text)
            .small(.subheadline)
            .lineLimit(1)
            .onTapGesture { if full != nil { peek() } }
            .popover(isPresented: isOpen, arrowEdge: .bottom) {
                FullValue(text: full ?? text).withAppModel()
            }
    }

    /// Opens the popover and closes it again after five seconds.
    private func peek() {
        closing?.cancel()
        closing = Task {
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            if !Task.isCancelled { closing = nil }
        }
    }
}

/// The whole value, in monospace and selectable, inside the popover.
private struct FullValue: View {
    let text: String

    var body: some View {
        Text(text)
            .fixedSize()
            .textSelection(.enabled)
            .font(.footnote.monospaced())
            .inset(h: 12, v: 6)
            .presentationCompactAdaptation(.popover)
    }
}

/// Lists the files an install wrote in a small dark window, folding down to one line when done.
struct InstalledFilesWindow: View {
    let files: [PushSetupModel.InstalledFile]
    let finished: Bool
    @State private var folded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            WindowBar(title: finished ? String(localized: "Installed \(files.count) files") : String(localized: "Writing files…"), folded: folded) {
                withAnimation(.smooth(duration: 0.3)) { folded.toggle() }
            }
            FileLines(files: files)
                .frame(maxHeight: folded ? 0 : nil, alignment: .top)
                .opacity(folded ? 0 : 1)
                .clipped()
        }
        .darkWell()
        .onChange(of: finished) { _, isFinished in
            if isFinished { foldSoon() }
        }
    }

    private func foldSoon() {
        Task {
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            withAnimation(.smooth(duration: 0.35)) { folded = true }
        }
    }
}

/// The title strip of the window: three dots, a caption and a chevron that turns when folded.
private struct WindowBar: View {
    let title: String
    let folded: Bool
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 8) {
                HStack(spacing: 5) {
                    ForEach([Color.red, .yellow, .green], id: \.self) { colour in
                        Circle().fill(colour.opacity(0.8)).frame(square: 9)
                    }
                }
                Text(title).small(.caption.weight(.medium))
                Spacer()
                Image(systemName: "chevron.down")
                    .small(.caption2.bold())
                    .rotationEffect(.degrees(folded ? -90 : 0))
            }
            .inset(h: 12, v: 8)
        }
        .buttonStyle(.plain)
    }
}

/// One line per file written, with its folder under it.
private struct FileLines: View {
    let files: [PushSetupModel.InstalledFile]

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(files, id: \.self) { file in
                HStack(spacing: 8) {
                    Text("+").foregroundStyle(.green)
                    Text(file.name)
                    Spacer()
                    Text(Self.sizeText(file.bytes)).foregroundStyle(.secondary)
                }
                .font(.caption.monospaced())
                Text(file.directory).small(.caption2.monospaced(), .tertiary).padding(.leading, 18)
            }
        }
        .padding(EdgeInsets(top: 0, leading: 12, bottom: 10, trailing: 12))
    }

    private static func sizeText(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}
