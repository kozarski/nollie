import AVFoundation
import NollieCore
import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

#if os(iOS)
/// Takes a photo with the system camera. The Mac gets pictures from a nearby iPhone through
/// Continuity Camera instead.
struct CameraPicker: UIViewControllerRepresentable {
    @Environment(\.dismiss) private var dismiss
    let onImage: (Data, String) -> Void

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ picker: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(owner: self) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let owner: CameraPicker

        init(owner: CameraPicker) { self.owner = owner }

        func imagePickerController(_ picker: UIImagePickerController,
                                   didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            defer { owner.dismiss() }
            guard let shot = info[.originalImage] as? UIImage,
                  let jpeg = shot.jpegData(compressionQuality: 0.9) else { return }
            owner.onImage(jpeg, "camera-\(Intake.stamp()).jpg")
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { owner.dismiss() }
    }
}
#endif

/// Sets the phone's audio session up for recording and puts it back. Does nothing on the Mac.
enum RecordingSession {
    static func begin(dictation: Bool) throws {
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        if dictation {
            // Dictation only listens, and lowers other audio while it does.
            let quietly: AVAudioSession.CategoryOptions = .duckOthers
            try session.setCategory(.record, mode: .measurement, options: quietly)
            let courteous: AVAudioSession.SetActiveOptions = .notifyOthersOnDeactivation
            try session.setActive(true, options: courteous)
        } else {
            try session.setCategory(.playAndRecord, mode: .default, options: .defaultToSpeaker)
            try session.setActive(true)
        }
        #endif
    }

    static func end() {
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
    }

    /// Single-channel AAC, written as an .m4a file.
    static func settings(sampleRate: Int) -> [String: Any] {
        [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVNumberOfChannelsKey: 1,
            AVSampleRateKey: sampleRate,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
        ]
    }
}

/// One recording in progress: the recorder, its temporary file, and a timer that polls it.
/// Dictation and the voice memo sheet share it.
@MainActor
final class MicCapture {
    struct Refused: LocalizedError {
        var errorDescription: String? { "Nollie can't use the microphone. You can allow it in Settings." }
    }

    struct WouldNotStart: LocalizedError {
        var errorDescription: String? { "Recording didn't start. Please try again." }
    }

    let file: URL
    private let recorder: AVAudioRecorder
    private var poller: Timer?

    private init(file: URL, recorder: AVAudioRecorder) {
        self.file = file
        self.recorder = recorder
    }

    /// Asks for the microphone and starts recording to `<stem>.m4a` in the temporary folder.
    /// Throws if permission is refused or the recorder cannot begin.
    static func start(stem: String, dictation: Bool, sampleRate: Int) async throws -> MicCapture {
        guard await AVAudioApplication.requestRecordPermission() else { throw Refused() }
        try RecordingSession.begin(dictation: dictation)
        let target = FileManager.default.temporaryDirectory.appendingPathComponent("\(stem).m4a")
        let recorder = try AVAudioRecorder(url: target, settings: RecordingSession.settings(sampleRate: sampleRate))
        recorder.isMeteringEnabled = dictation
        guard recorder.record() else { throw WouldNotStart() }
        return MicCapture(file: target, recorder: recorder)
    }

    /// Seconds recorded so far.
    var elapsed: TimeInterval { recorder.currentTime }

    /// Current level from 0 (quiet) to 1, taken from the average power over a 50 dB range.
    var loudness: Float {
        recorder.updateMeters()
        let decibels = recorder.averagePower(forChannel: 0)
        return Float.minimum(1, Float.maximum(0, (decibels + 50) / 50))
    }

    /// Runs `tick` on the main actor every `interval` seconds until `stop()`.
    func watch(every interval: TimeInterval, _ tick: @escaping @MainActor (MicCapture) -> Void) {
        poller = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                tick(self)
            }
        }
    }

    func stop() {
        poller?.invalidate()
        poller = nil
        recorder.stop()
        RecordingSession.end()
    }
}

/// Records a voice memo and hands the finished file over when the person chooses Attach.
struct AudioRecorderSheet: View {
    @State private var problem: String?
    @State private var elapsed: TimeInterval = 0
    @State private var memo: URL?
    @State private var capture: MicCapture?
    @Environment(\.dismiss) private var dismiss
    var onFinished: (URL) -> Void

    private var recording: Bool { capture != nil }

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                meter
                if let problem { Text(problem).quiet(.footnote, .red) }
                controls
            }
            .navigationTitle("Record Audio")
            .padding()
            .toolbar { cancelItem }
        }
        .presentationDetents([.medium])
    }

    @ToolbarContentBuilder private var cancelItem: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button("Cancel", action: abandon)
        }
    }

    private func abandon() {
        stopRecording()
        dismiss()
    }

    private var clock: String {
        Duration.seconds(elapsed).formatted(.time(pattern: .minuteSecond))
    }

    private var meter: some View {
        VStack(spacing: 24) {
            Image(systemName: recording ? "waveform.circle.fill" : "waveform.circle")
                .symbolEffect(.variableColor.iterative, isActive: recording)
                .foregroundStyle(recording ? Color.red : Color.secondary)
                .font(.system(size: 72, weight: .regular))
            Text(clock).font(Font.largeTitle.monospacedDigit())
        }
    }

    private var controls: some View {
        HStack(spacing: 16) {
            Button(recording ? "Stop" : "Record") {
                if recording { stopRecording() } else { startRecording() }
            }
            .buttonStyle(.nollieGlassProminent)
            .tint(recording ? .red : .accentColor)
            if let memo, !recording {
                Button("Attach") {
                    onFinished(memo)
                    dismiss()
                }
                .buttonStyle(.nollieGlass)
            }
        }
    }

    private func startRecording() {
        Task {
            do {
                let started = try await MicCapture.start(stem: "memo-\(Intake.stamp())", dictation: false, sampleRate: 44100)
                started.watch(every: 0.5) { elapsed = $0.elapsed }
                capture = started
                memo = started.file
                elapsed = 0
            } catch {
                problem = error.localizedDescription
            }
        }
    }

    private func stopRecording() {
        capture?.stop()
        capture = nil
    }
}
