import SwiftUI
import NollieCore

/// One tab per section of the bot card. A new case shows up without the header or the row changing.
enum ProfileTab: String, CaseIterable, Identifiable {
    case thisChat, look, instructions, model, papertrail, apps, computer, display

    var id: String { rawValue }

    var title: String { self == .thisChat ? "This chat" : rawValue.capitalized }

    /// Tabs for a card. "This chat" needs a chat to be open, and a private bot has no Papertrail.
    static func available(withChat: Bool, privateBot: Bool = false) -> [ProfileTab] {
        var hidden = Set<ProfileTab>()
        if !withChat { hidden.insert(.thisChat) }
        if privateBot { hidden.insert(.papertrail) }
        return allCases.filter { !hidden.contains($0) }
    }

    /// The tab an arrow key lands on: `delta` steps over, stopping at either end.
    static func moved(from tab: ProfileTab, by delta: Int, in tabs: [ProfileTab]) -> ProfileTab {
        guard let at = tabs.firstIndex(of: tab) else { return tabs.first ?? tab }
        let target = at + delta
        return tabs[target < 0 ? 0 : min(target, tabs.count - 1)]
    }
}

/// A sideways row of glass pills. The chosen one is filled with ink. They sit in the middle when
/// they fit, and scroll sideways otherwise. Every pill is focusable, so Tab gets to them and the
/// arrow keys change the choice. VoiceOver reads it as a tab bar.
struct ProfileTabRow: View {
    let tabs: [ProfileTab]
    @Binding private var selected: ProfileTab

    init(tabs: [ProfileTab], selected: Binding<ProfileTab>) {
        self.tabs = tabs
        _selected = selected
    }

    @State private var rowWidth: CGFloat = 0
    @FocusState private var focusedTab: ProfileTab?

    private static let glide = Animation.snappy(duration: 0.25)

    var body: some View {
        ScrollViewReader { proxy in strip(proxy) }
            .modifier(TabBarSemantics())
    }

    private func strip(_ proxy: ScrollViewProxy) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) { ForEach(tabs, content: pill) }
                .inset(h: 16, v: 6)
                .frame(minWidth: rowWidth)
        }
        .onGeometryChange(for: CGFloat.self, of: { $0.size.width }, action: { rowWidth = $0 })
        .onAppear { proxy.scrollTo(selected, anchor: .center) }
        .onChange(of: selected) { _, tab in
            withAnimation(Self.glide) { proxy.scrollTo(tab, anchor: .center) }
        }
        .onKeyPress(.leftArrow) { step(-1) }
        .onKeyPress(.rightArrow) { step(+1) }
    }

    private func pill(_ tab: ProfileTab) -> some View {
        let on = tab == selected
        return PlainButton(action: { choose(tab) }, label: { pillFace(tab, on: on) })
            .focusable()
            .focused($focusedTab, equals: tab)
            .accessibilityAddTraits(on ? [.isSelected] : [])
            .accessibilityIdentifier("profile.tab." + tab.rawValue)
            .id(tab)
    }

    private func pillFace(_ tab: ProfileTab, on: Bool) -> some View {
        Text(tab.title)
            .font(.subheadline.weight(on ? .semibold : .medium))
            .foregroundStyle(on ? Ink.onInk : Ink.text2)
            .lineLimit(1)
            .fixedSize()
            .inset(h: 16, v: 10)
            .background { if on { Capsule().fill(Ink.ink) } }
            .nollieGlass(on ? .regular.tint(Ink.ink) : .regular, in: Capsule(), solid: on ? Ink.ink : Ink.canvas)
            .contentShape(.capsule)
    }

    private func choose(_ tab: ProfileTab) {
        withAnimation(Self.glide) { selected = tab }
    }

    /// Arrow key with a pill focused: selection and focus travel together.
    private func step(_ delta: Int) -> KeyPress.Result {
        guard let here = focusedTab else { return .ignored }
        let next = ProfileTab.moved(from: here, by: delta, in: tabs)
        guard next != here else { return .handled }
        choose(next)
        focusedTab = next
        return .handled
    }
}

/// Marks the row of tabs as one tab bar for VoiceOver and for tests.
private struct TabBarSemantics: ViewModifier {
    func body(content: Content) -> some View {
        content
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Sections")
            .accessibilityAddTraits(.isTabBar)
            .accessibilityIdentifier("profile.tabs")
    }
}

/// The draft of the bot's instructions (its SOUL.md): the text on the gateway, the text being
/// edited, and the calls that load and store it.
@MainActor @Observable
final class SoulDraft {
    let profile: String
    var text = ""
    private(set) var saved = ""
    private(set) var loading = true
    private(set) var saving = false
    private(set) var failure: String?

    var isChanged: Bool { text != saved }
    private var route: String { "/api/profiles/\(profile)/soul" }

    init(profile: String) {
        self.profile = profile
    }

    func read(from runtime: GatewayRuntime?) async {
        defer { loading = false }
        guard let runtime else { return }
        do {
            let reply: JSONValue = try await runtime.api.get(route)
            saved = reply["content"]?.stringValue ?? ""
            text = saved
        } catch {
            failure = error.localizedDescription
        }
    }

    /// Stores the draft. True if the gateway accepted it.
    func write(to runtime: GatewayRuntime?) async -> Bool {
        guard let runtime else { return false }
        saving = true
        defer { saving = false }
        do {
            let body = JSONValue.object(["content": .string(text)])
            let _: JSONValue = try await runtime.api.send("PUT", route, json: body)
            saved = text
            failure = nil
            return true
        } catch {
            failure = error.localizedDescription
            return false
        }
    }
}

/// Full-screen editor for the bot's instructions (SOUL.md). The check mark stores them.
struct SoulEditorView: View {
    var profileName: String

    @Environment(\.dismiss) private var dismiss
    @Environment(AppModel.self) private var model
    @State private var soul: SoulDraft

    init(profileName: String) {
        self.profileName = profileName
        _soul = State(initialValue: SoulDraft(profile: profileName))
    }

    var body: some View {
        content
            .navigationTitle("Instructions")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { saveButton }
            .safeAreaInset(edge: .bottom) { failureNote }
            .task { await soul.read(from: model.runtime) }
    }

    @ViewBuilder private var content: some View {
        if soul.loading {
            ProgressView("Loading instructions…")
        } else {
            editor
        }
    }

    @ViewBuilder private var failureNote: some View {
        if let failure = soul.failure { Text(failure).quiet(.footnote, .red).padding(8) }
    }

    @ToolbarContentBuilder private var saveButton: some ToolbarContent {
        ToolbarItem(placement: .confirmationAction) {
            Button(action: store) {
                if soul.saving { ProgressView() } else { Image(systemName: "checkmark") }
            }
            .disabled(soul.saving || !soul.isChanged)
            .accessibilityLabel("Save instructions")
        }
    }

    private var editor: some View {
        TextEditor(text: $soul.text)
            .font(.body.monospaced())
            .scrollContentBackground(.hidden)
            .inset(h: 8)
            .overlay(alignment: .topLeading) { placeholder }
    }

    @ViewBuilder private var placeholder: some View {
        if soul.text.isEmpty {
            Text("Say how this bot should work…")
                .foregroundStyle(.tertiary)
                .padding(EdgeInsets(top: 8, leading: 13, bottom: 0, trailing: 0))
                .allowsHitTesting(false)
        }
    }

    private func store() {
        Task { if await soul.write(to: model.runtime) { dismiss() } }
    }
}
