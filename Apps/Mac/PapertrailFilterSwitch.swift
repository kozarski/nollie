#if os(macOS) && NOLLIE_DIRECT
import Darwin
import Foundation
import NetworkExtension
import NollieCore
import Observation
@preconcurrency import SystemExtensions
import SwiftUI

/// Papertrail's network filter, from the Mac app: asks macOS to install the filter, turns it on, and tells
/// Nollie Runtime through `RuntimeService/network-filter.json`, which it rereads while Hermes runs. On means
/// Refuse too: anything Hermes starts that tries to go around Nollie's door is stopped, so Papertrail sees
/// everything that leaves. macOS asks the person twice (the extension, then the filter); Nollie never answers
/// for them, it only waits and says where to look.
@MainActor @Observable
final class PapertrailFilterModel: NSObject {
    enum State: Equatable {
        /// This build doesn't carry the filter (the developer portal step is still pending).
        case unavailable
        case off
        /// macOS is waiting for the person to allow the extension in System Settings.
        case waiting
        /// The extension is in; macOS is asking whether Nollie may filter network content.
        case asking
        case on
        case failed(String)
    }

    static let extensionID = "com.coreykozarski.nollie.network-filter"
    static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension")!

    private(set) var state: State = .off
    private var request: OSSystemExtensionRequest?

    /// Whether this copy of Nollie carries the extension at all.
    static var embedded: Bool {
        let path = Bundle.main.bundleURL.appendingPathComponent("Contents/Library/SystemExtensions/\(extensionID).systemextension").path
        return FileManager.default.fileExists(atPath: path)
    }

    func refresh() async {
        // For pictures: `-nollie-demo-filter on|waiting|asking` shows that state in the demo copy, which never
        // asks macOS for anything.
        if DemoMode.isOn {
            let arguments = ProcessInfo.processInfo.arguments
            let shown = arguments.firstIndex(of: "-nollie-demo-filter").flatMap { $0 + 1 < arguments.count ? arguments[$0 + 1] : nil }
            state = ["on": State.on, "waiting": .waiting, "asking": .asking][shown ?? ""] ?? .unavailable
            return
        }
        guard Self.embedded else { state = .unavailable; return }
        guard state != .waiting, state != .asking else { return }
        let manager = NEFilterManager.shared()
        try? await manager.loadFromPreferences()
        state = manager.isEnabled && Self.readSwitch() ? .on : .off
    }

    func set(_ on: Bool) {
        guard state != .unavailable, !DemoMode.isOn else { return }
        if on { turnOn() } else { Task { await turnOff() } }
    }

    private func turnOn() {
        state = .waiting
        let made = OSSystemExtensionRequest.activationRequest(forExtensionWithIdentifier: Self.extensionID, queue: .main)
        made.delegate = self
        request = made
        OSSystemExtensionManager.shared.submitRequest(made)
    }

    /// The extension is in: turn the filter on. macOS asks the person whether to allow it.
    private func enableFilter() async {
        state = .asking
        let manager = NEFilterManager.shared()
        do {
            try await manager.loadFromPreferences()
            let configuration = NEFilterProviderConfiguration()
            configuration.filterSockets = true
            configuration.filterPackets = false
            manager.providerConfiguration = configuration
            manager.localizedDescription = "Nollie Papertrail"
            manager.isEnabled = true
            try await manager.saveToPreferences()
            try Self.writeSwitch(on: true)
            state = .on
        } catch {
            // The person said no, or macOS couldn't save it: nothing is half on.
            try? Self.writeSwitch(on: false)
            state = (error as NSError).domain == NEFilterErrorDomain ? .off : .failed(String(localized: "Couldn't turn it on. Try again."))
        }
    }

    private func turnOff() async {
        try? Self.writeSwitch(on: false)
        let manager = NEFilterManager.shared()
        try? await manager.loadFromPreferences()
        if manager.isEnabled {
            manager.isEnabled = false
            try? await manager.saveToPreferences()
        }
        state = .off
    }

    // MARK: The switch file Nollie Runtime reads

    private static var switchURL: URL {
        NolliePaths.current.runtimeService.appendingPathComponent("network-filter.json")
    }

    static func readSwitch() -> Bool {
        guard let data = try? OwnedSetupFiles.read(switchURL, maximum: 4096),
              let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        return value["version"] as? Int == 1 && value["on"] as? Bool == true
    }

    /// On always means Refuse as well (Corey, 27 Oct): "exactly" holds while it is on.
    static func switchData(on: Bool) -> Data {
        Data(#"{"version": 1, "on": \#(on), "refuse": \#(on)}"#.utf8)
    }

    static func writeSwitch(on: Bool) throws {
        let directory = NolliePaths.current.runtimeService
        try OwnedSetupFiles.createPrivateDirectory(directory)
        let staged = directory.appendingPathComponent("network-filter.json.new")
        _ = unlink(staged.path)
        try OwnedSetupFiles.writeNew(switchData(on: on), to: staged)
        guard rename(staged.path, switchURL.path) == 0 else { throw CocoaError(.fileWriteUnknown) }
    }
}

extension PapertrailFilterModel: OSSystemExtensionRequestDelegate {
    nonisolated func request(_ request: OSSystemExtensionRequest,
                             actionForReplacingExtension existing: OSSystemExtensionProperties,
                             withExtension ext: OSSystemExtensionProperties) -> OSSystemExtensionRequest.ReplacementAction {
        .replace
    }

    nonisolated func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) {
        Task { @MainActor in self.state = .waiting }
    }

    nonisolated func request(_ request: OSSystemExtensionRequest, didFinishWithResult result: OSSystemExtensionRequest.Result) {
        Task { @MainActor in
            if result == .completed { await self.enableFilter() } else { self.state = .waiting }
        }
    }

    nonisolated func request(_ request: OSSystemExtensionRequest, didFailWithError error: Error) {
        Task { @MainActor in self.state = .failed(String(localized: "macOS didn't install it. Try again.")) }
    }
}

/// The one switch on Settings › What left your Mac, and a few words when it can't be on yet.
struct PapertrailFilterToggle: View {
    @State private var model = PapertrailFilterModel()
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(spacing: 10) {
            GlassSwitch("Stop what Papertrail can't see", isOn: Binding(get: { model.state == .on }, set: { model.set($0) }),
                        id: "papertrail.filter.switch")
                .disabled(model.state == .unavailable || model.state == .waiting || model.state == .asking)
            if let words = PapertrailFilterWords.line(model.state) {
                Text(words).foregroundStyle(Ink.text2).multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .testID("papertrail.filter.state")
            }
            if model.state == .waiting {
                Button("Open System Settings") { openURL(PapertrailFilterModel.settingsURL) }
                    .buttonStyle(.glass)
                    .buttonBorderShape(.capsule)
                    .controlSize(.large)
                    .testID("papertrail.filter.settings")
            }
        }
        .task { await model.refresh() }
    }
}

enum PapertrailFilterWords {
    @MainActor static func line(_ state: PapertrailFilterModel.State) -> String? {
        switch state {
        case .unavailable: String(localized: "Not in this version of Nollie yet.")
        case .off: nil
        case .waiting: String(localized: "Allow Nollie Papertrail in System Settings › Login Items & Extensions.")
        case .asking: String(localized: "Choose Allow when your Mac asks about filtering.")
        case .on: String(localized: "Anything a helper starts that tries to go around Papertrail is stopped.",
                         comment: "Safety: Papertrail; what the network filter stops")
        case .failed(let words): words
        }
    }
}
#endif
