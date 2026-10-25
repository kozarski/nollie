import PhotosUI
import SwiftUI
import UniformTypeIdentifiers
import NollieCore

/// Takes what a person picks, pastes or drops and stages it on the chat.
@MainActor
struct ChatIntake {
    var chat: ChatSession

    func photos(_ picks: [PhotosPickerItem]) async {
        for photo in await Intake.load(picks) {
            chat.stageAttachment(data: photo.data, name: photo.name, kind: photo.kind)
        }
    }

    func file(_ url: URL, kind: AttachmentPreview.Kind? = nil) {
        switch Intake.read(url) {
        case .refused(let why):
            chat.banner = why
        case .read(let data, let name, let type):
            chat.stageAttachment(data: data, name: name, kind: kind ?? Intake.kind(of: type))
        }
    }

    /// Pasted pictures and documents, from the edit menu or Paste from Screenshots on the keyboard,
    /// are staged the same way a picked file is.
    func pasted(_ data: Data, name: String, type: UTType) {
        withAnimation(.snappy) { chat.stageAttachment(data: data, name: name, kind: Intake.kind(of: type)) }
    }
}

/// Drag files onto the composer (out of Finder, or from another iPad app) and they are staged as
/// if chosen in a picker. On the Mac, the Import from iPhone or iPad menu item also lands here,
/// standing in for the Camera row with a photo or scan taken on the phone.
struct DropAndImport: ViewModifier {
    var chat: ChatSession
    var importFile: (URL) -> Void

    func body(content: Content) -> some View {
        let receiving = content.dropDestination(for: URL.self) { urls, _ in
            urls.forEach(importFile)
            return !urls.isEmpty
        }
        #if os(macOS)
        receiving.importsItemProviders([.image, .pdf], onImport: stage)
        #else
        receiving
        #endif
    }

    #if os(macOS)
    /// Photos and scans imported from a nearby iPhone or iPad. A PDF means a scan.
    private func stage(_ providers: [NSItemProvider]) -> Bool {
        providers.forEach(load)
        return !providers.isEmpty
    }

    private func load(_ provider: NSItemProvider) {
        let isScan = provider.hasItemConformingToTypeIdentifier(UTType.pdf.identifier)
        let format: UTType = isScan ? .pdf : .image
        let fallback = isScan ? "Scan.pdf" : "Photo.jpg"
        let suffix = isScan ? ".pdf" : ".jpg"
        _ = provider.loadDataRepresentation(forTypeIdentifier: format.identifier) { bytes, _ in
            guard let bytes else { return }
            let name = provider.suggestedName.map { $0 + suffix } ?? fallback
            Task { @MainActor in
                chat.stageAttachment(data: bytes, name: name, kind: isScan ? .pdf : .image)
            }
        }
    }
    #endif
}

/// Reactions to the chat coming and going: say why the mic did nothing, warm the camera check,
/// focus the box for a new Mac chat, and answer Ask Nollie.
struct ComposerLifecycle: ViewModifier {
    var chat: ChatSession
    var dictationError: String?
    var clearDictationError: () -> Void
    var takeFocus: () -> Void
    var focusNow: () -> Void

    func body(content: Content) -> some View {
        content
            // If the mic is not allowed or no recognizer exists, say so in the banner rather than staying quiet.
            .onChange(of: dictationError) { _, message in
                guard let message else { return }
                chat.banner = message
                clearDictationError()
            }
            .modifier(FirstAppearance(chat: chat, focusNow: focusNow))
            .onAppear(perform: takeFocus)
            .onChange(of: AppModel.shared.composerFocusRequestedAt) { takeFocus() }
            .onChange(of: chat.storedID) { takeFocus() }
            .onChange(of: chat.title) { takeFocus() }
    }
}

private struct FirstAppearance: ViewModifier {
    var chat: ChatSession
    var focusNow: () -> Void

    func body(content: Content) -> some View {
        #if os(iOS)
        content.task {
            try? await Task.sleep(for: .seconds(1))
            _ = AttachSources.cameraAvailable
        }
        #else
        // On the Mac a brand-new chat puts the cursor in the field right away, as a send does.
        content.onAppear { if chat.items.isEmpty { focusNow() } }
        #endif
    }
}
