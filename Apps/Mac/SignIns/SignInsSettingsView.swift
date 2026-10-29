import SwiftUI
import NollieCore

/// Settings › Sign-ins, on the Mac only: how many sign-ins a helper may use after the person
/// says yes, each one as a capsule, the last use, and the recent uses under Advanced. Passwords
/// stay in this Mac's Keychain; showing one asks for Touch ID.
struct SignInsSettingsView: View {
    @Environment(AppModel.self) private var model
    var center: SignInCenter = .shared
    /// Recent uses, injected for pictures; read from the add-on otherwise.
    var fixedHistory: [SignInHistoryEntry]? = nil
    @State private var history: [SignInHistoryEntry] = []
    @State private var editing: SignInEditor.Target?
    @State private var removing: SavedSignIn?
    @State private var problem: String?

    private var store: SavedSignInStore { center.store }

    /// Helpers sign in only for an assistant on this very Mac.
    private var elsewhere: Bool {
        guard let rt = model.runtime else { return false }
        return !rt.gatewayIsOnThisMac
    }

    var body: some View {
        let shown = Array((fixedHistory ?? history).prefix(30))
        SettingsPage("signIns.page") {
            SignInsHero(count: store.items.count, elsewhere: elsewhere)
            if let problem {
                PageNote(.verbatim(problem), symbol: "exclamationmark.triangle.fill", tint: .orange, id: "signIns.problem")
            }
            VStack(spacing: 12) {
                ForEach(store.items) { item in
                    Button { editing = .edit(item) } label: {
                        GlassRowLabel(title: item.site, symbol: "key.fill", value: item.username, chevron: false)
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button("Edit…") { editing = .edit(item) }
                        Button("Remove…", role: .destructive) { removing = item }
                    }
                    .accessibilityLabel("\(item.site), \(item.username)")
                    .accessibilityIdentifier("signIns.row.\(item.site)")
                }
                Button { editing = .add } label: {
                    Label("Add sign-in", systemImage: "plus")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.nollieGlassProminent)
                .buttonBorderShape(.capsule)
                .controlSize(.large)
                .accessibilityIdentifier("signIns.add")
            }
            if let last = shown.first {
                PageNote("\(Self.line(last, bot: botName(last.bot))), \(Self.time(last.at))", symbol: "clock",
                         id: "signIns.last")
            }
            if !shown.isEmpty {
                AdvancedLink(id: "signIns.advanced") {
                    SignInsRecentUses(entries: shown, botName: botName).untitledPage()
                }
            }
        }
        .task {
            store.reload()
            guard fixedHistory == nil, let rt = model.runtime, rt.gatewayIsOnThisMac else { return }
            history = (try? await rt.signInHistory(days: 30)) ?? []
        }
        .sheet(item: $editing) { target in
            SignInEditor(target: target, store: store) { editing = nil }.withAppModel()
        }
        .confirmationDialog(removing.map { String(localized: "Remove the sign-in for \($0.site)?", comment: "Safety: deleting a saved sign-in") } ?? "", isPresented: Binding(
            get: { removing != nil }, set: { if !$0 { removing = nil } })) {
            Button("Remove", role: .destructive) {
                if let item = removing {
                    do { try store.remove(item); problem = nil } catch { problem = error.localizedDescription }
                }
                removing = nil
            }
        } message: {
            Text("Helpers can't use it after this.")
        }
    }

    private func botName(_ profile: String) -> String {
        model.runtime?.profiles.first { $0.name == profile }?.shownName ?? profile.capitalized
    }

    /// What happened, in a few words.
    static func line(_ entry: SignInHistoryEntry, bot: String) -> String {
        switch entry.outcome {
        case "signed_in": return String(localized: "\(bot) signed in to \(entry.site)")
        case "declined": return String(localized: "You said no to \(bot) on \(entry.site)")
        case "cancelled": return String(localized: "You stopped \(bot) on \(entry.site)")
        case "no_answer": return String(localized: "No answer for \(bot) on \(entry.site)")
        case "not_saved": return String(localized: "\(bot) asked for \(entry.site), not saved")
        default: return String(localized: "\(bot) couldn't sign in to \(entry.site)")
        }
    }

    /// Who said yes, when someone did.
    static func detail(_ entry: SignInHistoryEntry) -> String? {
        switch entry.approver {
        case "mac": return String(localized: "Allowed on this Mac", comment: "Who said yes to a sign-in")
        case "iphone": return String(localized: "Allowed on your iPhone", comment: "Who said yes to a sign-in")
        default: return nil
        }
    }

    /// "14:32" today, "Mon 09:12" this week, "12 Oct" before.
    static func time(_ at: Int, now: Date = Date(), calendar: Calendar = .current) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(at))
        if calendar.isDateInToday(date) { return date.formatted(.dateTime.hour().minute()) }
        if let days = calendar.dateComponents([.day], from: date, to: now).day, days < 7 {
            return date.formatted(.dateTime.weekday(.abbreviated).hour().minute())
        }
        return date.formatted(.dateTime.day().month(.abbreviated))
    }
}

/// The top of Sign-ins: how many are saved, or why helpers can't use them here.
struct SignInsHero: View {
    var count: Int
    /// The assistant runs on another computer, so no helper can use these.
    var elsewhere = false

    var body: some View {
        if elsewhere {
            PageHero(symbol: "desktopcomputer.trianglebadge.exclamationmark", title: "Not in use",
                     line: "Your assistant runs on another computer, so helpers can't use these.",
                     tint: .orange, id: "signIns.hero")
        } else {
            PageHero(symbol: "key.fill", title: .verbatim(Self.title(count)),
                     line: LocalizedStringResource("Nollie types it in. Helpers are never told the password.",
                                  comment: "Safety: what a helper learns of a saved password"),
                     tint: count == 0 ? .blue : .green, id: "signIns.hero")
        }
    }

    /// "No sign-ins yet", "1 sign-in", "3 sign-ins".
    static func title(_ count: Int) -> String {
        switch count {
        case 0: String(localized: "No sign-ins yet")
        default: String(localized: "\(count) sign-ins")
        }
    }
}

/// Sign-ins › Advanced: every use in the last 30 days, who said yes and when.
private struct SignInsRecentUses: View {
    var entries: [SignInHistoryEntry]
    var botName: (String) -> String

    var body: some View {
        SettingsPage("signIns.recent") {
            PageHero(symbol: "clock.arrow.circlepath", title: "Recent uses", line: "The last 30 days.",
                     tint: Ink.text, id: "signIns.recent.hero")
            VStack(spacing: 20) {
                ForEach(Array(entries.enumerated()), id: \.offset) { i, entry in row(entry, index: i) }
            }
        }
    }

    private func row(_ entry: SignInHistoryEntry, index: Int) -> some View {
        let line = SignInsSettingsView.line(entry, bot: botName(entry.bot))
        let detail = SignInsSettingsView.detail(entry)
        let time = SignInsSettingsView.time(entry.at)
        return HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(line).font(.body.weight(.medium)).foregroundStyle(Ink.text)
                    .fixedSize(horizontal: false, vertical: true)
                if let detail { Text(detail).font(.body).foregroundStyle(Ink.text2) }
            }
            Spacer(minLength: 8)
            Text(time).font(.body).foregroundStyle(Ink.text2).monospacedDigit()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([line, detail ?? "", time].filter { !$0.isEmpty }.joined(separator: ", "))
        .accessibilityIdentifier("signIns.history.\(index)")
    }
}

/// Adding or changing one sign-in. Changing one shows its password only after Touch ID.
struct SignInEditor: View {
    enum Target: Identifiable, Equatable {
        case add, edit(SavedSignIn)
        var id: String { if case .edit(let item) = self { return item.id }; return "add" }
    }

    var target: Target
    var store: SavedSignInStore
    var done: () -> Void
    @State private var site = ""
    @State private var username = ""
    @State private var password = ""
    @State private var note = ""
    @State private var unlocked = false
    @State private var problem: String?

    private var existing: SavedSignIn? { if case .edit(let item) = target { return item }; return nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(existing?.site ?? String(localized: "Add sign-in")).font(.title2.weight(.semibold))
            if existing != nil && !unlocked {
                Text("Touch ID shows this sign-in so you can change it.")
                    .foregroundStyle(.secondary)
                if let problem { Text(problem).font(.callout).foregroundStyle(Ink.warnText) }
                HStack(spacing: 8) {
                    Button("Show", action: unlock).buttonStyle(InkPillStyle(fill: false)).accessibilityIdentifier("signIns.show")
                    Button("Cancel", action: done).buttonStyle(OutlinePillStyle(fill: false))
                }
            } else {
                Form {
                    TextField("Site", text: $site, prompt: Text("example.com"))
                        .textContentType(.URL)
                        .accessibilityIdentifier("signIns.site")
                    TextField("Username", text: $username, prompt: Text("Email or username"))
                        .textContentType(.username)
                        .accessibilityIdentifier("signIns.username")
                    SecureField("Password", text: $password)
                        .textContentType(.password)
                        .accessibilityIdentifier("signIns.password")
                    TextField("Code note", text: $note, prompt: Text("Optional, like “Codes come by text”"))
                        .accessibilityIdentifier("signIns.note")
                }
                .formStyle(.grouped)
                .scrollDisabled(true)
                if let problem { Text(problem).font(.callout).foregroundStyle(Ink.warnText) }
                HStack(spacing: 8) {
                    Spacer()
                    Button("Cancel", action: done).buttonStyle(OutlinePillStyle(fill: false))
                    Button("Save", action: save).buttonStyle(InkPillStyle(fill: false))
                        .keyboardShortcut(.defaultAction)
                        .disabled(site.isEmpty || username.isEmpty || password.isEmpty)
                        .accessibilityIdentifier("signIns.save")
                }
            }
        }
        .padding(24)
        .frame(width: 440)
        .onAppear {
            if let existing { site = existing.site; username = existing.username }
        }
        .onDisappear { password = ""; note = "" }
    }

    private func unlock() {
        guard let existing else { return }
        Task {
            do {
                let reason = String(localized: "show the sign-in for \(existing.site)",
                                    comment: "Safety: Touch ID reason; finishes 'Nollie is trying to …'")
                let secret = try await store.reveal(existing, reason: reason)
                password = secret.password
                note = secret.note ?? ""
                unlocked = true
            } catch SavedSignInError.cancelled {
            } catch {
                problem = error.localizedDescription
            }
        }
    }

    private func save() {
        do {
            try store.save(site: site, username: username, secret: SignInSecret(password: password, note: note), replacing: existing)
            done()
        } catch {
            problem = error.localizedDescription
        }
    }
}
