import SwiftUI
import NollieCore

// Asks from someone at home: on the owner's side, a card that says who asked which helper and
// what for, with Allow once and Deny; on the member's side, the same card waiting on the owner.

/// On a member's phone, the name of the person who says yes ("Corey"). Nil everywhere else.
extension EnvironmentValues {
    @Entry var familyOwner: String? = nil
}

/// The asks waiting on the owner, at the top of the helpers list. Nothing shows when none wait.
struct FamilyAsksSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let asks = model.family.overview.asks
        VStack(spacing: 10) {
            ForEach(asks) { ask in
                FamilyAskCard(ask: ask, botName: name(of: ask.helper)) { choice in
                    Task { await answer(ask, choice) }
                }
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, asks.isEmpty ? 0 : 6)
        .animation(.snappy, value: asks.map(\.id))
        .task(id: model.runtime?.connection.id) {
            // Looked for while the list is open; the Mac's own helper or its door keeps them.
            while !Task.isCancelled, model.family.canShare(model) {
                await model.family.refreshOverview(model)
                try? await Task.sleep(for: .seconds(4))
            }
        }
    }

    /// The helper's shown name. A household copy shows as the helper it was made from ("Scout").
    private func name(of helper: String) -> String {
        let profiles = model.runtime?.profiles ?? []
        if let found = profiles.first(where: { $0.name == helper }) { return found.shownName }
        if let original = profiles.filter({ helper.hasPrefix($0.name + "-") }).max(by: { $0.name.count < $1.name.count }) {
            return original.shownName
        }
        return (helper.split(separator: "-").first.map(String.init) ?? helper).capitalized
    }

    /// A yes asks for Face ID first where a yes in a chat would.
    private func answer(_ ask: NollieFamilyAsk, _ choice: String) async {
        if choice == "once", !(await ApprovalOwnerCheck.check(ask.approval, bot: name(of: ask.helper))) { return }
        await model.family.answer(ask, choice: choice, model: model)
    }
}

/// One ask from someone at home: who and which helper over the usual approval card.
struct FamilyAskCard: View {
    var ask: NollieFamilyAsk
    var botName: String
    var onChoice: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("\(ask.person) asked \(botName)", systemImage: "person.2.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.teal)
                .fixedSize(horizontal: false, vertical: true)
                .testID("family.ask.who")
            ApprovalCardView(approval: ask.approval, count: 1, botName: botName, profile: ask.helper, onChoice: onChoice)
        }
        .padding(16)
        .nollieGlass(.regular, in: .rect(cornerRadius: Ink.cardRadius, style: .continuous))
        .accessibilityElement(children: .contain)
        .testID("family.ask")
    }
}

/// On a member's phone, an approval waits on the owner: what the helper wants to do, and Never mind.
struct FamilyWaitingCard: View {
    var approval: ApprovalRequest
    var botName: String
    var owner: String
    var onChoice: (String) -> Void

    private var about: String {
        if let ask = AskFirstAsk(approval) { return ask.summary }
        if let said = approval.description, !said.isEmpty { return said }
        return "Go ahead with something that needs a yes."
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "hourglass")
                    .font(.headline)
                    .foregroundStyle(.teal)
                    .symbolEffect(.pulse, options: .repeating)
                    .accessibilityHidden(true)
                Text("Waiting for \(owner)").font(Ink.cardTitle).foregroundStyle(Ink.text)
                    .fixedSize(horizontal: false, vertical: true)
                    .testID("family.waiting.title")
            }
            Text(about)
                .font(Ink.cardBody)
                .foregroundStyle(Ink.cardText)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 6)
                .padding(.bottom, 12)
                .testID("family.waiting.about")
            Button("Never mind") { onChoice("deny") }
                .buttonStyle(OutlinePillStyle(fill: false))
                .accessibilityHint("\(botName) won't do it.")
                .testID("family.waiting.cancel")
        }
        .contentShape(.rect)
        .accessibilityElement(children: .contain)
        .testID("family.waiting")
    }
}

/// Scanning a code for someone at home: who shares which helper, who says yes, and where the chats
/// are kept. The Mac decides what joining gives; this only says it plainly.
struct FamilyJoinConfirmation: View {
    var invite: NollieLinkInvite

    private var owner: String { invite.owner.isEmpty ? "Someone at home" : invite.owner }
    private var mac: String { invite.owner.isEmpty ? "their Mac" : "\(invite.owner)'s Mac" }

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "person.2.fill").font(.system(size: 48)).foregroundStyle(.teal)
                .accessibilityHidden(true)
            Text("\(owner) shares \(invite.helperList) with you")
                .font(.title2.bold()).multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("family.join.title")
            Text("\(invite.owner.isEmpty ? "They say" : invite.owner + " says") yes to anything that matters. Your chats are kept on \(mac).")
                .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("family.join.line")
        }
    }
}
