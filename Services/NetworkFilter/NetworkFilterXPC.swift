#if os(macOS)
import Foundation

/// What Nollie Runtime asks of the network filter over its Mach service: start sending reports, with the
/// switch as Nollie on the Mac has it. With nobody subscribed the filter lets everything through unread.
@objc protocol NetworkFilterService {
    /// `switchData` is a JSON `NetworkFilterPolicy.Switch`. The reply is false when it can't be read.
    func subscribe(_ switchData: Data, reply: @escaping (Bool) -> Void)
}

/// What the filter sends back: a JSON array of `NetworkFilterPolicy.Event`, a few at a time.
@objc protocol NetworkFilterReports {
    func deliver(_ events: Data)
}

enum NetworkFilterXPC {
    static func serviceInterface() -> NSXPCInterface { NSXPCInterface(with: NetworkFilterService.self) }
    static func reportsInterface() -> NSXPCInterface { NSXPCInterface(with: NetworkFilterReports.self) }
    /// Only Nollie Runtime, signed by the team, may subscribe.
    static let runtimeRequirement = "identifier \"\(NetworkFilterPolicy.runtimeBundleID)\" and anchor apple generic "
        + "and certificate leaf[subject.OU] = \"\(NetworkFilterPolicy.teamID)\""
    /// And Nollie Runtime only listens to the filter signed by the same team.
    static let filterRequirement = "identifier \"\(NetworkFilterPolicy.filterBundleID)\" and anchor apple generic "
        + "and certificate leaf[subject.OU] = \"\(NetworkFilterPolicy.teamID)\""
}
#endif
