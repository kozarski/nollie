import SwiftUI
import NollieCore

// MARK: - Two check marks

/// Shows two ticks: whether the plugin has been put on the gateway, and whether it runs.
struct CompanionStatusChecks: View {
    @Bindable var setup: PushSetupModel

    private enum Mark {
        case yes, no, unknown, trouble

        var symbol: String {
            switch self {
            case .yes: "checkmark.circle.fill"
            case .no: "xmark.circle"
            case .unknown: "questionmark.circle"
            case .trouble: "exclamationmark.triangle.fill"
            }
        }

        var colour: Color {
            switch self {
            case .yes: .green
            case .trouble: .orange
            default: .secondary
            }
        }
    }

    private var installedMark: Mark { setup.installedVersion == nil ? .no : .yes }

    private var runningMark: Mark {
        guard let beat = setup.heartbeat else { return .unknown }
        let age = Date().timeIntervalSince1970 - beat.updatedAt
        let recent = age <= PushSetupModel.heartbeatSeconds * 6
        return recent && beat.connected == true ? .yes : .trouble
    }

    var body: some View {
        check("Installed", installedMark, spoken: installedMark == .yes ? "Installed" : "Not installed")
        check("Running", runningMark, spoken: runningMark == .yes ? "Running" : "Not running")
    }

    private func check(_ title: String, _ mark: Mark, spoken: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Image(systemName: mark.symbol)
                .foregroundStyle(mark.colour)
                .accessibilityLabel(spoken)
        }
    }
}

// MARK: - Install state and the next step

/// One fact in a status line: a symbol and some words in a colour.
private struct Facet: View {
    let text: String
    let symbol: String
    let colour: Color

    var body: some View {
        // The icon and the first line of text share a baseline, however far the text wraps.
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: symbol).frame(width: 20)
            Text(text)
        }
        .foregroundStyle(colour)
    }
}

/// A title on the left and a value on the right, on plain stacks (a LabeledContent holding a Label
/// stretched each row to the screen's height).
private struct StatusLine<Value: View>: View {
    let title: String
    @ViewBuilder var value: () -> Value

    var body: some View {
        let trailing = value().multilineTextAlignment(.trailing)
        HStack(alignment: .top) {
            Text(title)
            Spacer(minLength: 12)
            trailing
        }
    }
}

/// Version installed, version running and how old the last heartbeat is, plus the one fix each state needs.
struct CompanionStatusRows: View {
    @Bindable var setup: PushSetupModel
    let runtime: GatewayRuntime
    var showInstall = true

    private var bundled: String { PushSetupModel.bundledPluginVersion }
    private var matchesBuild: Bool { setup.installedVersion == bundled && setup.installedScriptMatches }
    private var updateInFlight: Bool { setup.updating || setup.showUpdateConsole }
    private var showsUpdate: Bool { updateInFlight || setup.updateAvailable || setup.updateOutcome != nil }

    var body: some View {
        StatusLine(title: "Installed") { installed }
        StatusLine(title: "Running") { running }
        notes
        if showsUpdate {
            CompanionUpdateRows(setup: setup, runtime: runtime)
                .transition(.opacity)
        } else if setup.installedVersion != nil, showInstall {
            ReinstallBlock(setup: setup, runtime: runtime)
        }
        CheckNowButton(setup: setup, runtime: runtime)
    }

    // MARK: Notes under the rows

    @ViewBuilder private var notes: some View {
        if let beat = setup.heartbeat, beat.connected == false, let why = beat.error,
           why != "connecting…", !why.hasPrefix("reloading"),
           !updateInFlight, !setup.signInNeedsInstall, !setup.waitingForSignInHeartbeat {
            Text(why).note(.warning)
        }
        if let route = setup.heartbeat?.transport, !route.isEmpty {
            Text("Connected through \(route)").note()
        }
        if let problem = setup.companionCheckError { Text(problem).note(.problem) }
        if showInstall, matchesBuild, setup.needsRestart, !setup.updating {
            Text(staleWarning).note(.warning)
            MaintenanceButtons(runtime: runtime, compact: true, restartOnly: true)
        }
    }

    private var staleWarning: String {
        setup.runningOlderCode
            ? "The gateway is still running the previous companion code. Restart it to load what is on disk."
            : "The gateway is on an older companion. Restart it to load v\(bundled)."
    }

    // MARK: Installed

    @ViewBuilder private var installed: some View {
        if let version = setup.installedVersion {
            Facet(text: installedWords(version),
                  symbol: matchesBuild ? "checkmark.circle.fill" : "arrow.up.circle.fill",
                  colour: matchesBuild ? .green : .orange)
        } else if setup.checkingCompanion {
            ProgressView()
        } else {
            Facet(text: "Not installed", symbol: "xmark.circle", colour: .secondary)
        }
    }

    private func installedWords(_ version: String) -> String {
        if matchesBuild { return "v\(version) · matches this build" }
        if version == bundled { return "v\(version) · files differ from the ones in this build" }
        return "v\(version) · this build has v\(bundled)"
    }

    // MARK: Running

    @ViewBuilder private var running: some View {
        if let beat = setup.heartbeat {
            heartbeatFacet(beat)
        } else if setup.checkingCompanion {
            ProgressView()
        } else {
            Facet(text: "No heartbeat", symbol: "questionmark.circle", colour: .secondary)
        }
    }

    private func heartbeatFacet(_ beat: PushSetupModel.CompanionHeartbeat) -> Facet {
        let age = max(0, Date().timeIntervalSince1970 - beat.updatedAt)
        let ago = Duration.seconds(age).formatted(.units(width: .abbreviated, maximumUnitCount: 1))
        let version = "v" + beat.version
        if age > PushSetupModel.heartbeatSeconds * 6 {
            return Facet(text: "Stopped · last seen \(ago) ago (\(version))", symbol: "xmark.circle.fill", colour: .red)
        }
        if beat.connected == false {
            let state = beat.error == "connecting…" ? "connecting…" : "not connected"
            let older = setup.runningOlderCode ? " (older code)" : ""
            return Facet(text: "\(version)\(older) · \(state)", symbol: "exclamationmark.triangle.fill", colour: .orange)
        }
        if setup.runningOlderCode {
            return Facet(text: "\(version) · connected, but running older code · \(ago) ago",
                         symbol: "arrow.clockwise.circle.fill", colour: .orange)
        }
        let devices = beat.devices ?? 0
        let plural = devices == 1 ? "" : "s"
        return Facet(text: "\(version) · connected · \(devices) device\(plural) · \(ago) ago",
                     symbol: "checkmark.circle.fill", colour: .green)
    }
}

// MARK: - Reinstall

/// Puts the plugin on the gateway again, from this build, and says how it went.
private struct ReinstallBlock: View {
    let setup: PushSetupModel
    let runtime: GatewayRuntime

    var body: some View {
        BusyButton(title: "Reinstall plugin v\(PushSetupModel.bundledPluginVersion)", busyTitle: "Installing…",
                   symbol: "arrow.clockwise.circle", busy: setup.installingPlugin) {
            Task {
                await setup.installPlugin(runtime: runtime)
                await setup.checkCompanion(runtime: runtime)
            }
        }
        if let result = setup.pluginResult {
            Text(result).note(result.hasPrefix("Installed") ? .quiet : .problem)
        }
    }
}

// MARK: - Check now

/// Reads the companion again. The check is quick, so "Checking…" is held for a moment to show it
/// happened, and "Checked just now" stays for a few seconds after.
private struct CheckNowButton: View {
    let setup: PushSetupModel
    let runtime: GatewayRuntime
    @State private var holding = false
    @State private var justChecked = false

    private var busy: Bool { setup.checkingCompanion || holding }

    var body: some View {
        Button(action: check) { content }.disabled(busy)
    }

    @ViewBuilder private var content: some View {
        if busy {
            SpinnerLabel("Checking…")
        } else if justChecked {
            Label("Checked just now", systemImage: "checkmark.circle")
        } else if let last = setup.companionCheckedAt {
            Label("Check again (last \(last.formatted(date: .omitted, time: .shortened)))", systemImage: "arrow.triangle.2.circlepath")
        } else {
            Label("Check now", systemImage: "arrow.triangle.2.circlepath")
        }
    }

    private func check() {
        Task {
            holding = true
            async let finished: Void = setup.checkCompanion(runtime: runtime)
            try? await Task.sleep(nanoseconds: 900_000_000)
            await finished
            holding = false
            justChecked = true
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            justChecked = false
        }
    }
}
