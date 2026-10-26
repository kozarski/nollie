import AVFoundation
import Speech
import SwiftUI
import NollieCore

/// Drives dictation in the composer. The mic records and the field draws a waveform; on stop, speech
/// recognition on this device reads the recording. The audio file is always removed afterwards.
@MainActor
@Observable
final class DictationController {
    static let waveformSamples = 64
    /// Anything shorter than this is a stray tap, not speech.
    private static let shortestWorthKeeping: TimeInterval = 0.4

    var startedAt: Date?
    /// The most recent loudness readings, newest last, drawn as the waveform.
    var levels = [Float]()
    var error: String?
    /// After stopping and before the words arrive; the composer shows a spinner where the mic was.
    var isTranscribing = false
    var isListening = false
    var transcript = ""

    private var capture: MicCapture?

    func start() {
        // A reply being read aloud would talk over the recording.
        ReplyVoice.shared.stop()
        Task {
            do {
                let stem = "dictation-\(UUID().uuidString)"
                let mic = try await MicCapture.start(stem: stem, dictation: true, sampleRate: 24000)
                // Twenty readings a second keep the waveform smooth.
                mic.watch(every: 0.05) { [weak self] mic in self?.record(mic.loudness) }
                capture = mic
                begin()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    private func begin() {
        transcript = ""
        levels = []
        startedAt = Date()
        isListening = true
    }

    private func record(_ loudness: Float) {
        guard isListening else { return }
        levels = Array((levels + [loudness]).suffix(Self.waveformSamples))
    }

    private func haltRecorder() {
        capture?.stop()
        isListening = false
    }

    /// Ends the recording and returns what was said, or an empty string if nothing was.
    func stop() async -> String {
        haltRecorder()
        guard let file = capture?.file else { return "" }
        capture = nil
        defer { try? FileManager.default.removeItem(at: file) }

        let length = startedAt.map { Date().timeIntervalSince($0) } ?? 0
        guard length > Self.shortestWorthKeeping else { return "" }

        isTranscribing = true
        defer { isTranscribing = false }
        do {
            let heard = try await DeviceTranscriber.transcribe(file: file)
            transcript = heard
            if heard.isEmpty { error = "I didn't catch anything. Try again closer to the mic." }
        } catch let failure {
            transcript = ""
            error = failure.localizedDescription
        }
        return transcript
    }

    /// Throws the recording away without turning it into text, for when the composer goes away.
    func cancel() {
        haltRecorder()
        if let file = capture?.file { try? FileManager.default.removeItem(at: file) }
        capture = nil
    }
}

/// The composer's mic button. Tap once to listen (the field becomes a waveform) and tap the red stop
/// square to finish; the words appear in the field, as with the audio bar in Messages.
struct TalkButton: View {
    var dictation: DictationController
    /// Diameter of the circle.
    var size: CGFloat = 28
    /// Draws the mic on a black circle, as in the mockups, rather than a bare glyph.
    var inked = false
    var onTranscript: (String) -> Void

    var body: some View {
        PlainButton(action: toggle) { face }
            .accessibilityHint(spokenHint)
            .accessibilityLabel(spokenLabel)
    }

    private var spokenLabel: String { dictation.isListening ? "Stop dictating" : "Dictate" }

    private var spokenHint: String {
        if dictation.isListening { return "Stops, then types what you said" }
        return "Records you, then writes it out on this device"
    }

    private func toggle() {
        if !dictation.isListening {
            dictation.start()
            return
        }
        Task {
            let words = await dictation.stop()
            if !words.isEmpty { onTranscript(words) }
        }
    }

    @ViewBuilder private var face: some View {
        if dictation.isListening {
            Circle()
                .fill(.red)
                .overlay { RoundedRectangle(cornerRadius: 2).fill(.white).frame(square: size * 0.36) }
                .frame(square: size)
        } else if inked {
            Glyph("mic", .system(size: size * 0.42, weight: .medium), Ink.onInk)
                .frame(square: size)
                .background(Ink.ink, in: .circle)
        } else {
            Glyph("mic", .body.weight(.medium), .secondary)
                .frame(square: size)
        }
    }
}

/// The waveform shown while dictating: thin red bars that slide left as new readings arrive on the
/// right, and the time listened beside them.
struct DictationWaveform: View {
    let dictation: DictationController

    var body: some View {
        HStack(spacing: 10) {
            bars.frame(height: 22)
            clock
        }
        .accessibilityLabel(Text("Listening"))
    }

    private var clock: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let start = dictation.startedAt ?? context.date
            let total = Int(max(0, context.date.timeIntervalSince(start)))
            Text(String(format: "%d:%02d", total / 60, total % 60))
                .quiet(.subheadline.monospacedDigit())
        }
    }

    /// Readings padded on the left with silence so the newest always sits at the right edge.
    private var padded: [Float] {
        let missing = max(0, DictationController.waveformSamples - dictation.levels.count)
        return Array(repeating: 0, count: missing) + dictation.levels
    }

    private var bars: some View {
        GeometryReader { box in
            let slotWidth = box.size.width / CGFloat(DictationController.waveformSamples)
            let readings = padded
            HStack(alignment: .center, spacing: 0) {
                ForEach(readings.indices, id: \.self) { index in
                    let height = 3 + CGFloat(readings[index]) * (box.size.height - 6)
                    Capsule()
                        .fill(.red)
                        .frame(width: max(1.5, slotWidth * 0.45), height: max(3, height))
                        .frame(width: slotWidth)
                }
            }
            .frame(height: box.size.height)
        }
        .animation(.linear(duration: 0.05), value: dictation.levels.count)
    }
}
