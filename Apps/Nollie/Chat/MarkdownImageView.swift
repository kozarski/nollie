import NollieCore
import SwiftUI

/// An image a reply embeds on its own line. Nothing is fetched until the person taps. A reply can
/// point at any address, and loading it unasked would let injected text send chat details out in
/// the query string, and show the device's address, with no one touching anything. The image can
/// also be a link.
struct MarkdownImageView: View {
    @Environment(\.openURL) private var openURL
    var alt: String
    @State private var asked = false
    var url: String
    /// Becomes true when a load that was asked for has run past `loadTimeout`.
    @State private var timedOut = false
    var link: String?
    @State private var failed = false
    @State private var picture: UIImage?

    /// What the image slot shows. Kept as a plain value so tests need no network.
    enum Display: Equatable {
        case spinner
        case placeholder
        case image
    }

    /// An arrived picture always wins, even a late one. Failing, or stalling past the timeout,
    /// gives the placeholder. Anything else keeps the spinner going.
    static func display(success: Bool, failure: Bool, timedOut: Bool) -> Display {
        guard !success else { return .image }
        return failure || timedOut ? .placeholder : .spinner
    }

    static func placeholderTitle(alt: String) -> String { alt.isEmpty ? "Image unavailable" : alt }

    /// AsyncImage never gives up by itself. After this long a load that is still going shows the
    /// placeholder, and the picture replaces it if it turns up later.
    private static let loadTimeout: Duration = .seconds(15)

    /// Only https images from a named host are loaded. A reply must not get the app to read local
    /// paths, and cleartext http is refused by App Transport Security anyway.
    private var source: (address: URL, host: String)? {
        guard let address = URL(string: url), address.scheme?.lowercased() == "https",
              let host = address.host() else { return nil }
        return (address, host)
    }

    private var linkTarget: URL? {
        guard let link, let target = URL(string: link),
              let scheme = target.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return nil }
        return target
    }

    var body: some View {
        switch (source, asked) {
        case let (source?, true): shown(from: source.address)
        case let (source?, false): askButton(host: source.host)
        case (nil, _): placeholder
        }
    }

    private func askButton(host: String) -> some View {
        let title = alt.isEmpty ? "Load image from \(host)" : "\(alt) (load from \(host))"
        return Button {
            asked = true
        } label: {
            Label(title, systemImage: "photo")
                .spread()
                .font(.footnote)
        }
        .buttonStyle(.bordered)
        .accessibilityHint("Loads the image from \(host)")
    }

    /// Used whenever the image cannot be shown: wrong scheme, failure or timeout.
    private var placeholder: some View {
        Label(Self.placeholderTitle(alt: alt), systemImage: "photo").quiet(.footnote)
    }

    @ViewBuilder private func shown(from address: URL) -> some View {
        let slot = slotContent
            .spread()
            .task(id: address) { await fetch(address) }
            .accessibilityLabel(alt.isEmpty ? "Image" : alt)
        if let linkTarget {
            PlainButton { openURL(linkTarget) } label: { slot }
        } else {
            slot
        }
    }

    @ViewBuilder private var slotContent: some View {
        switch Self.display(success: picture != nil, failure: failed, timedOut: timedOut) {
        case .spinner:
            ProgressView().frame(minHeight: 60).frame(maxWidth: .infinity)
        case .placeholder:
            placeholder
        case .image:
            if let picture {
                Image(uiImage: picture)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    /// Saves to the cache folder, then decodes a smaller copy off the main thread, the way
    /// pictures from the gateway are handled. AsyncImage decoded the full bitmap in the row.
    private func fetch(_ address: URL) async {
        let timer = Task {
            try? await Task.sleep(for: Self.loadTimeout)
            timedOut = true
        }
        defer { timer.cancel() }
        do {
            let (data, _) = try await URLSession.shared.data(from: address)
            let file = Self.cachePath(for: address)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: file)
            if Task.isCancelled { return }
            let decoded = await AttachmentThumbs.imageAsync(at: file, side: 1200)
            picture = decoded
            failed = decoded == nil
        } catch {
            failed = true
        }
    }

    /// The cache file: a hash of the address as the name, with the address's extension if any.
    private static func cachePath(for address: URL) -> URL {
        var hash: UInt64 = 5381
        for byte in address.absoluteString.utf8 { hash = (hash << 5) &+ hash &+ UInt64(byte) }
        let suffix = address.pathExtension.isEmpty ? "" : "." + address.pathExtension
        return NolliePaths.current.webImages.appendingPathComponent("\(hash)\(suffix)")
    }
}
