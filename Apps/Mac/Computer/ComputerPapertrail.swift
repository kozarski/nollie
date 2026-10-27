#if os(macOS)
import Foundation
import NollieCore

/// Each time a bot used this Mac, one line in its Papertrail: which apps, how many actions and
/// looks, and that no picture of the screen left the Mac (the model that looked runs here). Never
/// what was on the screen, typed or clicked. Private bots keep no Papertrail.
@MainActor
enum ComputerPapertrail {
    struct Line: Encodable, Equatable {
        let bot: String
        let apps: [String]
        let actions: Int
        let looks: Int
    }

    static func line(for task: ComputerTask) -> Line {
        Line(bot: task.profile, apps: task.apps.map(\.name).prefix(8).map { String($0.prefix(60)) },
             actions: task.actions, looks: task.looks)
    }

    static func record(_ task: ComputerTask) {
        guard let runtime = AppModel.shared.runtime,
              !ComputerOtherControl.isPrivate(task.profile, connection: runtime.connection.id),
              let body = try? JSONEncoder().encode(line(for: task)) else { return }
        Task {
            _ = try? await runtime.api.raw("POST", "/api/plugins/nollie-workflow/papertrail/mac-session",
                                           body: (body, "application/json"), authenticated: true, timeout: 8)
        }
    }
}
#endif
