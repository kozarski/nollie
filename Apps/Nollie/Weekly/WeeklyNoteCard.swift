import SwiftUI
import UserNotifications
import NollieCore

/// The weekly note at the top of the main chat's thread, scrolling with it: a glass capsule with the week in a
/// few words. A tap opens the note; the cross puts it away until next week's.
struct WeeklyNoteStrip: View {
    var chat: ChatSession
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var weekly: WeeklyNoteModel { .shared }

    /// Only in Nollie's own main chat, as the night shift's card.
    private var isMainChat: Bool {
        chat.profileName == "default" && BotsHome.shared.entry(chat.runtime, "default").storedID == chat.storedID
    }

    var body: some View {
        Group {
            if isMainChat, weekly.cardShows(model), let note = weekly.note {
                WeeklyNoteCard(note: note, open: { model.weeklyRequest = UUID() }, putAway: {
                    withAnimation(reduceMotion ? nil : .snappy) { weekly.putAway() }
                })
                .frame(maxWidth: Ink.column)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.vertical, 6)
                .spread(.center)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .animation(reduceMotion ? nil : .snappy, value: weekly.note?.headline)
    }
}

/// The card itself: the note's symbol, "Your week", its one line, and a cross.
struct WeeklyNoteCard: View {
    var note: WeeklyNote
    var open: () -> Void
    var putAway: () -> Void
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        HStack(spacing: 14) {
            Button(action: open) {
                HStack(spacing: 14) {
                    if !large {
                        Image(systemName: WeeklyInk.symbol)
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(WeeklyInk.tint)
                            .accessibilityHidden(true)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        // At the largest sizes the card keeps to its name, so it never fills the chat.
                        let titleLayout = large ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4))
                            : AnyLayout(HStackLayout(spacing: 8))
                        titleLayout {
                            Text("Your week").font(.headline).foregroundStyle(Ink.text)
                                .fixedSize(horizontal: false, vertical: true)
                            if !note.news.isEmpty { NewTag() }
                        }
                        if !large {
                            Text(note.headline).font(.subheadline).foregroundStyle(Ink.text2)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)
            .accessibilityValue(note.headline)
            .accessibilityHint("Opens the note")
            .testID("weekly.card")
            Button(action: putAway) {
                Image(systemName: "xmark")
                    .font(.footnote.weight(.bold))
                    .foregroundStyle(Ink.text2)
                    .frame(width: 32, height: 32)
                    // A fingertip's square around the small cross, without moving it.
                    .tapTarget(face: 32)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Put away until next week")
            .testID("weekly.card.putAway")
        }
        .padding(.leading, 20).padding(.trailing, 10).padding(.vertical, 10)
        .nollieGlass(.regular, in: shape, solid: Ink.card)
    }

    private var large: Bool { typeSize.isAccessibilitySize }

    private var shape: AnyShape {
        typeSize.isAccessibilitySize ? AnyShape(.rect(cornerRadius: 26, style: .continuous)) : AnyShape(Capsule())
    }
}

/// Keeps the note fresh for this gateway, keeps its notification set, and opens the note when asked: from its
/// card, its notification, or a design picture's flag.
struct WeeklyNoteHost: ViewModifier {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var phase
    @AppStorage(WeeklyNoteModel.onKey) private var on = true
    @AppStorage(WeeklyNoteModel.weekdayKey) private var weekday = WeeklyNoteTiming.standard.weekday

    private var key: String {
        "\(model.runtime?.connection.id.uuidString ?? "")/\(model.runtime?.profiles.count ?? 0)/\(on)/\(weekday)/\(model.family.isMember(model))"
    }

    func body(content: Content) -> some View {
        content
            .task(id: key) { await WeeklyNoteModel.shared.refresh(model, force: true) }
            .onChange(of: phase) { _, now in
                if now == .active { Task { await WeeklyNoteModel.shared.refresh(model) } }
            }
            .sheet(isPresented: Binding(get: { model.weeklyRequest != nil && WeeklyNoteModel.shows(model) },
                                        set: { if !$0 { model.weeklyRequest = nil } })) {
                WeeklyNoteSheet().withAppModel()
            }
            #if DEBUG
            .task {
                // For pictures: `-nollie-demo-weekly-notification` shows the notification the Mac would send now,
                // with the line built from the same records, as its alerts helper builds it.
                guard DemoMode.isOn, ProcessInfo.processInfo.arguments.contains("-nollie-demo-weekly-notification") else { return }
                try? await Task.sleep(for: .seconds(4))
                let content = UNMutableNotificationContent()
                content.title = WeeklyNote.notificationTitle
                content.body = WeeklyNoteModel.shared.note?.notificationLine ?? WeeklyNote.notificationFallback
                content.userInfo = ["nollie": "weekly"]
                content.threadIdentifier = WeeklyNoteReminder.identifier
                try? await UNUserNotificationCenter.current().add(
                    UNNotificationRequest(identifier: "nollie.weekly.demo", content: content,
                                          trigger: UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)))
            }
            .task {
                // For pictures: `-nollie-demo-weekly` opens the note once the week has been read.
                guard DemoMode.isOn, ProcessInfo.processInfo.arguments.contains("-nollie-demo-weekly") else { return }
                try? await Task.sleep(for: .seconds(4))
                model.weeklyRequest = UUID()
                // `-nollie-demo-weekly-tap <line id> [undo]` presses that line's first tap, as a finger would, and
                // with `undo` its Undo a moment later.
                let words = ProcessInfo.processInfo.arguments
                guard let at = words.firstIndex(of: "-nollie-demo-weekly-tap"), at + 1 < words.count else { return }
                let line = words[at + 1]
                try? await Task.sleep(for: .seconds(2))
                let lines = (WeeklyNoteModel.shared.note?.helpers ?? []).flatMap { $0.did + $0.left }
                guard let action = lines.first(where: { $0.id == line })?.actions.first else { return }
                await WeeklyNoteModel.shared.perform(action, line: line, model: model)
                guard at + 2 < words.count, words[at + 2] == "undo", let undo = action.undo else { return }
                try? await Task.sleep(for: .seconds(3))
                await WeeklyNoteModel.shared.perform(undo, line: line, model: model)
            }
            #endif
    }
}

extension View {
    func weeklyNoteHost() -> some View { modifier(WeeklyNoteHost()) }
}
