#if os(macOS)
import AppKit
import SwiftUI

/// The answer buttons both cards end with: a refusal and a Touch ID approval, and on the
/// confirmation card a red Stop at the far left.
private struct ComputerAnswerRow: View {
    var allowTitle: String
    var stretch = false
    var stop: (() -> Void)? = nil
    var answer: (Bool) -> Void

    var body: some View {
        HStack(spacing: 10) {
            if let stop {
                Button("Stop", role: .destructive, action: stop)
                    .buttonStyle(.nollieGlass)
                    .tint(.red)
                    .foregroundStyle(.red)
                Spacer(minLength: 8)
            }
            Button { answer(false) } label: { widened(Text("Don't Allow")) }
                .buttonStyle(.nollieGlass)
                .keyboardShortcut(.cancelAction)
            Button { answer(true) } label: { widened(Label(allowTitle, systemImage: "touchid")) }
                .buttonStyle(.nollieGlassProminent)
        }
        .controlSize(.large)
        .buttonBorderShape(.capsule)
    }

    @ViewBuilder private func widened(_ label: some View) -> some View {
        if stretch { label.frame(maxWidth: .infinity) } else { label }
    }
}

/// "Scout wants to use your Mac": the apps, the bot's own words, the limits, and the answer.
///
/// This card is the boundary between a bot and the Mac. A bot's own tools run as the same user as
/// the add-on, so the process and Hermes checks before it are defence in depth only. What the
/// person sees here (the bot, the chat's title and platform as Hermes records them, every app)
/// and their Touch ID on Allow decide; see Docs/nollie-computer.md, "What keeps a bot in check".
struct ComputerApprovalCard: View {
    var approval: ComputerApproval
    var answer: (Bool) -> Void

    /// Which chat asked, as Hermes names it: a request can't borrow another chat's name.
    private var source: String {
        approval.platform.isEmpty ? approval.chatTitle : approval.chatTitle + " · " + approval.platform
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            heading
            apps
            // The one line safety needs: the limit, and that risky steps come back to the person.
            Text("Up to 30 minutes. Sending, buying, deleting and signing in ask you first.")
                .font(Ink.pill)
                .foregroundStyle(Ink.text3)
                .fixedSize(horizontal: false, vertical: true)
            ComputerAnswerRow(allowTitle: String(localized: "Allow", comment: "Safety: approval button, after Touch ID; lets the bot use the listed apps"),
                              stretch: true, answer: answer)
        }
        .padding(28)
        .frame(width: 400)
    }

    private var heading: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("\(approval.botName) wants to use your Mac")
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(Ink.text)
            Text(source).font(Ink.chip).foregroundStyle(Ink.text3).lineLimit(1)
            if !approval.request.purpose.isEmpty {
                // The bot's own words, quoted: Nollie hasn't checked them.
                Text("\u{201C}\(approval.request.purpose)\u{201D}")
                    .font(Ink.cardBody)
                    .foregroundStyle(Ink.text2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var apps: some View {
        VStack(spacing: 8) {
            ForEach(approval.apps, id: \.bundleID) { app in
                ComputerAppRow(bundleID: app.bundleID, name: app.name, note: app.viewOnly ? String(localized: "View only") : nil)
            }
            ForEach(approval.refused, id: \.self) { refused in
                ComputerAppRow(bundleID: "", name: refused.name,
                               note: refused.reason == ComputerPickedApps.notPicked(refused.name)
                                   ? String(localized: "Not picked", comment: "An app the person didn't pick for this Mac")
                                   : String(localized: "Not allowed", comment: "An app a bot may never use"),
                               dimmed: true)
                    .help(refused.shownReason)
            }
        }
    }
}

extension ComputerApproval.Refused {
    /// The reason in the person's language. `reason` itself is the English the bot's model gets.
    var shownReason: String {
        switch reason {
        case ComputerAppRules.nollie: String(localized: "Nollie can't use itself.")
        case ComputerAppRules.commands: String(localized: "Terminals and coding tools can run commands, so they stay with you.")
        case ComputerAppRules.passwords: String(localized: "Password managers stay with you.")
        case ComputerAppRules.settings: String(localized: "System Settings stays with you.")
        case ComputerAppRules.money: String(localized: "Money and crypto apps stay with you.")
        case ComputerAppRules.system: String(localized: "System tools and Finder can open or change anything, so they stay with you.")
        case ComputerAppRules.notOffered: String(localized: "Nollie doesn't offer this app yet.")
        case ComputerAppRules.notGenuine: String(localized: "This copy isn't signed by the app's maker, so it stays with you.")
        case ComputerAppRules.unidentified: String(localized: "This app can't be identified.")
        case ComputerCenter.notOnThisMac: String(localized: "Not on this Mac.")
        case ComputerPickedApps.notPicked(name): String(localized: "\(name) isn't one of the apps you picked for this Mac.")
        default: reason
        }
    }
}

/// One app on the approval card: a glass capsule with its icon, and a note when it has one.
struct ComputerAppRow: View {
    var bundleID: String
    var name: String
    var note: String?
    var dimmed = false

    var body: some View {
        HStack(spacing: 12) {
            ComputerAppIcon(bundleID: bundleID, size: 28).opacity(dimmed ? 0.45 : 1)
            Text(name).font(Ink.message.weight(.medium)).foregroundStyle(dimmed ? Ink.text3 : Ink.text)
            Spacer(minLength: 8)
            if let note { Text(note).font(Ink.chip).foregroundStyle(Ink.text2) }
        }
        .padding(EdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 18))
        .nollieGlass(in: .capsule)
        .accessibilityElement(children: .combine)
    }
}

/// "Scout wants to send something in Mail: click “Send”."
struct ComputerConfirmationCard: View {
    var confirmation: ComputerConfirmation
    var answer: (Bool) -> Void
    var stop: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            question
            ComputerAnswerRow(allowTitle: String(localized: "Allow Once", comment: "Safety: approval button, after Touch ID; allows this one step only"),
                              stop: stop, answer: answer)
        }
        .padding(28)
        .frame(width: 420)
    }

    private var question: some View {
        HStack(alignment: .top, spacing: 14) {
            warning
            words.padding(.top, 2)
        }
    }

    private var warning: some View {
        Image(systemName: "hand.raised.fill")
            .font(.system(size: 18))
            .foregroundStyle(Ink.warnText)
            .frame(square: 40)
            .background(Ink.warnFill, in: .circle)
    }

    private var words: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("\(confirmation.botName) wants to \(confirmation.sentence).")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Ink.text)
                .fixedSize(horizontal: false, vertical: true)
            if let check = confirmation.check {
                Text(check)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Ink.warnText)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("computer.confirm.check")
            }
        }
    }
}

/// The floating "Using Notes · Stop" capsule, on every Space while a bot uses the Mac.
struct ComputerStopPanelView: View {
    var task: ComputerTask
    var stop: () -> Void

    /// The app being used, or failing that the first one the task named.
    private var iconBundleID: String {
        let current = task.currentApp.flatMap { task.app(named: $0) }
        return (current ?? task.apps.first)?.bundleID ?? ""
    }

    var body: some View {
        HStack(spacing: 12) {
            ComputerAppIcon(bundleID: iconBundleID, size: 26)
            status
            Spacer(minLength: 10)
            stopButton
        }
        .padding(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 8))
        .frame(width: 280)
        .nollieGlass(in: .capsule)
    }

    private var status: some View {
        VStack(alignment: .leading, spacing: 1) {
            Group {
                if let current = task.currentApp { Text("Using \(current)") } else { Text("Using your Mac") }
            }
            .font(.system(size: 13.5, weight: .semibold))
            .foregroundStyle(Ink.text)
            .lineLimit(1)
            TimelineView(.periodic(from: .now, by: 30)) { tick in
                Text("\(task.botName) · \(Self.minutesLeft(task, at: tick.date))")
                    .font(.system(size: 12))
                    .foregroundStyle(Ink.text2)
                    .lineLimit(1)
            }
        }
    }

    // Drawn here, not by a system style: the panel never becomes the active window, and a system
    // button there would look disabled. Stop must always look ready.
    private var stopButton: some View {
        Button(action: stop) {
            Text("Stop")
                .font(.system(size: 13.5, weight: .semibold))
                .foregroundStyle(.white)
                .inset(h: 16, v: 7)
                .nollieGlass(.regular.tint(.red).interactive(), in: .capsule, solid: .red)
                .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .help("Stop (\(ComputerStopShortcut.label) from any app)")
        .accessibilityLabel("Stop \(task.botName) using your Mac")
        .accessibilityHint("Or press Control-Option-Command-Period in any app.")
    }

    static func minutesLeft(_ task: ComputerTask, at date: Date) -> String {
        let minutes = Int((task.expiresAt.timeIntervalSince(date) / 60).rounded(.up))
        return String(localized: "\(max(0, minutes)) min", comment: "Minutes left of a bot's use of the Mac")
    }
}

/// An app's own icon, or a "no" sign when there is no such app.
struct ComputerAppIcon: View {
    var bundleID: String
    var size: CGFloat = 24

    private var icon: NSImage? {
        guard !bundleID.isEmpty,
              let location = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        return NSWorkspace.shared.icon(forFile: location.path)
    }

    var body: some View {
        ZStack {
            if let icon {
                Image(nsImage: icon).resizable()
            } else {
                Image(systemName: "nosign").resizable().scaledToFit().padding(size * 0.2).foregroundStyle(Ink.text3)
            }
        }
        .frame(square: size)
        .accessibilityHidden(true)
    }
}

/// Nollie Computer's switch, app-wide and off until the person turns it on: Beta until a clean
/// account has been through it.
struct ComputerBetaToggle: View {
    @AppStorage(ComputerCenter.enabledKey) private var on = false

    var body: some View {
        Toggle(isOn: $on) {
            HStack(spacing: 8) {
                Label("Nollie Computer", systemImage: "macwindow.and.cursorarrow")
                betaTag
            }
        }
        .onChange(of: on) { _, enabled in
            if !enabled { ComputerCenter.shared.stop() }
            else { askForMacPermissionsIfNeeded() }
        }
        .accessibilityIdentifier("profile.computerBeta")
    }

    /// Turning it on is the moment to ask: Accessibility and Screen Recording are explained in one
    /// window now, not as a surprise on the first task. Nothing opens when both are already on.
    private func askForMacPermissionsIfNeeded() {
        let permissions = ComputerPermissions.shared
        permissions.refresh()
        if !permissions.allGranted { ComputerPanels.shared.showPermissions() }
    }

    private var betaTag: some View {
        Text("Beta")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
            .inset(h: 7, v: 2)
            .background(Capsule().strokeBorder(.secondary.opacity(0.5)))
    }
}
#endif
