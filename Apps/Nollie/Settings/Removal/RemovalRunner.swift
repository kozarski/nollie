import Foundation
import Observation
import NollieCore

/// What the runner asks of the system, so tests can stand in for every outside effect.
/// Each returns nil when done, or a plain sentence saying what couldn't be done.
@MainActor
protocol RemovalServices {
    func stopRuntime() async -> String?
    func unregisterRuntime() async -> String?
    func unregisterNotifications() async -> String?
    func releaseComputers(_ hermes: RemovalHermes) async -> String?
    func stopPushService() async -> String?
    func trash(_ url: URL) -> String?
    func forgetKeychain(_ service: String) -> String?
    func clearSettings()
    func deleteCloudData() async -> String?
}

/// Runs a plan one line at a time and reports each in plain words. Every file step is checked with
/// `RemovalPlan.permits` again right before it runs; a refused step is reported and skipped.
@MainActor @Observable
final class RemovalRunner {
    enum State: Equatable { case waiting, working, done, trouble(String) }
    struct Line: Identifiable, Equatable {
        let part: RemovalPart
        var state: State = .waiting
        var id: RemovalPart.Kind { part.kind }
    }
    enum Phase: Equatable { case reviewing, working, finished }

    private(set) var phase: Phase = .reviewing
    private(set) var lines: [Line]
    let plan: RemovalPlan
    let places: RemovalPlaces
    @ObservationIgnored private let services: RemovalServices
    @ObservationIgnored private let fileManager: FileManager
    /// The demo copy: every line goes through its motions and nothing on disk is touched.
    let pretend: Bool
    /// Pictures: the pretend run stops on this line, so a part-way picture can be taken.
    @ObservationIgnored var pretendHold: Int?

    init(plan: RemovalPlan, places: RemovalPlaces, services: RemovalServices, pretend: Bool = false, fileManager: FileManager = .default) {
        self.plan = plan
        self.places = places
        self.services = services
        self.pretend = pretend
        self.fileManager = fileManager
        lines = plan.parts.map { Line(part: $0) }
    }

    #if DEBUG
    /// Pictures: the first lines done, the next one working, the rest waiting.
    func showPartWay(_ done: Int) {
        phase = .working
        for index in lines.indices { lines[index].state = index < done ? .done : index == done ? .working : .waiting }
    }
    #endif

    var troubles: [String] { lines.compactMap { if case .trouble(let text) = $0.state { text } else { nil } } }
    var movedAppToTheTrash: Bool { lines.contains { $0.part.kind == .app && $0.state == .done } }

    func run() async {
        guard phase == .reviewing else { return }
        phase = .working
        for index in lines.indices {
            lines[index].state = .working
            if pretend, index == pretendHold { try? await Task.sleep(for: .seconds(3600)) }
            var trouble: String?
            for step in lines[index].part.steps {
                if let problem = await perform(step), trouble == nil { trouble = problem }
            }
            lines[index].state = trouble.map { .trouble($0) } ?? .done
        }
        phase = .finished
    }

    private func perform(_ step: RemovalStep) async -> String? {
        if pretend {
            try? await Task.sleep(for: .milliseconds(180))
            return nil
        }
        if let url = step.url, !RemovalPlan.permits(step, in: places) {
            return String(localized: "Nollie left \(url.lastPathComponent) alone, because it isn't Nollie's to remove.",
                          comment: "Safety: Remove Nollie, a step it refused; the placeholder is a file or folder name; keep exact meaning")
        }
        switch step {
        case .stopRuntime: return await services.stopRuntime()
        case .unregisterRuntime: return await services.unregisterRuntime()
        case .unregisterNotifications: return await services.unregisterNotifications()
        case .releaseComputers(let hermes): return await services.releaseComputers(hermes)
        case .stopPushService(let plist):
            if let problem = await services.stopPushService() { return problem }
            return delete(plist)
        case .trash(let url): return services.trash(url)
        case .tidyConfig(let url): return tidy(url)
        case .delete(let url): return delete(url)
        case .deleteIfEmpty(let url):
            try? fileManager.removeItem(at: url.appendingPathComponent(".DS_Store"))
            _ = rmdir(url.path)
            return nil
        case .forgetKeychain(let service): return services.forgetKeychain(service)
        case .clearSettings: services.clearSettings(); return nil
        case .deleteCloudData: return await services.deleteCloudData()
        case .trashApp(let url): return services.trash(url)
        }
    }

    private func delete(_ url: URL) -> String? {
        guard Disk.exists(url) else { return nil }
        // removeItem deletes links inside as links; it never follows them.
        do { try fileManager.removeItem(at: url); return nil } catch {
            return String(localized: "Couldn't delete \(url.lastPathComponent). You can delete it in Finder.",
                          comment: "Safety: Remove Nollie, what stayed; the placeholder is a file or folder name; keep exact meaning")
        }
    }

    /// A dated copy first, then the new text written beside the file and moved over it.
    private func tidy(_ config: URL) -> String? {
        guard let data = Disk.readSmallFile(config, maximum: 1_000_000), let text = String(data: data, encoding: .utf8) else {
            return String(localized: "Couldn't read your Hermes settings, so they still list Nollie's add-ons.",
                          comment: "Safety: Remove Nollie, what stayed; keep exact meaning")
        }
        guard let updated = HermesPluginList.removing(RemovalPlan.addOnNames, from: text) else { return nil }
        let stamp = Self.stamp.string(from: Date())
        let folder = config.deletingLastPathComponent()
        let backup = folder.appendingPathComponent("config.yaml.bak-nollie-removal-" + stamp)
        let temporary = folder.appendingPathComponent(".config.yaml.nollie-" + UUID().uuidString)
        let mode = ((try? fileManager.attributesOfItem(atPath: config.path))?[.posixPermissions] as? NSNumber)?.intValue ?? 0o600
        guard fileManager.createFile(atPath: backup.path, contents: data, attributes: [.posixPermissions: 0o600]),
              fileManager.createFile(atPath: temporary.path, contents: Data(updated.utf8), attributes: [.posixPermissions: mode]) else {
            try? fileManager.removeItem(at: temporary)
            return String(localized: "Couldn't update your Hermes settings, so they still list Nollie's add-ons.",
                          comment: "Safety: Remove Nollie, what stayed; keep exact meaning")
        }
        guard rename(temporary.path, config.path) == 0 else {
            try? fileManager.removeItem(at: temporary)
            return String(localized: "Couldn't update your Hermes settings, so they still list Nollie's add-ons.",
                          comment: "Safety: Remove Nollie, what stayed; keep exact meaning")
        }
        return nil
    }

    private static let stamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter
    }()
}

/// The demo copy and pictures: nothing outside happens.
struct PretendRemovalServices: RemovalServices {
    func stopRuntime() async -> String? { nil }
    func unregisterRuntime() async -> String? { nil }
    func unregisterNotifications() async -> String? { nil }
    func releaseComputers(_ hermes: RemovalHermes) async -> String? { nil }
    func stopPushService() async -> String? { nil }
    func trash(_ url: URL) -> String? { nil }
    func forgetKeychain(_ service: String) -> String? { nil }
    func clearSettings() {}
    func deleteCloudData() async -> String? { nil }
}
