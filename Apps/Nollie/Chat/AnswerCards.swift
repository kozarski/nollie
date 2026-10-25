import SwiftUI
import NollieCore

/// A question from Hermes for the person: several questions at once, or a single one answered
/// by picking (one choice or many) or by typing.
struct ClarifyCardView: View {
    var request: ClarifyRequest
    var onAnswer: (JSONValue) -> Void

    private var title: some View {
        Label("Hermes asks", systemImage: "questionmark.bubble.fill").quiet(.headline, .tint)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            title
            content
        }
    }

    @ViewBuilder private var content: some View {
        if let list = request.questions, !list.isEmpty {
            QuestionList(questions: list, onAnswer: onAnswer)
        } else {
            OneQuestion(request: request, onAnswer: onAnswer)
        }
    }
}

/// A set of questions, sent back together with one Answer button.
private struct QuestionList: View {
    var questions: [ClarifyQuestion]
    var onAnswer: (JSONValue) -> Void
    @State private var given: [String: String] = [:]

    private func slot(_ qid: String) -> Binding<String> {
        Binding(get: { given[qid] ?? "" }, set: { given[qid] = $0 })
    }

    var body: some View {
        ForEach(questions) { item in
            VStack(alignment: .leading, spacing: 6) {
                Text(item.question).font(.subheadline)
                field(for: item)
            }
        }
        HStack {
            Button("Skip", role: .cancel) { deliver([:]) }.buttonStyle(.nollieGlass)
            Button("Answer") { deliver(given) }.buttonStyle(.nollieGlassProminent)
        }
    }

    @ViewBuilder private func field(for item: ClarifyQuestion) -> some View {
        if let options = item.choices, !options.isEmpty {
            Picker(item.question, selection: slot(item.qid)) {
                Text("Choose…").tag("")
                ForEach(options, id: \.self) { choice in Text(choice).tag(choice) }
            }
            .labelsHidden()
        } else {
            TextField("Answer", text: slot(item.qid)).textFieldStyle(.roundedBorder)
        }
    }

    private func deliver(_ values: [String: String]) {
        onAnswer(.object(["answers": .object(values.mapValues(JSONValue.string))]))
    }
}

/// A lone question: type a reply, or choose. Many-choice questions collect picks until Answer.
private struct OneQuestion: View {
    var request: ClarifyRequest
    var onAnswer: (JSONValue) -> Void
    @State private var typed = ""
    @State private var picks: Set<String> = []

    private var allowsMany: Bool { request.multiSelect == true }

    private func reply(_ text: String) { onAnswer(.object(["answer": .string(text)])) }

    var body: some View {
        Text(request.question ?? "").font(.subheadline)
        answerArea
        Button("Skip") { reply("") }.font(.caption)
    }

    @ViewBuilder private var answerArea: some View {
        if let options = request.choices, !options.isEmpty {
            ForEach(options, id: \.self, content: optionButton)
            if allowsMany {
                Button("Answer") { reply(picks.sorted().joined(separator: ", ")) }
                    .buttonStyle(.nollieGlassProminent)
            }
        } else {
            HStack {
                TextField("Your answer", text: $typed, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...4)
                Button { reply(typed) } label: { Image(systemName: "arrow.up") }
                    .buttonStyle(.nollieGlassProminent)
            }
        }
    }

    private func tapped(_ option: String) {
        guard allowsMany else { return reply(option) }
        if !picks.insert(option).inserted { picks.remove(option) }
    }

    private func optionButton(_ option: String) -> some View {
        Button { tapped(option) } label: {
            HStack {
                if allowsMany { Image(systemName: picks.contains(option) ? "checkmark.circle.fill" : "circle") }
                Text(option).spread()
            }
        }
        .buttonStyle(.nollieGlass)
    }
}

/// Asks for a password, secret, vault code or login the gateway needs. What is typed goes
/// straight to the gateway and the app never logs it.
struct ValuePromptCardView: View {
    var method: String
    var request: ValuePromptRequest
    var onValue: (String) -> Void
    private static let settle = Duration.milliseconds(50)

    @State private var identifier: String = ""
    @State private var value: String = ""
    @FocusState private var focused: Bool

    private var savesLogin: Bool { method == "vault.save_login" }
    private var isCode: Bool { method == "vault.code" }

    #if os(macOS)
    private typealias FieldKind = NSTextContentType
    #else
    private typealias FieldKind = UITextContentType
    #endif

    private var contentType: FieldKind? {
        if isCode { return .oneTimeCode }
        return method == "sudo" ? nil : .password
    }

    private var title: String {
        let site = request.site ?? request.origin
        switch method {
        case "sudo": return "sudo password"
        case "secret": return "Secret: \(request.envVar ?? "")"
        case "vault.unlock_prompt": return "Unlock \(request.displayName ?? request.backend ?? "vault")"
        case "vault.save_login": return "Save login for \(site ?? "site")"
        case "vault.code": return "One-time code" + (request.site.map { " for \($0)" } ?? "")
        default: return method
        }
    }

    /// Lines the gateway sent along with the request, shown above the field.
    private enum Line: CaseIterable { case ask, command, hint }

    private func text(for line: Line) -> String? {
        let raw: String?
        switch line {
        case .ask: raw = request.prompt
        case .command: raw = request.command
        case .hint: raw = request.hint
        }
        return raw?.isEmpty == false ? raw : nil
    }

    @ViewBuilder private func lineView(_ line: Line, _ words: String) -> some View {
        switch line {
        case .ask: Text(words).font(.subheadline)
        case .command: Text(words).quiet(.system(.footnote, design: .monospaced))
        case .hint: Text(words).quiet(.caption)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: "key.fill").font(.headline.weight(.semibold))
            ForEach(Line.allCases, id: \.self) { line in
                if let words = text(for: line) { lineView(line, words) }
            }
            if savesLogin {
                TextField("Username / identifier", text: $identifier)
                    .textFieldStyle(.roundedBorder)
                    .textContentType(.username)
            }
            secretField
            HStack {
                Button("Skip", role: .cancel) { send("") }.buttonStyle(.nollieGlass)
                Button("Submit", action: submit).buttonStyle(.nollieGlassProminent).disabled(value.isEmpty)
            }
            Text("This goes straight to your gateway. Nollie never logs it.").quiet(.caption2)
        }
    }

    private var secretField: some View {
        SecureField(isCode ? "Code" : "Value", text: $value)
            .textFieldStyle(.roundedBorder)
            .textContentType(contentType)
            .focused($focused)
            .onSubmit { if !value.isEmpty { send(value) } }
    }

    /// Dismiss the keyboard before anything else. When answered, the card slides out of the dock, and
    /// removing a focused secure field mid-animation can crash on a sudo prompt.
    private func send(_ answer: String) {
        focused = false
        Task { @MainActor in
            try? await Task.sleep(for: Self.settle)
            onValue(answer)
        }
    }

    private func submit() {
        if savesLogin {
            send(RPCFrames.encode(["identifier": .string(identifier), "password": .string(value)]))
        } else {
            send(value)
        }
    }
}
