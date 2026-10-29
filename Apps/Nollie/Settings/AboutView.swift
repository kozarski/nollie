import SwiftUI
import NollieCore

/// Settings › About › Remove: on the Direct Mac edition, everything Nollie set up on this Mac and
/// then the app itself; elsewhere, Nollie's data on this device. Both go through one plan.
struct ResetView: View {
    @State private var sheetOpen = false

    private var buttonWords: String {
        let onDirectMac = RemovalPlaces.thisDevice().edition == .macDirect
        return onDirectMac
            ? String(localized: "Remove Nollie from this Mac…", comment: "Safety: opens the remove sheet; keep exact meaning")
            : String(localized: "Remove Nollie's data…", comment: "Safety: opens the remove sheet; keep exact meaning")
    }

    var body: some View {
        SettingsPage("reset.page") {
            PageHero(symbol: "trash.circle.fill", title: "Remove Nollie", line: "See what goes before anything happens.",
                     tint: .red, id: "reset.hero")
            Button(role: .destructive) { sheetOpen = true } label: {
                PageActionLabel(.verbatim(buttonWords), symbol: "trash")
            }
            .pageAction(tint: .red)
            .testID("settings.remove")
        }
        .sheet(isPresented: $sheetOpen) { RemoveNollieSheet().withAppModel() }
        .untitledPage()
    }
}

/// The wordmark plus a single line saying what Nollie is.
private struct AboutMasthead: View {
    @ScaledMetric(relativeTo: .largeTitle) private var markHeight: CGFloat = 76

    var body: some View {
        VStack(spacing: 16) {
            NollieWordmark(height: markHeight).testID("about.wordmark")
            Text("Your own crew of helpers, on your Mac and iPhone.")
                .font(.title3)
                .foregroundStyle(Ink.text2)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 20)
    }
}

/// Settings › About: the wordmark and what Nollie is, the notices, Remove, and the version with
/// Developer Mode behind Advanced.
struct AboutView: View {
    #if DEBUG
    struct DemoStart: Identifiable { let id = UUID(); var value: String? }
    @State private var demoRemove: DemoStart?
    #endif

    var body: some View {
        SettingsPage("about.page") {
            AboutMasthead()
            #if os(macOS) && NOLLIE_DIRECT
            UpdateSettingsSection()
            #endif
            GlassStack {
                GlassLink("Acknowledgements", symbol: "heart.text.square", id: "about.acknowledgements") { AcknowledgementsView() }
                GlassLink("Diagnostics", symbol: "stethoscope", id: "about.diagnostics") { DiagnosticsView() }
                GlassLink("Remove Nollie", symbol: "trash", id: "about.remove") { ResetView() }
            }
            AdvancedLink(id: "about.advanced") { AboutAdvancedView() }
        }
        .untitledPage()
        #if DEBUG
        // For pictures: `-nollie-demo-remove review|working|finished` opens the Remove sheet.
        .sheet(item: $demoRemove) { RemoveNollieSheet(demoStart: $0.value).withAppModel() }
        .task {
            let words = ProcessInfo.processInfo.arguments
            guard DemoMode.isOn, let flag = words.firstIndex(of: "-nollie-demo-remove"), flag + 1 < words.count else { return }
            try? await Task.sleep(for: .seconds(1))
            let stage = words[flag + 1]
            demoRemove = DemoStart(value: stage == "review" ? nil : stage)
        }
        #endif
    }
}

/// About › Advanced: which copy of Nollie this is, and the switch that shows the technical side.
private struct AboutAdvancedView: View {
    @AppStorage("nollie.developerMode") private var developerMode = false

    /// "1.2 (34)", from the app's own info.
    private var versionWords: String {
        func entry(_ key: String) -> String { Bundle.main.infoDictionary?[key] as? String ?? "?" }
        return "\(entry("CFBundleShortVersionString")) (\(entry("CFBundleVersion")))"
    }

    var body: some View {
        SettingsPage("about.advanced.page") {
            PageHero(symbol: "info.circle.fill", title: "Version \(versionWords)", tint: .blue, id: "about.version")
            VStack(spacing: 14) {
                GlassSwitch("Developer Mode", isOn: $developerMode, id: "settings.developerMode")
                PageNote("Shows technical details across Nollie, and an Advanced area in Settings.")
            }
        }
        .untitledPage()
    }
}
