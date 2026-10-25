#if os(macOS)
import Darwin
import Foundation

/// The Mac's log files, in `~/Library/Logs/Nollie` where Console shows them under Log Reports:
/// `Nollie.log` from the app and `Nollie Runtime.log` from the runtime helper. Each notice-or-above
/// entry from `NollieLog` is added; see `LogFileWriter` for the size limit and permissions.
public enum NollieLogFiles {
    public enum Role: Sendable {
        case app, runtimeHelper

        var fileName: String {
            let demo = Bundle.main.bundleIdentifier?.hasSuffix(".demo") == true
            switch self {
            case .app: return demo ? "Nollie Demo" : "Nollie"
            case .runtimeHelper: return "Nollie Runtime"
            }
        }
    }

    /// `~/Library/Logs/Nollie`. In the App Store edition, the same place inside its container.
    public static var directory: URL {
        let library = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true).appendingPathComponent("Library", isDirectory: true)
        return library.appendingPathComponent("Logs", isDirectory: true).appendingPathComponent("Nollie", isDirectory: true)
    }

    /// Whether the files carry private details in full. Only in a Debug build.
    public static let includesPrivateDetail: Bool = {
        #if DEBUG
        true
        #else
        false
        #endif
    }()

    private static let started = NSLock()
    nonisolated(unsafe) private static var writer: LogFileWriter?
    nonisolated(unsafe) private static var timer: DispatchSourceTimer?

    /// Starts the files for this process. Call once, early. Safe to call again.
    public static func start(_ role: Role) {
        started.lock(); defer { started.unlock() }
        guard writer == nil else { return }
        let writer = LogFileWriter(directory: directory, name: role.fileName)
        self.writer = writer
        let detail = includesPrivateDetail
        NollieLog.setSink { entry in writer.append(entry, includeDetail: detail) }
        writer.append(line: "info app: \(startLine(role))")
        if role == .runtimeHelper { keepHermesLinked() }
    }

    static func startLine(_ role: Role) -> String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        let system = ProcessInfo.processInfo.operatingSystemVersionString
        return "\(role.fileName) \(version) (\(build)) started, macOS \(system), pid \(getpid())"
    }

    /// Waits for what has been handed over so far to reach the disk.
    public static func flush() {
        started.lock(); let current = writer; started.unlock()
        current?.flush()
    }

    private static func keepHermesLinked() {
        let setups = NolliePaths.current.setups
        let folder = directory
        let queue = DispatchQueue(label: "com.coreykozarski.nollie.hermeslink", qos: .utility)
        let timer = DispatchSource.makeTimerSource(queue: queue)
        // Now, then every two minutes: a setup can be prepared or replaced while the helper runs.
        timer.schedule(deadline: .now(), repeating: .seconds(120), leeway: .seconds(10))
        timer.setEventHandler { HermesLogLink.refresh(setups: setups, in: folder) }
        timer.resume()
        self.timer = timer
    }
}
#endif
