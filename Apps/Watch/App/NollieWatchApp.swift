import SwiftUI
import UserNotifications
import WatchKit

/// Nollie on Apple Watch: approvals to answer, the crew at work with Stop, and the last Night shift note. Everything goes
/// through the iPhone, which holds the link to the Mac.
@main
struct NollieWatchApp: App {
    @WKApplicationDelegateAdaptor private var delegate: WatchAppDelegate
    @Environment(\.scenePhase) private var phase
    private let model = WatchModel.shared

    var body: some Scene {
        WindowGroup {
            WatchHome()
                .environment(model)
                .task { model.start() }
        }
        .onChange(of: phase) { _, now in
            if now == .active { Task { await model.refresh() } }
        }
        // The phone's picture can arrive while the app is closed: keep it for the widgets.
        .backgroundTask(.watchConnectivity) {
            await model.settle()
        }
    }
}

/// The pages: each waiting approval, then the crew, then the last Night shift note when there is one.
struct WatchHome: View {
    @Environment(WatchModel.self) private var model

    var body: some View {
        @Bindable var model = model
        NavigationStack {
            TabView(selection: $model.page) {
                ForEach(model.snapshot?.approvals ?? []) { approval in
                    ApprovalPage(approval: approval)
                        .tag(approval.id)
                        .containerBackground(Color.orange.opacity(0.28).gradient, for: .tabView)
                }
                CrewPage()
                    .tag(WatchModel.crewPage)
                    .containerBackground(crewTint.gradient, for: .tabView)
                if let night = model.snapshot?.night {
                    NightPage(note: night)
                        .tag(WatchModel.nightPage)
                        .containerBackground((night.needsLook ? Color.orange : Color.indigo).opacity(0.24).gradient, for: .tabView)
                }
            }
            .tabViewStyle(.verticalPage)
            .navigationTitle("Nollie")
            .animation(.smooth, value: model.snapshot?.approvals.map(\.id))
        }
    }

    private var crewTint: Color {
        (model.snapshot?.helpers.isEmpty ?? true) ? Color.gray.opacity(0.2) : Color.green.opacity(0.22)
    }
}

/// Notifications on the Watch: the same categories as the iPhone's, sized for the wrist. Allow
/// once opens the card here, so the whole request is read before the yes; Deny goes straight
/// back through the phone and never asks for more; Stop opens the crew and stops.
@MainActor
final class WatchAppDelegate: NSObject, WKApplicationDelegate, UNUserNotificationCenterDelegate {
    func applicationDidFinishLaunching() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.setNotificationCategories(WatchNotificationCategories.all)
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let info = response.notification.request.content.userInfo
        let details = WatchWire.notificationDetails(info)
        let action = response.actionIdentifier
        await MainActor.run {
            let model = WatchModel.shared
            model.start()
            switch action {
            case WatchNotificationNames.denyAction:
                if let details { model.denyFromNotification(details) }
            case WatchNotificationNames.stopAction:
                model.stopFromControl()
            case WatchNotificationNames.approveOnceAction, UNNotificationDefaultActionIdentifier:
                model.open(card: [details?["card_id"], details?["request_id"]].compactMap { $0 })
            default:
                break
            }
        }
    }
}

enum WatchNotificationCategories {
    static var all: Set<UNNotificationCategory> {
        let allow = UNNotificationAction(identifier: WatchNotificationNames.approveOnceAction, title: WatchWords.allowOnce,
                                         options: [.foreground])
        let deny = UNNotificationAction(identifier: WatchNotificationNames.denyAction, title: WatchWords.deny,
                                        options: [.destructive])
        let stop = UNNotificationAction(identifier: WatchNotificationNames.stopAction, title: WatchWords.stop,
                                        options: [.foreground, .destructive])
        return [
            UNNotificationCategory(identifier: WatchNotificationNames.approvalCategory, actions: [allow, deny],
                                   intentIdentifiers: [], options: []),
            UNNotificationCategory(identifier: WatchNotificationNames.computerCategory, actions: [stop],
                                   intentIdentifiers: [], options: []),
        ]
    }
}
