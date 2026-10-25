import Foundation
import Observation
import NollieCore

/// One helper's own computer, read and changed through the nollie-computer add-on on the Mac,
/// so the iPhone flips the same switch. A change whose answer is lost is never sent again:
/// the next read says what happened.
@MainActor @Observable
final class HelperComputerModel {
    let profile: String
    private(set) var status: HelperComputerStatus?
    private(set) var error: String?
    private(set) var actionError: String?
    /// The person asked for a computer while Cua still needs setting up; it turns on once Cua is ready.
    private(set) var wantsOn = false
    private(set) var sending = false

    init(profile: String) {
        self.profile = profile
        #if DEBUG
        // The demo copy's `-nollie-demo-own-computer-asked`: the switch already flipped, for the setup step's picture.
        if DemoMode.isOn, ProcessInfo.processInfo.arguments.contains("-nollie-demo-own-computer-asked") { wantsOn = true }
        #endif
    }

    private var query: [URLQueryItem] { [URLQueryItem(name: "profile", value: profile)] }

    func load(_ rt: GatewayRuntime) async {
        do {
            let read: HelperComputerStatus = try await rt.api.get(HelperComputerStatus.path, query: query)
            guard read.profile == profile else { return }
            status = read
            error = nil
        } catch HermesAPIError.http(let code, _) where code == 404 {
            status = nil
            error = "This needs Nollie's computer add-on on your Mac."
        } catch {
            if status == nil { self.error = "Couldn't check its computer right now." }
        }
        if status?.on == true { wantsOn = false }
        if wantsOn, let status, status.setup == .ready, !status.on, !status.busy {
            await send("on", rt)
        }
    }

    /// Reads while the section is open: every two seconds while something is changing.
    func watch(_ rt: GatewayRuntime, busy: @escaping @MainActor () -> Bool) async {
        while !Task.isCancelled {
            await load(rt)
            // Checked each second, so a switch flipped while idle is followed within two.
            var waited = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                waited += 1
                let changing = status?.busy == true || status?.state == .gettingReady || wantsOn || busy()
                if waited >= (changing ? 2 : 20) { break }
            }
        }
    }

    func setSwitch(_ on: Bool, _ rt: GatewayRuntime) async {
        actionError = nil
        if on {
            wantsOn = true
            if status?.setup == .ready { await send("on", rt) }
        } else {
            wantsOn = false
            if status?.on == true { await send("off", rt) }
        }
    }

    func notNow() { wantsOn = false }

    func reset(_ rt: GatewayRuntime) async { await send("reset", rt) }
    func remove(_ rt: GatewayRuntime) async { await send("remove", rt) }

    private func send(_ action: String, _ rt: GatewayRuntime) async {
        guard !sending else { return }
        sending = true
        defer { sending = false }
        let body: JSONValue = .object(["profile": .string(profile), "action": .string(action),
                                       "request_id": .string(UUID().uuidString)])
        do {
            let answer: HelperComputerStatus = try await rt.api.send("POST", HelperComputerStatus.path, json: body)
            status = answer
            actionError = nil
            if action == "on" || action == "off" { wantsOn = false }
        } catch HermesAPIError.http(let code, let detail) where (400..<500).contains(code) {
            // The add-on said no, in its own words; nothing changed.
            if action == "on" { wantsOn = false }
            actionError = Self.plain(detail)
            await load(rt)
        } catch {
            if action == "on" { wantsOn = false }
            actionError = "Couldn't confirm that change. Here's how it is now."
            await load(rt)
        }
    }

    /// The add-on's sentence without the status code the client appends.
    static func plain(_ detail: String) -> String {
        let text = detail.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? "That didn't work. Try again in a moment." : text
    }
}
