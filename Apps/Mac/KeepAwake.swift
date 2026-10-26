import AppKit
import IOKit.ps
import IOKit.pwr_mgt
import NollieCore

/// "Keep Mac awake for my crew". While it is on and `KeepAwakePolicy` says so, Nollie holds one power assertion
/// that stops idle sleep, named so `pmset -g assertions` and Activity Monitor show it is Nollie's and why. It
/// never changes the Mac's own energy settings: the screen still sleeps, a closed lid still sleeps, and letting
/// the assertion go (or quitting Nollie) gives the Mac back its usual sleep at once.
@MainActor @Observable
final class MacKeepAwake {
    static let shared = MacKeepAwake()
    static let key = "nollie.keepAwake"
    /// How often the facts are read again; the schedules themselves less often.
    static let tick: Duration = .seconds(30)
    static let schedulesEvery: TimeInterval = 5 * 60

    var isOn: Bool {
        didSet {
            guard isOn != oldValue else { return }
            if !DemoMode.isOn { UserDefaults.standard.set(isOn, forKey: Self.key) }
            schedulesReadAt = nil
            Task { await refresh() }
        }
    }
    private(set) var decision: KeepAwakePolicy.Decision = .sleep(.off)
    /// The Mac has a battery, so it is a laptop whose lid sleeps it whatever Nollie holds.
    private(set) var hasBattery = false

    private let hold = PowerAssertion()
    private var due: [Date] = []
    private var scheduleRunning = false
    private var schedulesReadAt: Date?
    private var loop: Task<Void, Never>?
    private var heard: NSObjectProtocol?

    private init() {
        isOn = DemoMode.isOn ? ProcessInfo.processInfo.arguments.contains("-nollie-demo-keep-awake")
            : UserDefaults.standard.bool(forKey: Self.key)
    }

    func start() {
        guard loop == nil else { return }
        heard = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil,
                                                                  queue: .main) { _ in
            MainActor.assumeIsolated {
                MacKeepAwake.shared.schedulesReadAt = nil
                Task { await MacKeepAwake.shared.refresh() }
            }
        }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: Self.tick)
            }
        }
    }

    /// Reads the facts, decides, and holds or lets go.
    func refresh(now: Date = Date()) async {
        let power = Self.power()
        hasBattery = power.hasBattery
        let runtime = AppModel.shared.runtime
        let here = runtime.map { Self.isOnThisMac($0.connection) } ?? false
        if isOn, here, let runtime { await readSchedules(runtime, now: now) }
        // For pictures: `-nollie-demo-keep-awake-due` puts a schedule at two tonight.
        let shown = DemoMode.isOn && ProcessInfo.processInfo.arguments.contains("-nollie-demo-keep-awake-due")
            ? [Calendar.current.date(bySettingHour: 2, minute: 0, second: 0, of: now.addingTimeInterval(86_400)) ?? now] : due
        let facts = KeepAwakePolicy.Facts(
            on: isOn, assistantHere: here, working: here && (Self.helpersWorking(runtime, now: now) || scheduleRunning),
            due: here ? shown : [], power: power.source, lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled,
            now: now)
        decision = KeepAwakePolicy.decide(facts)
        // A demo copy never holds the Mac awake: it only shows what it would do.
        guard !DemoMode.isOn else { return }
        if case .awake(let reason) = decision {
            hold.hold(named: KeepAwakePolicy.assertionName(reason))
        } else {
            hold.release()
        }
    }

    // MARK: Facts

    /// The assistant runs here: one Nollie set up on this Mac, or a gateway at a loopback address.
    static func isOnThisMac(_ connection: GatewayConnection) -> Bool {
        if connection.managedInstallationID != nil { return true }
        let host = connection.gateway.host.lowercased()
        return host == "localhost" || host == "::1" || host == "[::1]" || host.hasPrefix("127.")
    }

    /// A chat's turn, or a Board helper, is working now.
    private static func helpersWorking(_ runtime: GatewayRuntime?, now: Date) -> Bool {
        if TurnBoard.shared.running > 0 { return true }
        guard let activity = runtime?.kanban.activity else { return false }
        return !activity.activeProfiles.isEmpty && now.timeIntervalSince(activity.checkedAt) < 120
    }

    /// Every bot's schedules: when each is next due, and whether one runs now.
    private func readSchedules(_ runtime: GatewayRuntime, now: Date) async {
        if let read = schedulesReadAt, now.timeIntervalSince(read) < Self.schedulesEvery { return }
        schedulesReadAt = now
        guard let reply: JSONValue = try? await runtime.api.get("/api/cron/jobs") else { return }
        let entries = reply["jobs"]?.arrayValue ?? reply.arrayValue ?? []
        scheduleRunning = entries.contains(where: CronRun.isRunning)
        due = entries.compactMap { entry -> Date? in
            guard let job = ScheduledWork.decode(entry), !ScheduledWork.paused(job), !ScheduledWork.completed(job) else { return nil }
            return job.nextRunAt.flatMap(CronSchedule.onceDate)
        }
    }

    /// Plugged in or on battery, with the charge left, from the Mac's power sources.
    static func power() -> (source: KeepAwakePolicy.Power, hasBattery: Bool) {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else { return (.pluggedIn, false) }
        let providing = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() as String?
        let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] ?? []
        var charge: Double?
        var battery = false
        for source in sources {
            guard let details = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  details[kIOPSTypeKey] as? String == kIOPSInternalBatteryType else { continue }
            battery = true
            if let now = details[kIOPSCurrentCapacityKey] as? Double, let most = details[kIOPSMaxCapacityKey] as? Double, most > 0 {
                charge = now / most
            } else if let now = details[kIOPSCurrentCapacityKey] as? Int, let most = details[kIOPSMaxCapacityKey] as? Int, most > 0 {
                charge = Double(now) / Double(most)
            }
        }
        let onBattery = providing == kIOPMBatteryPowerKey
        return (onBattery ? .battery(charge) : .pluggedIn, battery)
    }
}

/// One `PreventUserIdleSystemSleep` assertion, held under a name or let go. The display may still sleep.
final class PowerAssertion {
    private var id: IOPMAssertionID = 0
    private(set) var name: String?

    var isHeld: Bool { name != nil }

    func hold(named name: String) {
        guard name != self.name else { return }
        var fresh: IOPMAssertionID = 0
        let made = IOPMAssertionCreateWithName(kIOPMAssertPreventUserIdleSystemSleep as CFString,
                                               IOPMAssertionLevel(kIOPMAssertionLevelOn), name as CFString, &fresh)
        guard made == kIOReturnSuccess else { return }
        // The new one first, so the Mac is never left without it in between.
        release()
        (id, self.name) = (fresh, name)
    }

    func release() {
        guard name != nil else { return }
        IOPMAssertionRelease(id)
        (id, name) = (0, nil)
    }

    deinit { release() }
}
