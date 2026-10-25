import SwiftUI
import NollieCore

/// Instructions: what the bot is for, its instructions and the Private switch. Where its
/// instructions live, and Delete bot, wait under Advanced.
struct ProfileInstructionsTab: View {
    @Bindable var state: ProfileCardState

    var body: some View {
        if state.isPrivate {
            CardHeadline(symbol: "lock.fill", tint: .purple, title: "Private", titleTint: .purple,
                         line: "Hidden from notifications, the chat list and backups.", id: "profile.instructions.hero")
        } else {
            CardHeadline(symbol: "text.quote", tint: state.tint, title: "How \(state.label) works",
                         line: state.savedBlurb.isEmpty ? "Say what it's for." : nil, id: "profile.instructions.hero")
        }
        blurbField
        GlassLink("Edit instructions", symbol: "doc.text", id: "profile.instructions") {
            SoulEditorView(profileName: state.name)
        }
        GlassSwitch("Private", isOn: $state.isPrivate, id: "bot.editor.private")
            .disabled(state.savingPrivacy)
            .onAppear { state.isPrivate = state.isHidden }
            .onChange(of: state.isPrivate) { _, on in Task { await state.setPrivacy(on) } }
        // Private stays above the controls it hides once it is on.
        if !state.savingPrivacy, !state.isPrivate, !AskFirstModel.isPrivateBot(state.name) {
            AskFirstSection(profileName: state.name, label: state.label)
        }
        AdvancedLink(id: "profile.instructions.advanced") {
            InstructionsAdvanced(state: state)
        }
    }

    private var blurbField: some View {
        VStack(spacing: 12) {
            PageHeading("Description")
            TextField("Description", text: $state.blurb, prompt: Text("What it's for"), axis: .vertical)
                .lineLimit(1...4)
                .textFieldStyle(.plain)
                .onSubmit { Task { await state.saveBlurb() } }
                .inset(h: 20, v: 14)
                .background(Ink.field, in: .rect(cornerRadius: 24, style: .continuous))
                .accessibilityIdentifier("profile.description")
            if state.blurb != (state.info?.description ?? "") {
                Button { Task { await state.saveBlurb() } } label: {
                    Text("Save description").font(.headline).spread(.center).inset(v: 6)
                }
                .buttonStyle(.nollieGlassProminent)
                .buttonBorderShape(.capsule)
                .accessibilityIdentifier("profile.description.save")
            }
        }
    }
}
