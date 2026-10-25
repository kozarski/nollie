import SwiftUI
import NollieCore

/// The dark circle ending the composer capsule. It is the mic with an empty field, send when there
/// is text or files to send, and stop during a turn.
struct ComposerEndButton: View {
    var chat: ChatSession
    var text: String
    var dictation: DictationController
    var onSend: () async -> Void
    var onDictated: (String) -> Void

    private var side: CGFloat { Ink.composerButton }
    private var hasFiles: Bool { !chat.staged.isEmpty }
    private var blank: Bool { text.trimmingCharacters(in: .whitespaces).isEmpty && !hasFiles }

    private enum Face { case listening, transcribing, stop, mic, send }

    private var face: Face {
        if dictation.isListening { return .listening }
        if dictation.isTranscribing { return .transcribing }
        if chat.isRunning && text.isEmpty { return .stop }
        return text.isEmpty && !hasFiles ? .mic : .send
    }

    var body: some View {
        switch face {
        case .listening, .mic:
            TalkButton(dictation: dictation, size: side, inked: true, onTranscript: onDictated)
        case .transcribing:
            ProgressView().controlSize(.small).frame(square: side).accessibilityLabel("Transcribing")
        case .stop:
            stopButton
        case .send:
            sendButton
        }
    }

    private var stopButton: some View {
        PlainButton {
            guard !AppModel.shared.awayBlocks() else { return }
            Task { await chat.stop() }
        } label: {
            RoundedRectangle(cornerRadius: 3).fill(Ink.onInk)
                .frame(square: side * 0.3)
                .frame(square: side)
                .background(Ink.ink, in: .circle)
        }
        .help("Stop (⌘.)")
        .accessibilityLabel("Stop")
        .accessibilityIdentifier("composer.stop")
    }

    private var sendButton: some View {
        PlainButton {
            Task { await onSend() }
        } label: {
            Glyph("arrow.up", .system(size: side * 0.42, weight: .bold), Ink.onInk)
                .frame(square: side)
                .background(Ink.ink.opacity(blank ? 0.3 : 1), in: .circle)
        }
        .disabled(blank)
        .accessibilityLabel(chat.isRunning ? "Queue message" : "Send")
        .accessibilityIdentifier("composer.send")
    }
}
