import SwiftUI
import NollieCore

/// One thing that can go wrong, and the checks to make for it, in order.
fileprivate struct Symptom: Identifiable {
    let id: String
    /// The few words on its row.
    let short: String
    let title: String
    let symbol: String
    let checks: [String]

    init(_ id: String, _ short: String, _ title: String, _ symbol: String, checks: [String]) {
        self.id = id
        self.short = short
        self.title = title
        self.symbol = symbol
        self.checks = checks
    }
}

/// Help for trouble with connecting, sign-in, the Companion or notifications. Symptoms are
/// listed as rows; each opens its checks in order, for people running their own gateway.
struct TroubleshootingView: View {
    private static let symptoms: [Symptom] = {
        let device = DeviceWords.this
        let mac = DeviceWords.isMac
        return [
            Symptom("connect", String(localized: "Can't connect"), String(localized: "The connection test stops"), "wifi.exclamationmark", checks: [
                String(localized: "Open the same URL in Safari on \(device). If the Hermes dashboard does not load there, the \(DeviceWords.kind) cannot reach the gateway and the app cannot either."),
                String(localized: "Use the dashboard's address (hermes serve, port 9119 unless you changed it), not a chat web UI or an SSH app."),
                String(localized: "At home or on a tailnet the address is plain http. Type http:// yourself if the form guessed https, or https:// if you put a certificate in front."),
                String(localized: "Tailscale: the Tailscale app on \(device) must be connected, and the gateway machine must be on the same tailnet."),
                String(localized: "Behind a reverse proxy: put the proxy's path in Path prefix (for example /hermes), and make sure the proxy passes WebSocket upgrades through."),
                String(localized: "Cloudflare Access: always https, with a service token. A browser login for Access cannot be used by the app."),
            ]),
            Symptom("signin", String(localized: "Sign-in fails"), String(localized: "Sign-in fails"), "person.badge.key", checks: [
                String(localized: "Sign in with browser needs a Hermes with native sign-in. If the app says the gateway lacks it, update Hermes on the gateway, or use a session token from the dashboard instead."),
                String(localized: "Nginx Proxy Manager with Block Common Exploits on used to reject the sign-in request; the app now encodes it fully. If a proxy still answers 403, check its rules for the /api path."),
                String(localized: "The browser closed without handing the app its code: the gateway's callback must reach \(device). A dashboard that only listens on the gateway machine cannot call back over the internet."),
                String(localized: "Username and password only works on a gateway that offers password sign-in. A browser-only gateway says so in the test; use the browser there."),
                String(localized: "Session token: copy HERMES_DASHBOARD_SESSION_TOKEN from the gateway's environment. It is refused when the gateway has its auth gate on."),
            ]),
            Symptom("companion", String(localized: "Companion won't install"), String(localized: "The Companion won't install or restart"),
                    "puzzlepiece.extension", checks: [
                String(localized: "Install writes files through the dashboard's file API. If it fails, the signed-in account needs permission to write under the profile's home."),
                String(localized: "Restart reports through the dashboard that is restarting, so its status often never comes back. The app watches for the Companion's first heartbeat instead; give it two minutes."),
                String(localized: "If the restart says the session expired, the app renews it once and tries again. If it still fails, sign in again from the card; if Settings › Advanced › Companion already shows it running, the restart happened."),
                String(localized: "After a restart, the gateway must be able to start the plugin: run hermes serve by hand once and read its output if the Companion never reports in."),
                String(localized: "Update the Companion from Settings › Advanced › Companion › Software Update whenever a build asks for it; old versions miss newer features."),
            ]),
            Symptom("push", String(localized: "No notifications"), String(localized: "No notifications"), "bell.slash", checks: [
                String(localized: "Settings › Advanced › Companion › This device must show the relay registered and the device file published. Register again if either is missing."),
                String(localized: "\(DeviceWords.settings) › Notifications › Nollie must allow alerts."),
                String(localized: "The Companion sends only for chats it mirrors: it attaches to running sessions when they start, so a turn already running when it was installed will not report."),
                String(localized: "Focus modes and Notification Summary hold alerts back; check the Focus that is on."),
                String(localized: "One device, one registration: signing in on a second one does not stop the first."),
            ]),
            Symptom("interrupted", String(localized: "A long task stopped"), String(localized: "A long task ends with \u{201C}Operation interrupted\u{201D}"),
                    "stop.circle", checks: [
                mac ? String(localized: "The gateway stops a turn when no app has been connected to its chat for a while. If your Mac sleeps or its network goes away, the connection ends.")
                    : String(localized: "The gateway stops a turn when no app has been connected to its chat for a while. iOS pauses Nollie soon after you leave it, and that ends the connection."),
                String(localized: "Update Hermes on the gateway machine with hermes update. Versions since September 2026 leave a turn that is still working alone and only stop one that has done nothing for ten minutes."),
                String(localized: "On an older Hermes, make it wait longer: Keep work running, on the interrupted turn's card. The dashboard service reads it when it starts, so restart it on the gateway machine afterwards."),
                String(localized: "\(AwayGrace.envKey) in the gateway's environment wins over that setting. If it is there (the Hermes dashboard lists it), change or remove it.",
                       comment: "Starts with the name of a setting in the gateway's environment; keep it as it is"),
                String(localized: "Stop, pressed in any app that has the chat open, ends the turn with the same words."),
                String(localized: "The chat is intact either way. Send a message such as \u{201C}continue\u{201D} and the bot carries on from what it had done."),
            ]),
            Symptom("approvals", String(localized: "No approval cards"), String(localized: "No approval cards"), "checkmark.shield", checks: [
                String(localized: "Settings › Advanced › Companion › This device › Approval requests says whether the gateway agreed to send them and how many arrived. \"Not acknowledged\" means an older Hermes: update it on the gateway."),
                String(localized: "Only actions the gateway's approval mode holds for a person reach \(device). In a mode that approves low-risk commands on its own, most turns never ask."),
                String(localized: "A card answered on another client (the dashboard, a terminal) disappears here too; the first answer wins."),
                mac ? String(localized: "With Confirm from notifications on, an Approve from a notification opens the chat and asks once more for risky actions. Settings › Privacy changes that.")
                    : String(localized: "With Confirm from the Lock Screen on, an Approve from a notification opens the chat and asks once more for risky actions. Settings › Privacy changes that."),
            ]),
        ]
    }()

    var body: some View {
        SettingsPage("troubleshooting.page") {
            PageHero(symbol: "wrench.and.screwdriver.fill", title: "What's wrong?", tint: .orange, id: "troubleshooting.hero")
            GlassStack {
                ForEach(Self.symptoms) { symptom in
                    GlassLink(.verbatim(symptom.short), symbol: symptom.symbol, id: "troubleshooting.\(symptom.id)") {
                        SymptomPage(symptom: symptom)
                    }
                }
            }
            PageNote("If a check fails, note what it says, then look at Status.")
        }
        .untitledPage()
    }
}

/// One symptom: what it looks like, then each check in order.
private struct SymptomPage: View {
    var symptom: Symptom

    var body: some View {
        SettingsPage("troubleshooting.topic") {
            PageHero(symbol: symptom.symbol, title: .verbatim(symptom.title), tint: .orange, id: "troubleshooting.topic.hero")
            VStack(alignment: .leading, spacing: 22) {
                ForEach(symptom.checks.indices, id: \.self) { CheckRow(number: $0 + 1, words: symptom.checks[$0]) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .untitledPage()
    }
}

/// A numbered check: the number in orange, then what to look at.
private struct CheckRow: View {
    var number: Int
    var words: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            Text("\(number)")
                .font(.title3.weight(.bold).monospacedDigit())
                .foregroundStyle(.orange)
                .frame(minWidth: 24, alignment: .trailing)
                .accessibilityHidden(true)
            Text(words)
                .font(.body)
                .foregroundStyle(Ink.text)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Check \(number). \(words)")
    }
}
