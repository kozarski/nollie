import SwiftUI
import NollieCore

/// The sheet for making a bot, or (with `editing`) changing one.
///
/// A new bot starts in the gallery of ready-made helpers when the crew add-on can take one: a tap
/// adds a helper with its look and instructions. "Your own" (and a gateway without the add-on) opens
/// the form: a gateway profile (name, description, default model) plus a look stored on this
/// device, with the live character, its name and the looks to pick from, and one button.
/// Description, model and "start from" are tucked under More options.
struct NewBotSheet: View {
    var runtime: GatewayRuntime
    /// Set this to edit an existing bot (look, description, model); a Delete button then appears at the
    /// end. Its name cannot change because a profile is just a folder that the gateway cannot rename.
    var editing: ProfileInfo? = nil

    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss

    @State private var typedName = ""
    @State private var about = ""
    @State private var cloneFrom = ""
    @State private var catalog: ModelOptionsResult?
    @State private var provider = ""
    @State private var modelName = ""
    /// The look chosen here. Until one is, the look follows the typed name.
    @State private var pickedLook: CharacterChoice?
    @State private var optionsOpen = false
    @State private var working = false
    @State private var problem: String?
    @State private var asksToDelete = false
    @State private var creation = NewBotCreation()
    @State private var pending: Task<Void, Never>?
    @State private var gallery = HelperGallery()
    @State private var makingOwn = false
    @FocusState private var nameFocused: Bool

    // MARK: Derived values

    /// The name as the gateway will store it: lowercase letters, digits, dashes and underscores,
    /// with runs of other characters turned into a single dash.
    private var slug: String {
        var out = ""
        for ch in typedName.lowercased() {
            let allowed = ch.isLetter || ch.isNumber || ch == "-" || ch == "_"
            let piece: Character = allowed ? ch : "-"
            if piece == "-", out.last == "-" { continue }
            out.append(piece)
        }
        return out.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    private var lookKey: String {
        if let editing { return editing.name }
        return slug.isEmpty ? "new-bot" : slug
    }
    private var look: CharacterChoice { pickedLook ?? .look(.defaultLook(forProfile: lookKey)) }
    private var nameTaken: Bool { runtime.profiles.contains(where: { $0.name == slug }) }
    private var hasModel: Bool { (!provider.isEmpty && !modelName.isEmpty) || !cloneFrom.isEmpty }

    private var canSubmit: Bool {
        if working { return false }
        if editing != nil { return true }
        let nameOK = creation.request != nil || (!slug.isEmpty && !nameTaken)
        return nameOK && hasModel && !app.lock.isLocked
    }

    private var buttonTitle: String {
        if working { return editing == nil ? "Creating…" : "Saving…" }
        if editing != nil { return "Save" }
        if creation.phase == .unconfirmed { return "Check again" }
        return creation.request == nil ? "Create" : "Retry setup"
    }

    private var modelLabel: String {
        if modelName.isEmpty { return cloneFrom.isEmpty ? "Choose a model" : "Copy bot's model" }
        return modelName.split(separator: "/").last.map(String.init) ?? modelName
    }

    // MARK: Body

    var body: some View {
        NavigationStack {
            start
                .navigationDestination(isPresented: $makingOwn) { form }
        }
        .presentationDetents([.large])
        .interactiveDismissDisabled(working)
        .onDisappear { pending?.cancel() }
        .onChange(of: app.lock.isLocked) { _, locked in
            if locked { pending?.cancel() }
        }
        .task {
            guard editing == nil else { return }
            await gallery.load(.gateway(runtime))
        }
    }

    /// Where the sheet opens: the gallery when it can be used, else the form.
    @ViewBuilder private var start: some View {
        if editing != nil || gallery.availability == .unavailable {
            form
        } else if gallery.availability == .ready {
            HelperGalleryView(runtime: runtime, gallery: gallery) { makingOwn = true }
                .navigationTitle("New Bot")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { cancelItem }
        } else {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .navigationTitle("New Bot")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { cancelItem }
        }
    }

    private var cancelItem: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button { dismiss() } label: { Image(systemName: "xmark") }
                .tint(.primary)
                .accessibilityLabel("Cancel")
                .help("Cancel")
                .disabled(working)
        }
    }

    private var form: some View {
        ScrollView {
            VStack(spacing: 22) {
                BotAvatar(profile: lookKey, size: 124, state: .listening, override: look)
                    .padding(.top, 10)
                    .accessibilityLabel("The new bot's look")
                nameBox
                // A bot that does not exist yet has no place to keep a photo.
                CharacterLookPicker(profile: lookKey, choice: Binding(get: { look }, set: { pickedLook = $0 }), allowsPhoto: false)
                moreOptions
                if let problem {
                    Text(problem)
                        .small(.footnote, .red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .testID("newBot.issue")
                }
                if let editing { deleteSection(editing) }
            }
            .padding(.horizontal, 22).padding(.bottom, 20)
            .frame(maxWidth: 520)
            .frame(maxWidth: .infinity)
        }
        .scrollDismissesKeyboard(.interactively)
        .safeAreaInset(edge: .bottom, spacing: 0) { footer }
        .navigationTitle(editing.map { "Edit \($0.label)" } ?? (makingOwn ? "Your Own" : "New Bot"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { if !makingOwn { cancelItem } }
        .task { await prepare() }
    }

    private var footer: some View {
        Button(buttonTitle) {
            pending = Task {
                if editing == nil { await create() } else { await save() }
            }
        }
        .buttonStyle(InkButtonStyle())
        .disabled(!canSubmit)
        .keyboardShortcut(.defaultAction)
        .padding(.init(top: 10, leading: 22, bottom: 12, trailing: 22))
        .frame(maxWidth: 520)
        .frame(maxWidth: .infinity)
        .testID("newBot.create")
    }

    private func prepare() async {
        if let editing, typedName.isEmpty {
            typedName = editing.name
            about = editing.description ?? ""
            modelName = editing.model ?? ""
            provider = editing.provider ?? ""
            pickedLook = BotAvatarStore.choice(for: editing.name)
        }
        catalog = try? await runtime.api.get("/api/model/options", profile: runtime.selectedProfile)
    }

    // MARK: Pieces

    private var nameBox: some View {
        let locked = editing != nil
        return VStack(spacing: 6) {
            TextField(locked ? "" : "Name your bot", text: $typedName)
                .font(.title3.weight(.semibold))
                .multilineTextAlignment(.center)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                #if os(macOS)
                .textFieldStyle(.plain)
                #endif
                .focused($nameFocused)
                .disabled(locked || creation.request != nil || working)
                .foregroundStyle(locked ? .secondary : .primary)
                .padding(.vertical, 15).padding(.horizontal, 20)
                .background(Color.primary.opacity(0.06), in: .capsule)
                .testID("newBot.name")

            if !locked, !typedName.isEmpty, slug != typedName {
                Text("Saved as \(slug)").small(.caption, .secondary)
            } else if !locked, creation.request == nil, nameTaken {
                Text("Another bot already has that name.").small(.caption, .red)
            }
        }
    }

    private var moreOptions: some View {
        VStack(alignment: .leading, spacing: 14) {
            Button {
                withAnimation(.snappy) { optionsOpen.toggle() }
            } label: {
                HStack {
                    Text("More options").font(.subheadline.weight(.medium))
                    Spacer()
                    Image(systemName: "chevron.down")
                        .font(.caption.weight(.semibold))
                        .rotationEffect(.degrees(optionsOpen ? 180 : 0))
                }
                .foregroundStyle(.secondary)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .testID("newBot.more")

            if optionsOpen {
                VStack(alignment: .leading, spacing: 16) {
                    descriptionField
                    modelRow
                    if editing == nil { startFromRow }
                }
                .padding(.top, 4)
                .disabled(working || creation.request != nil)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    private var descriptionField: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Description").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            TextField("What this bot is for", text: $about, axis: .vertical)
                .lineLimit(1...3)
                #if os(macOS)
                .textFieldStyle(.plain)
                #endif
                .padding(.vertical, 13).padding(.horizontal, 18)
                .background(Color.primary.opacity(0.06), in: .capsule)
        }
    }

    private var modelRow: some View {
        HStack {
            Text("Model").font(.subheadline)
            Spacer()
            if let catalog {
                Menu {
                    ForEach(catalog.providers) { entry in
                        Section(entry.name) {
                            ForEach(entry.models ?? [], id: \.self) { name in
                                Button(name) {
                                    provider = entry.slug
                                    modelName = name
                                }
                                .testID("newBot.model.\(entry.slug).\(name)")
                            }
                        }
                    }
                } label: {
                    Text(modelLabel).font(.subheadline).lineLimit(1)
                }
                .fixedSize()
                .testID("newBot.model")
            } else {
                ProgressView().controlSize(.small)
            }
        }
    }

    private var startFromRow: some View {
        HStack {
            Text("Start from").font(.subheadline)
            Spacer()
            Picker("Start from", selection: $cloneFrom) {
                Text("A fresh bot").tag("")
                ForEach(runtime.profiles.filter { !$0.isPrivateBot(on: runtime.connection.id) }) { bot in
                    Text(bot.label).tag(bot.name)
                }
            }
            .labelsHidden()
            .fixedSize()
        }
    }

    private func deleteSection(_ bot: ProfileInfo) -> some View {
        Button("Delete \(bot.label)", role: .destructive) { asksToDelete = true }
            .buttonStyle(SoftButtonStyle(compact: true))
            .disabled(working || bot.isDefault == true)
            // Attached to its own button so the dialog appears next to it rather than at the top of the sheet.
            .confirmationDialog(
                "Delete \(bot.label)?", isPresented: $asksToDelete, titleVisibility: .visible,
                actions: { Button("Delete bot", role: .destructive, action: asTask(deleteBot)) },
                message: { Text("This deletes its SOUL.md, config and chats from the gateway for good.") })
            .padding(.top, 8)
    }

    // MARK: Talking to the gateway

    /// The few profile calls this sheet makes.
    private struct Calls {
        let runtime: GatewayRuntime

        func describe(_ name: String, as text: String) async throws {
            let body = JSONValue.object(["description": .string(text)])
            let _: JSONValue = try await runtime.api.send("PUT", "/api/profiles/\(name)/description", json: body)
        }

        func choose(model: String, from provider: String, for name: String) async throws {
            let body = JSONValue.object(["provider": .string(provider), "model": .string(model)])
            let _: JSONValue = try await runtime.api.send("PUT", "/api/profiles/\(name)/model", json: body)
        }

        func remove(_ name: String) async throws {
            let _: JSONValue = try await runtime.api.send("DELETE", "/api/profiles/\(name)", body: EmptyBody())
        }

        func currentModel(of name: String) async throws -> (provider: String, model: String) {
            let options: ModelOptionsResult = try await runtime.api.get("/api/model/options", profile: name)
            return (options.provider ?? "", options.model ?? "")
        }
    }

    private var calls: Calls { Calls(runtime: runtime) }

    /// After a change that others should see: reload the bots, tell the chat list, close the sheet.
    private func finish(announcing: Bool) async {
        await runtime.loadProfiles()
        if announcing { NotificationCenter.default.post(name: .hermesSessionsChanged, object: nil) }
        dismiss()
    }

    private func save() async {
        guard let bot = editing else { return }
        working = true
        defer { working = false }
        do {
            let note = about.trimmingCharacters(in: .whitespacesAndNewlines)
            if note != (bot.description ?? "") { try await calls.describe(bot.name, as: note) }
            let modelChanged = (modelName, provider) != (bot.model ?? "", bot.provider ?? "")
            if modelChanged, !modelName.isEmpty { try await calls.choose(model: modelName, from: provider, for: bot.name) }
            BotAvatarStore.set(look, for: bot.name)
            await finish(announcing: false)
        } catch {
            problem = error.localizedDescription
        }
    }

    private func deleteBot() async {
        guard let bot = editing else { return }
        working = true
        defer { working = false }
        do {
            try await calls.remove(bot.name)
            if runtime.selectedProfile == bot.name {
                runtime.selectedProfile = runtime.profiles.first { $0.name != bot.name }?.name
            }
            await finish(announcing: true)
        } catch {
            problem = error.localizedDescription
        }
    }

    private func create() async {
        working = true
        defer { working = false }
        problem = nil

        let request = NewBotCreation.Request(
            name: slug,
            description: about.trimmingCharacters(in: .whitespacesAndNewlines),
            cloneFrom: cloneFrom.isEmpty ? nil : cloneFrom,
            provider: provider.isEmpty ? nil : provider,
            model: modelName.isEmpty ? nil : modelName)

        let calls = self.calls
        let stillAllowed = { !app.lock.isLocked && app.runtime === runtime }
        let verified = await creation.submit(
            request, allowed: stillAllowed,
            create: { body in try await runtime.api.send("POST", "/api/profiles", body: body) },
            setModel: { name, chosen in try await calls.choose(model: chosen.model, from: chosen.provider, for: name) },
            readModel: { name in
                let now = try await calls.currentModel(of: name)
                return .init(provider: now.provider, model: now.model)
            })

        guard !Task.isCancelled, stillAllowed(), verified, let created = creation.request?.name else {
            problem = creation.issue
            return
        }
        // The look picked here now belongs to the new name.
        BotAvatarStore.set(look, for: created)
        await finish(announcing: true)
    }
}
