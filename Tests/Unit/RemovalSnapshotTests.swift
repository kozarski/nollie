#if os(macOS)
import AppKit
import SwiftUI
import Testing
@testable import Nollie
@testable import NollieCore

/// Pictures of Remove Nollie on the Mac, light and dark, drawn in real AppKit windows from a made-up
/// Mac (nothing on this one is read or touched) and a pretend run. Attached to the results, and
/// written to `NOLLIE_SHOTS` (or the temporary folder's `nollie-removal-shots`).
@MainActor
@Suite(.serialized) struct RemovalSnapshotTests {
    private func demoRunner() -> RemovalRunner {
        let places = RemovalPlan.demoPlaces
        return RemovalRunner(plan: RemovalPlan.demo(places, options: .init()), places: places, services: PretendRemovalServices(), pretend: true)
    }

    @Test func theSheetBeforeDuringAndAfter() async throws {
        try attach(RemoveNollieSheet(preview: true), named: "remove-review")
        let working = demoRunner()
        working.showPartWay(3)
        try attach(RemoveNollieSheet(preview: true, previewRunner: working), named: "remove-working")
        let finished = demoRunner()
        await finished.run()
        try attach(RemoveNollieSheet(preview: true, previewRunner: finished), named: "remove-finished")
    }

    @Test func welcomeBack() throws {
        try attach(LeftoverSetupSheet(leftover: .init(installationID: UUID(), note: nil)), named: "remove-welcome-back")
    }

    private static let snapshotDefaults: UserDefaults = {
        let d = UserDefaults(suiteName: "nollie.removal-snapshots")!
        d.set(false, forKey: GlassAppearance.enabledKey)
        return d
    }()

    private func attach(_ view: some View, named name: String, wait: TimeInterval = 1.5) throws {
        let folder = ProcessInfo.processInfo.environment["NOLLIE_SHOTS"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("nollie-removal-shots")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            let host = NSHostingView(rootView: view
                .background(appearance == .aqua ? Color.white : Color(white: 0.12))
                .environment(\.colorScheme, appearance == .aqua ? .light : .dark)
                .defaultAppStorage(Self.snapshotDefaults)
                .environment(AppModel.shared))
            let window = NSWindow(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: appearance)
            window.isReleasedWhenClosed = false
            window.contentView = host
            defer { window.orderOut(nil); window.close() }
            let size = host.fittingSize
            try #require(size.width > 100 && size.height > 30, "\(name) has no size")
            window.setContentSize(size)
            host.frame.size = size
            window.setFrameOrigin(NSPoint(x: 40, y: 40))
            window.orderFrontRegardless()
            host.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(wait))
            host.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let data = try #require(bitmap.representation(using: .png, properties: [:]))
            let file = "\(name)-\(appearance == .aqua ? "light" : "dark").png"
            Attachment.record(data, named: file)
            try data.write(to: folder.appendingPathComponent(file))
        }
    }
}
#endif
