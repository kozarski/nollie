#if os(macOS)
import NollieCore
import SwiftUI

/// Settings' own row for using Nollie on an iPhone or iPad, near the top of the first screen: the linked device's
/// name, or Not linked. It opens the same sheet as Connection's Use Nollie on your iPhone, which stays where it was.
/// Only for Nollie's own assistant, the one with a door for a phone.
struct PhoneLinkRow: View {
    @Environment(AppModel.self) private var model
    @State private var showLink = false
    /// The owner's own linked devices, once Nollie Runtime has said. Nil until then.
    @State private var devices: [NollieLinkIPCDevice]?

    private var connection: GatewayConnection? { model.runtime?.connection }

    var body: some View {
        GlassStack {
            Button { showLink = true } label: {
                GlassRowLabel(title: Self.title, symbol: "iphone", value: Self.value(devices))
            }
            .buttonStyle(.plain)
            .testID("settings.row.phone")
        }
        .task(id: "\(connection?.id.uuidString ?? "")/\(showLink)") {
            guard !showLink else { return }
            devices = await Self.ownDevices()
        }
        .sheet(isPresented: $showLink) { NollieLinkSheet().withAppModel() }
    }

    static var title: String { String(localized: "iPhone & iPad", comment: "A Settings row: use Nollie on an iPhone or iPad") }

    /// Shown on the Mac's own assistant, and in the demo copy for pictures.
    static func shows(available: Bool, search: String) -> Bool {
        available && matches(search)
    }

    static func matches(_ search: String) -> Bool {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return true }
        let words = title + " " + String(localized: "iphone ipad phone pair link qr code scan mobile", comment: "Settings search words, not shown")
        return words.localizedCaseInsensitiveContains(query)
    }

    /// The linked device's name, how many are linked, or Not linked. Nil while not known yet.
    static func value(_ devices: [NollieLinkIPCDevice]?) -> String? {
        guard let devices else { return nil }
        switch devices.count {
        case 0: return String(localized: "Not linked", comment: "No iPhone or iPad uses Nollie on this Mac yet")
        case 1: return devices[0].name
        default: return String(localized: "\(devices.count) linked", comment: "How many iPhones and iPads use Nollie on this Mac")
        }
    }

    /// Phones of people at home a helper is shared with are theirs, not this row's.
    static func own(_ devices: [NollieLinkIPCDevice]) -> [NollieLinkIPCDevice] { devices.filter { $0.person == nil } }

    private static func ownDevices() async -> [NollieLinkIPCDevice]? {
        if DemoMode.isOn { return [] }
        guard let response = try? await NollieLinkMacClient.status() else { return nil }
        return own(response.devices)
    }
}
#endif
