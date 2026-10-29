#if os(iOS)
import Photos
#endif
import SwiftUI
import NollieCore

/// A picture full screen. Pinch or double-tap to zoom, drag it when zoomed, and save or share it.
/// The picture is decoded a single time and never larger than a few thousand pixels across.
struct ImageViewerSheet: View {
    @Environment(\.dismiss) private var dismiss
    var ref: MediaRef
    var profile: String?

    /// Where the load stands: nothing yet, the picture on disk and decoded, or a reason it failed.
    @State private var file: URL?
    @State private var picture: UIImage?
    @State private var loadProblem: String?
    #if os(iOS)
    @State private var photosState = PhotosSave.idle
    @State private var photosFailure: PhotoSaveFailure?
    @Environment(\.openURL) private var openURL
    #else
    @State private var downloadedTo: URL?
    @State private var downloadFailure: String?
    #endif

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                stage
            }
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) { toolbarButtons }
                ToolbarItem(placement: .cancellationAction) { Button("Done", action: { dismiss() }) }
            }
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .navigationTitle(ref.name)
            .preferredColorScheme(.dark)
            .modifier(failureAlert)
        }
        .task { await fetchPicture() }
    }

    // MARK: Showing it

    @ViewBuilder private var stage: some View {
        switch (picture, loadProblem) {
        case let (picture?, _):
            ZoomableImage(picture: picture)
                .accessibilityLabel("Image \(ref.name)")
                #if os(macOS)
                .onDrag { MediaSave.dragProvider(for: ref, profile: profile) }
                #endif
        case let (nil, problem?):
            VStack(spacing: 8) {
                Glyph("photo", .largeTitle, .secondary)
                Text(ref.name).font(.headline)
                Text(problem).quiet(.footnote).multilineTextAlignment(.center)
            }
            .padding()
        case (nil, nil):
            ProgressView().tint(.white)
        }
    }

    private func fetchPicture() async {
        guard let runtime = AppModel.shared.runtime else {
            loadProblem = String(localized: "Connect a gateway first.")
            return
        }
        let source = GatewayMediaAPI(api: runtime.api, profile: profile)
        do {
            let local = try await MediaStore.shared.localURL(for: ref, gateway: runtime.connection.id.uuidString, api: source)
            file = local
            picture = await AttachmentThumbs.imageAsync(at: local, side: 2400)
            if picture == nil { loadProblem = String(localized: "This file is not a picture this device can show.") }
        } catch {
            loadProblem = String(localized: "The gateway could not send this file: \(error.localizedDescription)")
        }
    }

    // MARK: Saving and sharing

    @ViewBuilder private var toolbarButtons: some View {
        if let file {
            saveButton(original: file)
            ShareLink(item: file) { Label("Share", systemImage: "square.and.arrow.up") }
        }
    }

    @ViewBuilder private func saveButton(original: URL) -> some View {
        #if os(iOS)
        // The untouched original goes to Photos. "Saved" appears only after Photos has it.
        if picture != nil {
            Button { saveToPhotos(original) } label: { Label(photosState.title, systemImage: photosState.symbol) }
                .disabled(photosState != .idle)
        }
        #else
        if let downloadedTo {
            Button {
                MediaSave.showInFinder(downloadedTo)
            } label: {
                Label("Saved · Show in Finder", systemImage: "checkmark")
            }
            .accessibilityIdentifier("media.showInFinder")
        } else {
            Button { saveToDownloads(original) } label: { Label("Save to Downloads", systemImage: "square.and.arrow.down") }
                .accessibilityIdentifier("media.save")
        }
        #endif
    }

    /// The alert for a save that failed. A refused permission gets its own wording and, on the
    /// phone, a shortcut to Settings, since iOS only asks once.
    private var failureAlert: some ViewModifier {
        #if os(iOS)
        FailureAlert(title: "Not saved to Photos", failure: $photosFailure) { failure in
            if failure.accessOff {
                Button("Open Settings") {
                    if let settings = URL(string: UIApplication.openSettingsURLString) { openURL(settings) }
                }
            }
        } text: { $0.message }
        #else
        FailureAlert(title: "Not saved to Downloads", failure: $downloadFailure) { _ in } text: { $0 }
        #endif
    }

    #if os(iOS)
    private enum PhotosSave {
        case idle, saving, saved

        var title: String {
            switch self {
            case .idle: String(localized: "Save to Photos")
            case .saving: String(localized: "Saving…")
            case .saved: String(localized: "Saved", comment: "A picture was saved to Photos")
            }
        }
        var symbol: String { self == .saved ? "checkmark" : "square.and.arrow.down" }
    }

    private func saveToPhotos(_ original: URL) {
        photosState = .saving
        Task {
            do {
                try await Self.addToLibrary(original)
                photosState = .saved
            } catch {
                photosFailure = PhotoSaveFailure(error, addOnly: PHPhotoLibrary.authorizationStatus(for: .addOnly))
                photosState = .idle
            }
        }
    }

    /// Nonisolated on purpose. The Photos framework calls this change block on its private queue;
    /// letting it adopt the view's actor made the app stop the first time it was called.
    nonisolated private static func addToLibrary(_ original: URL) async throws {
        try await PHPhotoLibrary.shared().performChanges {
            _ = PHAssetChangeRequest.creationRequestForAssetFromImage(atFileURL: original)
        }
    }
    #else
    private func saveToDownloads(_ original: URL) {
        do {
            downloadedTo = try MediaSave.toDownloads(original, name: ref.name)
        } catch {
            let name = ref.name
            downloadFailure = MediaSave.failureMessage(name: name, error: error)
        }
    }
    #endif
}

/// Shows a picture that zooms by pinch or double tap and pans while zoomed in.
private struct ZoomableImage: View {
    var picture: UIImage
    @State private var zoom = Zoom()

    /// Pinch and pan together: the live values of a gesture and where the last one settled.
    private struct Zoom {
        static let limits: ClosedRange<CGFloat> = 1...6
        var scale: CGFloat = 1
        var settledScale: CGFloat = 1
        var offset = CGSize.zero
        var settledOffset = CGSize.zero

        mutating func pinch(by factor: CGFloat) {
            scale = min(Self.limits.upperBound, max(Self.limits.lowerBound, settledScale * factor))
        }

        mutating func pinchEnded() {
            settledScale = scale
            if scale <= 1 { recenter() }
        }

        mutating func drag(by shift: CGSize) {
            if scale <= 1 { return }
            offset = .init(width: settledOffset.width + shift.width, height: settledOffset.height + shift.height)
        }

        mutating func dragEnded() { settledOffset = offset }

        mutating func toggle() {
            scale = scale > 1 ? 1 : 2.5
            settledScale = scale
            recenter()
        }

        private mutating func recenter() {
            offset = .zero
            settledOffset = .zero
        }
    }

    var body: some View {
        let pinch = MagnifyGesture()
            .onChanged { zoom.pinch(by: $0.magnification) }
            .onEnded { _ in withAnimation(.snappy) { zoom.pinchEnded() } }
        let pan = DragGesture()
            .onChanged { zoom.drag(by: $0.translation) }
            .onEnded { _ in zoom.dragEnded() }
        return Image(uiImage: picture)
            .resizable()
            .scaledToFit()
            .scaleEffect(zoom.scale)
            .offset(zoom.offset)
            .gesture(pinch)
            .simultaneousGesture(pan)
            .onTapGesture(count: 2) { withAnimation(.snappy) { zoom.toggle() } }
    }
}

#if os(iOS)
/// What the viewer tells the person when Save to Photos fails. When the cause is Photos access
/// being off (refused at the prompt, or switched off later) it says so and offers Settings.
struct PhotoSaveFailure: Equatable {
    static let accessOffMessage = String(localized: "Nollie is not allowed to add to Photos. Switch that on in Settings, then try again.")

    var message: String
    /// True when Photos permission is switched off, or the device restricts it.
    var accessOff: Bool

    /// `error` came out of the failed save. `addOnly` is the add-only permission as it stands now,
    /// checked too since a refusal does not always surface as Photos' own access error.
    init(_ error: any Error, addOnly: PHAuthorizationStatus) {
        let code = (error as? PHPhotosError)?.code
        let refusedHere = [PHPhotosError.Code.accessUserDenied, .accessRestricted].contains { $0 == code }
        let refusedOverall = [PHAuthorizationStatus.denied, .restricted].contains(addOnly)
        let off = refusedHere || refusedOverall
        self.init(message: off ? Self.accessOffMessage : String(localized: "Photos could not keep it: \(error.localizedDescription)"), accessOff: off)
    }

    init(message: String, accessOff: Bool) {
        self.accessOff = accessOff
        self.message = message
    }
}
#endif

/// An alert that is up while `failure` holds a value. Clearing the value dismisses it.
private struct FailureAlert<Failure, Extra: View>: ViewModifier {
    var title: LocalizedStringKey
    @Binding var failure: Failure?
    @ViewBuilder var extra: (Failure) -> Extra
    var text: (Failure) -> String

    func body(content: Content) -> some View {
        let showing = Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })
        content.alert(title, isPresented: showing, presenting: failure) { value in
            extra(value)
            Button("OK", role: .cancel) {}
        } message: { Text(text($0)) }
    }
}
