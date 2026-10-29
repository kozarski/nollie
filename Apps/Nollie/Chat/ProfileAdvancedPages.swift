import SwiftUI
import NollieCore

/// The pages behind each tab's Advanced row. Each says the one thing that matters first, then
/// the facts word for word.

/// Model: every model by its own name (an API key's included), what is saved now, and the home folder.
struct ModelAdvanced: View {
    var state: ProfileCardState

    var body: some View {
        SettingsPage("profile.model.advanced.page") {
            PageHero(symbol: "key.fill", title: "Use an API key", line: "Or any model by its name.", tint: Ink.text,
                     id: "profile.model.advanced.hero")
            if let providers = state.options?.providers {
                Menu {
                    ForEach(providers) { provider in
                        Section(provider.name) {
                            ForEach(provider.models ?? [], id: \.self) { model in
                                Button(model) { Task { await state.saveModel(provider: provider.slug, model: model) } }
                            }
                        }
                    }
                } label: {
                    CardChoiceLabel(title: String(localized: "Every model"), symbol: "list.bullet", tint: Ink.text2, value: nil, menu: true)
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .accessibilityIdentifier("profile.model.every")
            } else {
                ProgressView().frame(maxWidth: .infinity, minHeight: 60)
            }
            if let note = state.note { CardNote(words: note, saved: state.noteSaved) }
            CardFacts(facts: [
                CardFact(title: "Saved now", value: state.savedModel, monospaced: true),
                state.info?.path.flatMap { $0.isEmpty ? nil : CardFact(title: "Home", value: $0, monospaced: true) },
                state.lastProblem.map { CardFact(title: "Last problem", value: $0) },
            ].compactMap { $0 })
        }
        .untitledPage()
    }
}

/// Instructions: where they are kept, and Delete bot last.
struct InstructionsAdvanced: View {
    var state: ProfileCardState
    @State private var asking = false

    var body: some View {
        SettingsPage("profile.instructions.advanced.page") {
            if state.lastProblem != nil {
                PageHero(symbol: "exclamationmark.triangle.fill", title: "That change didn't go through", tint: .orange,
                         id: "profile.instructions.advanced.hero")
            } else {
                PageHero(symbol: "doc.text.fill", title: "Instructions in one file", line: "Kept with \(state.label)'s settings.",
                         tint: Ink.text, id: "profile.instructions.advanced.hero")
            }
            CardFacts(facts: [
                state.info?.path.flatMap { $0.isEmpty ? nil : CardFact(title: "Instructions file", value: $0 + "/SOUL.md", monospaced: true) },
                state.lastProblem.map { CardFact(title: "Last problem", value: $0) },
            ].compactMap { $0 })
            if state.mayDelete {
                GlassButton("Delete \(state.label)…", symbol: "trash", role: .destructive, id: "bot.editor.delete") { asking = true }
                    .disabled(state.deleting)
                    .confirmationDialog("Delete \(state.label)?", isPresented: $asking, titleVisibility: .visible) {
                        Button("Delete bot", role: .destructive) { Task { await state.deleteBot() } }
                    } message: { Text("Its instructions, settings and chats are removed. This can't be undone.") }
            }
        }
        .untitledPage()
    }
}

/// This chat: the model it runs on at the top, and how much of its memory it has used.
struct ThisChatAdvanced: View {
    var model: String?
    var context: String?

    var body: some View {
        SettingsPage("profile.thisChat.advanced.page") {
            PageHero(symbol: model == nil ? "gauge.with.dots.needle.33percent" : "cpu", title: model.map { .verbatim($0) } ?? "How full this chat is",
                     line: context.map { LocalizedStringResource("\($0) used.", comment: "How much of the chat's context is used, like 40% of 200,000") },
                     tint: Ink.text, id: "profile.thisChat.advanced.hero")
            CardFacts(facts: [
                model.map { CardFact(title: "Model for this chat", value: $0, monospaced: true) },
                context.map { CardFact(title: "Context", value: $0) },
            ].compactMap { $0 })
        }
        .untitledPage()
    }
}

/// Computer: how its own computer is (name, Start fresh, Remove), Nollie Computer and the Mac's
/// permissions for it (Mac only), and the last problem word for word.
struct ComputerAdvanced: View {
    var state: ProfileCardState
    #if os(macOS) && NOLLIE_DIRECT
    @AppStorage(ComputerCenter.enabledKey) private var computerOn = false
    #endif

    private var own: HelperComputerModel? { state.mayHaveOwnComputer ? state.ownComputer : nil }
    private var problem: String? { SystemControl.shared.lastError }

    var body: some View {
        SettingsPage("profile.computer.advanced.page") {
            if let own {
                HelperComputerAdvancedHero(computer: own, name: state.label)
                HelperComputerAdvanced(computer: own)
            } else if problem != nil {
                PageHero(symbol: "exclamationmark.triangle.fill", title: "That change didn't go through", tint: .orange,
                         id: "profile.computer.advanced.hero")
            } else {
                PageHero(symbol: "cursorarrow.rays", title: "How \(state.label) uses your Mac", tint: Ink.text,
                         id: "profile.computer.advanced.hero")
            }
            #if os(macOS) && NOLLIE_DIRECT
            if own != nil { PageHeading("Using this Mac") }
            GlassStack {
                // The switch, the model on this Mac and the apps a bot may use, for every bot.
                GlassLink("Apps on this Mac", symbol: "macwindow.and.cursorarrow", value: computerOn ? String(localized: "On", comment: "A switch state")
                                                                                             : String(localized: "Off", comment: "A switch state"),
                          id: "profile.computerApps") { ComputerAppsPage() }
                if computerOn {
                    GlassButton("Mac permissions", symbol: "lock.shield", id: "profile.computerPermissions") {
                        ComputerPanels.shared.showPermissions()
                    }
                }
            }
            #endif
            if let problem {
                CardFacts(facts: [CardFact(title: own == nil ? "Last problem" : "Last problem with Mac control", value: problem)])
            }
        }
        .untitledPage()
    }
}
