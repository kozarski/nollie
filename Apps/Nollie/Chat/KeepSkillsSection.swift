import SwiftUI
import NollieCore

/// A helper's "Keep skills as they are" switch, off to start. On, every skill it has is locked (Hermes 0.23's own lock):
/// it can't change them, and it can still use them. The workflow add-on locks each one it makes from then on.
/// Changing it is a setting, so a phone linked to a Mac shows it and says to change it there. Private bots are never
/// asked about.
struct KeepSkillsSection: View {
    let profileName: String
    @Environment(AppModel.self) private var model
    @State private var on: Bool?
    @State private var unavailable = false
    @State private var saving = false
    @State private var problem: String?

    private var runtime: GatewayRuntime? { model.runtime }
    private var linked: Bool { OnYourMac.applies(runtime?.connection) }
    private var scope: String {
        "\(profileName)/\(runtime?.connection.id.uuidString ?? "")/\(model.lock.isLocked)"
    }

    var body: some View {
        Group {
            if !unavailable, runtime != nil, !model.lock.isLocked, !AskFirstModel.isPrivateBot(profileName) {
                VStack(spacing: 12) {
                    GlassSwitch("Keep skills as they are", isOn: Binding(get: { on ?? false }, set: { want in
                        Task { await set(want) }
                    }), id: "profile.keepSkills")
                    .disabled(on == nil || saving || linked)
                    if linked {
                        OnYourMacNote(words: OnYourMac.changeThese)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 8)
                    } else if on == true {
                        PageNote("It can still use them. New ones stay as made.", symbol: "lock.fill", id: "profile.keepSkills.note")
                    }
                    if let problem {
                        PageNote(.verbatim(problem), symbol: "exclamationmark.triangle.fill", tint: .orange, id: "profile.keepSkills.problem")
                    }
                }
                .id("keepSkills")
            }
        }
        .task(id: scope) { await load() }
    }

    private func load() async {
        on = nil
        unavailable = false
        problem = nil
        guard let runtime, !model.lock.isLocked, !AskFirstModel.isPrivateBot(profileName) else { return }
        do {
            guard let found = try await KeepSkills.load(bot: profileName, api: runtime.api) else {
                unavailable = true   // an add-on without the switch
                return
            }
            guard !Task.isCancelled else { return }
            on = found
            // A skill written as plain files, past the helper's skill tool, isn't locked by the add-on: lock it now.
            if found, !linked { _ = await KeepSkills.settle(true, bot: profileName, api: runtime.api) }
        } catch HermesAPIError.http(status: let status, _) where status == 403 {
            unavailable = true
        } catch {
            guard !Task.isCancelled else { return }
            problem = String(localized: "Couldn't check this. Try again.")
        }
    }

    private func set(_ want: Bool) async {
        guard let runtime, on != want, !saving, !linked, !AskFirstModel.isPrivateBot(profileName) else { return }
        saving = true
        defer { saving = false }
        let previous = on
        on = want
        if await KeepSkills.set(want, bot: profileName, api: runtime.api) {
            problem = nil
        } else {
            // What the add-on has now, so the switch says what is true.
            on = (try? await KeepSkills.load(bot: profileName, api: runtime.api)) ?? previous
            problem = want ? String(localized: "Some skills couldn't be locked. Try again.")
                : String(localized: "Some skills couldn't be unlocked. Try again.")
        }
    }
}
