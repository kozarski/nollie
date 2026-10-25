import Foundation

enum ModelSetupMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case local, cloud, both

    var id: String { rawValue }
    var title: String {
        switch self { case .local: "On your Mac"; case .cloud: "Online"; case .both: "Both" }
    }
    var detail: String {
        switch self {
        case .local: "The model runs on your Mac, or the computer hosting your assistant. Downloads need internet and disk space. Web tools may still send data online."
        case .cloud: "An online provider handles your requests and context. Its usage costs and data policies apply."
        case .both: "Keep local and online models as options. Your current model and automatic switching stay unchanged."
        }
    }
    func allowsCloud(isPrivate: Bool, explicitlyAllowedForPrivate: Bool = false) -> Bool {
        self != .local && (!isPrivate || explicitlyAllowedForPrivate)
    }
}
