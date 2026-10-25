import Foundation
import Testing
import SwiftUI
#if os(macOS)
import AppKit
#endif
import NollieCore
@testable import Nollie

/// What a bot shows in the app and in the notification extensions: its stored choice, else its
/// profile's default look; a photo only when the photo is there.
@Suite struct BotIdentityTests {
    @Test func storedChoicesPickTheLook() {
        let stored = ["career": "look:spike", "nowhere": "look:duo", "forager": "studio:blob:curious:glass", "old": "initial"]
        #expect(BotAvatarStore.choice(for: "career", overrides: stored) == .look(.spike))
        #expect(BotAvatarStore.look(for: "career", overrides: stored) == .spike)
        #expect(BotAvatarStore.look(for: "nowhere", overrides: stored) == .duo)
        // Values the old faces saved, and bots with nothing saved, get their profile's default.
        for profile in ["forager", "old", "unsaved"] {
            #expect(BotAvatarStore.choice(for: profile, overrides: stored) == .look(.defaultLook(forProfile: profile)))
        }
        #expect(BotAvatarStore.look(for: "default", overrides: [:]) == .main)
    }

    @Test func aPhotoChoiceWithoutAPhotoShowsTheLook() {
        // A profile no one has used, so there is no photo file for it on this device.
        let profile = "identity-\(UUID().uuidString)"
        let stored = [profile: CharacterChoice.photo.raw]
        #expect(BotAvatarStore.choice(for: profile, overrides: stored) == .photo)
        #expect(!BotAvatarStore.showsPhoto(profile, overrides: stored))
        #expect(BotAvatarStore.look(for: profile, overrides: stored) == .defaultLook(forProfile: profile))
    }

    @Test func theMirrorGivesTheExtensionsTheSameBot() throws {
        let sent = BotLooks(colors: ["career": "#E07A5F", "Scout": "#E07A5F"],
                            avatars: ["career": "look:kick", "Scout": "look:kick", "nowhere": "photo",
                                      "forager": "photo", "old": "studio:circle:curious"],
                            photos: ["forager": Data([0xFF, 0xD8, 0xFF])])
        // Through the keychain it travels as JSON.
        let looks = try JSONDecoder().decode(BotLooks.self, from: JSONEncoder().encode(sent))

        let career = looks.key(profile: "career", label: "Scout")
        #expect(career == "career")
        #expect(looks.choice(key: career, profile: "career") == .look(.kick))
        // A push that only knows the label finds the bot too, whatever its case.
        let scout = looks.key(profile: "", label: "scout")
        #expect(scout == "Scout")
        #expect(looks.choice(key: scout, profile: "") == .look(.kick))

        #expect(looks.choice(key: "forager", profile: "forager") == .photo)
        // Photo chosen but none mirrored: the look instead.
        #expect(looks.choice(key: "nowhere", profile: "nowhere") == .look(.defaultLook(forProfile: "nowhere")))
        #expect(looks.choice(key: "old", profile: "old") == .look(.defaultLook(forProfile: "old")))
        // A bot the mirror does not know.
        #expect(looks.key(profile: "stranger", label: "Stranger") == nil)
        #expect(looks.choice(key: nil, profile: "stranger") == .look(.defaultLook(forProfile: "stranger")))
        #expect(looks.choice(key: nil, profile: "default") == .look(.main))
    }

    @Test func everyLookHasItsNotificationStill() {
        for id in CharacterLookID.allCases {
            #expect(UIImage(named: CharacterDrawing.avatarName(id)) != nil, "\(id)")
        }
    }

    @MainActor @Test(arguments: [28.0, 44.0])
    func theThreadsStillIsTheRequestedSizeAndDrawn(size: Double) throws {
        let side = CGFloat(size)
        let image = BotAvatarImage.make(profile: "identity-\(UUID().uuidString)", size: side)
        #expect(image.size == CGSize(width: side, height: side))
        let (filled, total) = try coverage(image)
        // The character fills a good part of its square; the corners stay clear.
        #expect(filled > total / 8, "\(filled) of \(total)")
        #expect(filled < total)
    }

    /// A busy GPU can return an empty picture; the thread falls back to the still rather than keep it.
    @MainActor @Test func anEmptyPictureIsNotTakenForACharacter() throws {
        let frame = CGRect(x: 0, y: 0, width: 28, height: 28)
        let empty = UIGraphicsImageRenderer(size: frame.size).image { _ in }
        #expect(!BotAvatarImage.hasInk(empty))
        let still = try #require(UIImage(named: CharacterDrawing.avatarName(.main)))
        #expect(BotAvatarImage.hasInk(UIGraphicsImageRenderer(size: frame.size).image { _ in still.draw(in: frame) }))
    }

    /// The stand-in is the notification still in a circle, so it never shows as a square tile.
    @MainActor @Test func theStandInIsRound() throws {
        let image = BotAvatarImage.standIn(profile: "identity-\(UUID().uuidString)", size: 28)
        let (filled, total) = try coverage(image)
        #expect(filled > total / 2, "\(filled) of \(total)")
        #expect(filled < total * 9 / 10, "\(filled) of \(total)")
    }

    /// Pixels with any ink, out of all of them.
    private func coverage(_ image: UIImage) throws -> (Int, Int) {
        #if os(macOS)
        let cg = try #require(image.cgImage(forProposedRect: nil, context: nil, hints: nil))
        #else
        let cg = try #require(image.cgImage)
        #endif
        let width = cg.width, height = cg.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        try pixels.withUnsafeMutableBytes { buffer in
            let context = try #require(CGContext(data: buffer.baseAddress, width: width, height: height,
                                                bitsPerComponent: 8, bytesPerRow: width * 4,
                                                space: CGColorSpaceCreateDeviceRGB(),
                                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        let filled = stride(from: 3, to: pixels.count, by: 4).filter { pixels[$0] > 16 }.count
        return (filled, width * height)
    }
}
