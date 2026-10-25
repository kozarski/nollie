import Foundation
import Testing
import SwiftUI
import ImageIO
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
import ScreenCaptureKit
#endif
import NollieCore
@testable import Nollie

@Suite struct CharacterTests {
    let catalog = CharacterCatalog.shared

    @Test func thePackageHasEveryLookAndState() {
        #expect(catalog.manifest.format == "nollie-characters")
        #expect(catalog.manifest.defaultLook == CharacterLookID.main.rawValue)
        #expect(Set(catalog.manifest.looks.map(\.id)) == Set(CharacterLookID.allCases.map(\.rawValue)))
        for state in CharacterState.allCases { #expect(catalog.manifest.states[state.rawValue] != nil, "\(state)") }
        for id in CharacterLookID.allCases {
            let look = catalog.look(id)
            #expect(look.id == id.rawValue)
            #expect(look.face.eyes.count == 2)
            #expect(catalog.face.eyes[look.eyes] != nil)
            #expect(catalog.face.brows[look.brows] != nil)
            #expect(catalog.face.mouths[look.mouth] != nil)
            for anchor in ["corner", "thought", "side"] { #expect(look.badgeAnchors[anchor]?.count == 2) }
        }
        // Mouth names keep their underscores (a snake-case decoder would have renamed them).
        #expect(catalog.face.mouths["v_m"] != nil)
        #expect(catalog.manifest.states["needs_you"]?.badge?.kind == "alert")
    }

    @Test func everyStateResolvesToShapesTheCatalogueHas() {
        for id in CharacterLookID.allCases {
            for state in CharacterState.allCases {
                for t in stride(from: 0.0, through: 6.0, by: 0.37) {
                    let pose = CharacterMotion.pose(look: id, state: state, time: 100 + t, stateTime: t, seed: 7)
                    #expect(catalog.face.eyes[pose.eyes] != nil, "\(id) \(state) eyes \(pose.eyes)")
                    #expect(catalog.face.brows[pose.brows] != nil, "\(id) \(state) brows \(pose.brows)")
                    #expect(catalog.face.mouths[pose.mouth] != nil, "\(id) \(state) mouth \(pose.mouth)")
                    #expect(pose.open > 0 && pose.open <= 1.06)
                }
            }
        }
    }

    @Test func theDefaultProfileIsNollieAndOthersAreStable() {
        #expect(CharacterLookID.defaultLook(forProfile: "default") == .nollie)
        #expect(CharacterLookID.defaultLook(forProfile: "") == .nollie)
        for profile in ["career", "nowhere", "forager", "anything at all"] {
            let look = CharacterLookID.defaultLook(forProfile: profile)
            #expect(look != .nollie)
            #expect(CharacterLookID.defaultLook(forProfile: profile) == look)
            #expect(CharacterLookID.defaultLook(forProfile: profile.uppercased()) == look)
        }
        // Corey's three working bots start out different from each other.
        let three = Set(["career", "nowhere", "forager"].map(CharacterLookID.defaultLook(forProfile:)))
        #expect(three.count == 3)
    }

    @Test func storedChoicesMigrateFromTheOldFaces() {
        #expect(CharacterChoice(raw: "photo") == .photo)
        #expect(CharacterChoice(raw: "look:kick") == .look(.kick))
        for old in ["", "initial", "animated:wave", "studio:nollie:friendly", "studio:drop:curious:glass", "look:nope"] {
            #expect(CharacterChoice(raw: old) == nil, "\(old)")
        }
        #expect(CharacterChoice.resolve(raw: "studio:circle:tall", profile: "default") == .look(.nollie))
        #expect(CharacterChoice.resolve(raw: nil, profile: "career") == .look(.defaultLook(forProfile: "career")))
        #expect(CharacterChoice.photo.look(forProfile: "default") == .nollie)
        let (map, changed) = CharacterChoice.migrated(["a": "studio:pill:wide", "b": "photo", "c": "look:duo", "d": "initial"])
        #expect(changed)
        #expect(map == ["b": "photo", "c": "look:duo"])
        #expect(!CharacterChoice.migrated(map).changed)
    }

    @Test func posesAreFunctionsOfTime() {
        let a = CharacterMotion.pose(look: .kick, state: .working, time: 1234.5, stateTime: 2.2, seed: 3)
        let b = CharacterMotion.pose(look: .kick, state: .working, time: 1234.5, stateTime: 2.2, seed: 3)
        #expect(a == b)
    }

    @Test func reduceMotionHoldsStill() {
        for state in CharacterState.allCases {
            let a = CharacterMotion.pose(look: .nollie, state: state, time: 10, stateTime: 0.2, reduceMotion: true, blinks: false)
            let b = CharacterMotion.pose(look: .nollie, state: state, time: 13.3, stateTime: 1.1, reduceMotion: true, blinks: false)
            if state == .done { continue }
            #expect(a.lift == b.lift && a.tilt == b.tilt && a.scaleX == b.scaleX && a.gazeX == b.gazeX && a.mouth == b.mouth, "\(state)")
        }
        let working = CharacterMotion.still(look: .nollie, state: .working)
        #expect(working.gazeX == 0 && working.gazeY == 0.45)
        #expect(working.mouth == "v_m")
        #expect(working.badgeStatic)
    }

    @Test func doneHopsOnceThenIdles() {
        let early = CharacterMotion.pose(look: .nollie, state: .done, time: 0, stateTime: 0.5, blinks: false)
        #expect(early.eyes == "happy")
        #expect(early.lift > 0.05)
        let after = CharacterMotion.pose(look: .nollie, state: .done, time: 0, stateTime: 2.5, blinks: false)
        #expect(after.eyes == catalog.look(.nollie).eyes)
        #expect(after.badge == nil)
    }

    @Test func needsYouShowsTheAlertAndBigEyes() {
        let pose = CharacterMotion.still(look: .nollie, state: .needsYou)
        #expect(pose.badge?.kind == "alert")
        #expect(pose.eyes == "glint")  // Nollie's side-eye is lidded, so it opens up
        #expect(pose.eyeScale > 1.2)
    }

    @Test func blinksComeEveryFewSeconds() {
        var shut = 0
        var last = -10.0, gaps: [Double] = []
        for i in 0..<6000 {
            let t = Double(i) / 100
            if CharacterMotion.blinkAmount(time: t, seed: 11) > 0.99 {
                shut += 1
                if t - last > 0.5 { gaps.append(t - last); last = t }
            }
        }
        #expect(shut > 0)
        #expect(gaps.dropFirst().allSatisfy { $0 > 1.5 && $0 < 6.5 })
    }

    @Test func tiersFollowTheSize() {
        #expect(CharacterDrawing.bodyName(.nollie, size: 20) == "character-nollie-body-28")
        #expect(CharacterDrawing.bodyName(.nollie, size: 28) == "character-nollie-body-28")
        #expect(CharacterDrawing.bodyName(.nollie, size: 44) == "character-nollie-body-52")
        #expect(CharacterDrawing.bodyName(.nollie, size: 96) == "character-nollie-body-124")
        #expect(CharacterDrawing.bodyName(.nollie, size: 200) == "character-nollie-body-master")
    }

    /// Exercise the sidebar's live-view path, rather than the separate reply-image cache.
    @MainActor @Test(.serialized, arguments: CharacterLookID.allCases, [false, true])
    func sidebarCharactersHaveInkAndClearCorners(look: CharacterLookID, working: Bool) async throws {
        let domain = "nollie.character-tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let profile = "character-test-\(UUID().uuidString)"
        let choices = try JSONEncoder().encode([profile: CharacterChoice.look(look).raw])
        defaults.set(String(decoding: choices, as: UTF8.self), forKey: BotAvatarStore.storageKey)
        defaults.set("still", forKey: CharacterView.styleKey)
        #if os(macOS)
        defaults.set(false, forKey: BotAmbient.animateKey)
        #endif

        for scheme in [ColorScheme.light, .dark] {
            let view = BotPresenceAvatar(profile: profile, size: Ink.rowAvatar, working: working)
                .environment(\.colorScheme, scheme)
                .defaultAppStorage(defaults)
            #if os(macOS)
            let image = try await windowImage(view, scheme: scheme)
            #else
            let renderer = ImageRenderer(content: view)
            renderer.scale = 2
            renderer.isOpaque = false
            let image = try #require(renderer.cgImage)
            #endif
            let pixels = try rgbaPixels(image)
            let total = image.width * image.height
            let inked = stride(from: 3, to: pixels.count, by: 4).filter { pixels[$0] > 16 }.count
            var magenta = 0
            for offset in stride(from: 0, to: pixels.count, by: 4) {
                if pixels[offset] > 240, pixels[offset + 1] < 16,
                   pixels[offset + 2] > 240, pixels[offset + 3] > 240 { magenta += 1 }
            }
            let corners = [0, image.width - 1, (image.height - 1) * image.width, total - 1]
            #expect(inked > total / 8, "\(look) \(scheme) working=\(working): \(inked) of \(total) pixels")
            #expect(inked < total * 9 / 10)
            #expect(corners.allSatisfy { pixels[$0 * 4 + 3] <= 16 })
            #expect(magenta < total / 100, "\(magenta) magenta pixels in \(look) \(scheme) working=\(working)")

            let data = NSMutableData()
            let dest = try #require(CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil))
            CGImageDestinationAddImage(dest, image, nil)
            #expect(CGImageDestinationFinalize(dest))
            Attachment.record(data as Data,
                              named: "sidebar-\(look.rawValue)-\(working ? "working" : "idle")-\(scheme == .dark ? "dark" : "light").png")
        }
    }

    #if os(macOS)
    /// Read the window's displayed surface. Offscreen renderers can redraw a failed Canvas successfully.
    @MainActor private func windowImage(_ view: some View, scheme: ColorScheme) async throws -> CGImage {
        let host = NSHostingView(rootView: view)
        let frame = CGRect(x: 0, y: 0, width: Ink.rowAvatar, height: Ink.rowAvatar)
        let window = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        window.isReleasedWhenClosed = false
        window.isOpaque = false
        window.backgroundColor = .clear
        window.contentView = host
        defer { window.orderOut(nil); window.close() }
        host.frame = frame
        window.orderFrontRegardless()
        host.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        await Task.yield()
        // This API only returns content this process can capture without requesting screen access.
        let content = try await SCShareableContent.currentProcess
        let ownWindow = try #require(content.windows.first {
            $0.windowID == CGWindowID(window.windowNumber)
                && $0.owningApplication?.processID == ProcessInfo.processInfo.processIdentifier
        })
        let filter = SCContentFilter(desktopIndependentWindow: ownWindow)
        let configuration = SCStreamConfiguration()
        configuration.width = Int(frame.width * 2)
        configuration.height = Int(frame.height * 2)
        configuration.showsCursor = false
        configuration.ignoreShadowsSingleWindow = true
        let background = CGColor(gray: 0, alpha: 0)
        defer { withExtendedLifetime(background) {} }
        configuration.backgroundColor = background
        var image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
        // The compositor may expose the new window before its first frame. Wait for any ink,
        // including a failed magenta frame, so a blank capture does not hide the rendering check.
        for _ in 0..<10 {
            let pixels = try rgbaPixels(image)
            if stride(from: 3, to: pixels.count, by: 4).contains(where: { pixels[$0] > 16 }) { return image }
            try await Task.sleep(for: .milliseconds(20))
            image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
        }
        return image
    }
    #endif

    private func rgbaPixels(_ image: CGImage) throws -> [UInt8] {
        var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
        try pixels.withUnsafeMutableBytes { buffer in
            let context = try #require(CGContext(data: buffer.baseAddress, width: image.width, height: image.height,
                                                bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                                space: CGColorSpaceCreateDeviceRGB(),
                                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return pixels
    }

    /// Every look in every state, light and dark, attached to the test run. Proof for the eye,
    /// not an assertion.
    @MainActor @Test func contactSheet() throws {
        for scheme in [ColorScheme.light, .dark] {
            let sheet = VStack(alignment: .leading, spacing: 6) {
                ForEach(CharacterLookID.allCases) { id in
                    HStack(spacing: 6) {
                        ForEach(CharacterState.allCases, id: \.self) { state in
                            CharacterView(look: id, state: state, size: 72, animated: false)
                        }
                        CharacterView(look: id, size: 28, animated: false)
                        CharacterView(look: id, size: 52, animated: false)
                        CharacterView(look: id, size: 160, animated: false)
                        CharacterGlyph(look: id).frame(width: 22, height: 22)
                    }
                }
            }
            .padding(16)
            .background(scheme == .dark ? Color(white: 0.06) : Color(white: 0.98))
            .environment(\.colorScheme, scheme)
            let renderer = ImageRenderer(content: sheet)
            renderer.scale = 2
            let image = try #require(renderer.cgImage)
            let data = NSMutableData()
            let dest = try #require(CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil))
            CGImageDestinationAddImage(dest, image, nil)
            #expect(CGImageDestinationFinalize(dest))
            Attachment.record(data as Data, named: "characters-\(scheme == .dark ? "dark" : "light").png")
        }
    }
}
