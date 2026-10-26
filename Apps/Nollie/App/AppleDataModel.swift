import Foundation
import Observation
import NollieCore

/// One helper's Calendar, Reminders and Contacts switches. They live with the add-on, so the iPhone
/// and the Mac show the same ones. On the Mac that keeps the data, turning one on asks macOS first,
/// at that moment, and stays off if the answer is no.
@MainActor @Observable
final class AppleDataModel {
    /// What the model needs from the gateway and this device. Tests stand in for both.
    struct Door {
        var load: (String) async throws -> AppleDataSwitches
        var save: (String, [AppleDataArea]) async throws -> AppleDataSwitches
        /// This Mac's own prompt, when this Mac keeps the data; nil on the iPhone or another Mac.
        var ask: ((AppleDataArea) async -> PermissionState)?
    }

    private(set) var switches: AppleDataSwitches?
    /// True when the gateway has no such switches (an older add-on): the section stays hidden.
    private(set) var unavailable = false
    private(set) var saving: Set<AppleDataArea> = []
    private(set) var error: String?
    /// macOS said no to this one: it stays off, and Settings is where that changes.
    private(set) var refused: AppleDataArea?
    private var bot: String?
    private var operation = UUID()
    private let isPrivate: (String) -> Bool

    init(isPrivate: @escaping (String) -> Bool = { PrivateBots.isPrivate($0) }) {
        self.isPrivate = isPrivate
    }

    private func isPrivateBot(_ bot: String) -> Bool { AskFirstModel.isPrivateBot(bot, isPrivate: isPrivate) }

    func reset() {
        operation = UUID()
        switches = nil
        unavailable = false
        saving = []
        error = nil
        refused = nil
        bot = nil
    }

    func isOn(_ area: AppleDataArea) -> Bool { switches?.isOn(area) ?? false }

    /// An area that is on here but that the Mac has not allowed yet, for the line under the switches.
    var waitingForMac: AppleDataArea? {
        AppleDataArea.allCases.first { isOn($0) && (switches?.macAccess($0)).map { $0 != .allowed } ?? false }
    }

    func load(bot: String, door: Door) async {
        guard !isPrivateBot(bot) else { reset(); return }
        if self.bot != bot { reset(); self.bot = bot }
        let operation = UUID()
        self.operation = operation
        do {
            let found = try await door.load(bot)
            guard self.operation == operation, found.bot == bot else { return }
            switches = found
            error = nil
        } catch HermesAPIError.http(status: 404, _) {
            guard self.operation == operation else { return }
            unavailable = true
        } catch {
            guard self.operation == operation, !Task.isCancelled else { return }
            self.error = "Couldn't check these. Try again."
        }
    }

    /// Turns one on or off. On asks this Mac's permission first when this Mac keeps the data; a no
    /// leaves it off. Nothing is saved for a bot that has become private.
    func set(_ area: AppleDataArea, on: Bool, bot: String, door: Door) async {
        guard let current = switches, current.bot == bot, !saving.contains(area), current.isOn(area) != on,
              !isPrivateBot(bot) else { return }
        saving.insert(area)
        defer { saving.remove(area) }
        refused = nil
        if on, let ask = door.ask {
            guard await ask(area) == .granted else {
                refused = area
                return
            }
        }
        var wanted = AppleDataArea.allCases.filter(current.isOn)
        if on { wanted.append(area) } else { wanted.removeAll { $0 == area } }
        do {
            let saved = try await door.save(bot, wanted)
            guard self.bot == bot, saved.bot == bot else { return }
            switches = saved
            error = nil
        } catch {
            guard self.bot == bot else { return }
            self.error = "Couldn't change that. Try again."
        }
    }

    static func door(runtime: GatewayRuntime, permissions: PermissionCenter) -> Door {
        var door = Door(load: { try await runtime.appleDataSwitches(bot: $0) },
                        save: { try await runtime.saveAppleDataSwitches(bot: $0, on: $1) })
        #if os(macOS)
        if runtime.gatewayIsOnThisMac {
            door.ask = { await permissions.ask(PermissionKind($0)) }
        }
        #endif
        return door
    }
}
