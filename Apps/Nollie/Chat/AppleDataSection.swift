import SwiftUI
import NollieCore

/// A helper's switches for the Mac's Calendar, Reminders and Contacts, all off to start. Reading is
/// free once on; every change still waits for a yes on a card. The iPhone shows the same switches:
/// the data is the Mac's, never the phone's own.
struct AppleDataSection: View {
    let profileName: String
    @Environment(AppModel.self) private var model
    @State private var setting = AppleDataModel()

    private var runtime: GatewayRuntime? { model.runtime }
    private var scope: String {
        "\(profileName)/\(runtime?.connection.id.uuidString ?? "")/\(runtime?.connection.gateway.description ?? "")/\(model.lock.isLocked)"
    }
    /// This Mac keeps the data, so a switch turned on here asks macOS here.
    private var keptHere: Bool {
        #if os(macOS)
        runtime?.gatewayIsOnThisMac ?? false
        #else
        false
        #endif
    }

    var body: some View {
        Group {
            if !setting.unavailable, runtime != nil, !model.lock.isLocked { switches }
        }
        .task(id: scope) {
            setting.reset()
            guard let runtime, !model.lock.isLocked else { return }
            await setting.load(bot: profileName, door: AppleDataModel.door(runtime: runtime, permissions: model.permissions))
        }
    }

    private var switches: some View {
        VStack(spacing: 12) {
            PageHeading(keptHere ? "On this Mac" : "From your Mac")
            GlassStack {
                ForEach(AppleDataArea.allCases) { area in
                    GlassSwitch(area.title, isOn: Binding(get: { setting.isOn(area) }, set: { on in
                        guard let runtime else { return }
                        let door = AppleDataModel.door(runtime: runtime, permissions: model.permissions)
                        Task { await setting.set(area, on: on, bot: profileName, door: door) }
                    }), id: "profile.appleData.\(area.rawValue)")
                    .disabled(setting.switches == nil || setting.saving.contains(area))
                }
            }
            notes
        }
    }

    @ViewBuilder private var notes: some View {
        if let area = setting.refused {
            PageNote("Allow \(area.title) for Nollie in System Settings.", symbol: "exclamationmark.triangle.fill",
                     tint: .orange, id: "profile.appleData.refused")
            GlassButton("Open Settings", symbol: "gear", id: "profile.appleData.openSettings") {
                model.permissions.openSettings(PermissionKind(area))
            }
        } else if let area = setting.waitingForMac, !keptHere {
            PageNote("Allow \(area.title) in Nollie on your Mac.", symbol: "desktopcomputer", id: "profile.appleData.needsMac")
        }
        if let error = setting.error {
            PageNote(error, symbol: "exclamationmark.triangle.fill", tint: .orange, id: "profile.appleData.problem")
            GlassButton("Try again", symbol: "arrow.clockwise", id: "profile.appleData.retry") {
                guard let runtime else { return }
                Task { await setting.load(bot: profileName, door: AppleDataModel.door(runtime: runtime, permissions: model.permissions)) }
            }
        }
    }
}
