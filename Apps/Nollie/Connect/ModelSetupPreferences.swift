import Foundation

enum ModelSetupMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case local, cloud, both

    var id: String { rawValue }
    var title: String {
        switch self {
        case .local: String(localized: "On your Mac", comment: "Where the model runs, as a title")
        case .cloud: String(localized: "Online", comment: "Where the model runs")
        case .both: String(localized: "Both", comment: "The model runs on your Mac and online")
        }
    }
    var detail: String {
        switch self {
        case .local: String(localized: "The model runs on your Mac, or the computer hosting your assistant. Downloads need internet and disk space. Web tools may still send data online.")
        case .cloud: String(localized: "An online provider handles your requests and context. Its usage costs and data policies apply.")
        case .both: String(localized: "Keep local and online models as options. Your current model and automatic switching stay unchanged.")
        }
    }
    func allowsCloud(isPrivate: Bool, explicitlyAllowedForPrivate: Bool = false) -> Bool {
        self != .local && (!isPrivate || explicitlyAllowedForPrivate)
    }
}
