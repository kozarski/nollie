import NollieCore
import SwiftUI
import AVKit
#if os(iOS)
import Photos
#else
import AppKit
#endif

/// The videos a reply or tool hands back, such as the `recording.mp4` of a Cua Driver session.
/// Each gets a card in the thread like a screenshot does: first frame and length once the file
/// is here, and it plays in place. The Mac fetches a file when its card shows up. The phone waits
/// for a tap, because recordings can be big.
struct VideoCardStrip: View {
    var refs: [MediaRef]
    var profile: String?
    var alignment: HorizontalAlignment = .leading

    var body: some View {
        VStack(alignment: alignment, spacing: 8) {
            ForEach(refs.prefix(6)) { VideoCard(ref: $0) }
        }
        .spread(alignment == .trailing ? .trailing : .leading)
    }
}

/// Everything about one video: its file, first frame, length, and the player once it starts.
@MainActor @Observable
final class VideoFetch {
    let ref: MediaRef
    /// The file on this device under its own name, used by Share, Save and the player.
    private(set) var local: URL?
    private(set) var poster: UIImage?
    private(set) var seconds: Double?
    private(set) var fetching = false
    var failed = false
    private(set) var player: AVPlayer?

    private static let fetchesOnSight: Bool = {
        #if os(macOS)
        true
        #else
        false
        #endif
    }()

    init(ref: MediaRef) { self.ref = ref }

    /// Cua Driver calls every recording `recording.mp4`, so the card gives it a better name.
    var title: String {
        let stem = (ref.name as NSString).deletingPathExtension.lowercased()
        let isScreen = stem == "recording" || stem.hasPrefix("screen")
        return isScreen ? "Screen recording" : ref.name
    }

    /// A file that is already here gets its frame and length now. Otherwise the Mac fetches it.
    func prepare(runtime: GatewayRuntime?) async {
        guard let runtime else { return }
        if let cached = await MediaStore.shared.cached(ref, gateway: runtime.connection.id.uuidString) {
            await adopt(cached)
        } else if Self.fetchesOnSight {
            await fetch(runtime: runtime)
        }
    }

    /// Streams from the gateway's files route into the media cache. A recording is too large to
    /// come back inside JSON like a picture does.
    func fetch(runtime: GatewayRuntime?) async {
        if fetching { return }
        guard let runtime else {
            failed = true
            return
        }
        fetching = true
        failed = false
        defer { fetching = false }
        let api = runtime.api
        do {
            let cached = try await MediaStore.shared.localFile(for: ref, gateway: runtime.connection.id.uuidString) { path in
                try await api.download("/api/files/download", query: [URLQueryItem(name: "path", value: path)])
            }
            await adopt(cached)
        } catch {
            failed = true
        }
    }

    private func adopt(_ cached: URL) async {
        let named = FileCard.named(cached, as: ref.name)
        local = named
        let asset = AVURLAsset(url: named)
        if let duration = try? await asset.load(.duration), duration.isNumeric, duration.seconds > 0 {
            seconds = duration.seconds
        }
        poster = await Self.firstFrame(of: asset)
    }

    private static func firstFrame(of asset: AVURLAsset) async -> UIImage? {
        let maker = AVAssetImageGenerator(asset: asset)
        maker.appliesPreferredTrackTransform = true
        maker.maximumSize = CGSize(width: 1280, height: 1280)
        guard let result = try? await maker.image(at: CMTime(seconds: 0.4, preferredTimescale: 600)) else { return nil }
        return UIImage(cgImage: result.image)
    }

    func play(runtime: GatewayRuntime?) async {
        if local == nil { await fetch(runtime: runtime) }
        guard let local else { return }
        let started = AVPlayer(url: local)
        player = started
        started.play()
    }

    func pause() { player?.pause() }

    /// Reads like "0:42", "3:05" or "1:02:03".
    static func length(_ seconds: Double) -> String {
        let whole = Int(seconds.rounded())
        let (h, m, s) = (whole / 3600, (whole / 60) % 60, whole % 60)
        return h > 0 ? "\(h):" + String(format: "%02d:%02d", m, s) : String(format: "%d:%02d", m, s)
    }
}

struct VideoCard: View {
    var ref: MediaRef
    var maxWidth: CGFloat = 360
    @Environment(AppModel.self) private var model
    @State private var video: VideoFetch
    #if os(iOS)
    @State private var savedToPhotos = false
    #endif

    init(ref: MediaRef, maxWidth: CGFloat = 360) {
        self.ref = ref
        self.maxWidth = maxWidth
        _video = State(initialValue: VideoFetch(ref: ref))
    }

    private var spokenName: String {
        guard let seconds = video.seconds else { return video.title }
        return "\(video.title), \(VideoFetch.length(seconds))"
    }

    var body: some View {
        let outline = RoundedRectangle(cornerRadius: 14, style: .continuous)
        Color.clear
            .aspectRatio(16.0 / 9.0, contentMode: .fit)
            .overlay { stage }
            .frame(maxWidth: maxWidth)
            .clipShape(outline)
            .overlay(outline.strokeBorder(.primary.opacity(0.08), lineWidth: 0.5))
            .contextMenu { menu }
            .task(id: ref.id) { await video.prepare(runtime: model.runtime) }
            .onDisappear { video.pause() }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(spokenName)
            .accessibilityHint(video.player == nil ? "Plays it" : "")
            .accessibilityIdentifier("video.card")
    }

    @ViewBuilder private var stage: some View {
        if let player = video.player {
            VideoPlayer(player: player)
        } else {
            PlainButton { Task { await video.play(runtime: model.runtime) } } label: {
                ZStack {
                    backdrop
                    playMark
                    footer
                }
                .contentShape(.rect)
            }
        }
    }

    @ViewBuilder private var backdrop: some View {
        if let poster = video.poster {
            Image(uiImage: poster).resizable().scaledToFill()
        } else {
            LinearGradient(colors: [.primary.opacity(0.12), .primary.opacity(0.05)], startPoint: .top, endPoint: .bottom)
        }
    }

    private var playMark: some View {
        ZStack {
            if video.fetching {
                ProgressView()
            } else if video.failed {
                Image(systemName: "exclamationmark.triangle").font(.system(size: 19, weight: .semibold))
            } else {
                Image(systemName: "play.fill").font(.system(size: 19, weight: .semibold)).offset(x: 1.5)
            }
        }
        .frame(square: 50)
        .nollieGlass(.regular.interactive(), in: .circle)
    }

    /// Name and length along the bottom edge, over a fade to black.
    private var footer: some View {
        let label = video.failed ? "Couldn't load \(video.title.lowercased())" : video.title
        return VStack(spacing: 0) {
            Spacer(minLength: 0)
            HStack(spacing: 6) {
                Image(systemName: "record.circle")
                    .font(.caption2.weight(.bold))
                Text(label)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if let seconds = video.seconds {
                    Text(VideoFetch.length(seconds)).monospacedDigit()
                }
            }
            .quiet(.caption.weight(.medium), .white)
            .padding(EdgeInsets(top: 14, leading: 10, bottom: 7, trailing: 10))
            .background(LinearGradient(colors: [.black.opacity(0), .black.opacity(0.6)], startPoint: .top, endPoint: .bottom))
        }
    }

    @ViewBuilder private var menu: some View {
        if let local = video.local {
            ShareLink(item: local, preview: SharePreview(video.title)) { Label("Share", systemImage: "square.and.arrow.up") }
            #if os(macOS)
            Button { saveToDownloads(local) } label: { Label("Save to Downloads", systemImage: "square.and.arrow.down") }
            Button { NSWorkspace.shared.open(local) } label: { Label("Open in QuickTime Player", systemImage: "play.rectangle") }
            #else
            Button { Task { await saveToPhotos(local) } } label: {
                Label(savedToPhotos ? "Saved to Photos" : "Save to Photos", systemImage: "photo.on.rectangle")
            }
            .disabled(savedToPhotos)
            #endif
        } else {
            Button { Task { await video.fetch(runtime: model.runtime) } } label: { Label("Download", systemImage: "arrow.down.circle") }
        }
    }

    #if os(macOS)
    private func saveToDownloads(_ url: URL) {
        let name = ref.name
        do {
            let saved = try MediaSave.toDownloads(url, name: name)
            MediaSave.showInFinder(saved)
        } catch {
            MediaSave.explainFailure(name: name, error: error)
        }
    }
    #else
    private func saveToPhotos(_ url: URL) async {
        do {
            try await Self.addToLibrary(url)
            savedToPhotos = true
        } catch {
            video.failed = true
        }
    }

    /// Nonisolated since Photos invokes the change block from its own queue, just as in
    /// ImageViewerSheet.
    nonisolated private static func addToLibrary(_ url: URL) async throws {
        try await PHPhotoLibrary.shared().performChanges {
            _ = PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
        }
    }
    #endif
}
