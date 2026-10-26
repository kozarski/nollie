import SwiftUI

/// Settings › Voice: whether replies are read aloud, what voice does, and a way to hear it.
/// Everything spoken and heard stays on this device.
struct VoiceSettingsView: View {
    @AppStorage(VoiceSettings.readAloudKey) private var readAloud = false

    private static let sample = "Hello. This is how your replies will sound."

    var body: some View {
        SettingsPage("voice.page") {
            PageHero(symbol: readAloud ? "speaker.wave.2.fill" : "speaker.slash.fill",
                     title: readAloud ? "Replies read aloud" : "Replies stay quiet",
                     line: "Speech never leaves \(DeviceWords.this).",
                     tint: readAloud ? .indigo : Ink.text2, id: "voice.hero")
            FactStrip(facts: [
                Fact(symbol: "play.circle.fill", word: "Tap to hear"),
                Fact(symbol: "waveform", word: "Hands-free"),
                Fact(symbol: "lock.fill", word: "On device"),
                Fact(symbol: "hand.tap.fill", word: "Tap to approve"),
            ], tint: .indigo, id: "voice.facts")
            GlassStack {
                GlassSwitch("Read replies aloud", isOn: $readAloud, id: "voice.readAloud")
                    .onChange(of: readAloud) { _, on in if !on { ReplyVoice.shared.stop() } }
                GlassButton(ReplyVoice.shared.isSpeaking("voice.sample") ? "Stop" : "Hear the voice",
                            symbol: ReplyVoice.shared.isSpeaking("voice.sample") ? "stop.fill" : "play.fill",
                            value: ReplyVoice.voiceName, id: "voice.sample") {
                    ReplyVoice.shared.toggle(Self.sample, key: "voice.sample", owner: "settings")
                }
            }
        }
        .animation(.snappy, value: readAloud)
        .onDisappear { ReplyVoice.shared.stop(for: "settings") }
    }
}
