import SwiftUI
import NollieCore

/// What the person did with a card.
enum ConversationCardAction: Equatable {
    /// The question's answer, as Hermes takes it: `{choice}` for an approval, `{answers}` for a question,
    /// `{value}` for a typed value.
    case answer(GatewayJSON)
    /// Taken down here without an answer, so another window can still give one.
    case setAside
}

extension ConversationEngine {
    func perform(_ action: ConversationCardAction, on card: ConversationCard) {
        switch action {
        case .answer(let result): answer(card: card.id, with: result)
        case .setAside: setAside(card: card.id)
        }
    }
}

/// A question the bot is waiting on, as a card under the newest row: an approval, a question with choices or
/// words, or a typed value.
struct ConversationCardView: View {
    let card: ConversationCard
    let act: (ConversationCardAction) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            switch card.kind {
            case .approval(_, let command, let description, let choices):
                ApprovalCard(command: command, description: description, choices: choices) { choice in
                    act(.answer(["choice": .string(choice)]))
                }
            case .clarify(let questions):
                ClarifyCard(questions: questions) { answers in
                    act(.answer(["answers": .object(answers.mapValues { .string($0) })]))
                }
            case .value(let prompt, let secret):
                ValueCard(prompt: prompt, secret: secret, send: { act(.answer(["value": .string($0)])) },
                          notNow: { act(.setAside) })
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Ink.card, in: .rect(cornerRadius: Ink.cardRadius, style: .continuous))
        .padding(.bottom, ConversationMetrics.rowGap)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("card.\(card.id)")
    }
}

private struct ApprovalCard: View {
    let command: String?
    let description: String?
    let choices: [String]
    let answer: (String) -> Void

    var body: some View {
        Text("Allow this?", comment: "Safety: approval card title; keep exact meaning").font(Ink.cardTitle).foregroundStyle(Ink.text)
        if let description, !description.isEmpty {
            Text(description).font(Ink.cardBody).foregroundStyle(Ink.cardText)
        }
        if let command, !command.isEmpty {
            // All of it, always: what runs is exactly what you read.
            Text(command)
                .font(Ink.code11)
                .foregroundStyle(Ink.codeText)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Ink.code, in: .rect(cornerRadius: 14, style: .continuous))
        }
        HStack(spacing: 10) {
            Button(String(localized: "Allow once", comment: "Safety: approval card button; allows this one time")) { answer("once") }
                .buttonStyle(InkPillStyle())
                .accessibilityIdentifier("card.allowOnce")
            Button(String(localized: "Deny", comment: "Safety: approval card button; refuses the request")) { answer("deny") }
                .buttonStyle(OutlinePillStyle())
                .accessibilityIdentifier("card.deny")
            if choices.contains("session") || choices.contains("always") {
                Menu {
                    if choices.contains("session") {
                        Button(String(localized: "Allow in this chat",
                                      comment: "Safety: approval card choice; allows it for the rest of this chat")) { answer("session") }
                    }
                    if choices.contains("always") {
                        Button(String(localized: "Always allow",
                                      comment: "Safety: approval card choice; allows it from now on")) { answer("always") }
                    }
                } label: {
                    Image(systemName: "ellipsis").frame(height: 20)
                }
                .menuStyle(.button)
                .buttonStyle(OutlinePillStyle())
                .accessibilityLabel("More choices")
                .accessibilityIdentifier("card.more")
            }
        }
    }
}

/// One or more questions. A single question with choices answers on the tap; otherwise each question takes a
/// choice or a few words, and Answer sends them together.
private struct ClarifyCard: View {
    let questions: [ConversationCard.Question]
    let send: ([String: String]) -> Void
    @State private var answers: [String: String] = [:]

    private var oneTap: Bool { questions.count == 1 && !(questions[0].choices.isEmpty) && !questions[0].multipleChoice }
    private var complete: Bool {
        questions.allSatisfy { !(answers[$0.id] ?? "").trimmingCharacters(in: .whitespaces).isEmpty }
    }

    var body: some View {
        if questions.isEmpty {
            Text("A question").font(Ink.cardTitle).foregroundStyle(Ink.text)
        }
        ForEach(questions, id: \.id) { question in
            VStack(alignment: .leading, spacing: 10) {
                Text(question.text.isEmpty ? String(localized: "A question") : question.text)
                    .font(Ink.cardTitle)
                    .foregroundStyle(Ink.text)
                    .fixedSize(horizontal: false, vertical: true)
                if question.choices.isEmpty {
                    TextField("Answer", text: binding(question.id), axis: .vertical)
                        .textFieldStyle(.plain)
                        .font(Ink.message)
                        .padding(.horizontal, 16).padding(.vertical, 11)
                        .background(Ink.field, in: .capsule)
                        .accessibilityIdentifier("card.answer.\(question.id)")
                } else {
                    FlowLayout(spacing: 8) {
                        ForEach(question.choices, id: \.self) { choice in
                            let chosen = selected(question).contains(choice)
                            Button(choice) { choose(choice, in: question) }
                                .buttonStyle(ChoicePillStyle(chosen: chosen))
                                .accessibilityIdentifier("card.choice.\(choice)")
                        }
                    }
                }
            }
        }
        if !oneTap {
            Button("Answer") { send(answers) }
                .buttonStyle(InkPillStyle())
                .disabled(!complete)
                .accessibilityIdentifier("card.send")
        }
    }

    private func binding(_ id: String) -> Binding<String> {
        Binding(get: { answers[id] ?? "" }, set: { answers[id] = $0 })
    }

    private func selected(_ question: ConversationCard.Question) -> [String] {
        (answers[question.id] ?? "").split(separator: "\n").map(String.init)
    }

    private func choose(_ choice: String, in question: ConversationCard.Question) {
        if oneTap { return send([question.id: choice]) }
        if question.multipleChoice {
            var chosen = selected(question)
            if let index = chosen.firstIndex(of: choice) { chosen.remove(at: index) } else { chosen.append(choice) }
            answers[question.id] = chosen.joined(separator: "\n")
        } else {
            answers[question.id] = choice
        }
    }
}

/// A choice in a question: glass, or ink once chosen.
private struct ChoicePillStyle: ButtonStyle {
    let chosen: Bool

    func makeBody(configuration: Configuration) -> some View {
        if chosen {
            InkPillStyle().makeBody(configuration: configuration)
        } else {
            OutlinePillStyle().makeBody(configuration: configuration)
        }
    }
}

/// A typed value (a password, a code, a key): a field and Send, or Not now to answer it elsewhere.
private struct ValueCard: View {
    let prompt: String
    let secret: Bool
    let send: (String) -> Void
    let notNow: () -> Void
    @State private var value = ""

    var body: some View {
        Text(prompt.isEmpty ? String(localized: "Needs a value") : prompt)
            .font(Ink.cardTitle)
            .foregroundStyle(Ink.text)
            .fixedSize(horizontal: false, vertical: true)
        Group {
            if secret {
                SecureField("Value", text: $value)
            } else {
                TextField("Value", text: $value)
            }
        }
        .textFieldStyle(.plain)
        .font(Ink.message)
        .padding(.horizontal, 16).padding(.vertical, 11)
        .background(Ink.field, in: .capsule)
        .onSubmit { if !value.isEmpty { send(value) } }
        .accessibilityIdentifier("card.value")
        HStack(spacing: 10) {
            Button("Send") { send(value) }
                .buttonStyle(InkPillStyle())
                .disabled(value.isEmpty)
                .accessibilityIdentifier("card.send")
            Button("Not now", action: notNow)
                .buttonStyle(OutlinePillStyle())
                .accessibilityIdentifier("card.notNow")
        }
    }
}
