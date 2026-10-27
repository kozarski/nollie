import SwiftUI
import NollieCore

/// A quick answer conversation: Nollie at the top, what stays on this device, the exchanges, and a
/// message box. Each answer can be copied and, away from the Mac, handed to Nollie there.
struct QuickAnswerSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var answers: QuickAnswers
    @State private var draft = ""
    @FocusState private var typing: Bool
    /// Debug: questions asked by themselves when the sheet opens, for pictures.
    private let script: [String]

    init(place: QuickAnswerRules.Place, script: [String] = []) {
        _answers = State(initialValue: QuickAnswers(place: place))
        self.script = script
    }

    private var place: QuickAnswerRules.Place { answers.place }

    var body: some View {
        #if os(macOS)
        VStack(spacing: 0) {
            HStack {
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark").font(.body.weight(.semibold)).frame(square: 32)
                }
                .buttonStyle(.nollieGlass)
                .buttonBorderShape(.circle)
                .keyboardShortcut(.cancelAction)
                .accessibilityLabel("Close")
                .testID("quickAnswer.close")
            }
            .padding([.top, .horizontal], 16)
            thread
        }
        .frame(minWidth: 520, idealWidth: 600, minHeight: 600, idealHeight: 700)
        .background(Ink.canvas)
        #else
        NavigationStack {
            thread
                .background(Ink.canvas.ignoresSafeArea())
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }.testID("quickAnswer.close")
                    }
                }
                .navigationBarTitleDisplayMode(.inline)
        }
        #endif
    }

    private var thread: some View {
        ScrollViewReader { reader in
            ScrollView {
                VStack(spacing: 22) {
                    header
                    if answers.turns.isEmpty { starters }
                    ForEach(answers.turns) { turn in
                        VStack(alignment: .leading, spacing: 10) {
                            question(turn.question)
                            reply(turn)
                        }
                        .id(turn.id)
                    }
                    Color.clear.frame(height: 1).id("end")
                }
                .frame(maxWidth: 640)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 20)
                .padding(.bottom, 16)
            }
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: answers.turns.last?.answer) {
                withAnimation(reduceMotion ? nil : .snappy) { reader.scrollTo("end", anchor: .bottom) }
            }
            .onChange(of: answers.turns.count) {
                withAnimation(reduceMotion ? nil : .snappy) { reader.scrollTo("end", anchor: .bottom) }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { composer }
        .task { await playScript() }
    }

    // MARK: Header

    private var header: some View {
        VStack(spacing: 12) {
            CharacterView(look: .main, state: answers.isWriting ? .thinking : .listening, size: 84)
                .accessibilityHidden(true)
            Text("Quick answer")
                .font(.system(.title2, design: .rounded, weight: .bold))
                .foregroundStyle(Ink.text)
                .accessibilityAddTraits(.isHeader)
            FlowLayout(spacing: 8) {
                badge("lock.fill", "Stays on \(DeviceWords.this)")
                badge("bubble.left.fill", "Talk only")
            }
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityElement(children: .combine)
            .testID("quickAnswer.promise")
        }
        .padding(.top, 8)
        .frame(maxWidth: .infinity)
    }

    private func badge(_ symbol: String, _ words: String) -> some View {
        Label(words, systemImage: symbol)
            .font(.subheadline.weight(.medium))
            .foregroundStyle(Ink.text2)
            .padding(.horizontal, 14).padding(.vertical, 8)
            .nollieGlass(.regular, in: Capsule())
    }

    // MARK: Starters

    private static let starterIdeas: [(symbol: String, words: String, prompt: String)] = [
        ("text.bubble", "Reword a message", "Reword this so it sounds warmer: "),
        ("lightbulb", "Explain something", "Explain simply: "),
        ("fork.knife", "Ideas for dinner", "What could I cook tonight with "),
    ]

    private var starters: some View {
        VStack(spacing: 10) {
            ForEach(Self.starterIdeas, id: \.words) { idea in
                Button {
                    draft = idea.prompt
                    typing = true
                } label: {
                    Label(idea.words, systemImage: idea.symbol)
                        .font(.body.weight(.medium))
                        .padding(.horizontal, 6).padding(.vertical, 4)
                }
                .buttonStyle(.nollieGlass)
                .buttonBorderShape(.capsule)
                .controlSize(.large)
                .tint(.primary)
            }
        }
        .padding(.top, 6)
    }

    // MARK: The exchange

    private func question(_ text: String) -> some View {
        HStack {
            Spacer(minLength: 48)
            Text(text)
                .font(Ink.message)
                .lineSpacing(Ink.lineSpacing)
                .foregroundStyle(Ink.onInk)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .inset(h: Ink.bubblePadH, v: Ink.bubblePadV)
                .background(Ink.ink, in: MessageBubbleShape(side: .trailing, tailed: true, radius: Ink.bubbleRadius))
        }
    }

    @ViewBuilder private func reply(_ turn: QuickAnswers.Turn) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            switch turn.state {
            case .failed(let failure):
                Label(failure.words, systemImage: failure == .cancelled ? "stop.circle" : "exclamationmark.circle")
                    .font(.subheadline)
                    .foregroundStyle(Ink.text2)
                    .fixedSize(horizontal: false, vertical: true)
                    .testID("quickAnswer.failed")
            default:
                answerBubble(turn)
            }
            if turn.canHandOff { actions(turn) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func answerBubble(_ turn: QuickAnswers.Turn) -> some View {
        let shown: AttributedString = turn.state == .writing
            ? AttributedString(turn.answer.isEmpty ? "…" : turn.answer)
            : Self.formatted(turn.answer)
        return HStack(alignment: .top, spacing: 0) {
            Text(shown)
                .font(Ink.message)
                .lineSpacing(Ink.lineSpacing)
                .foregroundStyle(turn.answer.isEmpty ? Ink.text3 : Ink.text)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .inset(h: Ink.bubblePadH, v: Ink.bubblePadV)
                .background(Ink.bubble, in: MessageBubbleShape(side: .leading, tailed: true, radius: Ink.bubbleRadius))
                .contentTransition(.opacity)
            Spacer(minLength: 40)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(turn.state == .writing ? "Writing" : turn.answer)
        .testID(turn.state == .writing ? "quickAnswer.writing" : "quickAnswer.answer")
    }

    /// Bold and italics as the model writes them; anything else stays as typed.
    private static func formatted(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace,
                                                              failurePolicy: .returnPartiallyParsedIfPossible)
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }

    @ViewBuilder private func actions(_ turn: QuickAnswers.Turn) -> some View {
        let needsMac: Bool = if case .helper = turn.state { true } else { false }
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) { actionButtons(turn, needsMac: needsMac) }
            VStack(alignment: .leading, spacing: 10) { actionButtons(turn, needsMac: needsMac) }
        }
        .padding(.leading, 4)
    }

    @ViewBuilder private func actionButtons(_ turn: QuickAnswers.Turn, needsMac: Bool) -> some View {
        if !needsMac {
            Button {
                UIPasteboard.general.string = turn.answer
            } label: {
                Label("Copy", systemImage: "doc.on.doc").font(.subheadline.weight(.medium))
            }
            .buttonStyle(.nollieGlass)
            .buttonBorderShape(.capsule)
            .tint(.primary)
            .testID("quickAnswer.copy")
        }
        if place.handsOff { handOff(turn, prominent: needsMac) }
    }

    @ViewBuilder private func handOff(_ turn: QuickAnswers.Turn, prominent: Bool) -> some View {
        let handoff = QuickAnswerHandoff.shared
        switch handoff.state(of: turn.id) {
        case nil:
            let button = Button {
                Task { await handoff.handOff(id: turn.id, text: turn.question, model: model) }
            } label: {
                Label("Ask Nollie on your Mac", systemImage: "desktopcomputer").font(.subheadline.weight(.semibold))
            }
            .testID("quickAnswer.handOff")
            .buttonBorderShape(.capsule)
            if prominent { button.buttonStyle(.nollieGlassProminent) } else { button.buttonStyle(.nollieGlass).tint(.primary) }
        case .waiting?:
            HStack(spacing: 8) {
                Label("Goes when your Mac is back", systemImage: "clock")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Ink.text2)
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .nollieGlass(.regular, in: Capsule())
                Button { handoff.cancel(turn.id) } label: {
                    Image(systemName: "xmark").font(.footnote.weight(.semibold)).frame(square: 22)
                }
                .buttonStyle(.nollieGlass)
                .buttonBorderShape(.circle)
                .tint(.primary)
                .accessibilityLabel("Don't send")
                .testID("quickAnswer.handOff.cancel")
            }
            .testID("quickAnswer.handOff.waiting")
        case .sending?:
            Label { Text("Sending") } icon: { ProgressView().controlSize(.small) }
                .font(.subheadline.weight(.medium)).foregroundStyle(Ink.text2)
        case .sent?:
            Label("Sent to your Mac", systemImage: "checkmark.circle.fill")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(Color.readableGreen)
                .testID("quickAnswer.handOff.sent")
        }
    }

    // MARK: Message box

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 10) {
            TextField("Ask a quick question", text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .font(Ink.message)
                .lineLimit(1...4)
                .focused($typing)
                .submitLabel(.send)
                .onSubmit(send)
                .padding(.vertical, 10)
                .testID("quickAnswer.field")
            Button {
                if answers.isWriting { answers.stop() } else { send() }
            } label: {
                Image(systemName: answers.isWriting ? "stop.fill" : "arrow.up")
                    .font(.body.weight(.bold))
                    .frame(square: 34)
            }
            .buttonStyle(.nollieGlassProminent)
            .buttonBorderShape(.circle)
            .disabled(!answers.isWriting && draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .accessibilityLabel(answers.isWriting ? "Stop" : "Send")
            .testID("quickAnswer.send")
            .padding(.vertical, 4)
        }
        .padding(.leading, 18).padding(.trailing, 6)
        .nollieGlass(.regular, in: Capsule())
        .frame(maxWidth: 640)
        .padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 12)
    }

    private func send() {
        guard !answers.isWriting else { return }
        let text = draft
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        draft = ""
        answers.ask(text)
    }

    private func playScript() async {
        for line in script {
            answers.ask(line)
            await answers.settle()
            if QuickAnswerDemo.handsOff, let turn = answers.turns.last, case .helper = turn.state, place.handsOff {
                await QuickAnswerHandoff.shared.handOff(id: turn.id, text: turn.question, model: model)
            }
        }
    }
}
