import AVFoundation
import SwiftUI
import NollieCore

/// The composer's talk button: starts talk mode in this chat. The first time, a sheet says why
/// Nollie wants the mic before the system asks.
struct TalkModeButton: View {
    var chat: ChatSession
    @State private var asking = false

    var body: some View {
        PlainButton(action: tapped) {
            Glyph("waveform", .system(size: Ink.composerButton * 0.42, weight: .semibold), Ink.text)
                .frame(square: Ink.composerButton)
                .background(Ink.plusFill, in: .circle)
                .contentShape(.circle)
        }
        .accessibilityLabel("Talk")
        .accessibilityHint("A spoken conversation. Replies are read aloud.")
        .testID("composer.talk")
        .sheet(isPresented: $asking) {
            VoicePermissionSheet(bot: chat.profileName, onAllowed: begin).withAppModel()
        }
    }

    private func tapped() {
        if AVAudioApplication.shared.recordPermission == .granted {
            begin()
        } else {
            asking = true
        }
    }

    private func begin() {
        withAnimation(.snappy) { TalkMode.shared.start(in: chat) }
    }
}

/// Before the system's microphone question: the bot, what talk mode does, and one button. When
/// the mic was turned off before, the button opens Settings instead.
struct VoicePermissionSheet: View {
    var bot: String
    var onAllowed: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var state: PermissionState = .notAsked
    @State private var busy = false

    private var permissions: PermissionCenter { AppModel.shared.permissions }

    private var botName: String {
        AppModel.shared.runtime?.profiles.first { $0.name == bot }?.shownName ?? "Nollie"
    }

    var body: some View {
        FittedSheet {
            VStack(spacing: 18) {
                BotAvatar(profile: bot, size: 96, state: .listening)
                Text("Talk with \(botName)")
                    .font(.title2.weight(.bold)).multilineTextAlignment(.center)
                    .testID("voice.permission.title")
                Text(line)
                    .font(.body).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .testID("voice.permission.line")
                VStack(spacing: 10) {
                    Button(action: allow) {
                        Text(state == .denied ? "Open Settings" : "Allow microphone").fullWidthLabel()
                    }
                    .buttonStyle(.nollieGlassProminent)
                    .disabled(busy)
                    .testID("voice.permission.allow")
                    Button("Not now") { dismiss() }
                        .small(.subheadline, .secondary)
                        .testID("voice.permission.notNow")
                }
                .padding(.top, 6)
            }
            .sheetColumn()
        }
        .task {
            await permissions.refresh(.microphone)
            state = permissions.state(.microphone)
        }
    }

    private var line: String {
        if state == .denied { return String(localized: "The microphone is off for Nollie. You can turn it on in Settings.") }
        return String(localized: "I listen while you talk. Your voice stays on \(DeviceWords.this), and only your words are sent.",
                      comment: "Safety: what leaves the device in talk mode; %@ is a phrase like this iPhone")
    }

    private func allow() {
        if state == .denied {
            permissions.openSettings(.microphone)
            return
        }
        busy = true
        Task {
            state = await permissions.ask(.microphone)
            busy = false
            guard state == .granted else { return }
            dismiss()
            onAllowed()
        }
    }
}

/// Talk mode in place of the composer: what is happening in a word, the mic's level while it
/// listens, and End. While a reply is read, a tap on the words stops it and listens.
struct TalkBar: View {
    var namespace: Namespace.ID
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var talk: TalkMode { TalkMode.shared }
    private var phase: TalkLoop.Phase { talk.phase }

    var body: some View {
        HStack(spacing: 12) {
            status
            Spacer(minLength: 8)
            if phase == .listening {
                TalkLevels(levels: talk.levels).frame(width: 72, height: 22).transition(.opacity)
            }
            endButton
        }
        .padding(.leading, 16)
        .padding(Ink.composerInset)
        .frame(minHeight: Ink.composerHeight)
        .composerSurface(namespace: namespace)
        .animation(.snappy, value: phase)
        .accessibilityElement(children: .contain)
        .testID("talk.bar")
    }

    private var status: some View {
        PlainButton(action: { talk.skip() }) {
            HStack(spacing: 10) {
                Image(systemName: symbol)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(phase == .needsYou ? Color.orange : Ink.text)
                    .symbolEffect(.variableColor.iterative, isActive: animating)
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: 28)
                    .accessibilityHidden(true)
                Text(TalkWords.state(phase))
                    .font(.headline)
                    .foregroundStyle(Ink.text)
                    .contentTransition(.opacity)
                    .testID("talk.state")
            }
        }
        // Only while speaking is the tap anything; dimming it the rest of the time would look broken.
        .allowsHitTesting(phase == .speaking)
        .accessibilityHint(phase == .speaking ? "Stops reading and listens" : "")
    }

    private var symbol: String {
        switch phase {
        case .off, .listening: "waveform"
        case .transcribing, .waiting: "ellipsis"
        case .speaking: "speaker.wave.2.fill"
        case .needsYou: "hand.raised.fill"
        }
    }

    private var animating: Bool {
        !reduceMotion && [.listening, .transcribing, .waiting, .speaking].contains(phase)
    }

    private var endButton: some View {
        Button { withAnimation(.snappy) { talk.stop() } } label: {
            Text("End").font(.headline).padding(.horizontal, 6)
        }
        .buttonStyle(.nollieGlassProminent)
        .buttonBorderShape(.capsule)
        .tint(.red)
        .controlSize(.large)
        .accessibilityLabel("End talking")
        .testID("talk.end")
    }
}

/// The mic's level while listening: a few soft bars, newest on the right.
struct TalkLevels: View {
    var levels: [Float]

    var body: some View {
        GeometryReader { box in
            let count = TalkMode.levelSamples
            let readings = Array(repeating: Float(0), count: max(0, count - levels.count)) + levels
            let slot = box.size.width / CGFloat(count)
            HStack(spacing: 0) {
                ForEach(readings.indices, id: \.self) { index in
                    Capsule()
                        .fill(Ink.text2)
                        .frame(width: max(2, slot * 0.5), height: max(3, CGFloat(readings[index]) * box.size.height))
                        .frame(width: slot)
                }
            }
            .frame(height: box.size.height)
        }
        .animation(.linear(duration: 0.05), value: levels)
        .accessibilityHidden(true)
    }
}

/// The play button beside a reply: hear just that one, tap again to stop.
struct ReplyListenButton: View {
    var text: String
    var key: String
    /// The bot, so its character shows it is speaking.
    var owner: String

    var body: some View {
        let speaking = ReplyVoice.shared.isSpeaking(key)
        PlainButton(action: { ReplyVoice.shared.toggle(SpokenReply.plain(text), key: key, owner: owner) }) {
            Image(systemName: speaking ? "stop.fill" : "play.fill")
                .font(.footnote.weight(.semibold))
                // The circle keeps its size, so the symbol stops growing where it would spill out.
                .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                .foregroundStyle(Ink.text2)
                .contentTransition(.symbolEffect(.replace))
                .frame(square: 30)
                .nollieGlass(.regular.interactive(), in: .circle)
                .frame(square: 44)
                .contentShape(.circle)
        }
        .accessibilityLabel(speaking ? "Stop reading" : "Read aloud")
        .testID("reply.listen")
    }
}
