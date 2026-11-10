import SwiftUI
import NollieCore

/// What's new, as a sheet: Nollie at the top, a line of welcome, then each change with where to find it.
/// More opens the longer telling for anyone who wants it. One button closes it.
struct WhatsNewSheet: View {
    var notes: [WhatsNewNote]
    @Environment(\.dismiss) private var dismiss
    @State private var open: Set<String> = []
    @ScaledMetric(relativeTo: .largeTitle) private var face: CGFloat = 92

    var body: some View {
        ScrollView {
            VStack(spacing: 30) {
                masthead
                ForEach(notes) { note in
                    VStack(alignment: .leading, spacing: 26) {
                        if notes.count > 1 {
                            Text(verbatim: Self.versionWords(note.version))
                                .font(.title3.weight(.semibold)).foregroundStyle(Ink.text)
                                .accessibilityAddTraits(.isHeader)
                        }
                        ForEach(note.items.filter(\.showsHere)) { item in
                            WhatsNewRow(item: item, isOpen: open.contains(note.version + item.id)) {
                                withAnimation(.smooth(duration: 0.25)) { toggle(note.version + item.id) }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                Text("You can read this again in Settings, under About.")
                    .font(.footnote).foregroundStyle(Ink.text2)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: 520)
            .padding(EdgeInsets(top: 34, leading: 26, bottom: 24, trailing: 26))
            .frame(maxWidth: .infinity)
        }
        .background(Ink.canvas.ignoresSafeArea())
        .safeAreaInset(edge: .bottom) {
            Button { dismiss() } label: {
                Text("Got it").fullWidthLabel()
            }
            .pageAction()
            .testID("whatsNew.done")
            .frame(maxWidth: 520)
            .padding(.horizontal, 26).padding(.bottom, 14).padding(.top, 10)
            .frame(maxWidth: .infinity)
            // The page ends behind the button, never showing through around it.
            .background(Ink.canvas)
        }
        .sheetFrame(.form)
    }

    private var masthead: some View {
        VStack(spacing: 12) {
            BotAvatar(profile: "default", size: face, state: .done, photos: false)
            Text("What's new")
                .font(.largeTitle.weight(.bold)).foregroundStyle(Ink.text)
                .accessibilityAddTraits(.isHeader)
                .testID("whatsNew.title")
            if let first = notes.first {
                if notes.count == 1 {
                    Text(verbatim: Self.versionWords(first.version))
                        .font(.subheadline.weight(.medium)).foregroundStyle(Ink.text2)
                }
                Text(first.lead)
                    .font(.title3).foregroundStyle(Ink.text2)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func toggle(_ key: String) {
        if open.contains(key) { open.remove(key) } else { open.insert(key) }
    }

    /// "Nollie 1.3.3".
    static func versionWords(_ version: String) -> String {
        String(localized: "Nollie \(version)", comment: "The app's name and a version number")
    }
}

/// One change: its symbol, what it is in a sentence, where it lives on a small glass pill, and More.
private struct WhatsNewRow: View {
    var item: WhatsNewNote.Item
    var isOpen: Bool
    var toggle: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: item.symbol)
                .symbolRenderingMode(.hierarchical)
                .font(.system(size: 30, weight: .medium))
                .foregroundStyle(.tint)
                .frame(width: 44, alignment: .center)
                .padding(.top, 2)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 8) {
                Text(item.title).font(.headline).foregroundStyle(Ink.text)
                    .fixedSize(horizontal: false, vertical: true)
                Text(item.line).font(.body).foregroundStyle(Ink.text2)
                    .fixedSize(horizontal: false, vertical: true)
                if isOpen, let more = item.more {
                    Text(more).font(.body).foregroundStyle(Ink.text)
                        .fixedSize(horizontal: false, vertical: true)
                        .transition(.opacity)
                        .testID("whatsNew.more.\(item.id)")
                }
                pills
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .contain)
        .testID("whatsNew.item.\(item.id)")
    }

    /// Where to find it, and the way to the longer telling. They wrap under each other on a narrow screen.
    private var pills: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) { place; moreButton }
            VStack(alignment: .leading, spacing: 8) { place; moreButton }
        }
        .padding(.top, 2)
    }

    @ViewBuilder private var place: some View {
        if let place = item.place {
            Label(place, systemImage: "mappin")
                .font(.footnote.weight(.medium)).foregroundStyle(Ink.text2)
                .padding(.horizontal, 12).padding(.vertical, 7)
                .nollieGlass(.regular, in: Capsule(), solid: Ink.card)
                .accessibilityLabel(Text("Where to find it: \(place)"))
        }
    }

    @ViewBuilder private var moreButton: some View {
        if item.more != nil {
            Button(action: toggle) {
                Text(isOpen ? "Less" : "More")
                    .font(.footnote.weight(.semibold))
                    .padding(.horizontal, 14).padding(.vertical, 7)
                    .frame(minHeight: 30)
                    .contentShape(Capsule())
                    .nollieGlass(.regular, in: Capsule(), solid: Ink.card)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.tint)
            .testID("whatsNew.toggle.\(item.id)")
        }
    }
}

/// Shows the note once after an update, to someone who already had Nollie set up. Never in the demo copy
/// (its flows start from a known screen), never over a locked app, and never while tests drive the app.
private struct WhatsNewHost: ViewModifier {
    @Environment(AppModel.self) private var model
    @AppStorage(WhatsNew.seenKey) private var seen: String?
    @State private var showing: [WhatsNewNote] = []

    private static var underTest: Bool { ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil }

    func body(content: Content) -> some View {
        content
            .task(id: model.lock.isLocked) { await offer() }
            .sheet(isPresented: Binding(get: { !showing.isEmpty }, set: { if !$0 { close() } })) {
                WhatsNewSheet(notes: showing).withAppModel()
            }
    }

    private func offer() async {
        #if DEBUG
        // For pictures: `-nollie-demo-whats-new` opens the newest note in the demo copy.
        if DemoMode.isOn, ProcessInfo.processInfo.arguments.contains("-nollie-demo-whats-new") {
            try? await Task.sleep(for: .seconds(2))
            showing = WhatsNew.note(for: WhatsNew.currentVersion, in: WhatsNew.notes).map { [$0] } ?? []
            return
        }
        #endif
        // Only over the chats of someone already set up, never over the Mac's welcome.
        guard !DemoMode.isOn, !Self.underTest, model.hasConnections, !model.lock.isLocked, showing.isEmpty else { return }
        let due = WhatsNew.pending(seen: seen, current: WhatsNew.currentVersion, notes: WhatsNew.notes)
        guard !due.isEmpty else {
            // An update with no note of its own still counts as seen, so an older note never comes back.
            if seen != nil, seen != WhatsNew.currentVersion { WhatsNew.markSeen() }
            return
        }
        // Let the chats settle first, so the sheet doesn't land on a screen still drawing itself.
        try? await Task.sleep(for: .seconds(1.2))
        guard !Task.isCancelled, !model.lock.isLocked else { return }
        showing = due
    }

    private func close() {
        showing = []
        if !DemoMode.isOn { WhatsNew.markSeen() }
    }
}

extension View {
    func whatsNewHost() -> some View { modifier(WhatsNewHost()) }
}

/// Settings › About: the newest note, to read again.
struct WhatsNewAgainButton: View {
    @State private var open = false

    var body: some View {
        GlassButton("What's new", symbol: "sparkles", id: "about.whatsNew") { open = true }
            .sheet(isPresented: $open) {
                WhatsNewSheet(notes: WhatsNew.note(for: WhatsNew.currentVersion, in: WhatsNew.notes).map { [$0] } ?? [])
                    .withAppModel()
            }
    }
}
