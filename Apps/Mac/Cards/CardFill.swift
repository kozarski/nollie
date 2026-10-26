import Foundation
import NollieCore
#if NOLLIE_DIRECT
import Vision
#endif

/// What to type, and where. Only ever in memory, for one fill, and never logged or printed.
struct CardFillJob: Sendable {
    /// The helper's Cua computer (`local:dev`).
    var computer: String
    var number: String
    var expiry: String
    var code: String
}

extension CardFillJob: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    var description: String { "CardFillJob(computer: \(computer), card hidden)" }
    var debugDescription: String { description }
    var customMirror: Mirror { Mirror(self, children: ["computer": computer], displayStyle: .struct) }
}

/// Reads a helper's screen and types a card into it.
protocol CardFilling: Sendable {
    /// The lines of text on the computer's screen now, read on this Mac. nil when it couldn't be read.
    func screenText(_ computer: String) async -> [String]?
    /// Types the card into the box that has focus: the number, Tab, the expiry, Tab, the code, Return.
    func fill(_ job: CardFillJob) async -> Result<Void, PaymentFailure>
}

/// The keys a fill presses, in order. Separate so the steps can be tested without a computer.
enum CardFillSteps {
    static func steps(for job: CardFillJob, sandbox: String) -> [(String, [String: Any])] {
        [("computer_type", ["sandbox": sandbox, "text": job.number]),
         ("computer_key", ["sandbox": sandbox, "key": CuaSignInExchange.tabKey]),
         ("computer_type", ["sandbox": sandbox, "text": job.expiry]),
         ("computer_key", ["sandbox": sandbox, "key": CuaSignInExchange.tabKey]),
         ("computer_type", ["sandbox": sandbox, "text": job.code]),
         ("computer_key", ["sandbox": sandbox, "key": CuaSignInExchange.returnKey])]
    }
}

/// One exchange with Cua's MCP server: look the computer up, then take a picture or type. Checks the
/// computer is the one named and ready first; reports only fixed reasons, never Cua's text.
enum CuaCardExchange {
    static func run(_ line: CuaLineTransport, computer: String,
                    then work: (_ tool: (String, [String: Any]) throws -> [String: Any], _ sandbox: String) throws -> Void) -> Result<Void, PaymentFailure> {
        var next = 0
        func call(_ method: String, _ params: [String: Any]) throws -> [String: Any] {
            next += 1
            let id = next
            try line.send(["jsonrpc": "2.0", "id": id, "method": method, "params": params])
            for _ in 0..<32 {
                guard let reply = try line.receive() else { throw PaymentFailure.computerUnavailable }
                if reply["id"] as? Int == id {
                    guard reply["error"] == nil, let result = reply["result"] as? [String: Any] else { throw PaymentFailure.computerUnavailable }
                    return result
                }
            }
            throw PaymentFailure.computerUnavailable
        }
        let tool: (String, [String: Any]) throws -> [String: Any] = { name, arguments in
            try call("tools/call", ["name": name, "arguments": arguments])
        }
        do {
            _ = try call("initialize", ["protocolVersion": "2024-11-05", "capabilities": [String: Any](),
                                        "clientInfo": ["name": "nollie-cards", "version": "0.1.0"]])
            try line.send(["jsonrpc": "2.0", "method": "notifications/initialized"])
            guard let sandbox = CuaSignInExchange.readySandbox(try tool("sandbox_get", ["name": computer]), named: computer) else {
                return .failure(.computerUnavailable)
            }
            try work(tool, sandbox)
            return .success(())
        } catch let failure as PaymentFailure {
            return .failure(failure)
        } catch {
            return .failure(.computerUnavailable)
        }
    }

    /// Types the card. Once typing has begun, any failure is "couldn't finish", whatever Cua said.
    static func fill(_ line: CuaLineTransport, job: CardFillJob) -> Result<Void, PaymentFailure> {
        run(line, computer: job.computer) { tool, sandbox in
            for (name, arguments) in CardFillSteps.steps(for: job, sandbox: sandbox) {
                guard let result = try? tool(name, arguments), result["isError"] as? Bool != true else {
                    throw PaymentFailure.fillFailed
                }
            }
        }
    }

    /// One picture of the computer's screen, in memory.
    static func picture(_ line: CuaLineTransport, computer: String) -> Data? {
        var found: Data?
        _ = run(line, computer: computer) { tool, sandbox in
            let result = try tool("computer_screenshot", ["sandbox": sandbox])
            guard result["isError"] as? Bool != true else { return }
            for part in result["content"] as? [[String: Any]] ?? [] where part["type"] as? String == "image" {
                if let text = part["data"] as? String, let data = Data(base64Encoded: text), data.count <= 8 * 1024 * 1024 {
                    found = data
                    return
                }
            }
        }
        return found
    }
}

#if NOLLIE_DIRECT
/// A helper's own Cua computer, through Cua's public command line, as saved sign-ins use it: it connects
/// to the daemon that already runs, with only the permissions each step needs.
struct CuaCardFill: CardFilling {
    /// Finds Cua's command line and the person's home the way saved sign-ins do.
    var cua = CuaSpaceSignInFill()
    var timeout: TimeInterval = 20

    private func session<T: Sendable>(_ permissions: String, _ body: @escaping @Sendable (CuaLineTransport) -> T,
                                      unavailable: T) async -> T {
        let socket = self.cua.home.appendingPathComponent(".cua/cua.sock")
        var info = stat()
        guard let cua = self.cua.executable(), lstat(socket.path, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFSOCK else { return unavailable }
        let timeout = timeout
        return await Task.detached {
            let process = Process()
            process.executableURL = cua
            process.arguments = ["--daemon", socket.path, "mcp", "--permissions", permissions]
            var environment = ProcessInfo.processInfo.environment
            environment["CUA_TELEMETRY"] = "0"
            process.environment = environment
            let input = Pipe(), output = Pipe()
            process.standardInput = input
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            do { try process.run() } catch { return unavailable }
            let line = PipeLines(input: input.fileHandleForWriting, output: output.fileHandleForReading)
            let watchdog = DispatchWorkItem { if process.isRunning { process.terminate() } }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)
            let result = body(line)
            watchdog.cancel()
            try? input.fileHandleForWriting.close()
            if process.isRunning { process.terminate() }
            process.waitUntilExit()
            return result
        }.value
    }

    func screenText(_ computer: String) async -> [String]? {
        let picture = await session("sandbox:get,computer:screenshot", { CuaCardExchange.picture($0, computer: computer) },
                                    unavailable: nil)
        guard let picture else { return nil }
        return await ScreenWords.read(picture)
    }

    func fill(_ job: CardFillJob) async -> Result<Void, PaymentFailure> {
        await session("sandbox:get,computer:type,computer:key", { CuaCardExchange.fill($0, job: job) },
                      unavailable: .failure(.computerUnavailable))
    }
}

/// The words in a picture, read with the Mac's own text recognition. The picture stays in memory.
enum ScreenWords {
    static func read(_ picture: Data) async -> [String]? {
        var request = RecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        guard let found = try? await request.perform(on: picture) else { return nil }
        let lines = found.compactMap { $0.topCandidates(1).first?.string }
        // A screen with no words at all means the reading failed, not that the screen is blank.
        return lines.isEmpty ? nil : lines
    }
}
#else
/// The App Store edition is sandboxed: it can't reach Cua's daemon.
struct CuaCardFill: CardFilling {
    func screenText(_ computer: String) async -> [String]? { nil }
    func fill(_ job: CardFillJob) async -> Result<Void, PaymentFailure> { .failure(.fillUnavailable) }
}
#endif

#if DEBUG
/// The demo copy's computer: a checkout showing the total, a fill that works, and the number gone
/// after a moment. Never in a release build.
final class DemoCardFill: CardFilling, @unchecked Sendable {
    var total = "£48.99"
    private var filled = false

    func screenText(_ computer: String) async -> [String]? {
        filled ? ["Thank you for your order", "Paid with Visa •••• 4242"] : ["Checkout", "Total \(total)", "Card number"]
    }

    func fill(_ job: CardFillJob) async -> Result<Void, PaymentFailure> {
        try? await Task.sleep(for: .milliseconds(800))
        filled = true
        return .success(())
    }
}
#endif
