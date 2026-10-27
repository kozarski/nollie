import PhotosUI
import SwiftUI
import NollieCore
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

/// What stands for each bot: one of the character looks, or a photo the person picked. Choices
/// are kept per profile in UserDefaults under `botAvatars` as "look:<id>" or "photo"; photos are
/// files in the app's BotAvatars folder. A photo stays on this device; a picked look is shared
/// with the person's other devices through the gateway (`BotLookSharing`). A bot with nothing
/// saved shows its profile's default look.
enum BotAvatarStore {
    static let storageKey = "botAvatars"

    /// NSCache is safe across threads; this wrapper tells the compiler so.
    private struct SharedCache: @unchecked Sendable {
        let images = NSCache<NSString, UIImage>()
    }
    private static let shared = SharedCache()
    private static var images: NSCache<NSString, UIImage> { shared.images }

    private static let choices = DefaultsTable(key: storageKey)

    static func stored() -> [String: String] { choices.read() }

    @MainActor static func save(_ table: [String: String]) {
        choices.write(table)
        BotLooksMirror.mirror()
    }

    // MARK: Choices

    /// The bot's saved choice, or its profile's default look.
    static func choice(for profile: String, overrides: [String: String]? = nil) -> CharacterChoice {
        CharacterChoice.resolve(raw: (overrides ?? stored())[profile], profile: profile)
    }

    /// The look to draw for a bot. A photo bot uses this when its photo is missing.
    static func look(for profile: String, overrides: [String: String]? = nil) -> CharacterLookID {
        choice(for: profile, overrides: overrides).look(forProfile: profile)
    }

    /// Whether the bot is set to a photo and that photo exists.
    static func showsPhoto(_ profile: String, overrides: [String: String]? = nil) -> Bool {
        choice(for: profile, overrides: overrides) == .photo && photo(for: profile) != nil
    }

    /// The gap that stands a bot's character on a pill below it: the character's foot gap (each
    /// look's box ends a little above its frame, Spike's the most) plus `overlap`. A photo fills
    /// its frame, so it needs only the overlap.
    static func seat(for profile: String, size: CGFloat, overlap: CGFloat) -> CGFloat {
        showsPhoto(profile) ? overlap : CharacterDrawing.footGap(look(for: profile), size: size) + overlap
    }

    @MainActor static func set(_ choice: CharacterChoice, for profile: String) {
        var table = stored()
        table[profile] = choice.raw
        save(table)
    }

    /// Removes choices saved by the old drawn faces, once, so those bots take their default look
    /// and the extensions only get current choices. Photos are kept.
    @MainActor static func migrate() {
        let (table, changed) = CharacterChoice.migrated(stored())
        if changed { save(table) }
    }

    // MARK: Photos

    private static var photoFolder: URL {
        let folder = NolliePaths.current.botAvatars
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    static func photoURL(for profile: String) -> URL? {
        // Letters and digits stay; everything else becomes an underscore, so the name is a safe file name.
        let safe = profile.map { ($0.isLetter || $0.isNumber) ? String($0) : "_" }.joined()
        return photoFolder.appending(path: safe + ".jpg")
    }

    /// Crops to a 320-point square, writes a JPEG, and forgets any cached copy.
    static func savePhoto(_ data: Data, for profile: String) throws {
        let failure = CocoaError(.fileWriteUnknown)
        guard let destination = photoURL(for: profile), let picture = UIImage(data: data) else { throw failure }

        let side: CGFloat = 320
        let scale = max(side / picture.size.width, side / picture.size.height)
        let scaled = CGSize(width: picture.size.width * scale, height: picture.size.height * scale)
        let centred = CGRect(origin: CGPoint(x: (side - scaled.width) / 2, y: (side - scaled.height) / 2), size: scaled)
        let canvas = UIGraphicsImageRenderer(size: CGSize(width: side, height: side))
        let cropped = canvas.image { _ in picture.draw(in: centred) }

        guard let jpeg = cropped.jpegData(compressionQuality: 0.85) else { throw failure }
        try jpeg.write(to: destination, options: .atomic)
        images.removeObject(forKey: profile as NSString)
    }

    static func photo(for profile: String) -> UIImage? {
        let key = profile as NSString
        if let cached = images.object(forKey: key) { return cached }
        let loaded = photoURL(for: profile)
            .flatMap { try? Data(contentsOf: $0) }
            .flatMap { UIImage(data: $0) }
        if let loaded { images.setObject(loaded, forKey: key) }
        return loaded
    }

    static func removePhoto(for profile: String) {
        photoURL(for: profile).map { try? FileManager.default.removeItem(at: $0) }
        images.removeObject(forKey: profile as NSString)
    }

    /// Removes every bot's photo; part of a full reset.
    static func removeAllPhotos() {
        try? FileManager.default.removeItem(at: NolliePaths.current.botAvatars)
        images.removeAllObjects()
    }
}

/// A grid of looks to pick from, with the option of a photo instead. Used by the new bot sheet
/// and by Bot settings.
struct CharacterLookPicker: View {
    var profile: String
    @Binding var choice: CharacterChoice
    /// Offer "Use a photo". Off when the bot does not exist yet and so has nowhere to keep one.
    var allowsPhoto = true

    @State private var pickedPhoto: PhotosPickerItem?
    @State private var photoProblem: String?

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 8), count: 3)

    var body: some View {
        VStack(spacing: 14) {
            LazyVGrid(columns: columns, spacing: 14) {
                ForEach(CharacterLookID.allCases) { look in cell(for: look) }
            }
            if allowsPhoto { photoRow }
        }
        .padding(.vertical, 6)
        .animation(.snappy, value: choice)
    }

    private func cell(for look: CharacterLookID) -> some View {
        let selected = choice == .look(look)
        return Button {
            choice = .look(look)
        } label: {
            VStack(spacing: 6) {
                CharacterView(look: look, state: selected ? .listening : .idle, size: 64,
                              seed: CharacterLookID.seed(look.rawValue), animated: selected)
                    .frame(width: 76, height: 76)
                    .background(Circle().fill(Ink.text.opacity(selected ? 0.08 : 0)))
                    .overlay(Circle().strokeBorder(Ink.text.opacity(selected ? 0.55 : 0), lineWidth: 1.5))
                Text(look.name).font(.caption).foregroundStyle(selected ? .primary : .secondary)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(look.name)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .testID("bot.look.\(look.rawValue)")
    }

    private var photoRow: some View {
        let hasPhoto = choice == .photo
        return HStack {
            PhotosPicker(selection: $pickedPhoto, matching: .images) {
                Label(hasPhoto ? "Change photo" : "Use a photo", systemImage: "photo").font(.subheadline)
            }
            .foregroundStyle(.tint)
            .buttonStyle(.plain)
            Spacer()
            photoProblem.map { Text($0).small(.caption, .red) }
            if hasPhoto { removeButton }
        }
        .onChange(of: pickedPhoto) { _, item in
            if let item { Task { await take(item) } }
        }
    }

    private var removeButton: some View {
        Button("Remove photo") {
            BotAvatarStore.removePhoto(for: profile)
            choice = .look(.defaultLook(forProfile: profile))
        }
        .buttonStyle(.borderless)
        .font(.subheadline)
    }

    private func take(_ item: PhotosPickerItem) async {
        defer { pickedPhoto = nil }
        do {
            guard let data = try await item.loadTransferable(type: Data.self) else { return }
            try BotAvatarStore.savePhoto(data, for: profile)
            photoProblem = nil
            choice = .photo
        } catch {
            photoProblem = "That photo didn't load."
        }
    }
}
