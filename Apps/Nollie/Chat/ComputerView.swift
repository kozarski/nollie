import SwiftUI
import NollieCore

/// One place to watch a bot work and manage its access to the Mac.
struct ComputerView: View {
    let chat: ChatSession
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Environment(AppModel.self) private var model
    @State private var preview = ComputerPreviewModel()
    @State private var paused = false
    @State private var expanded = false
    @State private var controlError: String?
    @State private var controlMessage: String?
    @State private var stopTask: Task<Void, Never>?

    private var profile: String { chat.profileName }
    private var name: String { chat.runtime.profiles.first { $0.name == profile }?.shownName ?? profile }
    private var active: Bool { BotComputerActivity.isActive(runtime: chat.runtime, profile: profile) }
    private var activityStatus: BotComputerActivity.Status { BotComputerActivity.status(runtime: chat.runtime, profile: profile) }
    private var control: SystemControl { .shared }
    private var watching: Bool { !paused && scenePhase == .active }
    private var watchKey: String { "\(chat.runtime.connection.id)/\(profile)/\(chat.storedID)/\(watching)" }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    HStack(spacing: 10) {
                        BotAvatar(profile: profile, size: 34, state: activityStatus == .usingComputer ? .usingTool : (activityStatus == .working ? .working : .idle)).accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(name).font(.headline)
                            Text(activityStatus.title)
                                .font(.subheadline).foregroundStyle(.secondary)
                                .accessibilityIdentifier("computer.activity.status")
                        }
                        Spacer()
                        if active {
                            Label("In use", systemImage: "circle.fill")
                                .font(.caption.weight(.semibold)).foregroundStyle(.blue)
                                .accessibilityElement(children: .ignore)
                                .accessibilityLabel("In use")
                                .accessibilityIdentifier("computer.active")
                        }
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        Toggle(isOn: Binding(get: { control.isOn(profile, chat.runtime) }, set: { enabled in
                            controlMessage = nil
                            Task {
                                let saved = await control.set(enabled, profile: profile, rt: chat.runtime)
                                controlError = saved ? nil : String(localized: "Couldn’t change Mac access. Try again.")
                            }
                        })) {
                            Label("Allow Mac control", systemImage: "desktopcomputer")
                        }
                        .toggleStyle(.switch)
                        .spread()
                        .disabled(control.isBusy(profile, chat.runtime) || control.state(profile, chat.runtime) == nil)
                        .accessibilityIdentifier("profile.systemControl")
                        Text("Applies to \(name)’s Mac screen actions. Tasks and virtual computers keep running.")
                            .font(.caption).foregroundStyle(.secondary)
                        if control.state(profile, chat.runtime) != false {
                            Button("Stop Mac control", systemImage: "stop.circle") { stopMacControl() }
                                .disabled(control.isBusy(profile, chat.runtime) || model.lock.isLocked || (control.state(profile, chat.runtime) == nil && controlError == nil))
                                .accessibilityHint("Turns off this bot’s permission for further Mac screen actions.")
                                .accessibilityIdentifier("computer.stopMacControl")
                        }
                        if let controlMessage {
                            Text(controlMessage).font(.footnote).foregroundStyle(.secondary)
                                .accessibilityIdentifier("computer.control.confirmed")
                        }
                        if let controlError {
                            Text(controlError).font(.footnote).foregroundStyle(.red)
                                .accessibilityIdentifier("computer.control.error")
                        }
                    }
                    .padding(16)
                    .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 18))

                    VStack(alignment: .leading, spacing: 14) {
                        HStack {
                            Label("\(name)’s computer", systemImage: "macwindow")
                                .font(.headline)
                            Spacer()
                            if preview.loading { ProgressView().controlSize(.small) }
                        }
                        if preview.kind == "space" {
                            Text(preview.computerName ?? String(localized: "Virtual computer"))
                                .font(.subheadline).foregroundStyle(.secondary)
                        }
                        if preview.image != nil, preview.kind == "space" {
                            previewControls
                        } else {
                            Text(preview.loading ? String(localized: "Checking computer…") : computerStatus)
                                .font(.subheadline).foregroundStyle(.secondary)
                                .accessibilityIdentifier("computer.unavailable")
                        }
                    }
                    .padding(16)
                    .spread()
                    .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 18))

                    if preview.image != nil, preview.kind != "space" {
                        VStack(alignment: .leading, spacing: 12) {
                            Label(preview.kind == "mac" ? "Your Mac" : "Last shared screen", systemImage: "desktopcomputer").font(.headline)
                            previewControls
                        }
                    }
                }
                .padding(20)
                .frame(maxWidth: 800)
                .spread(.center)
            }
            .navigationTitle("Computer")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }.accessibilityIdentifier("computer.done")
                }
            }
        }
        .presentationDetents([.large])
        #if os(macOS)
        .frame(width: 560, height: preview.image == nil ? 380 : 650)
        #endif
        .task { await control.refresh(profile, chat.runtime) }
        .task(id: watchKey) { if watching { await preview.watch(chat) } }
        .onDisappear { stopTask?.cancel() }
        .onChange(of: model.lock.isLocked) { _, locked in
            if locked { stopTask?.cancel(); controlMessage = nil }
        }
        .sheet(isPresented: $expanded) {
            NavigationStack {
                screen(large: true).padding(12)
                    .navigationTitle(preview.computerName ?? String(localized: "Computer", comment: "A computer the bot uses; a noun"))
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) { Button("Done") { expanded = false } }
                    }
            }
            .sheetFrame(.wide)
            .withAppModel()
        }
    }

    private var computerStatus: String {
        if preview.signInPaused { return WatchPolicy.signInPausedSentence }
        if preview.needsCompanion { return String(localized: "Computer preview is unavailable on this gateway.") }
        if preview.kind == "space" { return String(localized: "Preview unavailable. Reconnecting…") }
        if preview.interrupted || preview.unavailable && preview.kind == nil { return String(localized: "Couldn’t check the computer. Trying again…") }
        return String(localized: "No virtual computer connected to this chat yet.")
    }

    private var previewControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            screen()
            HStack {
                Button("Open preview", systemImage: "arrow.up.left.and.arrow.down.right") { expanded = true }
                    .accessibilityIdentifier("computer.expand")
                Spacer()
                Button(paused ? "Resume preview" : "Pause preview", systemImage: paused ? "play.fill" : "pause.fill") { paused.toggle() }
                    .accessibilityHint("Changes screen updates only. The bot can keep working.")
                    .accessibilityIdentifier("computer.pause")
            }
            .font(.subheadline)
            Text("Pausing the preview only stops screen updates. The bot can keep working.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func stopMacControl() {
        let runtime = chat.runtime
        guard !model.lock.isLocked, model.runtime === runtime else { return }
        controlMessage = nil
        controlError = nil
        stopTask = Task {
            let stopped = await control.stopMacControl(profile: profile, rt: runtime) {
                !model.lock.isLocked && model.runtime === runtime
            }
            guard !Task.isCancelled, !model.lock.isLocked, model.runtime === runtime else { return }
            controlMessage = stopped ? String(localized: "Mac control is off.") : nil
            controlError = stopped ? nil : String(localized: "Couldn't confirm Mac control is off. Check the connection and try again.")
        }
    }

    private func screen(large: Bool = false) -> some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let live = watching && preview.isLive(at: context.date)
            ZStack {
                Color.black.opacity(0.92)
                if let image = preview.image {
                    Image(image, scale: 1, label: Text("\(name)’s computer screen")).resizable().scaledToFit()
                        .accessibilityValue(preview.frame?.capturedAt.map { Date(timeIntervalSince1970: $0).formatted(date: .omitted, time: .standard) } ?? String(localized: "Last screen"))
                        .accessibilityIdentifier("computer.frame")
                } else {
                    VStack(spacing: 12) {
                        if preview.loading { ProgressView().tint(.white) }
                        else { Image(systemName: "desktopcomputer").font(.largeTitle) }
                        Text(preview.loading ? String(localized: "Connecting to the screen…")
                             : (preview.signInPaused ? WatchPolicy.signInPausedSentence : String(localized: "No screen to show yet")))
                            .font(.subheadline)
                    }.foregroundStyle(.white.opacity(0.8))
                }
            }
            #if os(macOS)
            .frame(height: large ? 450 : 270)
            #else
            .aspectRatio(16 / 10, contentMode: .fit)
            #endif
            .overlay(alignment: .topLeading) {
                if preview.image != nil {
                    Label(paused ? "Preview paused" : (live ? "Live" : "Last screen"), systemImage: live ? "circle.fill" : "clock")
                        .font(.caption.weight(.semibold))
                        .inset(h: 10, v: 7)
                        .background(.regularMaterial, in: .capsule)
                        .padding(12)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(paused ? "Preview paused" : (live ? "Live" : "Last screen"))
                        .accessibilityIdentifier("computer.preview.status")
                }
            }
            .clipShape(.rect(cornerRadius: 18))
            .overlay { RoundedRectangle(cornerRadius: 18).strokeBorder(active ? Color.blue.opacity(0.7) : Color.primary.opacity(0.1), lineWidth: active ? 2 : 1) }
            .shadow(color: active ? .blue.opacity(0.2) : .clear, radius: 12)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("computer.preview")
        }
    }
}
