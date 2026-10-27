#if os(macOS) && NOLLIE_DIRECT
import Foundation

/// Nollie Runtime's side of Papertrail's network filter. While Hermes runs and the switch is on, it
/// subscribes to the filter's Mach service and writes each connection the filter saw going around the door
/// into that bot's Papertrail, as kind `direct`. A connection the filter refused never left, so it is only
/// counted. Without the filter installed this does nothing: the subscription simply never answers.
final class RuntimeNetworkFilter: NSObject, NetworkFilterReports, @unchecked Sendable {
    private let book: PapertrailDoorBook
    let state: NetworkFilterPolicy.Switch
    private let lock = NSLock()
    private var connection: NSXPCConnection?
    private var running = false
    private var refusedCount = 0
    private var unplacedCount = 0

    init(book: PapertrailDoorBook, switch state: NetworkFilterPolicy.Switch) {
        self.book = book
        self.state = state
    }

    /// The switch as Nollie on the Mac last wrote it; off when missing or unreadable.
    static func readSwitch(directory: URL) -> NetworkFilterPolicy.Switch {
        let file = directory.appendingPathComponent(NetworkFilterPolicy.Switch.fileName)
        return NetworkFilterPolicy.Switch.read(try? OwnedSetupFiles.read(file, maximum: 4096))
    }

    var refused: Int { lock.lock(); defer { lock.unlock() }; return refusedCount }
    var unplaced: Int { lock.lock(); defer { lock.unlock() }; return unplacedCount }

    func start() {
        lock.lock()
        guard state.on, !running else { lock.unlock(); return }
        running = true
        lock.unlock()
        connect()
    }

    func stop() {
        lock.lock()
        running = false
        let old = connection
        connection = nil
        lock.unlock()
        old?.invalidate()
    }

    private func connect() {
        let made = NSXPCConnection(machServiceName: NetworkFilterPolicy.machService, options: [])
        made.setCodeSigningRequirement(NetworkFilterXPC.filterRequirement)
        made.remoteObjectInterface = NetworkFilterXPC.serviceInterface()
        made.exportedInterface = NetworkFilterXPC.reportsInterface()
        made.exportedObject = self
        made.invalidationHandler = { [weak self] in self?.lost(made) }
        made.interruptionHandler = { [weak self] in self?.subscribe(made) }
        lock.lock()
        guard running else { lock.unlock(); return }
        connection = made
        lock.unlock()
        made.resume()
        subscribe(made)
    }

    private func subscribe(_ made: NSXPCConnection) {
        guard let data = try? JSONEncoder().encode(state) else { return }
        (made.remoteObjectProxyWithErrorHandler { _ in } as? NetworkFilterService)?.subscribe(data) { _ in }
    }

    /// The filter went away (not installed, updated, turned off): try again in a while, while Hermes runs.
    private func lost(_ made: NSXPCConnection) {
        lock.lock()
        let again = running && connection === made
        if again { connection = nil }
        lock.unlock()
        guard again else { return }
        DispatchQueue.global().asyncAfter(deadline: .now() + 30) { [weak self] in self?.connect() }
    }

    func deliver(_ events: Data) {
        guard events.count <= 1 << 20, let batch = try? JSONDecoder().decode([NetworkFilterPolicy.Event].self, from: events) else { return }
        record(batch.prefix(1000))
    }

    func record<S: Sequence>(_ batch: S) where S.Element == NetworkFilterPolicy.Event {
        for event in batch {
            if event.refused {
                lock.lock(); refusedCount += 1; lock.unlock()
                continue
            }
            guard let bot = PapertrailDoorBook.botName(Substring(event.bot)), bot != PapertrailDoorBook.unplaced,
                  (1...65_535).contains(event.port), !event.host.isEmpty, event.host.utf8.count <= 255,
                  event.host.utf8.allSatisfy({ $0 > 32 && $0 < 127 }) else {
                lock.lock(); unplacedCount += 1; lock.unlock()
                continue
            }
            book.record(bot: bot, kind: "direct", host: event.host, port: UInt16(event.port))
        }
    }
}
#endif
