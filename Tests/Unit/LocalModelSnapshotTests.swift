import Foundation
import SwiftUI
import ImageIO
import UniformTypeIdentifiers
import Testing
#if os(macOS)
import AppKit
#endif
@testable import Nollie
import NollieCore

@MainActor @Suite
struct LocalModelSnapshotTests {
    @Test func nativeProgressSelectedAndReplyPictures() async throws {
        let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
        let job = try decoder.decode(LocalModelJob.self, from: Data(#"{"job_id":"picture","kind":"quickstart","target":"Small local model","model_id":"small","status":"running","phase":"downloading","total_bytes":3500000000,"done_bytes":1400000000,"started_at":1800000000,"can_pause":true}"#.utf8))
        let connection = GatewayConnection(name: "Picture only", gateway: try .normalize("http://127.0.0.1:9"), authMode: .sessionToken)
        let runtime = GatewayRuntime(connection: connection, store: ConnectionStore())
        let models = try decoder.decode([LocalModelCatalogEntry].self, from: Data(#"[{"id":"small","display_name":"Small local model","recommended":true,"fits":true,"spilled":false,"needs_engine":false,"model_id":"small-q4","size_bytes":3500000000,"start_window":8192},{"id":"other","display_name":"Another local model","fits":true,"spilled":false,"needs_engine":false,"model_id":"other-q4","size_bytes":4200000000,"start_window":8192}]"#.utf8))
        let snapshot = LocalModelSetupSnapshot(hardware: .init(ramTotalBytes: 16000000000), models: models)
        for state in [LocalModelQuickstart.State.idle, .installing, .selected, .ready] {
            let picture: LocalModelQuickstart
            if state == .idle {
                picture = LocalModelQuickstart(api: .init { _, _, _ in throw CancellationError() },
                    scope: .init(installationID: UUID(), connectionID: connection.id, profile: "default"),
                    persistence: .init(load: { nil }, save: { _ in }),
                    inspect: { snapshot }, isCurrent: { false }, checkReply: { _ in throw CancellationError() })
            } else {
                picture = LocalModelQuickstart.picture(state: state, job: job,
                    selectedModel: state == .installing ? nil : "small-q4",
                    reply: state == .ready ? "Hello! What would you like a hand with?" : nil)
            }
            for width: CGFloat in [390, 560] {
                for scheme in [ColorScheme.light, .dark] {
                    let view = VStack(alignment: .leading, spacing: 16) {
                        Text("Local model").font(.title2.weight(.semibold))
                        LocalModelQuickstartSection(runtime: runtime, snapshot: snapshot, picture: picture)
                    }
                    .buttonStyle(.bordered)
                    .padding(24)
                    .frame(width: width, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .background(scheme == .dark ? Color.black : Color.white)
                    .environment(\.colorScheme, scheme)
                    .environment(AppModel.shared)
                    let data = try await capture(view, width: width)
                    Attachment.record(data, named: "local-model-\(state)-\(Int(width))-\(scheme == .dark ? "dark" : "light").png")
                }
            }
            // A fixture cannot dispatch actions even if rendering or input behavior changes.
            picture.install(models[0]); picture.restore(); picture.testReply(); picture.pause(); picture.resume()
            #expect(picture.state == state)
            #expect(!picture.busy)
        }
    }

    private func capture(_ view: some View, width: CGFloat) async throws -> Data {
        #if os(macOS)
        // Native controls need AppKit rendering. ImageRenderer substitutes a warning
        // for the system progress bar instead of capturing its actual appearance.
        let host = NSHostingView(rootView: view)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 700),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.orderOut(nil); window.close() }
        host.frame.size = NSSize(width: width, height: 700)
        host.layoutSubtreeIfNeeded()
        let height = ceil(host.fittingSize.height)
        try #require(height > 100 && height < 1000, "Snapshot has an invalid fitting height")
        window.setContentSize(NSSize(width: width, height: height))
        host.frame.size = NSSize(width: width, height: height)
        await Task.yield()
        host.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        return try #require(bitmap.representation(using: .png, properties: [:]))
        #else
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        let image = try #require(renderer.cgImage)
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        try #require(CGImageDestinationFinalize(destination))
        return data as Data
        #endif
    }
}
