import SwiftUI
import NollieCore

/// "Share Scout": someone at home asks this helper from their own iPhone, and the owner stays in
/// charge. What is true first, what they can and can't do, the people who have it (each with
/// Remove), and one clear action. Opened from a helper's menu.
struct FamilyShareView: View {
    var profile: String
    @Environment(AppModel.self) private var model
    @State private var adding = false
    @State private var removing: String?

    private var family: FamilyModel { model.family }
    private var bot: ProfileInfo? { model.runtime?.profiles.first { $0.name == profile } }
    private var name: String { bot?.shownName ?? profile.capitalized }
    private var isPrivate: Bool {
        bot?.isPrivateBot(on: model.runtime?.connection.id) == true || ["private", "moss"].contains(profile)
    }
    /// The people who have their own copy of this helper.
    private var people: [NollieFamilyMember] {
        family.overview.members.filter { member in member.helpers.contains { FamilyShareView.isCopy($0, of: profile) } }
    }

    static func isCopy(_ helper: String, of profile: String) -> Bool { helper == profile || helper.hasPrefix(profile + "-") }

    var body: some View {
        NavigationStack {
            SettingsPage("family.share") {
                FamilySharePage(name: name, isPrivate: isPrivate, people: people, removing: removing, issue: family.issue,
                                add: { adding = true }, remove: remove)
            }
            .untitledPage()
            .doneToolbar(id: "family.share.close")
        }
        .sheet(isPresented: $adding) {
            FamilyAddSomeone(profile: profile, name: name).withAppModel()
        }
        #if DEBUG
        // Pictures: `-nollie-demo-family-add <name>` opens Add someone and makes that person's code.
        .task { if FamilyAddSomeone.demoPerson != nil { adding = true } }
        #endif
        .task {
            while !Task.isCancelled {
                await family.refreshOverview(model, force: true)
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    private func remove(_ member: NollieFamilyMember) {
        removing = member.id
        Task {
            await family.remove(member, model: model)
            removing = nil
        }
    }
}

/// What the share screen shows, apart from where it comes from: also drawn by the design snapshots.
struct FamilySharePage: View {
    var name: String
    var isPrivate = false
    var people: [NollieFamilyMember]
    var removing: String? = nil
    var issue: String? = nil
    var add: () -> Void = {}
    var remove: (NollieFamilyMember) -> Void = { _ in }

    var body: some View {
        if isPrivate {
            PageHero(symbol: "lock.fill", title: "\(name) is Private", line: "Private helpers stay yours.", tint: .purple, id: "family.hero")
        } else {
            PageHero(symbol: "person.2.fill", title: "Share \(name)", line: "Someone at home asks \(name) from their iPhone.",
                     tint: .teal, id: "family.hero")
            FactTiles(leading: FactTile(title: "They can", tint: .teal,
                                        facts: [Fact(symbol: "bubble.left.fill", word: "Chat"), Fact(symbol: "photo.fill", word: "Send photos")],
                                        id: "family.they"),
                      trailing: FactTile(title: "Only you", tint: Ink.text2,
                                         facts: [Fact(symbol: "checkmark.seal.fill", word: "Say yes"), Fact(symbol: "brain.head.profile", word: "Memory"),
                                                 Fact(symbol: "creditcard.fill", word: "Cards"), Fact(symbol: "person.3.fill", word: "Other helpers")],
                                         id: "family.you"))
            VStack(spacing: 14) {
                Button(action: add) { PageActionLabel(LocalizedStringResource("Add someone"), symbol: "person.badge.plus") }
                    .pageAction(tint: .teal)
                    .testID("family.add")
                // Safety: what the copy takes with it, and what never goes.
                Text("Each person gets their own \(name), with your instructions and none of your memory or chats.")
                    .font(.footnote).foregroundStyle(Ink.text2).multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .testID("family.copyNote")
            }
            if !people.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    PageHeading(people.count == 1 ? LocalizedStringResource("Shared with", comment: "Heading over the one person who has this helper")
                                                   : LocalizedStringResource("Shared with \(people.count)", comment: "Heading over the people who have this helper"))
                    ForEach(people) { person in
                        FamilyPersonRow(member: person, busy: removing == person.id) { remove(person) }
                    }
                }
                .accessibilityElement(children: .contain)
                .testID("family.people")
            }
            if let issue {
                Text(issue).foregroundStyle(Ink.text2).multilineTextAlignment(.center).testID("family.issue")
            }
        }
    }
}

/// One person on a glass capsule, with Remove: one tap, and they are cut off at once.
struct FamilyPersonRow: View {
    var member: NollieFamilyMember
    var busy = false
    var remove: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "person.crop.circle.fill")
                .font(.title2).foregroundStyle(.teal)
                .accessibilityHidden(true)
            Text(member.person).font(.headline).foregroundStyle(Ink.text)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            if busy {
                ProgressView().controlSize(.small)
            } else {
                Button("Remove", role: .destructive, action: remove)
                    .buttonStyle(.borderless)
                    .font(.headline)
                    .foregroundStyle(.red)
                    .accessibilityLabel("Remove \(member.person)")
                    .testID("family.remove")
            }
        }
        .inset(h: 22, v: 14)
        .frame(minHeight: 54)
        .nollieGlass(.regular, in: Capsule(), solid: Ink.card)
        .accessibilityElement(children: .contain)
    }
}

/// Add someone: their name, then Nollie makes their own copy of the helper and a code they scan
/// with Nollie on their iPhone, at home. The code works once, for two minutes.
struct FamilyAddSomeone: View {
    var profile: String
    var name: String
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var person = ""
    @State private var offer: NollieLinkOffer?
    @State private var busy = false
    @State private var issue: String?
    @State private var joined = false
    @FocusState private var typing: Bool

    private var trimmed: String { person.trimmingCharacters(in: .whitespacesAndNewlines) }

    static var demoPerson: String? {
        #if DEBUG
        let args = ProcessInfo.processInfo.arguments
        if DemoMode.isOn, let i = args.firstIndex(of: "-nollie-demo-family-add"), i + 1 < args.count { return args[i + 1] }
        #endif
        return nil
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                FamilyAddPage(name: name, person: $person, offer: offer, busy: busy, joined: joined, issue: issue,
                              make: make, again: { offer = nil; make() })
                    .focused($typing)
                    .frame(maxWidth: 440).padding(28).frame(maxWidth: .infinity)
            }
            .background(Ink.canvas.ignoresSafeArea())
            .untitledPage()
            .doneToolbar(id: "family.add.close")
        }
        .onAppear {
            typing = true
            #if DEBUG
            if let demo = Self.demoPerson, person.isEmpty { person = demo; make() }
            #endif
        }
        .task(id: offer?.urlString) { await watchForJoin() }
    }

    private func make() {
        guard !busy, !trimmed.isEmpty else { return }
        busy = true
        issue = nil
        Task {
            defer { busy = false }
            do {
                offer = try await model.family.share(profile, with: trimmed, model: model)
            } catch {
                issue = error.localizedDescription
            }
        }
    }

    /// The code is spent once someone joins with it; the people list says so.
    private func watchForJoin() async {
        guard offer != nil else { return }
        let before = Set(model.family.overview.members.map(\.id))
        while !Task.isCancelled, !joined {
            try? await Task.sleep(for: .seconds(2))
            await model.family.refreshOverview(model, force: true)
            if model.family.overview.members.contains(where: { !before.contains($0.id) && $0.person == trimmed }) {
                withAnimation(.snappy) { joined = true }
            }
        }
    }
}

/// The Add someone sheet's content: also drawn by the design snapshots.
struct FamilyAddPage: View {
    var name: String
    @Binding var person: String
    var offer: NollieLinkOffer?
    var busy = false
    var joined = false
    var issue: String?
    var make: () -> Void = {}
    var again: () -> Void = {}
    var now = Date()

    private var who: String {
        let trimmed = person.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? String(localized: "They", comment: "Stands in for a person's name when none was typed") : trimmed
    }

    var body: some View {
        VStack(spacing: 28) {
            if joined {
                PageHero(symbol: "checkmark.circle.fill", title: "\(who) joined", line: "They can ask \(name) now.", tint: .green, id: "family.add.hero")
            } else if let offer {
                PageHero(symbol: "qrcode", title: "Scan to join", line: nil, tint: .teal, id: "family.add.hero")
                PairingCodeImage(value: offer.urlString).privacySensitive()
                Text("\(who) opens Nollie on their iPhone, at home, and scans this.")
                    .font(.title3.weight(.semibold)).foregroundStyle(Ink.text)
                    .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                    .testID("family.add.instruction")
                if offer.expiresAt <= now {
                    Button(action: again) { PageActionLabel(LocalizedStringResource("New code"), symbol: "arrow.clockwise") }
                        .pageAction(tint: .teal).testID("family.add.again")
                }
            } else {
                PageHero(symbol: "person.badge.plus", title: "Who's it for?", line: "They get their own \(name).", tint: .teal, id: "family.add.hero")
                TextField("Name", text: $person, prompt: Text("Their name"))
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .autocorrectionDisabled()
                    .submitLabel(.go)
                    .onSubmit(make)
                    .inset(h: 22, v: 16)
                    .background(Ink.field, in: Capsule())
                    .testID("family.add.name")
                if busy {
                    ProgressView("Making \(who)'s \(name)").testID("family.add.busy")
                } else {
                    Button(action: make) { PageActionLabel(LocalizedStringResource("Make code"), symbol: "qrcode") }
                        .pageAction(tint: .teal)
                        .disabled(person.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .testID("family.add.make")
                }
            }
            if let issue {
                Text(issue).foregroundStyle(Ink.text2).multilineTextAlignment(.center).testID("family.add.issue")
            }
        }
    }
}
