import AVFAudio
import Foundation
import Speech

/// Dictation: a voice recording becomes text on this device, and the audio goes nowhere.
public enum DeviceTranscriber {
    /// The person's language is one the on-device speech model cannot do yet.
    public struct Failure: LocalizedError {
        public let locale: Locale

        public var errorDescription: String? {
            let language = locale.identifier
            return String(localized: "Speech recognition on this device is not available for \(language) yet.", table: "Core", comment: "The value is a language code, such as cy_GB")
        }
    }

    /// Reads a whole recording. The first run for a language fetches Apple's speech model.
    public static func transcribe(file url: URL, locale: Locale = .current) async throws -> String {
        let reader = try await readyReader(for: locale)
        let recording = try AVAudioFile(forReading: url)

        // Phrases stream in while the analyzer works, so listening starts before the audio is fed.
        async let phrases = collectPhrases(from: reader)
        let analyzer = SpeechAnalyzer(modules: [reader])
        _ = try await analyzer.analyzeSequence(from: recording)
        try await analyzer.finalizeAndFinishThroughEndOfInput()

        let spoken = try await phrases.joined(separator: " ")
        return spoken.replacingOccurrences(of: "  ", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A speech reader for the person's language, with its model installed.
    private static func readyReader(for locale: Locale) async throws -> SpeechTranscriber {
        guard let language = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else {
            throw Failure(locale: locale)
        }
        let reader = SpeechTranscriber(locale: language, preset: .transcription)
        if let download = try await AssetInventory.assetInstallationRequest(supporting: [reader]) {
            try await download.downloadAndInstall()
        }
        return reader
    }

    private static func collectPhrases(from reader: SpeechTranscriber) async throws -> [String] {
        var phrases: [String] = []
        for try await result in reader.results { phrases.append(String(result.text.characters)) }
        return phrases
    }
}
