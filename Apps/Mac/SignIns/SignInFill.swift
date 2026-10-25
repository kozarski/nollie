import Foundation
import NollieCore

/// What to type, and where. Only ever in memory, for one fill, and never logged or printed.
struct SignInFillJob: Sendable {
    /// "mac" for this Mac, or the helper's Cua computer (`local:dev`).
    var computer: String
    /// "username": type the username, Tab, the password, Return. "password": the password and Return.
    var focus: String
    var username: String
    var password: String
}

extension SignInFillJob: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    var description: String { "SignInFillJob(computer: \(computer), focus: \(focus), credentials hidden)" }
    var debugDescription: String { description }
    var customMirror: Mirror { Mirror(self, children: ["computer": computer, "focus": focus], displayStyle: .struct) }
}

/// Types a saved sign-in into a helper's computer.
protocol SignInFilling: Sendable {
    func fill(_ job: SignInFillJob) async -> Result<Void, SignInFailure>
}

/// The computer decides how: a Cua computer through Cua's own command line, this Mac not yet.
struct SignInFillRouter: SignInFilling {
    var space: any SignInFilling = CuaSpaceSignInFill()
    var mac: any SignInFilling = MacSignInFill()

    func fill(_ job: SignInFillJob) async -> Result<Void, SignInFailure> {
        job.computer == "mac" ? await mac.fill(job) : await space.fill(job)
    }
}

/// This Mac, through Nollie Computer. Not wired yet, on purpose: Nollie Computer keeps browsers
/// view-only and refuses typing into password fields (ComputerActionRules), and both are rules a
/// security review signed off. Filling here needs its own reviewed exception: only the focused
/// secure field, only in an app the person approved for the running task.
struct MacSignInFill: SignInFilling {
    func fill(_ job: SignInFillJob) async -> Result<Void, SignInFailure> { .failure(.fillUnavailable) }
}

/// One JSON-RPC line at a time with Cua's MCP server. A protocol so the exchange can be tested
/// without a computer.
protocol CuaLineTransport: AnyObject {
    func send(_ message: [String: Any]) throws
    /// The next message, or nil when the other side closed.
    func receive() throws -> [String: Any]?
}

/// The steps for a fill, separate from the process that carries them. Checks the computer is the
/// one named and ready before anything is typed; reports only fixed reasons, never Cua's text.
enum CuaSignInExchange {
    /// Cua's key names for the two keys a fill presses.
    static let tabKey = "tab"
    static let returnKey = "enter"

    static func run(_ line: CuaLineTransport, job: SignInFillJob) -> Result<Void, SignInFailure> {
        var next = 0
        func call(_ method: String, _ params: [String: Any]) throws -> [String: Any] {
            next += 1
            let id = next
            try line.send(["jsonrpc": "2.0", "id": id, "method": method, "params": params])
            for _ in 0..<32 {
                guard let reply = try line.receive() else { throw SignInFailure.computerUnavailable }
                if reply["id"] as? Int == id {
                    guard reply["error"] == nil, let result = reply["result"] as? [String: Any] else { throw SignInFailure.computerUnavailable }
                    return result
                }
            }
            throw SignInFailure.computerUnavailable
        }
        func tool(_ name: String, _ arguments: [String: Any]) throws -> [String: Any] {
            try call("tools/call", ["name": name, "arguments": arguments])
        }
        do {
            _ = try call("initialize", ["protocolVersion": "2024-11-05", "capabilities": [String: Any](),
                                        "clientInfo": ["name": "nollie-sign-in", "version": "0.1.0"]])
            try line.send(["jsonrpc": "2.0", "method": "notifications/initialized"])
            guard let sandbox = readySandbox(try tool("sandbox_get", ["name": job.computer]), named: job.computer) else {
                return .failure(.computerUnavailable)
            }
            var steps: [(String, [String: Any])] = []
            if job.focus != "password" {
                steps.append(("computer_type", ["sandbox": sandbox, "text": job.username]))
                steps.append(("computer_key", ["sandbox": sandbox, "key": tabKey]))
            }
            steps.append(("computer_type", ["sandbox": sandbox, "text": job.password]))
            steps.append(("computer_key", ["sandbox": sandbox, "key": returnKey]))
            for (name, arguments) in steps {
                // Once typing has begun, any failure is "couldn't finish", whatever Cua said.
                guard let result = try? tool(name, arguments), result["isError"] as? Bool != true else { return .failure(.fillFailed) }
            }
            return .success(())
        } catch let failure as SignInFailure {
            return .failure(failure)
        } catch {
            return .failure(.computerUnavailable)
        }
    }

    /// The Space's full id when sandbox_get found the one named and it is ready: a bare name must
    /// be that Space's name, a qualified one exactly its id.
    static func readySandbox(_ result: [String: Any], named name: String) -> String? {
        guard result["isError"] as? Bool != true else { return nil }
        for part in result["content"] as? [[String: Any]] ?? [] where part["type"] as? String == "text" {
            guard let text = part["text"] as? String, let data = text.data(using: .utf8),
                  let info = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let id = info["id"] as? String, info["status"] as? String == "ready" else { continue }
            let pieces = id.split(separator: ":", maxSplits: 1).map(String.init)
            guard pieces.count == 2, ["local", "cloud"].contains(pieces[0]), info["location"] as? String == pieces[0] else { continue }
            if name.contains(":") ? id == name : pieces[1] == name { return id }
        }
        return nil
    }
}

#if NOLLIE_DIRECT
/// A helper's own Cua computer, through Cua's public command line: `cua --daemon ~/.cua/cua.sock mcp`
/// with only the permissions a fill needs (look the computer up, type, press keys). It connects to
/// the daemon that already runs and never starts one, creates, resumes or chooses a computer.
struct CuaSpaceSignInFill: SignInFilling {
    var home = FileManager.default.homeDirectoryForCurrentUser
    var timeout: TimeInterval = 20

    func executable() -> URL? {
        // The tool inside the Cua Spaces app in use (the person's own, else Nollie's own copy), by
        // full path. Then where the person may have put one; a Mac app's PATH has none of these.
        if let tool = NollieCuaPlaces.cli(home: home, own: NolliePaths.current.cua) { return tool }
        return [home.appendingPathComponent(".local/bin/cua"), home.appendingPathComponent(".cargo/bin/cua"),
                URL(fileURLWithPath: "/opt/homebrew/bin/cua"), URL(fileURLWithPath: "/usr/local/bin/cua")]
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    func fill(_ job: SignInFillJob) async -> Result<Void, SignInFailure> {
        let socket = home.appendingPathComponent(".cua/cua.sock")
        var info = stat()
        guard let cua = executable(), lstat(socket.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFSOCK else {
            return .failure(.computerUnavailable)
        }
        let timeout = timeout
        return await Task.detached {
            let process = Process()
            process.executableURL = cua
            process.arguments = ["--daemon", socket.path, "mcp", "--permissions", "sandbox:get,computer:type,computer:key"]
            var environment = ProcessInfo.processInfo.environment
            environment["CUA_TELEMETRY"] = "0"
            process.environment = environment
            let input = Pipe(), output = Pipe()
            process.standardInput = input
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            do { try process.run() } catch { return .failure(.computerUnavailable) }
            let line = PipeLines(input: input.fileHandleForWriting, output: output.fileHandleForReading)
            let watchdog = DispatchWorkItem { if process.isRunning { process.terminate() } }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)
            let result = CuaSignInExchange.run(line, job: job)
            watchdog.cancel()
            try? input.fileHandleForWriting.close()
            if process.isRunning { process.terminate() }
            process.waitUntilExit()
            return result
        }.value
    }
}

/// Newline-separated JSON over the child's pipes.
final class PipeLines: CuaLineTransport {
    private let input: FileHandle
    private let output: FileHandle
    private var buffer = Data()
    private static let limit = 4 * 1024 * 1024

    init(input: FileHandle, output: FileHandle) {
        self.input = input
        self.output = output
    }

    func send(_ message: [String: Any]) throws {
        var data = try JSONSerialization.data(withJSONObject: message)
        data.append(0x0A)
        try input.write(contentsOf: data)
    }

    func receive() throws -> [String: Any]? {
        while true {
            if let end = buffer.firstIndex(of: 0x0A) {
                let line = buffer[buffer.startIndex..<end]
                buffer.removeSubrange(buffer.startIndex...end)
                if let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] { return object }
                continue
            }
            guard buffer.count < Self.limit, let chunk = try output.read(upToCount: 65536), !chunk.isEmpty else { return nil }
            buffer.append(chunk)
        }
    }
}
#else
/// The App Store edition is sandboxed: it can't reach Cua's daemon.
struct CuaSpaceSignInFill: SignInFilling {
    func fill(_ job: SignInFillJob) async -> Result<Void, SignInFailure> { .failure(.fillUnavailable) }
}
#endif
