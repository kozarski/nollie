#if os(macOS)
import AppKit
import Foundation
import Observation
import NollieCore

/// The Mac's automatic Cua setup, after the person's one yes. Nollie Runtime downloads, checks
/// and installs Cua; this app only asks it to and shows how far it has got. When the setup
/// service isn't on this Mac, the screen falls back to Cua's own download page.
///
/// Nollie never opens the Cua Spaces app (it would add its own menu bar item) and never makes it
/// a login item. Only Cua's background part runs, started and stopped by Nollie Runtime.
@MainActor @Observable
final class CuaSetup {
    static let shared = CuaSetup()
    static let bundleID = "com.trycua.spaces.macos"
    static let downloadPage = URL(string: "https://cua.ai/download")!

    private(set) var run: HelperComputerSetupRun = .idle
    @ObservationIgnored private var polling: Task<Void, Never>?
    @ObservationIgnored var request: (ManagedRuntimeOperation) async throws -> ManagedRuntimeReply = ManagedRuntimeRequest.send
    @ObservationIgnored var isAvailable = NativeSetupPlan.directAvailable

    var isWorking: Bool { if case .working = run { true } else { false } }

    init() {
        #if DEBUG
        if DemoMode.isOn, let held = Self.demoHeld { run = held }
        #endif
    }

    /// Starts (or rejoins) the setup.
    func start() async {
        #if DEBUG
        if DemoMode.isOn { demo(); return }
        #endif
        guard isAvailable else { run = .unavailable; return }
        do { run = Self.map(try NollieCuaSetupResponse.decode(try await request(.cuaSetupStart).data)) } catch { run = .unavailable; return }
        follow()
    }

    /// Picks up a setup that is already running, for example after the window reopens.
    func refresh() async {
        #if DEBUG
        if DemoMode.isOn { return }
        #endif
        guard isAvailable, !isWorking else { return }
        guard let response = try? NollieCuaSetupResponse.decode(try await request(.cuaSetupStatus).data) else { return }
        let mapped = Self.map(response)
        if case .working = mapped { run = mapped; follow() }
    }

    func reset() { if !isWorking { run = .idle } }

    private func follow() {
        polling?.cancel()
        polling = Task { [weak self] in
            while let self, self.isWorking, !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let reply = try? await self.request(.cuaSetupStatus),
                      let response = try? NollieCuaSetupResponse.decode(reply.data) else { continue }
                self.run = Self.map(response)
            }
        }
    }

    static func map(_ response: NollieCuaSetupResponse) -> HelperComputerSetupRun {
        switch response.phase {
        case .idle: .idle
        case .checking: .working(.checking, fraction: nil)
        case .downloading: .working(.downloading, fraction: response.fraction)
        case .installing: .working(.installing, fraction: nil)
        case .starting: .working(.starting, fraction: nil)
        case .preparing: .working(.preparing, fraction: nil)
        case .done: .done
        case .needsQuit: .needsQuit
        case .failed: .failed(response.failure ?? "Couldn't set up Cua by itself.")
        case .unavailable: .unavailable
        }
    }

    /// Asks Cua Spaces to quit (it asks first if an agent is busy), then updates it.
    func quitCuaThenUpdate() async {
        for app in NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleID) { app.terminate() }
        for _ in 0..<40 where !NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleID).isEmpty {
            try? await Task.sleep(for: .milliseconds(250))
        }
        await start()
    }

    func openDownloadPage() { NSWorkspace.shared.open(Self.downloadPage) }

    #if DEBUG
    /// The demo copy: `-nollie-demo-cua-setup downloading:0.42` holds one step for its picture;
    /// without it, a short pretend run.
    private static var demoHeld: HelperComputerSetupRun? {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "-nollie-demo-cua-setup"), i + 1 < args.count else { return nil }
        let parts = args[i + 1].split(separator: ":")
        guard let first = parts.first, let step = HelperComputerSetupRun.Step(rawValue: String(first)) else { return nil }
        return .working(step, fraction: parts.count > 1 ? Double(parts[1]) : nil)
    }

    private func demo() {
        if let held = Self.demoHeld { run = held; return }
        polling?.cancel()
        polling = Task { [weak self] in
            for fraction in stride(from: 0.0, through: 1.0, by: 0.2) {
                self?.run = .working(.downloading, fraction: fraction)
                try? await Task.sleep(for: .milliseconds(400))
            }
            for step in [HelperComputerSetupRun.Step.checking, .installing, .starting, .preparing] {
                self?.run = .working(step, fraction: nil)
                try? await Task.sleep(for: .milliseconds(500))
            }
            self?.run = .done
        }
    }
    #endif
}
#endif
