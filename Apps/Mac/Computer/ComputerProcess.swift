#if os(macOS)
import CryptoKit
import Darwin
import Foundation

/// The facts macOS keeps about a running process, read by its pid: where its program is, who
/// started it, when, and with what arguments. Read from the kernel, never from the process.
struct ComputerProcess: Equatable, Sendable {
    var pid: Int32
    var parent: Int32
    /// Seconds and microseconds since 1970: with the pid, names one process even after the pid
    /// is reused.
    var started: Double
    var path: String
    var arguments: [String]

    init(pid: Int32, parent: Int32, started: Double, path: String, arguments: [String]) {
        self.pid = pid
        self.parent = parent
        self.started = started
        self.path = path
        self.arguments = arguments
    }

    /// Nil when the process is gone, isn't this user's, or its program can't be found.
    init?(pid: Int32) {
        guard let info = Self.info(pid), let path = Self.path(of: pid) else { return nil }
        self.init(pid: pid, parent: Int32(info.pbi_ppid),
                  started: Double(info.pbi_start_tvsec) + Double(info.pbi_start_tvusec) / 1_000_000,
                  path: path, arguments: Self.arguments(of: pid))
    }

    static func info(_ pid: Int32) -> proc_bsdinfo? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard pid > 0, proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return info
    }

    static func path(of pid: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(4 * MAXPATHLEN))
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return String(cString: buffer)
    }

    /// The kernel's short name for the process, which stays when its file is deleted.
    static func name(_ info: proc_bsdinfo) -> String {
        withUnsafeBytes(of: info.pbi_name) { raw in
            let name = String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
            return name.isEmpty ? withUnsafeBytes(of: info.pbi_comm) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) } : name
        }
    }

    /// The process's command line (`KERN_PROCARGS2`), without its environment.
    static func arguments(of pid: Int32) -> [String] {
        var mib = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return [] }
        var bytes = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &bytes, &size, nil, 0) == 0 else { return [] }
        let count = bytes.withUnsafeBytes { $0.load(as: Int32.self) }
        var index = MemoryLayout<Int32>.size
        // The executable path, then padding, then argv.
        while index < size, bytes[index] != 0 { index += 1 }
        while index < size, bytes[index] == 0 { index += 1 }
        var arguments: [String] = []
        while arguments.count < Int(count), index < size {
            let start = index
            while index < size, bytes[index] != 0 { index += 1 }
            arguments.append(String(decoding: bytes[start..<index], as: UTF8.self))
            index += 1
        }
        return arguments
    }

    /// Every process's pid.
    static func allPIDs() -> [Int32] {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(count) + 64)
        let filled = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        return pids.prefix(Int(max(0, filled))).filter { $0 > 0 }
    }

    /// The process macOS holds responsible for this one (for its privacy permissions): a launchd
    /// job is responsible for itself, and everything it starts stays its own, wherever it moves.
    static func responsible(for pid: Int32) -> Int32? {
        typealias Lookup = @convention(c) (pid_t) -> pid_t
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_get_pid_responsible_for_pid") else { return nil }
        let found = unsafeBitCast(symbol, to: Lookup.self)(pid)
        return found > 0 ? found : nil
    }

    /// Whether a process is listening on this TCP port, or on a Unix socket at this path.
    static func listens(_ pid: Int32, tcpPort: Int? = nil, unixPath: String? = nil) -> Bool {
        let bytes = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard bytes > 0 else { return false }
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(bytes) / MemoryLayout<proc_fdinfo>.size + 16)
        let filled = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &fds, Int32(fds.count * MemoryLayout<proc_fdinfo>.size))
        guard filled > 0 else { return false }
        for fd in fds.prefix(Int(filled) / MemoryLayout<proc_fdinfo>.size) where fd.proc_fdtype == UInt32(PROX_FDTYPE_SOCKET) {
            var info = socket_fdinfo()
            let size = Int32(MemoryLayout<socket_fdinfo>.size)
            guard proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDSOCKETINFO, &info, size) == size else { continue }
            let kind = info.psi.soi_kind
            if let tcpPort, kind == Int32(SOCKINFO_TCP) {
                let tcp = info.psi.soi_proto.pri_tcp
                if tcp.tcpsi_state == TSI_S_LISTEN, Int(UInt16(bigEndian: UInt16(truncatingIfNeeded: tcp.tcpsi_ini.insi_lport))) == tcpPort {
                    return true
                }
            }
            if let unixPath, kind == Int32(SOCKINFO_UN) {
                var address = info.psi.soi_proto.pri_un.unsi_addr.ua_sun
                let path = withUnsafeBytes(of: &address.sun_path) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
                if path == unixPath, info.psi.soi_options & Int16(SO_ACCEPTCONN) != 0 { return true }
            }
        }
        return false
    }

    /// The pipes a process holds open, by the kernel's handle for each end.
    static func pipes(of pid: Int32) -> (held: Set<UInt64>, peers: [Int32: UInt64]) {
        let bytes = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard bytes > 0 else { return ([], [:]) }
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(bytes) / MemoryLayout<proc_fdinfo>.size + 16)
        let filled = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &fds, Int32(fds.count * MemoryLayout<proc_fdinfo>.size))
        guard filled > 0 else { return ([], [:]) }
        var held: Set<UInt64> = []
        var peers: [Int32: UInt64] = [:]
        for fd in fds.prefix(Int(filled) / MemoryLayout<proc_fdinfo>.size) where fd.proc_fdtype == UInt32(PROX_FDTYPE_PIPE) {
            var pipe = pipe_fdinfo()
            let size = Int32(MemoryLayout<pipe_fdinfo>.size)
            guard proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDPIPEINFO, &pipe, size) == size else { continue }
            held.insert(pipe.pipeinfo.pipe_handle)
            peers[fd.proc_fd] = pipe.pipeinfo.pipe_peerhandle
        }
        return (held, peers)
    }
}

/// The code signature the kernel holds for a running process: which program it is, who signed
/// it, and whether it is still intact. It follows `exec`, reads nothing from disk, and still
/// answers after the program's file is deleted.
struct ComputerSignature: Equatable, Sendable {
    var identifier: String?
    var team: String?
    var valid: Bool

    private typealias Csops = @convention(c) (pid_t, UInt32, UnsafeMutableRawPointer?, Int) -> Int32
    private static let csops: Csops? = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "csops").map { unsafeBitCast($0, to: Csops.self) }

    static func of(pid: Int32) -> ComputerSignature {
        guard let csops else { return ComputerSignature(identifier: nil, team: nil, valid: false) }
        func text(_ op: UInt32) -> String? {
            // An 8-byte header, then the string.
            var buffer = [UInt8](repeating: 0, count: 4096)
            guard csops(pid, op, &buffer, buffer.count) == 0 else { return nil }
            let value = String(decoding: buffer[8...].prefix { $0 != 0 }, as: UTF8.self)
            return value.isEmpty ? nil : value
        }
        var status: UInt32 = 0
        let valid = csops(pid, 0, &status, MemoryLayout<UInt32>.size) == 0 && status & 0x1 != 0  // CS_OPS_STATUS, CS_VALID
        return ComputerSignature(identifier: text(11), team: text(14), valid: valid)  // CS_OPS_IDENTITY, CS_OPS_TEAMID
    }
}

/// Who is on the other end of Nollie's socket: the nollie-mac add-on, run by Hermes itself on this
/// Mac, for one bot. Read from the kernel when the connection is made, so a request can't say it
/// came from somewhere else, and a task answers only to the process that asked for it.
///
/// Defence in depth, not the boundary: a bot's own tools run as the same user and in the same
/// Hermes job, so nothing here can fully tell them apart. The boundary is the person's yes on the
/// approval card, with Touch ID (Docs/nollie-computer.md, "What keeps a bot in check").
struct ComputerPeer: Equatable, Sendable {
    enum Host: String, Sendable {
        /// Hermes's gateway, which runs the bots' messaging chats (Signal, Telegram and the rest).
        case gateway
        /// Hermes's dashboard, which runs the chats in the Nollie app.
        case dashboard
    }

    var pid: Int32
    var started: Double
    var host: Host
    /// The bot whose add-on folder the program runs from: `default` for the main bot.
    var profile: String

    /// SHA-256 of Companions/nollie-mac/server.py as Nollie ships it (a test keeps the two in step).
    static let addOnDigest = "ad74465311de22e3d9914229ed51864961ab06cdb4bcf9a2d3a00a798270d112"

    /// The peer of a connected Unix socket, or nil when it isn't the add-on run by Hermes.
    static func of(socket fd: Int32, hermesHome: String = NSHomeDirectory() + "/.hermes") -> ComputerPeer? {
        var pid: pid_t = 0
        var size = socklen_t(MemoryLayout<pid_t>.size)
        // SOL_LOCAL, LOCAL_PEERPID
        guard getsockopt(fd, 0, 0x002, &pid, &size) == 0, pid > 0 else { return nil }
        return identify(pid: pid, hermesHome: hermesHome)
    }

    static func identify(pid: Int32, hermesHome: String) -> ComputerPeer? {
        guard let me = ComputerProcess(pid: pid), let parent = ComputerProcess(pid: me.parent) else { return nil }
        var ancestors: [ComputerProcess] = []
        var next = parent.parent
        while next > 1, ancestors.count < 6, let process = ComputerProcess(pid: next) {
            ancestors.append(process)
            next = process.parent
        }
        // Its standard input and output are pipes whose other ends Hermes itself holds: the MCP
        // connection, not a terminal, a file or a pipe some other program feeds.
        let mine = ComputerProcess.pipes(of: pid).peers
        let held = ComputerProcess.pipes(of: parent.pid).held
        let fromParent = [0, 1].allSatisfy { mine[$0].map(held.contains) ?? false }
        // The parent is the real thing: listening where Hermes's dashboard or gateway listens, and
        // it, the add-on and the top of its chain belong to one launchd job that answers for itself.
        let top = ancestors.last ?? parent
        let job = ComputerProcess.responsible(for: top.pid)
        let oneJob = job == top.pid && ComputerProcess.responsible(for: parent.pid) == job && ComputerProcess.responsible(for: pid) == job
        let listening = ComputerProcess.listens(parent.pid, tcpPort: dashboardPort, unixPath: hermesHome + "/gateway.sock")
        let facts = Facts(me: me, parent: parent, ancestors: ancestors, reachedLaunchd: next == 1,
                          signature: ComputerSignature.of(pid: pid), stdioFromParent: fromParent, oneLaunchdJob: oneJob,
                          parentListens: listening)
        return identify(facts, hermesHome: hermesHome, digest: fileDigest)
    }

    struct Facts: Sendable {
        var me: ComputerProcess
        var parent: ComputerProcess
        var ancestors: [ComputerProcess]
        var reachedLaunchd: Bool
        var signature: ComputerSignature
        var stdioFromParent: Bool
        var oneLaunchdJob: Bool
        var parentListens: Bool
    }

    /// The dashboard's port, as Nollie connects to it here.
    nonisolated(unsafe) static var dashboardPort = 9119

    /// The rules, on facts already read:
    /// - macOS's own Python, intact, running exactly `-I <bot's plugin folder>/nollie-mac/server.py`
    ///   and nothing else, and that file is the add-on Nollie ships;
    /// - its parent is Hermes's own `gateway run` or `dashboard`, the topmost in its chain, listening
    ///   where Hermes does, started by launchd (directly, or through Hermes's own wrappers and
    ///   osascript) as one job with the add-on, not from a shell, a terminal or a bot's tools;
    /// - its standard input and output are pipes that parent holds.
    static func identify(_ facts: Facts, hermesHome: String, digest: (String) -> String?) -> ComputerPeer? {
        let home = hermesHome.hasSuffix("/") ? String(hermesHome.dropLast()) : hermesHome
        let me = facts.me, parent = facts.parent
        guard facts.signature.valid, facts.signature.identifier == "com.apple.python3", facts.signature.team == nil,
              !me.path.hasPrefix(home + "/") else { return nil }
        guard me.arguments.count == 3, me.arguments[1] == "-I" else { return nil }
        let script = me.arguments[2]
        // A plain absolute path: no "." or "..", no empty parts.
        let pieces = script.split(separator: "/", omittingEmptySubsequences: false).dropFirst()
        guard script.hasPrefix("/"), !pieces.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }),
              script.hasPrefix(home + "/") else { return nil }
        let parts = script.dropFirst(home.count + 1).split(separator: "/").map(String.init)
        let profile: String
        if parts == ["plugins", "nollie-mac", "server.py"] {
            profile = "default"
        } else if parts.count == 5, parts[0] == "profiles", parts[2] == "plugins", parts[3] == "nollie-mac", parts[4] == "server.py",
                  !parts[1].hasPrefix(".") {
            profile = parts[1]
        } else {
            return nil
        }
        // The private bot's folder is never read, not even to check a file. The file is read only by
        // this very path, with no link followed anywhere along it (`fileDigest`), so no other name
        // leads into a private bot's folder.
        guard !ComputerOtherControl.isPrivate(profile) else { return nil }
        guard digest(script) == addOnDigest else { return nil }
        guard parent.path.hasPrefix(home + "/") else { return nil }
        let words = parent.arguments.dropFirst()
        let host: Host
        if let index = words.firstIndex(of: "gateway"), words.index(after: index) < words.endIndex, words[words.index(after: index)] == "run" {
            host = .gateway
        } else if words.contains("dashboard") {
            host = .dashboard
        } else {
            return nil
        }
        guard facts.reachedLaunchd, facts.ancestors.allSatisfy({ $0.path.hasPrefix(home + "/") || $0.path == "/usr/bin/osascript" }),
              facts.stdioFromParent, facts.oneLaunchdJob, facts.parentListens else { return nil }
        // The topmost Hermes host in its chain: a copy started under the real one doesn't count.
        guard !facts.ancestors.contains(where: { isHost($0.arguments.dropFirst()) }) else { return nil }
        return ComputerPeer(pid: me.pid, started: me.started, host: host, profile: profile)
    }

    static func isHost(_ words: ArraySlice<String>) -> Bool {
        if let index = words.firstIndex(of: "gateway"), words.index(after: index) < words.endIndex, words[words.index(after: index)] == "run" {
            return true
        }
        return words.contains("dashboard")
    }

    /// SHA-256 of the file at exactly this path: opened in one step that follows no link anywhere
    /// along the path, so it can't lead somewhere else, even if a folder is swapped meanwhile.
    static func fileDigest(_ path: String) -> String? {
        let fd = open(path, O_RDONLY | O_NOFOLLOW_ANY | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        guard let data = try? handle.readToEnd(), data.count < 1 << 20 else { return nil }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// The same process as this one, still running.
    var isStillThere: Bool { ComputerProcess(pid: pid)?.started == started }
}
#endif
