#if os(macOS)
import Darwin
import Foundation

/// The door the Hermes add-on (Companions/nollie-mac) knocks on: a Unix socket in Nollie's own
/// Application Support folder, readable only by this user, one JSON line in and one out.
///
/// - `{"op":"start","session_id","chat","profile","apps":[...],"purpose"}` checks the session with
///   Hermes, asks the person (the card) and, once approved, starts Nollie Computer. The reply
///   carries the task's secret id, and the task answers only to the process that asked: the
///   nollie-mac add-on that Hermes's own gateway or dashboard runs (`ComputerPeer`).
/// - `{"op":"do","task","app","step"}` does one step in one app: the model on this Mac looks and
///   picks each action, Nollie's rules judge each one, and only a short sentence comes back. The
///   add-on, and so the bot's own model, never gets a screenshot or the window's words.
/// - `{"op":"act",...}` (single actions, with pictures) is refused: it would hand the screen out.
/// - `{"op":"end","task"}` ends the task.
///
/// The add-on never reaches the helper itself: Nollie holds its only trusted sessions.
final class ComputerBroker: @unchecked Sendable {
    static let shared = ComputerBroker()

    /// Longest any request is served (a card's two minutes, then starting or acting), and within
    /// the add-on's own wait.
    let requestLimit: TimeInterval

    init(requestLimit: TimeInterval = 270) {
        self.requestLimit = requestLimit
    }

    static var socketURL: URL { ComputerHelper.supportDirectory.appendingPathComponent("control.sock") }

    private var listener: Int32 = -1
    private let lock = NSLock()
    /// Connections being served. More than a few at once is nobody legitimate.
    private var open = 0
    static let maxConnections = 4

    /// Starts listening. Safe to call more than once.
    func start(path: String = ComputerBroker.socketURL.path, center: ComputerCenter? = nil) {
        lock.lock()
        defer { lock.unlock() }
        guard listener < 0 else { return }
        let folder = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        chmod(folder, 0o700)
        unlink(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { close(fd); return }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            for (i, b) in bytes.enumerated() { raw[i] = b }
            raw[bytes.count] = 0
        }
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0, chmod(path, 0o600) == 0, listen(fd, 8) == 0 else { close(fd); return }
        listener = fd
        let thread = Thread { [weak self] in self?.acceptLoop(fd, center: center) }
        thread.name = "Nollie Computer broker"
        thread.start()
    }

    func stop(path: String = ComputerBroker.socketURL.path) {
        lock.lock()
        defer { lock.unlock() }
        guard listener >= 0 else { return }
        shutdown(listener, SHUT_RDWR)
        close(listener)
        listener = -1
        unlink(path)
    }

    private func acceptLoop(_ fd: Int32, center: ComputerCenter?) {
        while true {
            let client = accept(fd, nil, nil)
            if client < 0 {
                if errno == EINTR { continue }
                return
            }
            // Only this user's processes; anything else is closed unread.
            var uid: uid_t = 0, gid: gid_t = 0
            guard getpeereid(client, &uid, &gid) == 0, uid == geteuid() else { close(client); continue }
            var noSigPipe: Int32 = 1
            setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
            // The request line must arrive within 5 seconds (answers may take minutes: no write limit).
            var tv = timeval(tv_sec: 5, tv_usec: 0)
            setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
            let admitted = lock.withLock { () -> Bool in
                guard open < Self.maxConnections else { return false }
                open += 1
                return true
            }
            guard admitted else { close(client); continue }
            Thread.detachNewThread { [weak self] in
                // Which process this is, read from the kernel now: the add-on run by Hermes, or not.
                let peer = ComputerPeer.of(socket: client)
                self?.serve(client, peer: peer, center: center)
                self?.lock.withLock { self?.open -= 1 }
            }
        }
    }

    private func serve(_ client: Int32, peer: ComputerPeer?, center: ComputerCenter?) {
        defer { close(client) }
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 16384)
        while !buffer.contains(0x0A), buffer.count < 1 << 20 {
            let n = read(client, &chunk, chunk.count)
            guard n > 0 else { return }
            buffer.append(chunk, count: n)
        }
        let line = buffer.prefix { $0 != 0x0A }
        let request = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] ?? [:]
        let parsed = Self.parse(request)
        let semaphore = DispatchSemaphore(value: 0)
        let box = ReplyBox()
        Task { @MainActor in
            let target = center ?? .shared
            // New actions stop well before the answer is given up on: a card may still take its two minutes.
            let deadline = Date().addingTimeInterval(max(1, self.requestLimit - target.answerTimeout - 30))
            let answer = await Self.handle(parsed, peer: peer, center: target, deadline: deadline)
            // Too late: nobody is waiting for that task, so it ends at once.
            if !box.set(answer), let task = answer["task"] as? String { target.finish(taskID: task, from: peer) }
            semaphore.signal()
        }
        // Every request ends: one that takes too long gets an answer and frees its place.
        _ = semaphore.wait(timeout: .now() + requestLimit)
        // An action may still go through after its answer was given up on: say so.
        let late: String = switch parsed {
        case let .act(_, act) where act.kind != .look: Self.tooLongMaybeDone
        case .step: Self.tooLongMaybeDone
        default: Self.tooLong
        }
        let reply = box.take() ?? ["ok": false, "error": late]
        guard var data = try? JSONSerialization.data(withJSONObject: reply) else { return }
        data.append(0x0A)
        _ = data.withUnsafeBytes { write(client, $0.baseAddress, data.count) }
    }

    // Answers to the add-on reach the bot's model, so they stay in English.
    static let tooLong = "Nollie took too long to answer, so nothing was done."
    static let tooLongMaybeDone = "Nollie took too long to answer. That action may have been done: look again before going on."

    /// The answer, handed over once: either in time, or never (and then the late one is undone).
    private final class ReplyBox: @unchecked Sendable {
        private let lock = NSLock()
        private var reply: [String: Any]?
        private var closed = false
        /// False when nobody is waiting any more.
        func set(_ value: [String: Any]) -> Bool { lock.withLock { closed ? false : { reply = value; return true }() } }
        func take() -> [String: Any]? { lock.withLock { closed = true; return reply } }
    }

    // MARK: Requests

    enum Request: Sendable, Equatable {
        case start(ComputerStartRequest)
        case act(task: String, ComputerActRequest)
        case step(task: String, app: String, step: String)
        case end(task: String)
        case invalid(String)
    }

    static func parse(_ json: [String: Any]) -> Request {
        func string(_ key: String, max: Int = 300) -> String? {
            (json[key] as? String).map { String($0.prefix(max)) }
        }
        switch json["op"] as? String {
        case "start":
            let apps = (json["apps"] as? [Any] ?? []).compactMap { $0 as? String }.prefix(8).map { String($0.prefix(100)) }
            // The main bot has no profile name in a gateway session: it is "default".
            let profile = string("profile", max: 100).flatMap { $0.isEmpty ? nil : $0 } ?? "default"
            return .start(ComputerStartRequest(sessionID: string("session_id", max: 200) ?? "", profile: profile,
                                               apps: Array(apps), purpose: string("purpose") ?? ""))
        case "act":
            guard let task = string("task", max: 100),
                  let kind = (json["action"] as? String).flatMap(ComputerAction.Kind.init(rawValue:)) else {
                return .invalid("Unknown action.")
            }
            let act = ComputerActRequest(kind: kind, app: string("app", max: 100) ?? "", element: string("element", max: 40),
                                         x: (json["x"] as? NSNumber)?.doubleValue, y: (json["y"] as? NSNumber)?.doubleValue,
                                         text: string("text", max: 5000),
                                         keys: (json["keys"] as? [Any] ?? []).compactMap { $0 as? String }.prefix(5).map { String($0.prefix(20)) },
                                         direction: string("direction", max: 10), amount: (json["amount"] as? NSNumber)?.intValue,
                                         query: string("query", max: 100))
            return .act(task: task, act)
        case "do":
            return .step(task: string("task", max: 100) ?? "", app: string("app", max: 100) ?? "", step: string("step", max: 500) ?? "")
        case "end":
            return .end(task: string("task", max: 100) ?? "")
        default:
            return .invalid("Unknown request.")
        }
    }

    static let oneStepAtATime = "Nollie takes one step at a time with mac_do, so the screen stays on this Mac. Nothing was done."

    /// `peer`: the process that sent it, which a task then answers to alone. `deadline`: when the
    /// last new action of a step may start, so a step ends before its answer is given up on.
    @MainActor static func handle(_ request: Request, peer: ComputerPeer?, center: ComputerCenter,
                                  deadline: Date = .distantFuture) async -> [String: Any] {
        switch request {
        case let .invalid(message):
            return ["ok": false, "error": message]
        case var .start(start):
            start.peer = peer
            switch await center.requestStart(start) {
            case let .success(task):
                return ["ok": true, "task": task.id, "expires_at": task.expiresAt.timeIntervalSince1970,
                        "apps": task.apps.map { ["name": $0.name, "bundle_id": $0.bundleID, "view_only": $0.viewOnly] }]
            case let .failure(refusal):
                return ["ok": false, "error": refusal.message]
            }
        case .act:
            return ["ok": false, "error": oneStepAtATime]
        case let .step(task, app, step):
            switch await center.doStep(taskID: task, app: app, step: step, from: peer, deadline: deadline) {
            case let .success(words):
                // Words only: never a picture, never the window's own text.
                return ["ok": true, "content": [ComputerContent.text(words).json]]
            case let .failure(refusal):
                return ["ok": false, "error": refusal.message]
            }
        case let .end(task):
            center.finish(taskID: task, from: peer)
            return ["ok": true]
        }
    }
}

extension ComputerContent {
    var json: [String: Any] {
        switch self {
        case let .text(text): ["type": "text", "text": text]
        case let .image(data, mime): ["type": "image", "data": data, "mimeType": mime]
        }
    }
}
#endif
