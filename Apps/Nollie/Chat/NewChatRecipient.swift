import SwiftUI
import NollieCore

/// Who a new message goes to: the bot chosen, and what is typed in the To: field to find one.
@MainActor @Observable
final class Recipient {
    /// With a bot chosen, a hidden marker character leads the To: field. On the software
    /// keyboard, Backspace in the apparently empty field deletes that marker, and that is how Backspace takes away
    /// the chip (as in Messages). `onKeyPress` sees hardware keys only.
    static let mark = "\u{200B}"

    var bot: ProfileInfo?
    var typing = ""

    /// What the person typed, without the mark.
    var words: String { typing.replacingOccurrences(of: Self.mark, with: "") }

    /// The bots left to choose from: not the chosen one, and matching what was typed.
    func matches(in all: [ProfileInfo]) -> [ProfileInfo] {
        let needle = words.trimmingCharacters(in: .whitespaces)
        return all.filter { candidate in
            candidate.name != bot?.name
                && (needle.isEmpty || [candidate.label, candidate.name].contains { $0.localizedCaseInsensitiveContains(needle) })
        }
    }

    func choose(_ chosen: ProfileInfo) {
        withAnimation(.snappy) { bot = chosen }
        typing = Self.mark
    }

    func release() {
        let kept = words
        withAnimation(.snappy) { bot = nil }
        typing = kept
    }

    /// Keeps the mark in place while a bot is chosen.
    func guardMark(old: String, new: String) {
        guard bot != nil else { return }
        if !new.contains(Self.mark) {
            // The marker is gone, so Backspace in an empty field retracts the chip (and puts the marker back in
            // field again). Any other way, the field gets its mark back.
            if old == Self.mark { release() } else { typing = Self.mark + new }
        } else if !new.hasPrefix(Self.mark) {
            typing = Self.mark + new.replacingOccurrences(of: Self.mark, with: "")
        }
    }
}

/// The To: line: the chosen bot as a chip, the name field, and a plus that brings the field back.
struct RecipientRow: View {
    @Bindable var recipient: Recipient
    var focus: FocusState<Bool>.Binding
    var matches: [ProfileInfo]
    var onPicked: (ProfileInfo) -> Void
    var onPlus: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text("To:").quiet(.body).padding(.top, 4)
            FlowLayout(spacing: 6) {
                if let bot = recipient.bot { chip(bot) }
                nameInput
            }
            GlassCircleButton(symbol: "plus", diameter: 32, action: onPlus)
                .accessibilityLabel("Choose a bot")
        }
        .inset(h: 14, v: 8)
        .nollieGlass(.regular, in: .rect(cornerRadius: 22))
        .inset(h: 16)
    }

    private func chip(_ bot: ProfileInfo) -> some View {
        HStack(spacing: 5) {
            BotAvatar(profile: bot.name, size: 20, animated: false)
            Text(bot.label).font(.subheadline).lineLimit(1)
        }
        .padding(EdgeInsets(top: 4, leading: 4, bottom: 4, trailing: 10))
        .background { Capsule().fill(Color.nollie.opacity(0.15)) }
        // The chip as a whole, bot and all, because the marker character cannot be tapped by itself.
        .contentShape(Capsule())
        .onTapGesture { recipient.release() }
        .accessibilityLabel("\(bot.label), \(DeviceWords.tap) to remove")
    }

    private var nameInput: some View {
        TextField(recipient.bot == nil ? "Bot name" : "", text: $recipient.typing)
            .modifier(BareNameField())
            .focused(focus)
            .frame(minWidth: 90, minHeight: 28)
            .onSubmit { matches.first.map(onPicked) }
            // Backspace while an input method composes edits its text and never takes the chip.
            .onKeyPress(.delete) {
                guard recipient.words.isEmpty, recipient.bot != nil, !InputComposition.isActive else { return .ignored }
                recipient.release()
                return .handled
            }
            .onChange(of: recipient.typing) { old, new in recipient.guardMark(old: old, new: new) }
    }
}

/// The To: field's text input, plain on the Mac and free of autocapitalisation on the phone.
private struct BareNameField: ViewModifier {
    func body(content: Content) -> some View {
        content
            .autocorrectionDisabled()
            .textInputAutocapitalization(.never)
            #if os(macOS)
            .textFieldStyle(.plain)
            #endif
    }
}

/// The bots that match what was typed, a card each.
struct BotMatchList: View {
    var matches: [ProfileInfo]
    var typed: String
    var problem: String?
    var onPicked: (ProfileInfo) -> Void

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(matches) { bot in
                    PlainButton { onPicked(bot) } label: { card(bot) }
                    Divider().padding(.leading, 72)
                }
                if let problem { Text(problem).quiet(.footnote, .red).padding() }
            }
            .padding(.top, 6)
        }
        .scrollDismissesKeyboard(.interactively)
    }

    private func card(_ bot: ProfileInfo) -> some View {
        let model = bot.model.map { ModelNames.tail($0) }
        let subtitle = [bot.description, model].compactMap(\.self).filter { !$0.isEmpty }.joined(separator: " · ")
        return HStack(spacing: 12) {
            BotAvatar(profile: bot.name, size: 40, animated: false)
            VStack(alignment: .leading, spacing: 2) {
                Text(emphasised(bot.label))
                Text(subtitle).quiet().lineLimit(1)
            }
            Spacer()
        }
        .inset(h: 20, v: 10)
        .contentShape(Rectangle())
    }

    /// The label with the part the person typed in bold and the accent colour.
    private func emphasised(_ label: String) -> AttributedString {
        var styled = AttributedString(label)
        let needle = typed.trimmingCharacters(in: .whitespaces)
        if !needle.isEmpty, let hit = styled.range(of: needle, options: .caseInsensitive) {
            styled[hit].font = .body.weight(.semibold)
            styled[hit].foregroundColor = .accentColor
        }
        return styled
    }
}
