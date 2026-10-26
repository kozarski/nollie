import AVFoundation
import NaturalLanguage
import SwiftUI

/// Settings › Voice.
enum VoiceSettings {
    /// "Read replies aloud": each reply that arrives in the chat on screen is spoken.
    static let readAloudKey = "voice.readReplies"
}

/// Reads replies aloud with the best voice already on this device. The words never leave it:
/// the system's speech synthesizer does the work locally. One thing speaks at a time; starting
/// another, or Stop, ends the one before.
@MainActor
@Observable
final class ReplyVoice: NSObject {
    static let shared = ReplyVoice()

    /// What is being read: a reply's row id, or a talk mode key.
    private(set) var speakingKey: String?
    /// Whose words are being read: a chat's stored id or a bot's profile name, so that bot's
    /// character can show it is speaking.
    private(set) var speakingFor: String?

    @ObservationIgnored private let synthesizer = AVSpeechSynthesizer()
    @ObservationIgnored private var current: AVSpeechUtterance?
    @ObservationIgnored private var finished: CheckedContinuation<Void, Never>?

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    var isSpeaking: Bool { speakingKey != nil }

    func isSpeaking(_ key: String) -> Bool { speakingKey == key }

    /// Starts reading `text`, or stops if this same thing is already being read.
    func toggle(_ text: String, key: String, owner: String) {
        if speakingKey == key { stop(); return }
        Task { await speak(text, key: key, owner: owner) }
    }

    /// Reads `text` and returns once it has been read or stopped.
    func speak(_ text: String, key: String, owner: String) async {
        stop()
        let words = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !words.isEmpty else { return }
        SpeakingSession.begin()
        let utterance = Self.utterance(for: words)
        current = utterance
        speakingKey = key
        speakingFor = owner
        await withCheckedContinuation { done in
            finished = done
            synthesizer.speak(utterance)
        }
    }

    /// Stops at once, mid-word.
    func stop() {
        guard current != nil else { return }
        synthesizer.stopSpeaking(at: .immediate)
        ended(current)
    }

    /// Stops only if what is speaking belongs to one of `owners`.
    func stop(for owners: String...) {
        if let speakingFor, owners.contains(speakingFor) { stop() }
    }

    fileprivate func ended(_ utterance: AVSpeechUtterance?) {
        guard let utterance, utterance === current else { return }
        current = nil
        speakingKey = nil
        speakingFor = nil
        SpeakingSession.end()
        finished?.resume()
        finished = nil
    }

    // MARK: The voice

    /// A calm pace, a touch under the system's usual one, with a breath before it starts.
    private static func utterance(for text: String) -> AVSpeechUtterance {
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = bestVoice(for: language(of: text))
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 0.96
        utterance.pitchMultiplier = 1
        utterance.preUtteranceDelay = 0.1
        return utterance
    }

    /// The reply's own language when it is clear, otherwise the person's.
    private static func language(of text: String) -> String {
        let person = AVSpeechSynthesisVoice.currentLanguageCode()
        guard let found = NLLanguageRecognizer.dominantLanguage(for: text)?.rawValue,
              !person.hasPrefix(found) else { return person }
        return found
    }

    /// The most natural voice installed for `language`: premium, then enhanced, then the rest.
    /// Novelty voices and the person's own Personal Voice are never used.
    static func bestVoice(for language: String) -> AVSpeechSynthesisVoice? {
        let base = language.split(separator: "-").first.map(String.init) ?? language
        let fitting = AVSpeechSynthesisVoice.speechVoices().filter { voice in
            !voice.voiceTraits.contains(.isNoveltyVoice) && !voice.voiceTraits.contains(.isPersonalVoice)
                && (voice.language == language || voice.language.hasPrefix(base + "-"))
        }
        let ranked = fitting.sorted { a, b in
            if a.quality != b.quality { return a.quality.rawValue > b.quality.rawValue }
            // Same quality: the person's exact region first.
            return (a.language == language ? 0 : 1) < (b.language == language ? 0 : 1)
        }
        return ranked.first ?? AVSpeechSynthesisVoice(language: language)
    }

    /// The voice's name, as Settings shows it ("Zoe").
    static var voiceName: String? {
        bestVoice(for: AVSpeechSynthesisVoice.currentLanguageCode())?.name
    }
}

extension ReplyVoice: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        let done = UncheckedBox(utterance)
        Task { @MainActor in ReplyVoice.shared.ended(done.value) }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        let done = UncheckedBox(utterance)
        Task { @MainActor in ReplyVoice.shared.ended(done.value) }
    }
}

/// Carries a value the delegate gets off the main actor back onto it.
private struct UncheckedBox<Value>: @unchecked Sendable {
    let value: Value
    init(_ value: Value) { self.value = value }
}

/// The phone's audio while a reply is read: spoken audio that lowers music and pauses podcasts,
/// then gives them back. Nothing to do on the Mac.
enum SpeakingSession {
    static func begin() {
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        let polite: AVAudioSession.CategoryOptions = [.duckOthers, .interruptSpokenAudioAndMixWithOthers]
        try? session.setCategory(.playback, mode: .spokenAudio, options: polite)
        try? session.setActive(true)
        #endif
    }

    static func end() {
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
    }
}
