import SwiftUI
import NollieCore

/// A bot's picture: its character in the state it is in, or the photo the person picked. When a
/// turn has just ended the character hops once, and a tap makes it perk up.
struct BotAvatar: View {
    var profile: String
    var size: CGFloat = 28
    var state: CharacterState = .idle
    /// Draws this choice rather than the saved one (for previews in pickers).
    var override: CharacterChoice? = nil
    /// False shows only the still pose (a stack of small faces, a long thread).
    var animated = true
    /// Show the person's photo when they picked one. Off for pictures that get shared.
    var photos = true

    @AppStorage(BotAvatarStore.storageKey) private var savedChoices = ""
    @State private var hopping = false
    @State private var perkedUp = false

    private var choice: CharacterChoice {
        if let override { return override }
        return CharacterChoice.resolve(raw: DefaultsTable.decode(savedChoices)[profile], profile: profile)
    }

    /// An idle bot hops after a finished turn and listens after a tap; any other state wins.
    private var pose: CharacterState {
        switch (state, hopping, perkedUp) {
        case (.idle, true, _): .done
        case (.idle, false, true): .listening
        default: state
        }
    }

    var body: some View {
        picture
            .frame(width: size, height: size)
            .reaction(to: BotAmbient.shared.finished[profile], hold: CharacterCatalog.shared.state(.done).oneShot ?? 1.6, flag: $hopping)
            .reaction(to: BotAmbient.shared.tapped[profile], hold: 1.2, flag: $perkedUp)
            .accessibilityHidden(true)
    }

    @ViewBuilder private var picture: some View {
        if photos, choice == .photo, let image = BotAvatarStore.photo(for: profile) {
            Image(uiImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: size, height: size)
                .clipShape(.circle)
        } else {
            CharacterView(
                look: choice.look(forProfile: profile), state: pose, size: size,
                seed: CharacterLookID.seed(profile), animated: animated)
        }
    }
}

private extension View {
    /// Raises `flag` for `hold` seconds when `moment` changes to something under a second old.
    func reaction(to moment: Date?, hold: Double, flag: Binding<Bool>) -> some View {
        task(id: moment) {
            guard let moment, -moment.timeIntervalSinceNow < 1 else { return }
            flag.wrappedValue = true
            try? await Task.sleep(for: .seconds(hold))
            flag.wrappedValue = false
        }
    }
}

/// Copies colours, avatar picks and photo thumbnails for each bot into the shared keychain
/// (`BotLooks`), because that is the one store the notification extensions can open.
@MainActor
enum BotLooksMirror {
    static func mirror() {
        let profiles = AppModel.shared.runtime?.profiles ?? []
        var avatars = BotAvatarStore.stored()
        var colors = BotColors.stored()

        // Every profile known to the gateway is written with its resolved choice, whether or not one was
        // saved, so extensions render the identical character.
        for name in Set(avatars.keys).union(profiles.map(\.name)) {
            avatars[name] = BotAvatarStore.choice(for: name, overrides: avatars).raw
            colors[name] = colors[name] ?? BotColors.hex(for: name)
        }

        var photos = avatars.filter { $0.value == "photo" }.keys.reduce(into: [String: Data]()) { out, name in
            out[name] = BotAvatarStore.photo(for: name).flatMap(thumbnail)
        }

        // A push names a bot by profile name, but a companion that knows only the label must find
        // it too, so each look is also kept under the label.
        for profile in profiles where !profile.label.isEmpty && profile.label != profile.name {
            avatars[profile.label] = avatars[profile.name]
            colors[profile.label] = colors[profile.name]
            photos[profile.label] = photos[profile.name]
        }
        BotLooks(colors: colors, avatars: avatars, photos: photos).save()
    }

    /// A JPEG whose longest side is at most 128 points.
    private static func thumbnail(_ image: UIImage) -> Data? {
        let factor = 128 / max(image.size.width, image.size.height)
        let scaled = image.size.applying(CGAffineTransform(scaleX: factor, y: factor))
        let target = CGSize(width: max(1, scaled.width), height: max(1, scaled.height))
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let drawn = UIGraphicsImageRenderer(size: target, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
        return drawn.jpegData(compressionQuality: 0.75)
    }
}
